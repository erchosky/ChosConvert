//! Planning for audio/video inputs (FFmpeg engine, with native fallbacks).

use super::encoders::{
    EncoderChoice, SelectedEncoder, bitrate_args, compat_args, quality_args, reference_kbps,
    select_audio, select_video, software_alternative, supports_two_pass,
};
use super::{
    ConversionPlan, EngineKind, EstimateConfidence, FfmpegJob, FfmpegPass, Intent, MetadataScope,
    PlanNote, PlanRequest, PlanStep, QualityLevel, SizeEstimate, VerifySpec, engine_missing,
    native_av, unsupported,
};
use crate::capabilities::{Capabilities, Os};
use crate::error::CoreResult;
use crate::ffmpeg::{INPUT, NULL, OUTPUT};
use crate::formats::{Family, Format};
use crate::media::{AudioStream, MediaInfo, SubtitleStream, VideoStream};
use crate::target_size::{
    self, TargetSizeBudget, TargetSizeInput, VideoCodec, scale_to_short_side,
};

fn s(v: &str) -> String {
    v.to_string()
}

fn base_args() -> Vec<String> {
    [
        "-hide_banner",
        "-nostdin",
        "-loglevel",
        "error",
        "-progress",
        "pipe:1",
        "-nostats",
        "-n",
    ]
    .iter()
    .map(|a| s(a))
    .collect()
}

fn muxer(f: Format) -> &'static str {
    match f {
        Format::Mp4 => "mp4",
        Format::Mov => "mov",
        Format::Mkv => "matroska",
        Format::Webm => "webm",
        Format::Avi => "avi",
        Format::M4a => "ipod",
        Format::Mp3 => "mp3",
        Format::Wav => "wav",
        Format::Flac => "flac",
        Format::Ogg => "ogg",
        Format::Opus => "opus",
        Format::Aiff => "aiff",
        Format::Gif => "gif",
        Format::Caf => "caf",
        Format::Aac => "adts",
        _ => "null",
    }
}

fn is_mp4_family(f: Format) -> bool {
    matches!(f, Format::Mp4 | Format::Mov | Format::M4a)
}

pub(crate) fn video_ok_in(container: Format, codec: &str) -> bool {
    match container {
        Format::Mp4 => matches!(codec, "h264" | "hevc" | "av1" | "mpeg4"),
        Format::Mov => matches!(codec, "h264" | "hevc" | "prores" | "mjpeg" | "mpeg4"),
        Format::Mkv => !matches!(codec, "unknown"),
        Format::Webm => matches!(codec, "vp8" | "vp9" | "av1"),
        Format::Avi => matches!(codec, "mpeg4" | "h264" | "mjpeg"),
        _ => false,
    }
}

pub(crate) fn audio_ok_in(container: Format, codec: &str) -> bool {
    let pcm = codec.starts_with("pcm_");
    match container {
        Format::Mp4 => matches!(codec, "aac" | "alac" | "mp3" | "ac3" | "eac3"),
        Format::M4a => matches!(codec, "aac" | "alac"),
        Format::Mov => matches!(codec, "aac" | "alac" | "mp3" | "ac3" | "eac3") || pcm,
        Format::Mkv => !matches!(codec, "unknown"),
        Format::Webm => matches!(codec, "opus" | "vorbis"),
        Format::Mp3 => codec == "mp3",
        Format::Flac => codec == "flac",
        Format::Opus => codec == "opus",
        Format::Ogg => matches!(codec, "vorbis" | "opus" | "flac"),
        Format::Wav => matches!(
            codec,
            "pcm_s16le" | "pcm_s24le" | "pcm_s32le" | "pcm_f32le" | "pcm_u8"
        ),
        Format::Aiff => matches!(codec, "pcm_s16be" | "pcm_s24be" | "pcm_s32be"),
        Format::Aac => codec == "aac",
        Format::Caf => true,
        Format::Avi => matches!(codec, "mp3" | "ac3") || pcm,
        _ => false,
    }
}

fn is_text_sub(codec: &str) -> bool {
    matches!(
        codec,
        "subrip" | "srt" | "ass" | "ssa" | "webvtt" | "mov_text" | "text"
    )
}

/// Returns the subtitle codec to use in `container`, or None to drop the stream.
fn subtitle_codec_for(container: Format, sub: &SubtitleStream) -> Option<&'static str> {
    match container {
        Format::Mp4 | Format::Mov if is_text_sub(&sub.codec) => Some("mov_text"),
        Format::Mkv => Some("copy"),
        Format::Webm if is_text_sub(&sub.codec) => Some("webvtt"),
        _ => None,
    }
}

/// The native media engine on macOS can read these containers.
fn native_av_readable(f: Format) -> bool {
    matches!(
        f,
        Format::Mov
            | Format::Mp4
            | Format::M4a
            | Format::Wav
            | Format::Aiff
            | Format::Caf
            | Format::Mp3
            | Format::Aac
    )
}

fn default_video_codec(caps: &Capabilities) -> VideoCodec {
    // HEVC halves sizes and is universally playable on Apple platforms; Windows needs a
    // paid extension for HEVC playback, so H.264 is the safer default there.
    if caps.platform.os == Os::Macos {
        VideoCodec::Hevc
    } else {
        VideoCodec::H264
    }
}

struct VideoCtx<'a> {
    req: &'a PlanRequest,
    info: &'a MediaInfo,
    video: &'a VideoStream,
    caps: &'a Capabilities,
}

