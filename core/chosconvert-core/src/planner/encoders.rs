//! Encoder selection and per-encoder rate-control arguments.

use serde::{Deserialize, Serialize};

use super::QualityLevel;
use crate::capabilities::{Capabilities, Os};
use crate::target_size::VideoCodec;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(tag = "mode", content = "name", rename_all = "snake_case")]
pub enum EncoderChoice {
    #[default]
    Auto,
    Hardware,
    Software,
    Specific(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SelectedEncoder {
    pub name: String,
    pub codec: VideoCodec,
    pub hardware: bool,
}

fn hardware_candidates(codec: VideoCodec, os: Os) -> &'static [&'static str] {
    match (codec, os) {
        (VideoCodec::H264, Os::Macos) => &["h264_videotoolbox"],
        (VideoCodec::Hevc, Os::Macos) => &["hevc_videotoolbox"],
        (VideoCodec::Av1, Os::Macos) => &[],
        (VideoCodec::Vp9, Os::Macos) => &[],
        (VideoCodec::H264, _) => &["h264_nvenc", "h264_qsv", "h264_amf", "h264_mf"],
        (VideoCodec::Hevc, _) => &["hevc_nvenc", "hevc_qsv", "hevc_amf", "hevc_mf"],
        (VideoCodec::Av1, _) => &["av1_nvenc", "av1_qsv", "av1_amf"],
        (VideoCodec::Vp9, _) => &["vp9_qsv"],
    }
}

fn software_candidates(codec: VideoCodec) -> &'static [&'static str] {
    match codec {
        VideoCodec::H264 => &["libx264", "libopenh264"],
        VideoCodec::Hevc => &["libx265"],
        VideoCodec::Av1 => &["libsvtav1", "libaom-av1"],
        VideoCodec::Vp9 => &["libvpx-vp9"],
    }
}

/// Picks an available encoder for `codec`. With `Auto`, hardware is preferred unless
/// `prefer_software` (e.g. precise two-pass target-size encodes).
pub fn select_video(
    caps: &Capabilities,
    codec: VideoCodec,
    choice: &EncoderChoice,
    prefer_software: bool,
) -> Option<SelectedEncoder> {
    let ff = caps.ffmpeg()?;
    let os = caps.platform.os;
    let pick = |names: &[&str], hardware: bool| {
        names
            .iter()
            .find(|n| ff.has_encoder(n))
            .map(|n| SelectedEncoder {
                name: (*n).to_string(),
                codec,
                hardware,
            })
    };
    match choice {
        EncoderChoice::Specific(name) => ff
            .encoders
            .iter()
            .find(|e| &e.name == name && e.codec == codec.ffmpeg_name())
            .map(|e| SelectedEncoder {
                name: e.name.clone(),
                codec,
                hardware: e.hardware,
            }),
        EncoderChoice::Hardware => pick(hardware_candidates(codec, os), true),
        EncoderChoice::Software => pick(software_candidates(codec), false),
        EncoderChoice::Auto if prefer_software => pick(software_candidates(codec), false)
            .or_else(|| pick(hardware_candidates(codec, os), true)),
        EncoderChoice::Auto => pick(hardware_candidates(codec, os), true)
            .or_else(|| pick(software_candidates(codec), false)),
    }
}

pub fn software_alternative(caps: &Capabilities, codec: VideoCodec) -> Option<SelectedEncoder> {
    select_video(caps, codec, &EncoderChoice::Software, true)
}

/// Whether VideoToolbox constant-quality (`-q:v`) is available (Apple Silicon only).
fn vt_constant_quality(caps: &Capabilities) -> bool {
    caps.platform.os == Os::Macos && caps.platform.arch == "arm64"
}

/// Reference bits-per-pixel for bitrate-driven encoders at each quality level.
fn reference_bpp(codec: VideoCodec, level: QualityLevel) -> f64 {
    let base = match level {
        QualityLevel::Smaller => 0.055,
        QualityLevel::Balanced => 0.09,
        QualityLevel::High => 0.14,
    };
    match codec {
        VideoCodec::H264 => base,
        VideoCodec::Vp9 => base * 0.75,
        VideoCodec::Hevc => base * 0.65,
        VideoCodec::Av1 => base * 0.55,
    }
}

/// Typical bitrate for a level, used by bitrate-only encoders and for estimates.
pub fn reference_kbps(codec: VideoCodec, level: QualityLevel, w: u32, h: u32, fps: f64) -> u32 {
    let bps = reference_bpp(codec, level) * w as f64 * h as f64 * fps.max(1.0);
    (bps / 1000.0).round().clamp(150.0, 120_000.0) as u32
}

