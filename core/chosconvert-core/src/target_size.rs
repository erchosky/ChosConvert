//! Target file size optimizer.
//!
//! Given a duration and a byte budget, compute audio/video bitrates, resolution and frame
//! rate that maximize quality while staying under the budget; then evaluate real outputs and
//! refine the bitrate when the result misses the acceptance window.
//!
//! Acceptance window: `MIN_FILL * target <= actual <= target`. Overshoot is never accepted
//! (sharing services enforce hard limits). At most `MAX_REFINEMENTS` extra encodes happen.

use serde::{Deserialize, Serialize};

use crate::error::{AppError, CoreResult, ErrorCode, Recovery};
use crate::formats::Format;

/// Fraction of the target aimed for on the first attempt (rate-control overshoot margin).
pub const SAFETY: f64 = 0.95;
/// Lowest acceptable fill ratio before trying a higher bitrate.
pub const MIN_FILL: f64 = 0.80;
pub const MAX_REFINEMENTS: u32 = 2;
/// Below this video bitrate the result is not worth producing.
pub const MIN_VIDEO_KBPS: u32 = 40;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VideoCodec {
    H264,
    Hevc,
    Av1,
    Vp9,
}

impl VideoCodec {
    /// Minimum bits per pixel per frame for a watchable result.
    pub fn min_bpp(self) -> f64 {
        match self {
            VideoCodec::H264 => 0.050,
            VideoCodec::Vp9 => 0.040,
            VideoCodec::Hevc => 0.035,
            VideoCodec::Av1 => 0.030,
        }
    }
    pub fn ffmpeg_name(self) -> &'static str {
        match self {
            VideoCodec::H264 => "h264",
            VideoCodec::Hevc => "hevc",
            VideoCodec::Av1 => "av1",
            VideoCodec::Vp9 => "vp9",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TargetSizeInput {
    pub duration_s: f64,
    pub target_bytes: u64,
    /// Display dimensions (after rotation).
    pub width: u32,
    pub height: u32,
    #[serde(default)]
    pub fps: Option<f64>,
    #[serde(default)]
    pub has_audio: bool,
    #[serde(default)]
    pub audio_channels: u32,
    pub codec: VideoCodec,
    pub container: Format,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TargetSizeBudget {
    pub target_bytes: u64,
    pub overhead_bytes: u64,
    pub audio_kbps: u32,
    pub audio_channels: u32,
    pub video_kbps: u32,
    pub width: u32,
    pub height: u32,
    /// Set when the frame rate is reduced to save bits.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fps: Option<f64>,
    pub estimated_bytes: u64,
    /// True when even the lowest sensible resolution is below the quality floor.
    pub low_quality: bool,
    pub attempt: u32,
}

fn even(v: f64) -> u32 {
    let v = v.round().max(2.0) as u32;
    v - (v % 2)
}

/// Scales (w, h) so the short side equals `short`, preserving aspect ratio, even dims.
pub fn scale_to_short_side(w: u32, h: u32, short: u32) -> (u32, u32) {
    if w == 0 || h == 0 {
        return (w, h);
    }
    if w <= h {
        let s = short as f64 / w as f64;
        (even(short as f64), even(h as f64 * s))
    } else {
        let s = short as f64 / h as f64;
        (even(w as f64 * s), even(short as f64))
    }
}

fn overhead_bytes(container: Format, duration_s: f64, fps: f64, has_audio: bool) -> u64 {
    let frames = duration_s * fps;
    let audio_packets = if has_audio {
        duration_s * 48_000.0 / 1024.0
    } else {
        0.0
    };
    let per_packet = match container {
        Format::Mkv | Format::Webm => 12.0,
        _ => 10.0, // mp4/mov sample tables (stsz/stco/stts) + chunk headers
    };
    (32_768.0 + (frames + audio_packets) * per_packet) as u64
}

fn audio_ladder(total_kbps: f64, channels: u32) -> (u32, u32) {
    let stereo = channels >= 2;
    let kbps = if total_kbps >= 3000.0 {
        160
    } else if total_kbps >= 1200.0 {
        128
    } else if total_kbps >= 600.0 {
        96
    } else if total_kbps >= 300.0 {
        64
    } else if total_kbps >= 150.0 {
        48
    } else {
        32
    };
    if !stereo || kbps <= 32 {
        // Mono for tiny budgets: halving channels beats starving the video.
        let mono = if stereo {
            kbps
        } else {
            (kbps as f64 * 0.6).round() as u32
        };
        (mono.max(24), 1)
    } else {
        (kbps, 2)
    }
}

/// Computes the encoding budget for the first attempt.
pub fn compute(input: &TargetSizeInput) -> CoreResult<TargetSizeBudget> {
    if !(input.duration_s.is_finite() && input.duration_s > 0.0) {
        return Err(AppError::new(
            ErrorCode::UnsupportedOperation,
            "This file's duration is unknown, so a target size can't be calculated.",
        ));
    }
    let src_fps = input
        .fps
        .filter(|f| *f > 0.0 && f.is_finite())
        .unwrap_or(30.0);
    let overhead = overhead_bytes(input.container, input.duration_s, src_fps, input.has_audio);
    let usable = input.target_bytes as f64 * SAFETY - overhead as f64;
    let unreachable = || {
        AppError::new(
            ErrorCode::TargetSizeUnreachable,
            "This target size is too small for a video this long.",
        )
        .with_recovery(&[Recovery::IncreaseTargetSize])
    };
    if usable <= 0.0 {
        return Err(unreachable());
    }
    let total_kbps = usable * 8.0 / input.duration_s / 1000.0;
    let (audio_kbps, audio_channels) = if input.has_audio {
        audio_ladder(total_kbps, input.audio_channels.max(1))
    } else {
        (0, 0)
    };
    let video_kbps_f = total_kbps - audio_kbps as f64;
    if video_kbps_f < MIN_VIDEO_KBPS as f64 {
        return Err(unreachable().with_details(format!(
            "video budget {video_kbps_f:.0} kbps < {MIN_VIDEO_KBPS} kbps"
        )));
    }
    let video_kbps = video_kbps_f.floor() as u32;

    // Frame rate: high-fps sources at modest bitrates look better at 30 fps.
    let fps = if src_fps > 30.5 && video_kbps < 2500 {
        Some(30.0)
    } else {
        None
    };
    let eff_fps = fps.unwrap_or(src_fps);

    let short_src = input.width.min(input.height);
    let mut ladder: Vec<u32> = [2160, 1440, 1080, 720, 540, 480, 360, 240]
        .into_iter()
        .filter(|s| *s < short_src)
        .collect();
    ladder.insert(0, short_src);
    let min_bpp = input.codec.min_bpp();
    let bps = video_kbps as f64 * 1000.0;
    let mut chosen = None;
    for short in &ladder {
        let (w, h) = scale_to_short_side(input.width, input.height, *short);
        let bpp = bps / (w as f64 * h as f64 * eff_fps);
        if bpp >= min_bpp {
            chosen = Some((w, h));
            break;
        }
    }
    let low_quality = chosen.is_none();
    let (width, height) = chosen.unwrap_or_else(|| {
        let floor = ladder
            .iter()
            .copied()
            .filter(|s| *s >= 240)
            .min()
            .unwrap_or(short_src);
        scale_to_short_side(input.width, input.height, floor)
    });

    let estimated =
        ((video_kbps + audio_kbps) as f64 * 1000.0 / 8.0 * input.duration_s) as u64 + overhead;
    Ok(TargetSizeBudget {
        target_bytes: input.target_bytes,
        overhead_bytes: overhead,
        audio_kbps,
        audio_channels,
        video_kbps,
        width,
        height,
        fps,
        estimated_bytes: estimated,
        low_quality,
        attempt: 1,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Accept,
    TooLarge,
    TooSmall,
}

pub fn evaluate(target_bytes: u64, actual_bytes: u64) -> Verdict {
    if actual_bytes > target_bytes {
        Verdict::TooLarge
    } else if (actual_bytes as f64) < target_bytes as f64 * MIN_FILL {
        Verdict::TooSmall
    } else {
        Verdict::Accept
    }
}

/// Produces the next budget after an attempt, or `None` when no further attempt is useful.
///
/// `history` holds `(video_kbps, actual_bytes)` for every attempt so far (including `prev`).
/// Encoders are not linear in bitrate, so once one attempt is over and one under the target,
/// the next bitrate is interpolated inside that bracket (secant step) instead of scaling the
/// last attempt, which would oscillate.
pub fn refine(
    prev: &TargetSizeBudget,
    duration_s: f64,
    actual_bytes: u64,
    history: &[(u32, u64)],
) -> Option<TargetSizeBudget> {
    if prev.attempt > MAX_REFINEMENTS {
        return None;
    }
    let verdict = evaluate(prev.target_bytes, actual_bytes);
    if verdict == Verdict::Accept {
        return None;
    }
    let target = prev.target_bytes as f64;
    let aim = target
        * if verdict == Verdict::TooLarge {
            0.95
        } else {
            0.93
        };

    let over = history
        .iter()
        .filter(|(_, s)| *s > prev.target_bytes)
        .min_by_key(|(_, s)| *s)
        .copied();
    let under = history
        .iter()
        .filter(|(_, s)| *s <= prev.target_bytes)
        .max_by_key(|(_, s)| *s)
        .copied();

    let video_kbps = match (over, under) {
        (Some((ko, so)), Some((ku, su))) if ko > ku && so > su => {
            if (ko - ku) as f64 <= ku as f64 * 0.02 {
                return None; // bracket exhausted
            }
            let k = ku as f64 + (aim - su as f64) * (ko - ku) as f64 / (so - su) as f64;
            // Stay strictly inside the bracket.
            let lo = ku as f64 + 1.0;
            let hi = ko as f64 - 1.0;
            k.clamp(lo, hi).floor() as u32
        }
        _ => {
            let audio_bytes = prev.audio_kbps as f64 * 1000.0 / 8.0 * duration_s;
            let actual_video = actual_bytes as f64 - audio_bytes - prev.overhead_bytes as f64;
            let desired_video = aim - audio_bytes - prev.overhead_bytes as f64;
            if actual_video <= 0.0 || desired_video <= 0.0 {
                return None;
            }
            let mut factor = desired_video / actual_video;
            if verdict == Verdict::TooSmall {
                factor = factor.min(1.6);
            }
            (prev.video_kbps as f64 * factor).floor() as u32
        }
    };
    if video_kbps < MIN_VIDEO_KBPS || video_kbps == prev.video_kbps {
        return None;
    }
    let mut next = prev.clone();
    next.video_kbps = video_kbps;
    next.attempt += 1;
    next.estimated_bytes = ((video_kbps + prev.audio_kbps) as f64 * 1000.0 / 8.0 * duration_s)
        as u64
        + prev.overhead_bytes;
    Some(next)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(duration: f64, target_mb: f64) -> TargetSizeInput {
        TargetSizeInput {
            duration_s: duration,
            target_bytes: (target_mb * 1_000_000.0) as u64,
            width: 3840,
            height: 2160,
            fps: Some(60.0),
            has_audio: true,
            audio_channels: 2,
            codec: VideoCodec::H264,
            container: Format::Mp4,
        }
    }

    #[test]
    fn budget_fits_under_target() {
        for (dur, mb) in [(30.0, 10.0), (120.0, 25.0), (600.0, 8.0), (5.0, 50.0)] {
            let b = compute(&input(dur, mb)).expect("budget");
            assert!(b.estimated_bytes < b.target_bytes, "{dur}s/{mb}MB: {b:?}");
            assert!(b.video_kbps >= MIN_VIDEO_KBPS);
            assert_eq!(b.width % 2, 0);
            assert_eq!(b.height % 2, 0);
            assert!(b.width >= b.height, "aspect preserved");
        }
    }

    #[test]
    fn small_budgets_reduce_resolution_and_fps() {
        let b = compute(&input(120.0, 10.0)).expect("budget");
        assert!(b.height < 2160);
        assert_eq!(b.fps, Some(30.0));
        let big = compute(&input(10.0, 100.0)).expect("budget");
        assert_eq!((big.width, big.height), (3840, 2160));
        assert_eq!(big.fps, None);
        assert_eq!(big.audio_kbps, 160);
    }

    #[test]
    fn portrait_stays_portrait() {
        let mut i = input(60.0, 10.0);
        i.width = 1080;
        i.height = 1920;
        let b = compute(&i).expect("budget");
        assert!(b.height > b.width);
    }

    #[test]
    fn impossible_targets_are_rejected() {
        let err = compute(&input(3600.0, 1.0)).expect_err("too small");
        assert_eq!(err.code, ErrorCode::TargetSizeUnreachable);
        let mut i = input(10.0, 10.0);
        i.duration_s = 0.0;
        assert!(compute(&i).is_err());
    }

    #[test]
    fn refinement_converges_and_terminates() {
        let i = input(100.0, 10.0);
        let mut b = compute(&i).expect("budget");
        // Encoder overshoots by 15% each time relative to requested bitrate.
        let mut attempts = 1;
        let mut history = Vec::new();
        loop {
            let actual = (b.estimated_bytes as f64 * 1.15) as u64;
            history.push((b.video_kbps, actual));
            match evaluate(b.target_bytes, actual) {
                Verdict::Accept => break,
                _ => match refine(&b, i.duration_s, actual, &history) {
                    Some(n) => {
                        b = n;
                        attempts += 1;
                    }
                    None => break,
                },
            }
        }
        assert!(attempts <= 1 + MAX_REFINEMENTS);
        let final_actual = (b.estimated_bytes as f64 * 1.15) as u64;
        assert!(
            final_actual <= b.target_bytes,
            "{final_actual} > {}",
            b.target_bytes
        );
    }

    #[test]
    fn nonlinear_encoder_is_bracketed_not_oscillating() {
        // Size responds super-linearly to bitrate (like x264 on noisy content).
        let size_for = |kbps: u32| (kbps as f64).powf(1.6) * 70.0;
        let i = input(12.0, 2.0);
        let mut b = compute(&i).expect("budget");
        let mut history = Vec::new();
        let mut accepted = false;
        for _ in 0..=MAX_REFINEMENTS {
            let actual = size_for(b.video_kbps) as u64;
            history.push((b.video_kbps, actual));
            if evaluate(b.target_bytes, actual) == Verdict::Accept {
                accepted = true;
                break;
            }
            match refine(&b, i.duration_s, actual, &history) {
                Some(n) => b = n,
                None => break,
            }
        }
        let best_under = history
            .iter()
            .filter(|(_, s)| *s <= b.target_bytes)
            .map(|(_, s)| *s)
            .max();
        assert!(accepted || best_under.is_some(), "{history:?}");
    }

    #[test]
    fn evaluate_window() {
        assert_eq!(evaluate(100, 101), Verdict::TooLarge);
        assert_eq!(evaluate(100, 100), Verdict::Accept);
        assert_eq!(evaluate(100, 80), Verdict::Accept);
        assert_eq!(evaluate(100, 79), Verdict::TooSmall);
    }

    #[test]
    fn scale_helper() {
        assert_eq!(scale_to_short_side(3840, 2160, 1080), (1920, 1080));
        assert_eq!(scale_to_short_side(1080, 1920, 720), (720, 1280));
        assert_eq!(scale_to_short_side(1001, 1000, 720), (720, 720));
    }
}