pub fn plan(req: &PlanRequest, budget: Option<&TargetSizeBudget>) -> CoreResult<ConversionPlan> {
    let info = &req.input;
    let force = req.engine_override;
    let ff_ok = req.capabilities.ffmpeg().is_some() && force != Some(EngineKind::NativeAv);
    let native_ok = req.capabilities.native_av.available
        && native_av_readable(info.detection.format)
        && force != Some(EngineKind::Ffmpeg);

    if !ff_ok {
        if native_ok {
            return native_av::plan(req);
        }
        return Err(engine_missing());
    }

    match (&req.intent, info.family) {
        (Intent::MakeSmaller { level }, Family::Video) => video_encode(req, *level, None, None),
        (Intent::MakeSmaller { level }, Family::Audio) => audio_make_smaller(req, *level),
        (Intent::Convert { format }, Family::Video) if format.family() == Family::Video => {
            video_convert(req, *format)
        }
        (Intent::Convert { format }, Family::Video) if *format == Format::Gif => {
            gif(req, 0.0, 6.0, 480, 12)
        }
        (Intent::Convert { format }, _) if format.family() == Family::Audio => {
            audio_convert(req, *format, info.family == Family::Video)
        }
        (Intent::ExtractAudio { format }, Family::Video) => extract_audio(req, *format),
        (Intent::RemoveMetadata { scope }, _) => remove_metadata(req, *scope),
        (Intent::TargetSize { target_bytes }, Family::Video) => {
            video_target_size(req, *target_bytes, budget)
        }
        (Intent::TargetSize { target_bytes }, Family::Audio) => {
            audio_target_size(req, *target_bytes)
        }
        (Intent::Resize { max_dimension }, Family::Video) => {
            video_encode(req, QualityLevel::High, Some(*max_dimension), None)
        }
        (Intent::WebOptimize, Family::Video) => video_encode(
            req,
            QualityLevel::Balanced,
            Some(1080),
            Some(VideoCodec::H264),
        ),
        (
            Intent::CreateGif {
                start_s,
                duration_s,
                width,
                fps,
            },
            Family::Video,
        ) => gif(req, *start_s, *duration_s, *width, *fps),
        _ => Err(unsupported("This action isn't available for this file.")),
    }
}

fn primary_video(info: &MediaInfo) -> CoreResult<&VideoStream> {
    info.primary_video()
        .ok_or_else(|| unsupported("This file doesn't contain a video track."))
}

fn overhead_estimate(duration: f64) -> f64 {
    32_768.0 + duration * 80.0 * 10.0
}

fn ensure_video_container(f: Format) -> CoreResult<Format> {
    if f.family() == Family::Video {
        Ok(f)
    } else {
        Err(unsupported("That container can't hold video."))
    }
}

/// Builds a full video encode (make smaller / resize / web optimize).
fn video_encode(
    req: &PlanRequest,
    level: QualityLevel,
    max_short_side: Option<u32>,
    codec_override: Option<VideoCodec>,
) -> CoreResult<ConversionPlan> {
    let info = &req.input;
    let video = primary_video(info)?;
    let caps = &req.capabilities;
    let opts = &req.options;
    let ctx = VideoCtx {
        req,
        info,
        video,
        caps,
    };
    let container = ensure_video_container(opts.container.unwrap_or(Format::Mp4))?;
    let mut notes = Vec::new();

    let mut codec = opts
        .video_codec
        .or(codec_override)
        .unwrap_or_else(|| default_video_codec(caps));
    if video.hdr
        && codec == VideoCodec::H264
        && opts.video_codec.is_none()
        && codec_override.is_none()
    {
        codec = VideoCodec::Hevc;
    }
    if video.hdr {
        notes.push(PlanNote::new(if codec == VideoCodec::H264 {
            "hdr_to_sdr_without_tonemap"
        } else {
            "hdr_preserved"
        }));
    }
    if container == Format::Webm && !matches!(codec, VideoCodec::Vp9 | VideoCodec::Av1) {
        codec = VideoCodec::Vp9;
    }

    let choice = opts.encoder.clone().unwrap_or_default();
    let enc = select_video(caps, codec, &choice, false)
        .or_else(|| {
            // Requested codec unavailable: fall back to H.264, which every build has.
            notes.push(PlanNote::with(
                "codec_unavailable_fallback",
                &[s(codec.ffmpeg_name())],
            ));
            select_video(caps, VideoCodec::H264, &EncoderChoice::Auto, false)
        })
        .ok_or_else(engine_missing)?;

    // Resolution
    let (dw, dh) = video.display_size();
    let level_cap = match level {
        QualityLevel::Smaller => Some(1080),
        _ => None,
    };
    let cap = opts.max_short_side.or(max_short_side).or(level_cap);
    let short = dw.min(dh);
    let dims = match cap {
        Some(c) if c < short => Some(scale_to_short_side(dw, dh, c)),
        _ => None,
    };
    let src_fps = video.fps.unwrap_or(30.0);
    let fps = opts.fps.filter(|f| *f > 0.0 && *f < src_fps);

    let build = |enc: &SelectedEncoder| -> FfmpegJob {
        let (w, h) = dims.unwrap_or((dw, dh));
        let mut a = base_args();
        a.extend([s("-i"), s(INPUT)]);
        a.extend(map_video_and_audio(
            &ctx,
            container,
            opts.remove_audio.unwrap_or(false),
        ));
        a.extend([s("-c:v"), enc.name.clone()]);
        let rate = match opts.video_kbps {
            Some(k) => bitrate_args(enc, k, None),
            None => quality_args(caps, enc, level, opts.crf, (w, h, fps.unwrap_or(src_fps))),
        };
        a.extend(rate);
        let ten_bit = video.bit_depth.unwrap_or(8) > 8 && codec != VideoCodec::H264;
        a.extend(compat_args(
            enc,
            ten_bit && video.hdr || ten_bit,
            is_mp4_family(container),
        ));
        a.extend(color_args(video));
        let mut filters = Vec::new();
        if let Some((w, h)) = dims {
            filters.push(format!("scale={w}:{h}:flags=lanczos"));
        }
        if let Some(f) = fps {
            filters.push(format!("fps={f}"));
        }
        if !filters.is_empty() {
            a.extend([s("-vf"), filters.join(",")]);
        }
        a.extend(audio_args_for_video(&ctx, container, level, false));
        a.extend(metadata_args(opts.strip_metadata.unwrap_or(false)));
        a.extend(container_args(container));
        a.extend([s("-f"), s(muxer(container)), s(OUTPUT)]);
        FfmpegJob {
            passes: vec![FfmpegPass { args: a }],
            duration_s: info.duration_s,
            video_encoder: Some(enc.name.clone()),
            hardware: enc.hardware,
            fallback: None,
        }
    };

    let mut job = build(&enc);
    if enc.hardware {
        if let Some(sw) = software_alternative(caps, enc.codec)
            .or_else(|| software_alternative(caps, VideoCodec::H264))
        {
            job.fallback = Some(Box::new(build(&sw)));
        }
    }

    let mut steps = vec![PlanStep::Inspect, PlanStep::TranscodeVideo];
    if dims.is_some() {
        steps.push(PlanStep::Scale);
    }
    if fps.is_some() {
        steps.push(PlanStep::ReduceFrameRate);
    }
    steps.push(audio_step(&ctx, container, level));
    if opts.strip_metadata.unwrap_or(false) {
        steps.push(PlanStep::StripMetadata);
    }
    steps.extend([PlanStep::Verify, PlanStep::Finalize]);
    notes.extend(dropped_stream_notes(&ctx, container));

    let duration = info.duration_s.unwrap_or(0.0);
    let estimate = (duration > 0.0).then(|| {
        let (w, h) = dims.unwrap_or((dw, dh));
        let mut vk = opts
            .video_kbps
            .unwrap_or_else(|| reference_kbps(enc.codec, level, w, h, fps.unwrap_or(src_fps)))
            as f64;
        if let Some(src) = video.bit_rate.or(info.bit_rate) {
            vk = vk.min(src as f64 / 1000.0 * 0.9);
        }
        let ak = if info.audio.is_empty() {
            0.0
        } else {
            level_audio_kbps(level) as f64
        };
        let bytes = (vk + ak) * 1000.0 / 8.0 * duration + overhead_estimate(duration);
        SizeEstimate::around(bytes, 0.45, EstimateConfidence::Low)
    });

    let must_be_smaller =
        matches!(req.intent, Intent::MakeSmaller { .. }).then_some(info.size_bytes);
    if let (Some(limit), Some(est)) = (must_be_smaller, estimate.as_ref()) {
        if est.bytes as f64 > limit as f64 * 0.85 {
            notes.push(PlanNote::new("little_saving_likely"));
        }
    }
    Ok(ConversionPlan {
        engine: EngineKind::Ffmpeg,
        output_format: container,
        output_extension: s(container.primary_extension()),
        reencode: true,
        steps,
        notes,
        estimate,
        image: None,
        ffmpeg: Some(job),
        native_av: None,
        target_budget: None,
        verify: VerifySpec {
            expect_family: Some(Family::Video),
            expect_duration_s: info.duration_s,
            max_bytes: None,
            must_be_smaller_than: must_be_smaller,
            expect_no_location: opts.strip_metadata.unwrap_or(false),
        },
    })
}