/// Quality-driven rate control arguments.
pub fn quality_args(
    caps: &Capabilities,
    enc: &SelectedEncoder,
    level: QualityLevel,
    crf: Option<u32>,
    dims: (u32, u32, f64),
) -> Vec<String> {
    let pick = |s: u32, b: u32, h: u32| {
        crf.unwrap_or(match level {
            QualityLevel::Smaller => s,
            QualityLevel::Balanced => b,
            QualityLevel::High => h,
        })
        .to_string()
    };
    let v = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    let mut args = match enc.name.as_str() {
        "libx264" => {
            let mut a = v(&["-crf"]);
            a.push(pick(28, 23, 19));
            a.extend(v(&["-preset", "medium"]));
            a
        }
        "libx265" => {
            let mut a = v(&["-crf"]);
            a.push(pick(30, 26, 22));
            a.extend(v(&["-preset", "medium"]));
            a
        }
        "libsvtav1" => {
            let mut a = v(&["-crf"]);
            a.push(pick(40, 34, 28));
            a.extend(v(&["-preset", "8"]));
            a
        }
        "libaom-av1" => {
            let mut a = v(&["-crf"]);
            a.push(pick(38, 32, 26));
            a.extend(v(&["-b:v", "0", "-cpu-used", "6", "-row-mt", "1"]));
            a
        }
        "libvpx-vp9" => {
            let mut a = v(&["-crf"]);
            a.push(pick(38, 32, 26));
            a.extend(v(&[
                "-b:v",
                "0",
                "-row-mt",
                "1",
                "-deadline",
                "good",
                "-cpu-used",
                "4",
            ]));
            a
        }
        "h264_videotoolbox" | "hevc_videotoolbox" if vt_constant_quality(caps) => {
            let mut a = v(&["-q:v"]);
            a.push(pick(48, 58, 68));
            a
        }
        n if n.ends_with("_nvenc") => {
            let mut a = v(&["-rc", "vbr", "-cq"]);
            a.push(pick(32, 26, 21));
            a.extend(v(&["-b:v", "0", "-preset", "p5"]));
            a
        }
        n if n.ends_with("_qsv") => {
            let mut a = v(&["-global_quality"]);
            a.push(pick(30, 25, 21));
            a
        }
        _ => {
            // Bitrate-only encoders (x86 VideoToolbox, AMF, MediaFoundation, openh264).
            let (w, h, fps) = dims;
            let kbps = reference_kbps(enc.codec, level, w, h, fps);
            bitrate_args(enc, kbps, None)
        }
    };
    if enc.name.starts_with("libsvtav1") && crf.is_none() && level == QualityLevel::Smaller {
        args.extend(v(&["-svtav1-params", "tune=0"]));
    }
    args
}

/// Bitrate-driven rate control. `pass` is Some(1|2) for two-pass encodes.
pub fn bitrate_args(enc: &SelectedEncoder, kbps: u32, pass: Option<u8>) -> Vec<String> {
    let mut a = vec!["-b:v".to_string(), format!("{kbps}k")];
    match enc.name.as_str() {
        "libx264" | "libvpx-vp9" => {
            if enc.name == "libx264" {
                a.extend(["-preset".into(), "medium".into()]);
            } else {
                a.extend([
                    "-row-mt".into(),
                    "1".into(),
                    "-deadline".into(),
                    "good".into(),
                ]);
            }
            if let Some(p) = pass {
                a.extend([
                    "-pass".into(),
                    p.to_string(),
                    "-passlogfile".into(),
                    crate::ffmpeg::PASSLOG.into(),
                ]);
            }
        }
        "libx265" => a.extend(["-preset".into(), "medium".into()]),
        "libsvtav1" => a.extend(["-preset".into(), "8".into()]),
        n if n.ends_with("_videotoolbox") => {
            // Constrain peaks so VideoToolbox's ABR stays close to the budget.
            a.extend([
                "-maxrate".into(),
                format!("{}k", (kbps as f64 * 1.5) as u32),
                "-bufsize".into(),
                format!("{}k", kbps * 2),
            ]);
        }
        _ => {}
    }
    a
}

/// Whether an encoder supports FFmpeg's generic two-pass mode.
pub fn supports_two_pass(enc: &SelectedEncoder) -> bool {
    matches!(enc.name.as_str(), "libx264" | "libvpx-vp9")
}

/// Container tag / profile arguments needed for broad playback compatibility.
pub fn compat_args(enc: &SelectedEncoder, ten_bit: bool, mp4_family: bool) -> Vec<String> {
    let mut a: Vec<String> = Vec::new();
    match enc.codec {
        VideoCodec::Hevc => {
            if mp4_family {
                a.extend(["-tag:v".into(), "hvc1".into()]);
            }
            if ten_bit {
                if enc.name == "hevc_videotoolbox" {
                    a.extend([
                        "-profile:v".into(),
                        "main10".into(),
                        "-pix_fmt".into(),
                        "p010le".into(),
                    ]);
                } else if enc.name == "libx265" {
                    a.extend(["-pix_fmt".into(), "yuv420p10le".into()]);
                }
            } else if enc.name == "libx265" {
                a.extend(["-pix_fmt".into(), "yuv420p".into()]);
            }
        }
        VideoCodec::H264 => {
            // 8-bit 4:2:0 is the only universally playable H.264 flavour.
            if enc.name == "h264_videotoolbox" {
                a.extend(["-pix_fmt".into(), "nv12".into()]);
            } else {
                a.extend(["-pix_fmt".into(), "yuv420p".into()]);
            }
        }
        VideoCodec::Av1 | VideoCodec::Vp9 => {
            a.extend([
                "-pix_fmt".into(),
                if ten_bit { "yuv420p10le" } else { "yuv420p" }.into(),
            ]);
        }
    }
    a
}

/// Picks an FFmpeg audio encoder for a codec, preferring the platform implementation.
pub fn select_audio(caps: &Capabilities, codec: &str) -> Option<&'static str> {
    let ff = caps.ffmpeg()?;
    let candidates: &[&'static str] = match codec {
        "aac" => &["aac_at", "aac", "libfdk_aac"],
        "mp3" => &["libmp3lame"],
        "opus" => &["libopus"],
        "vorbis" => &["libvorbis"],
        "flac" => &["flac"],
        "alac" => &["alac_at", "alac"],
        "pcm_s16le" => &["pcm_s16le"],
        "pcm_s24le" => &["pcm_s24le"],
        "pcm_s16be" => &["pcm_s16be"],
        "pcm_s24be" => &["pcm_s24be"],
        _ => &[],
    };
    candidates
        .iter()
        .copied()
        // libfdk_aac is nonfree: never selected even if present.
        .filter(|n| *n != "libfdk_aac")
        .find(|n| ff.has_encoder(n))
}