fn color_args(video: &VideoStream) -> Vec<String> {
    let mut a = Vec::new();
    if video.hdr {
        if let Some(p) = &video.color_primaries {
            a.extend([s("-color_primaries"), p.clone()]);
        }
        if let Some(t) = &video.color_transfer {
            a.extend([s("-color_trc"), t.clone()]);
        }
        a.extend([s("-colorspace"), s("bt2020nc")]);
    }
    a
}

fn level_audio_kbps(level: QualityLevel) -> u32 {
    match level {
        QualityLevel::Smaller => 96,
        QualityLevel::Balanced => 128,
        QualityLevel::High => 192,
    }
}

fn map_video_and_audio(ctx: &VideoCtx, container: Format, remove_audio: bool) -> Vec<String> {
    let mut a = vec![s("-map"), format!("0:{}", ctx.video.index)];
    if !remove_audio {
        for au in &ctx.info.audio {
            a.extend([s("-map"), format!("0:{}", au.index)]);
        }
    }
    if ctx.req.options.keep_subtitles.unwrap_or(true) {
        for (i, sub) in ctx
            .info
            .subtitles
            .iter()
            .filter(|s| subtitle_codec_for(container, s).is_some())
            .enumerate()
        {
            a.extend([s("-map"), format!("0:{}", sub.index)]);
            if let Some(c) = subtitle_codec_for(container, sub) {
                a.extend([format!("-c:s:{i}"), s(c)]);
            }
        }
    }
    a
}

fn dropped_stream_notes(ctx: &VideoCtx, container: Format) -> Vec<PlanNote> {
    let mut notes = Vec::new();
    if ctx.info.video.len() > 1 {
        notes.push(PlanNote::with(
            "extra_video_tracks_dropped",
            &[(ctx.info.video.len() - 1).to_string()],
        ));
    }
    let dropped = ctx
        .info
        .subtitles
        .iter()
        .filter(|s| subtitle_codec_for(container, s).is_none())
        .count();
    if dropped > 0 && ctx.req.options.keep_subtitles.unwrap_or(true) {
        notes.push(PlanNote::with("subtitles_dropped", &[dropped.to_string()]));
    }
    notes
}

fn audio_step(ctx: &VideoCtx, container: Format, level: QualityLevel) -> PlanStep {
    if ctx.req.options.remove_audio.unwrap_or(false) || ctx.info.audio.is_empty() {
        PlanStep::RemoveAudio
    } else if ctx
        .info
        .audio
        .iter()
        .all(|a| can_copy_audio(ctx, a, container, Some(level)))
    {
        PlanStep::CopyAudio
    } else {
        PlanStep::TranscodeAudio
    }
}

fn can_copy_audio(
    ctx: &VideoCtx,
    a: &AudioStream,
    container: Format,
    level: Option<QualityLevel>,
) -> bool {
    let o = &ctx.req.options;
    if o.audio_codec.is_some()
        || o.audio_kbps.is_some()
        || o.audio_channels.is_some()
        || o.sample_rate.is_some()
    {
        return false;
    }
    if !audio_ok_in(container, &a.codec) {
        return false;
    }
    match level {
        // When shrinking, only copy audio that is already lean.
        Some(l) => a
            .bit_rate
            .map(|b| b <= (level_audio_kbps(l) as u64 + 32) * 1000)
            .unwrap_or(false),
        None => true,
    }
}

fn audio_args_for_video(
    ctx: &VideoCtx,
    container: Format,
    level: QualityLevel,
    copy_ok: bool,
) -> Vec<String> {
    let o = &ctx.req.options;
    if o.remove_audio.unwrap_or(false) || ctx.info.audio.is_empty() {
        return vec![s("-an")];
    }
    let copy = copy_ok
        || ctx
            .info
            .audio
            .iter()
            .all(|a| can_copy_audio(ctx, a, container, Some(level)));
    if copy {
        return vec![s("-c:a"), s("copy")];
    }
    let codec = o.audio_codec.clone().unwrap_or_else(|| {
        if container == Format::Webm {
            s("opus")
        } else {
            s("aac")
        }
    });
    let enc = select_audio(ctx.caps, &codec).unwrap_or("aac");
    let mut a = vec![s("-c:a"), s(enc)];
    let kbps = o.audio_kbps.unwrap_or_else(|| level_audio_kbps(level));
    a.extend([s("-b:a"), format!("{kbps}k")]);
    let channels = o.audio_channels.or_else(|| {
        let src = ctx.info.audio.first().and_then(|a| a.channels).unwrap_or(2);
        (level == QualityLevel::Smaller && src > 2).then_some(2)
    });
    if let Some(ch) = channels {
        a.extend([s("-ac"), ch.to_string()]);
    }
    if let Some(sr) = o.sample_rate {
        a.extend([s("-ar"), sr.to_string()]);
    } else if enc == "libopus" {
        a.extend([s("-ar"), s("48000")]);
    }
    a
}

fn metadata_args(strip: bool) -> Vec<String> {
    if strip {
        [
            "-map_metadata",
            "-1",
            "-map_metadata:s:v",
            "-1",
            "-map_metadata:s:a",
            "-1",
            "-fflags",
            "+bitexact",
            "-flags:v",
            "+bitexact",
            "-flags:a",
            "+bitexact",
        ]
        .iter()
        .map(|x| s(x))
        .collect()
    } else {
        vec![s("-map_metadata"), s("0")]
    }
}

fn container_args(container: Format) -> Vec<String> {
    if is_mp4_family(container) {
        vec![s("-movflags"), s("+faststart")]
    } else {
        Vec::new()
    }
}

/// Container conversion: remux whenever every kept stream fits the target container.
fn video_convert(req: &PlanRequest, target: Format) -> CoreResult<ConversionPlan> {
    let info = &req.input;
    let video = primary_video(info)?;
    let caps = &req.capabilities;
    let opts = &req.options;
    let ctx = VideoCtx {
        req,
        info,
        video,
        caps,
    };
    let container = ensure_video_container(target)?;
    let video_copy = video_ok_in(container, &video.codec)
        && opts.video_codec.is_none()
        && opts.max_short_side.is_none()
        && opts.fps.is_none()
        && opts.crf.is_none()
        && opts.video_kbps.is_none();
    if !video_copy {
        // Re-encode only what's needed, using the container's natural codec.
        let codec = opts.video_codec.unwrap_or(match container {
            Format::Webm => VideoCodec::Vp9,
            _ => VideoCodec::H264,
        });
        let mut r = req.clone();
        r.options.container = Some(container);
        r.options.video_codec = Some(codec);
        let mut plan = video_encode(&r, QualityLevel::High, None, Some(codec))?;
        plan.verify.must_be_smaller_than = None;
        return Ok(plan);
    }

    let mut a = base_args();
    a.extend([s("-i"), s(INPUT)]);
    a.extend(map_video_and_audio(
        &ctx,
        container,
        opts.remove_audio.unwrap_or(false),
    ));
    a.extend([s("-c:v"), s("copy")]);
    if video.codec == "hevc" && is_mp4_family(container) {
        a.extend([s("-tag:v"), s("hvc1")]);
    }
    let audio_copy = info
        .audio
        .iter()
        .all(|au| can_copy_audio(&ctx, au, container, None));
    a.extend(audio_args_for_video(
        &ctx,
        container,
        QualityLevel::High,
        audio_copy,
    ));
    a.extend(metadata_args(opts.strip_metadata.unwrap_or(false)));
    a.extend(container_args(container));
    a.extend([s("-f"), s(muxer(container)), s(OUTPUT)]);

    let mut steps = vec![PlanStep::Inspect, PlanStep::Remux, PlanStep::CopyVideo];
    steps.push(
        if info.audio.is_empty() || opts.remove_audio.unwrap_or(false) {
            PlanStep::RemoveAudio
        } else if audio_copy {
            PlanStep::CopyAudio
        } else {
            PlanStep::TranscodeAudio
        },
    );
    if info
        .subtitles
        .iter()
        .any(|s| subtitle_codec_for(container, s).is_some_and(|c| c != "copy" && c != s.codec))
    {
        steps.push(PlanStep::ConvertSubtitles);
    }
    steps.extend([PlanStep::Verify, PlanStep::Finalize]);
    let mut notes = vec![PlanNote::new("remux_no_quality_loss")];
    notes.extend(dropped_stream_notes(&ctx, container));
    Ok(ConversionPlan {
        engine: EngineKind::Ffmpeg,
        output_format: container,
        output_extension: s(container.primary_extension()),
        reencode: !audio_copy,
        steps,
        notes,
        estimate: Some(SizeEstimate::around(
            info.size_bytes as f64,
            0.05,
            EstimateConfidence::High,
        )),
        image: None,
        ffmpeg: Some(FfmpegJob {
            passes: vec![FfmpegPass { args: a }],
            duration_s: info.duration_s,
            video_encoder: None,
            hardware: false,
            fallback: None,
        }),
        native_av: None,
        target_budget: None,
        verify: VerifySpec {
            expect_family: Some(Family::Video),
            expect_duration_s: info.duration_s,
            ..Default::default()
        },
    })
}

/// Natural audio container for a codec, for lossless extraction.
fn container_for_audio_codec(codec: &str) -> Option<Format> {
    Some(match codec {
        "aac" | "alac" => Format::M4a,
        "mp3" => Format::Mp3,
        "opus" => Format::Opus,
        "vorbis" => Format::Ogg,
        "flac" => Format::Flac,
        "pcm_s16le" | "pcm_s24le" | "pcm_s32le" | "pcm_f32le" => Format::Wav,
        "pcm_s16be" | "pcm_s24be" => Format::Aiff,
        _ => return None,
    })
}

struct AudioTarget {
    codec: &'static str,
    kbps: Option<u32>,
    vbr_quality: Option<u32>,
    sample_rate: Option<u32>,
}

fn audio_target_for(
    format: Format,
    src: Option<&AudioStream>,
    level: QualityLevel,
) -> CoreResult<AudioTarget> {
    let deep = src.and_then(|a| a.bit_depth).unwrap_or(16) > 16
        || src.is_some_and(|a| {
            matches!(
                a.codec.as_str(),
                "pcm_s24le" | "pcm_s24be" | "pcm_s32le" | "pcm_f32le"
            )
        });
    let lossy_kbps = |s: u32, b: u32, h: u32| match level {
        QualityLevel::Smaller => s,
        QualityLevel::Balanced => b,
        QualityLevel::High => h,
    };
    Ok(match format {
        Format::Mp3 => AudioTarget {
            codec: "mp3",
            kbps: None,
            vbr_quality: Some(match level {
                QualityLevel::Smaller => 5,
                QualityLevel::Balanced => 2,
                QualityLevel::High => 0,
            }),
            sample_rate: None,
        },
        Format::M4a | Format::Aac => AudioTarget {
            codec: "aac",
            kbps: Some(lossy_kbps(128, 192, 256)),
            vbr_quality: None,
            sample_rate: None,
        },
        Format::Opus => AudioTarget {
            codec: "opus",
            kbps: Some(lossy_kbps(64, 128, 192)),
            vbr_quality: None,
            sample_rate: Some(48_000),
        },
        Format::Ogg => AudioTarget {
            codec: "vorbis",
            kbps: Some(lossy_kbps(112, 160, 224)),
            vbr_quality: None,
            sample_rate: None,
        },
        Format::Flac => AudioTarget {
            codec: "flac",
            kbps: None,
            vbr_quality: None,
            sample_rate: None,
        },
        Format::Wav => AudioTarget {
            codec: if deep { "pcm_s24le" } else { "pcm_s16le" },
            kbps: None,
            vbr_quality: None,
            sample_rate: None,
        },
        Format::Aiff => AudioTarget {
            codec: if deep { "pcm_s24be" } else { "pcm_s16be" },
            kbps: None,
            vbr_quality: None,
            sample_rate: None,
        },
        _ => return Err(unsupported("That audio format isn't supported.")),
    })
}

fn is_lossless_codec(codec: &str) -> bool {
    codec.starts_with("pcm_") || matches!(codec, "flac" | "alac" | "wavpack" | "ape" | "tta")
}

fn build_audio_job(
    req: &PlanRequest,
    format: Format,
    level: QualityLevel,
    from_video: bool,
    force_kbps: Option<u32>,
) -> CoreResult<(FfmpegJob, bool, Option<u32>)> {
    let info = &req.input;
    let opts = &req.options;
    let src = info
        .primary_audio()
        .ok_or_else(|| unsupported("This file has no audio."))?;
    let mut target = audio_target_for(format, Some(src), level)?;
    if format == Format::M4a && opts.audio_codec.as_deref() == Some("alac") {
        target = AudioTarget {
            codec: "alac",
            kbps: None,
            vbr_quality: None,
            sample_rate: None,
        };
    }
    if let Some(k) = force_kbps.or(opts.audio_kbps) {
        target.kbps = Some(k);
        target.vbr_quality = None;
    }
    let untouched = opts.audio_channels.is_none()
        && opts.sample_rate.is_none()
        && force_kbps.is_none()
        && opts.audio_kbps.is_none();
    let copy = untouched && src.codec == target.codec;
    let mut a = base_args();
    a.extend([
        s("-i"),
        s(INPUT),
        s("-map"),
        format!("0:{}", src.index),
        s("-vn"),
        s("-sn"),
        s("-dn"),
    ]);
    if copy {
        a.extend([s("-c:a"), s("copy")]);
    } else {
        let enc = select_audio(&req.capabilities, target.codec).ok_or_else(engine_missing)?;
        a.extend([s("-c:a"), s(enc)]);
        if let Some(q) = target.vbr_quality {
            a.extend([s("-q:a"), q.to_string()]);
        } else if let Some(k) = target.kbps {
            a.extend([s("-b:a"), format!("{k}k")]);
        }
        if let Some(ch) = opts.audio_channels {
            a.extend([s("-ac"), ch.to_string()]);
        }
        if let Some(sr) = opts.sample_rate.or(target.sample_rate) {
            a.extend([s("-ar"), sr.to_string()]);
        }
        if target.codec == "flac" {
            a.extend([s("-compression_level"), s("8")]);
        }
    }
    a.extend(metadata_args(opts.strip_metadata.unwrap_or(false)));
    a.extend(container_args(format));
    a.extend([s("-f"), s(muxer(format)), s(OUTPUT)]);
    let _ = from_video;
    Ok((
        FfmpegJob {
            passes: vec![FfmpegPass { args: a }],
            duration_s: info.duration_s,
            video_encoder: None,
            hardware: false,
            fallback: None,
        },
        copy,
        target.kbps.or(target.vbr_quality.map(|q| match q {
            0 => 245,
            1..=2 => 190,
            3..=4 => 165,
            _ => 130,
        })),
    ))
}

fn audio_estimate(
    info: &MediaInfo,
    format: Format,
    kbps: Option<u32>,
    copy: bool,
) -> Option<SizeEstimate> {
    let d = info.duration_s?;
    if copy {
        return Some(SizeEstimate::around(
            info.size_bytes as f64,
            0.1,
            EstimateConfidence::Medium,
        ));
    }
    let src = info.primary_audio()?;
    let sr = src.sample_rate.unwrap_or(44_100) as f64;
    let ch = src.channels.unwrap_or(2) as f64;
    match format {
        Format::Wav | Format::Aiff => {
            let depth = if src.bit_depth.unwrap_or(16) > 16 {
                3.0
            } else {
                2.0
            };
            Some(SizeEstimate::around(
                sr * ch * depth * d + 4096.0,
                0.02,
                EstimateConfidence::High,
            ))
        }
        Format::Flac => Some(SizeEstimate::around(
            sr * ch * 2.0 * d * 0.58,
            0.3,
            EstimateConfidence::Low,
        )),
        _ => kbps.map(|k| {
            SizeEstimate::around(
                k as f64 * 1000.0 / 8.0 * d + 8192.0,
                0.12,
                EstimateConfidence::Medium,
            )
        }),
    }
}

fn audio_convert(
    req: &PlanRequest,
    format: Format,
    from_video: bool,
) -> CoreResult<ConversionPlan> {
    let info = &req.input;
    let (job, copy, kbps) = build_audio_job(req, format, QualityLevel::Balanced, from_video, None)?;
    let mut notes = Vec::new();
    let src = info.primary_audio();
    if let Some(src) = src {
        if !is_lossless_codec(&src.codec)
            && matches!(format, Format::Flac | Format::Wav | Format::Aiff)
        {
            notes.push(PlanNote::new("lossless_from_lossy"));
        }
        if !src.codec.starts_with("pcm_")
            && src.codec != "flac"
            && !copy
            && !matches!(format, Format::Flac | Format::Wav | Format::Aiff)
            && !is_lossless_codec(&src.codec)
        {
            notes.push(PlanNote::new("lossy_to_lossy"));
        }
    }
    let steps = vec![
        PlanStep::Inspect,
        if copy {
            PlanStep::Remux
        } else {
            PlanStep::TranscodeAudio
        },
        PlanStep::Verify,
        PlanStep::Finalize,
    ];
    Ok(ConversionPlan {
        engine: EngineKind::Ffmpeg,
        output_format: format,
        output_extension: s(format.primary_extension()),
        reencode: !copy,
        steps,
        notes,
        estimate: audio_estimate(info, format, kbps, copy),
        image: None,
        ffmpeg: Some(job),
        native_av: None,
        target_budget: None,
        verify: VerifySpec {
            expect_family: Some(Family::Audio),
            expect_duration_s: info.duration_s,
            ..Default::default()
        },
    })
}

fn extract_audio(req: &PlanRequest, format: Option<Format>) -> CoreResult<ConversionPlan> {
    let info = &req.input;
    let src = info
        .primary_audio()
        .ok_or_else(|| unsupported("This video has no audio track."))?;
    let natural = container_for_audio_codec(&src.codec);
    let format = format.or(natural).unwrap_or(Format::M4a);
    let mut plan = audio_convert(req, format, true)?;
    if !plan.reencode {
        plan.notes
            .insert(0, PlanNote::new("audio_extracted_without_reencoding"));
    }
    Ok(plan)
}

fn audio_make_smaller(req: &PlanRequest, level: QualityLevel) -> CoreResult<ConversionPlan> {
    let info = &req.input;
    let src = info
        .primary_audio()
        .ok_or_else(|| unsupported("This file has no audio."))?;
    let format = match src.codec.as_str() {
        "mp3" => Format::Mp3,
        "opus" => Format::Opus,
        "vorbis" => Format::Ogg,
        _ => Format::M4a,
    };
    let (_, _, kbps) = build_audio_job(req, format, level, false, None)?;
    // Lossy sources: never re-encode at a higher bitrate than the source.
    let force = match (src.bit_rate, kbps) {
        (Some(b), Some(k)) if !is_lossless_codec(&src.codec) && (b / 1000) as u32 <= k + 8 => {
            Some(((b / 1000) as f64 * 0.7).max(48.0) as u32)
        }
        _ => None,
    };
    let (job, _, kbps) = build_audio_job(
        req,
        format,
        level,
        false,
        force.or(kbps.filter(|_| format != Format::Mp3)),
    )?;
    Ok(ConversionPlan {
        engine: EngineKind::Ffmpeg,
        output_format: format,
        output_extension: s(format.primary_extension()),
        reencode: true,
        steps: vec![
            PlanStep::Inspect,
            PlanStep::TranscodeAudio,
            PlanStep::Verify,
            PlanStep::Finalize,
        ],
        notes: if is_lossless_codec(&src.codec) {
            vec![PlanNote::new("lossless_to_lossy")]
        } else {
            Vec::new()
        },
        estimate: audio_estimate(info, format, kbps, false),
        image: None,
        ffmpeg: Some(job),
        native_av: None,
        target_budget: None,
        verify: VerifySpec {
            expect_family: Some(Family::Audio),
            expect_duration_s: info.duration_s,
            must_be_smaller_than: Some(info.size_bytes),
            ..Default::default()
        },
    })
}

fn audio_target_size(req: &PlanRequest, target_bytes: u64) -> CoreResult<ConversionPlan> {
    let info = &req.input;
    let d = info
        .duration_s
        .ok_or_else(|| unsupported("This file's duration is unknown."))?;
    let usable = target_bytes as f64 * 0.96 - 16_384.0;
    let kbps = (usable * 8.0 / d / 1000.0).floor();
    if kbps < 24.0 {
        return Err(crate::error::AppError::new(
            crate::error::ErrorCode::TargetSizeUnreachable,
            "This target size is too small for audio this long.",
        )
        .with_recovery(&[crate::error::Recovery::IncreaseTargetSize]));
    }
    let kbps = (kbps as u32).min(320);
    let (job, _, _) = build_audio_job(req, Format::M4a, QualityLevel::Balanced, false, Some(kbps))?;
    Ok(ConversionPlan {
        engine: EngineKind::Ffmpeg,
        output_format: Format::M4a,
        output_extension: s("m4a"),
        reencode: true,
        steps: vec![
            PlanStep::Inspect,
            PlanStep::CalculateBudget,
            PlanStep::TranscodeAudio,
            PlanStep::Verify,
            PlanStep::Finalize,
        ],
        notes: Vec::new(),
        estimate: Some(SizeEstimate::around(
            kbps as f64 * 125.0 * d,
            0.05,
            EstimateConfidence::Medium,
        )),
        image: None,
        ffmpeg: Some(job),
        native_av: None,
        target_budget: None,
        verify: VerifySpec {
            expect_family: Some(Family::Audio),
            expect_duration_s: info.duration_s,
            max_bytes: Some(target_bytes),
            ..Default::default()
        },
    })
}

fn remove_metadata(req: &PlanRequest, scope: MetadataScope) -> CoreResult<ConversionPlan> {
    let info = &req.input;
    let container = match info.detection.format {
        f @ (Format::Mp4
        | Format::Mov
        | Format::Mkv
        | Format::Webm
        | Format::M4a
        | Format::Mp3
        | Format::Flac
        | Format::Ogg
        | Format::Opus
        | Format::Wav
        | Format::Aiff) => f,
        _ => {
            return Err(unsupported(
                "Removing metadata isn't supported for this format.",
            ));
        }
    };
    let mut a = base_args();
    a.extend([s("-i"), s(INPUT)]);
    for v in &info.video {
        a.extend([s("-map"), format!("0:{}", v.index)]);
    }
    for au in &info.audio {
        a.extend([s("-map"), format!("0:{}", au.index)]);
    }
    for sub in &info.subtitles {
        a.extend([s("-map"), format!("0:{}", sub.index)]);
    }
    a.extend([s("-c"), s("copy")]);
    if info.video.iter().any(|v| v.codec == "hevc") && is_mp4_family(container) {
        a.extend([s("-tag:v"), s("hvc1")]);
    }
    // Both scopes strip container/stream tags; Apple timed-metadata tracks (location) are
    // dropped by mapping only audio/video/subtitle streams. "location" keeps chapters.
    a.extend(metadata_args(true));
    if scope == MetadataScope::All {
        a.extend([s("-map_chapters"), s("-1")]);
    }
    a.extend(container_args(container));
    a.extend([s("-f"), s(muxer(container)), s(OUTPUT)]);
    let family = info.family;
    Ok(ConversionPlan {
        engine: EngineKind::Ffmpeg,
        output_format: container,
        output_extension: s(info
            .detection
            .extension
            .as_deref()
            .filter(|e| container.matches_extension(e))
            .unwrap_or(container.primary_extension())),
        reencode: false,
        steps: vec![
            PlanStep::Inspect,
            PlanStep::Remux,
            if scope == MetadataScope::All {
                PlanStep::StripMetadata
            } else {
                PlanStep::StripLocation
            },
            PlanStep::Verify,
            PlanStep::Finalize,
        ],
        notes: vec![PlanNote::new("remux_no_quality_loss")],
        estimate: Some(SizeEstimate::around(
            info.size_bytes as f64,
            0.02,
            EstimateConfidence::High,
        )),
        image: None,
        ffmpeg: Some(FfmpegJob {
            passes: vec![FfmpegPass { args: a }],
            duration_s: info.duration_s,
            video_encoder: None,
            hardware: false,
            fallback: None,
        }),
        native_av: None,
        target_budget: None,
        verify: VerifySpec {
            expect_family: Some(family),
            expect_duration_s: info.duration_s,
            expect_no_location: true,
            ..Default::default()
        },
    })
}

fn video_target_size(
    req: &PlanRequest,
    target_bytes: u64,
    budget: Option<&TargetSizeBudget>,
) -> CoreResult<ConversionPlan> {
    let info = &req.input;
    let video = primary_video(info)?;
    let caps = &req.capabilities;
    let opts = &req.options;
    let ctx = VideoCtx {
        req,
        info,
        video,
        caps,
    };
    let container = Format::Mp4;
    let codec = opts.video_codec.unwrap_or(VideoCodec::H264);
    let choice = opts.encoder.clone().unwrap_or_default();
    // Two-pass software encodes hit the budget far more precisely than hardware ABR.
    let enc = select_video(caps, codec, &choice, true).ok_or_else(engine_missing)?;
    let (dw, dh) = video.display_size();
    let remove_audio = opts.remove_audio.unwrap_or(false);
    let budget = match budget {
        Some(b) => b.clone(),
        None => target_size::compute(&TargetSizeInput {
            duration_s: info.duration_s.unwrap_or(0.0),
            target_bytes,
            width: dw,
            height: dh,
            fps: video.fps,
            has_audio: !info.audio.is_empty() && !remove_audio,
            audio_channels: info.primary_audio().and_then(|a| a.channels).unwrap_or(2),
            codec,
            container,
        })?,
    };

    let build = |enc: &SelectedEncoder| -> FfmpegJob {
        let two_pass = opts.two_pass.unwrap_or(true) && supports_two_pass(enc);
        let mut filters = Vec::new();
        if (budget.width, budget.height) != (dw, dh) {
            filters.push(format!(
                "scale={}:{}:flags=lanczos",
                budget.width, budget.height
            ));
        }
        if let Some(f) = budget.fps {
            filters.push(format!("fps={f}"));
        }
        let common_video = |pass: Option<u8>| {
            let mut a = vec![s("-c:v"), enc.name.clone()];
            a.extend(bitrate_args(enc, budget.video_kbps, pass));
            a.extend(compat_args(enc, false, true));
            if !filters.is_empty() {
                a.extend([s("-vf"), filters.join(",")]);
            }
            a
        };
        let mut passes = Vec::new();
        if two_pass {
            let mut p1 = base_args();
            p1.extend([s("-i"), s(INPUT), s("-map"), format!("0:{}", video.index)]);
            p1.extend(common_video(Some(1)));
            p1.extend([s("-an"), s("-sn"), s("-f"), s("null"), s(NULL)]);
            passes.push(FfmpegPass { args: p1 });
        }
        let mut p2 = base_args();
        p2.extend([s("-i"), s(INPUT)]);
        p2.extend(map_video_and_audio(&ctx, container, remove_audio));
        p2.extend(common_video(two_pass.then_some(2)));
        if budget.audio_kbps > 0 && !remove_audio {
            let aenc = select_audio(caps, "aac").unwrap_or("aac");
            p2.extend([
                s("-c:a"),
                s(aenc),
                s("-b:a"),
                format!("{}k", budget.audio_kbps),
                s("-ac"),
                budget.audio_channels.to_string(),
            ]);
        } else {
            p2.push(s("-an"));
        }
        p2.extend(metadata_args(opts.strip_metadata.unwrap_or(false)));
        p2.extend(container_args(container));
        p2.extend([s("-f"), s(muxer(container)), s(OUTPUT)]);
        passes.push(FfmpegPass { args: p2 });
        FfmpegJob {
            passes,
            duration_s: info.duration_s,
            video_encoder: Some(enc.name.clone()),
            hardware: enc.hardware,
            fallback: None,
        }
    };
    let mut job = build(&enc);
    if enc.hardware {
        if let Some(sw) = software_alternative(caps, codec) {
            job.fallback = Some(Box::new(build(&sw)));
        }
    }
    let mut steps = vec![PlanStep::Inspect, PlanStep::CalculateBudget];
    if job.passes.len() > 1 {
        steps.push(PlanStep::TwoPassEncode);
    } else {
        steps.push(PlanStep::TranscodeVideo);
    }
    if (budget.width, budget.height) != (dw, dh) {
        steps.push(PlanStep::Scale);
    }
    if budget.fps.is_some() {
        steps.push(PlanStep::ReduceFrameRate);
    }
    steps.push(if budget.audio_kbps > 0 {
        PlanStep::TranscodeAudio
    } else {
        PlanStep::RemoveAudio
    });
    steps.extend([PlanStep::Verify, PlanStep::Refine, PlanStep::Finalize]);
    let mut notes = vec![PlanNote::with(
        "target_budget",
        &[
            budget.video_kbps.to_string(),
            budget.audio_kbps.to_string(),
            format!("{}x{}", budget.width, budget.height),
        ],
    )];
    if budget.low_quality {
        notes.push(PlanNote::new("target_low_quality"));
    }
    if video.hdr {
        notes.push(PlanNote::new("hdr_to_sdr_without_tonemap"));
    }
    notes.extend(dropped_stream_notes(&ctx, container));
    Ok(ConversionPlan {
        engine: EngineKind::Ffmpeg,
        output_format: container,
        output_extension: s("mp4"),
        reencode: true,
        steps,
        notes,
        estimate: Some(SizeEstimate {
            bytes: budget.estimated_bytes,
            low_bytes: (budget.estimated_bytes as f64 * 0.85) as u64,
            high_bytes: budget.target_bytes,
            confidence: EstimateConfidence::Medium,
        }),
        image: None,
        ffmpeg: Some(job),
        native_av: None,
        target_budget: Some(budget),
        verify: VerifySpec {
            expect_family: Some(Family::Video),
            expect_duration_s: info.duration_s,
            max_bytes: Some(target_bytes),
            ..Default::default()
        },
    })
}

fn gif(
    req: &PlanRequest,
    start_s: f64,
    duration_s: f64,
    width: u32,
    fps: u32,
) -> CoreResult<ConversionPlan> {
    let info = &req.input;
    let video = primary_video(info)?;
    let total = info.duration_s.unwrap_or(duration_s);
    let start = start_s.clamp(0.0, (total - 0.1).max(0.0));
    let dur = duration_s.clamp(0.5, 30.0).min((total - start).max(0.1));
    let (dw, _) = video.display_size();
    let w = width.clamp(64, 1280).min(dw.max(2));
    let w = w - (w % 2);
    let fps = fps.clamp(5, 30);
    let mut a = base_args();
    a.extend([
        s("-ss"),
        format!("{start:.3}"),
        s("-t"),
        format!("{dur:.3}"),
        s("-i"),
        s(INPUT),
        s("-filter_complex"),
        format!(
            "[0:{}]fps={fps},scale={w}:-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
            video.index
        ),
        s("-loop"),
        s("0"),
        s("-f"),
        s("gif"),
        s(OUTPUT),
    ]);
    Ok(ConversionPlan {
        engine: EngineKind::Ffmpeg,
        output_format: Format::Gif,
        output_extension: s("gif"),
        reencode: true,
        steps: vec![
            PlanStep::Inspect,
            PlanStep::RenderGif,
            PlanStep::Verify,
            PlanStep::Finalize,
        ],
        notes: vec![PlanNote::with(
            "gif_clip",
            &[format!("{start:.1}"), format!("{dur:.1}")],
        )],
        estimate: None,
        image: None,
        ffmpeg: Some(FfmpegJob {
            passes: vec![FfmpegPass { args: a }],
            duration_s: Some(dur),
            video_encoder: Some(s("gif")),
            hardware: false,
            fallback: None,
        }),
        native_av: None,
        target_budget: None,
        verify: VerifySpec {
            expect_family: Some(Family::Image),
            ..Default::default()
        },
    })
}
