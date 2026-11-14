use super::*;
use crate::actions::{ActionId, actions_for};
use crate::capabilities::{
    Capabilities, FfmpegCaps, FfmpegLicense, NativeAvCaps, NativeImageCaps, Os, Platform,
    parse_encoders,
};
use crate::detect::detect_bytes;
use crate::ffmpeg::{INPUT, OUTPUT};
use crate::media::{AudioStream, ImageInfo, MediaInfo, VideoStream};

const ENCODERS: &str = " ------
 V....D libx264              libx264 H.264 (codec h264)
 V....D h264_videotoolbox    VideoToolbox H.264 Encoder (codec h264)
 V....D hevc_videotoolbox    VideoToolbox H.265 Encoder (codec hevc)
 V....D libx265              libx265 H.265 / HEVC (codec hevc)
 V....D libvpx-vp9           libvpx VP9 (codec vp9)
 V..... libsvtav1            SVT-AV1 (codec av1)
 V....D gif                  GIF
 A....D aac                  AAC (Advanced Audio Coding)
 A..... aac_at               aac (AudioToolbox) (codec aac)
 A....D alac                 ALAC
 A....D flac                 FLAC
 A....D libmp3lame           libmp3lame MP3 (codec mp3)
 A....D libopus              libopus Opus (codec opus)
 A....D pcm_s16le            PCM signed 16-bit little-endian
 A....D pcm_s24le            PCM signed 24-bit little-endian
 A....D pcm_s16be            PCM signed 16-bit big-endian
 A....D pcm_s24be            PCM signed 24-bit big-endian
 S....D mov_text             3GPP Timed Text subtitle
";

fn caps(with_ffmpeg: bool) -> Capabilities {
    use Format::*;
    Capabilities {
        platform: Platform {
            os: Os::Macos,
            arch: "arm64".into(),
            os_version: "27.0".into(),
            cpu_count: 10,
            memory_bytes: 16 << 30,
        },
        native_image: NativeImageCaps {
            read: vec![Jpeg, Png, Gif, Webp, Avif, Heic, Tiff, Bmp],
            write: vec![Jpeg, Png, Gif, Avif, Heic, Tiff, Bmp],
        },
        native_av: NativeAvCaps {
            available: true,
            h264_encode: true,
            hevc_encode: true,
            aac_encode: true,
            alac_encode: true,
        },
        core_webp: true,
        ffmpeg: with_ffmpeg.then(|| FfmpegCaps {
            path: "/opt/test/ffmpeg".into(),
            ffprobe_path: Some("/opt/test/ffprobe".into()),
            version: "9.0".into(),
            license: FfmpegLicense::Lgpl,
            configuration: String::new(),
            encoders: parse_encoders(ENCODERS),
            muxers: [
                "mp4", "mov", "matroska", "webm", "ipod", "mp3", "wav", "flac", "ogg", "opus",
                "gif",
            ]
            .iter()
            .map(|s| s.to_string())
            .collect(),
        }),
        pdf_native: true,
        ocr_native: true,
    }
}

fn video_info(fmt_head: &[u8], ext: &str, vcodec: &str, acodec: &str, w: u32, h: u32) -> MediaInfo {
    let det = detect_bytes(fmt_head, None, Some(ext));
    MediaInfo {
        path: format!("/Users/test/Movies/clip.{ext}"),
        file_name: format!("clip.{ext}"),
        size_bytes: 487_000_000,
        family: Family::Video,
        detection: det,
        container: None,
        duration_s: Some(180.0),
        bit_rate: Some(21_000_000),
        video: vec![VideoStream {
            index: 0,
            codec: vcodec.into(),
            width: w,
            height: h,
            fps: Some(30.0),
            bit_rate: Some(20_000_000),
            bit_depth: Some(8),
            ..Default::default()
        }],
        audio: vec![AudioStream {
            index: 1,
            codec: acodec.into(),
            sample_rate: Some(48_000),
            channels: Some(2),
            bit_rate: Some(256_000),
            ..Default::default()
        }],
        subtitles: vec![],
        chapters: 0,
        image: None,
        pdf: None,
        metadata: vec![],
        has_location: true,
        inspector: "test".into(),
    }
}

const MOV: &[u8] = b"\0\0\0\x14ftypqt  \0\0\0\0qt  ";
const MP4: &[u8] = b"\0\0\0\x14ftypisom\0\0\0\0isom";

fn req(input: MediaInfo, intent: Intent, with_ffmpeg: bool) -> PlanRequest {
    PlanRequest {
        input,
        intent,
        options: AdvancedOptions::default(),
        capabilities: caps(with_ffmpeg),
        engine_override: None,
    }
}

fn last_args(p: &ConversionPlan) -> &Vec<String> {
    &p.ffmpeg
        .as_ref()
        .expect("ffmpeg job")
        .passes
        .last()
        .expect("pass")
        .args
}

fn assert_safe_template(p: &ConversionPlan) {
    let job = p.ffmpeg.as_ref().expect("ffmpeg");
    for pass in &job.passes {
        assert_eq!(
            pass.args.iter().filter(|a| *a == INPUT).count(),
            1,
            "{:?}",
            pass.args
        );
        assert!(
            !pass.args.iter().any(|a| a.contains("/Users/test")),
            "raw path leaked"
        );
        assert!(pass.args.contains(&"-n".to_string()), "never overwrite");
    }
    assert_eq!(last_args(p).last().map(String::as_str), Some(OUTPUT));
}

#[test]
fn remove_metadata_from_h264_mp4_is_remux() {
    let p = plan(&req(
        video_info(MP4, "mp4", "h264", "aac", 1920, 1080),
        Intent::RemoveMetadata {
            scope: MetadataScope::All,
        },
        true,
    ))
    .expect("plan");
    assert!(!p.reencode);
    assert_eq!(p.output_format, Format::Mp4);
    let a = last_args(&p);
    assert!(a.windows(2).any(|w| w == ["-c", "copy"]));
    assert!(a.windows(2).any(|w| w == ["-map_metadata", "-1"]));
    assert!(p.steps.contains(&PlanStep::Remux));
    assert!(p.verify.expect_no_location);
    assert_safe_template(&p);
}

#[test]
fn mov_to_mp4_remuxes_compatible_streams() {
    let p = plan(&req(
        video_info(MOV, "mov", "h264", "aac", 1920, 1080),
        Intent::Convert {
            format: Format::Mp4,
        },
        true,
    ))
    .expect("plan");
    assert!(!p.reencode);
    let a = last_args(&p);
    assert!(a.windows(2).any(|w| w == ["-c:v", "copy"]));
    assert!(a.windows(2).any(|w| w == ["-c:a", "copy"]));
    assert_safe_template(&p);
}

#[test]
fn hevc_to_webm_transcodes() {
    let p = plan(&req(
        video_info(MOV, "mov", "hevc", "aac", 1920, 1080),
        Intent::Convert {
            format: Format::Webm,
        },
        true,
    ))
    .expect("plan");
    assert!(p.reencode);
    let a = last_args(&p);
    assert!(a.windows(2).any(|w| w == ["-c:v", "libvpx-vp9"]));
    assert!(a.windows(2).any(|w| w == ["-c:a", "libopus"]));
    assert_safe_template(&p);
}

#[test]
fn make_smaller_uses_hardware_with_software_fallback() {
    let mut info = video_info(MOV, "mov", "hevc", "aac", 3840, 2160);
    info.video[0].hdr = true;
    info.video[0].bit_depth = Some(10);
    info.video[0].color_transfer = Some("arib-std-b67".into());
    let p = plan(&req(
        info,
        Intent::MakeSmaller {
            level: QualityLevel::Balanced,
        },
        true,
    ))
    .expect("plan");
    let job = p.ffmpeg.as_ref().expect("job");
    assert_eq!(job.video_encoder.as_deref(), Some("hevc_videotoolbox"));
    assert!(job.hardware);
    let fb = job.fallback.as_ref().expect("fallback");
    assert_eq!(fb.video_encoder.as_deref(), Some("libx265"));
    let a = last_args(&p);
    assert!(a.windows(2).any(|w| w == ["-profile:v", "main10"]));
    assert!(a.windows(2).any(|w| w == ["-tag:v", "hvc1"]));
    assert!(p.notes.iter().any(|n| n.code == "hdr_preserved"));
    assert_eq!(p.verify.must_be_smaller_than, Some(487_000_000));
    assert!(p.estimate.is_some());
    assert_safe_template(&p);
}

#[test]
fn smaller_level_downscales_4k() {
    let p = plan(&req(
        video_info(MOV, "mov", "h264", "aac", 3840, 2160),
        Intent::MakeSmaller {
            level: QualityLevel::Smaller,
        },
        true,
    ))
    .expect("plan");
    let a = last_args(&p);
    assert!(a.iter().any(|x| x.starts_with("scale=1920:1080")), "{a:?}");
    assert!(p.steps.contains(&PlanStep::Scale));
}

#[test]
fn target_size_plans_two_pass_x264_with_budget() {
    let p = plan(&req(
        video_info(MOV, "mov", "hevc", "aac", 3840, 2160),
        Intent::TargetSize {
            target_bytes: 25_000_000,
        },
        true,
    ))
    .expect("plan");
    let job = p.ffmpeg.as_ref().expect("job");
    assert_eq!(job.passes.len(), 2);
    assert_eq!(job.video_encoder.as_deref(), Some("libx264"));
    let budget = p.target_budget.as_ref().expect("budget");
    assert!(budget.estimated_bytes < 25_000_000);
    assert!(budget.height < 2160);
    let p1 = &job.passes[0].args;
    assert!(p1.windows(2).any(|w| w == ["-pass", "1"]));
    assert!(p1.contains(&"-an".to_string()));
    assert_eq!(p.verify.max_bytes, Some(25_000_000));
    assert!(p.steps.contains(&PlanStep::Refine));
    assert_safe_template(&p);
}

#[test]
fn extract_aac_audio_without_reencoding() {
    let p = plan(&req(
        video_info(MOV, "mov", "h264", "aac", 1920, 1080),
        Intent::ExtractAudio { format: None },
        true,
    ))
    .expect("plan");
    assert_eq!(p.output_format, Format::M4a);
    assert!(!p.reencode);
    assert!(last_args(&p).windows(2).any(|w| w == ["-c:a", "copy"]));
    assert!(
        p.notes
            .iter()
            .any(|n| n.code == "audio_extracted_without_reencoding")
    );
}

fn wav_info() -> MediaInfo {
    let det = detect_bytes(b"RIFF\0\0\0\0WAVEfmt ", None, Some("wav"));
    MediaInfo {
        path: "/Users/test/audio.wav".into(),
        file_name: "audio.wav".into(),
        size_bytes: 52_000_000,
        family: Family::Audio,
        detection: det,
        container: Some("wav".into()),
        duration_s: Some(295.0),
        bit_rate: Some(1_411_000),
        video: vec![],
        audio: vec![AudioStream {
            index: 0,
            codec: "pcm_s16le".into(),
            sample_rate: Some(44_100),
            channels: Some(2),
            bit_rate: Some(1_411_000),
            bit_depth: Some(16),
            ..Default::default()
        }],
        subtitles: vec![],
        chapters: 0,
        image: None,
        pdf: None,
        metadata: vec![],
        has_location: false,
        inspector: "test".into(),
    }
}

#[test]
fn wav_to_mp3_aac_flac() {
    for (fmt, enc) in [
        (Format::Mp3, "libmp3lame"),
        (Format::M4a, "aac_at"),
        (Format::Flac, "flac"),
    ] {
        let p = plan(&req(wav_info(), Intent::Convert { format: fmt }, true)).expect("plan");
        assert_eq!(p.output_format, fmt);
        assert!(
            last_args(&p)
                .windows(2)
                .any(|w| w[0] == "-c:a" && w[1] == enc),
            "{fmt:?}"
        );
        assert!(p.estimate.is_some());
        assert_safe_template(&p);
    }
}

#[test]
fn without_ffmpeg_video_uses_native_presets_or_reports_missing_engine() {
    let p = plan(&req(
        video_info(MOV, "mov", "hevc", "aac", 3840, 2160),
        Intent::MakeSmaller {
            level: QualityLevel::Balanced,
        },
        false,
    ))
    .expect("native plan");
    assert_eq!(p.engine, EngineKind::NativeAv);
    assert_eq!(
        p.native_av.as_ref().map(|n| n.preset.as_str()),
        Some("AVAssetExportPresetHEVC1920x1080")
    );

    let mut mkv = video_info(
        &[0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0],
        "mkv",
        "h264",
        "aac",
        1920,
        1080,
    );
    mkv.detection.format = Format::Mkv;
    let err = plan(&req(
        mkv,
        Intent::MakeSmaller {
            level: QualityLevel::Balanced,
        },
        false,
    ))
    .expect_err("no engine");
    assert_eq!(err.code, ErrorCode::EngineUnavailable);
}

fn png_info(w: u32, h: u32, alpha: bool) -> MediaInfo {
    let det = detect_bytes(
        &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0],
        None,
        Some("png"),
    );
    MediaInfo {
        path: "/Users/test/photo.png".into(),
        file_name: "photo.png".into(),
        size_bytes: 18_000_000,
        family: Family::Image,
        detection: det,
        container: None,
        duration_s: None,
        bit_rate: None,
        video: vec![],
        audio: vec![],
        subtitles: vec![],
        chapters: 0,
        image: Some(ImageInfo {
            width: w,
            height: h,
            has_alpha: alpha,
            frame_count: 1,
            has_gps: true,
            ..Default::default()
        }),
        pdf: None,
        metadata: vec![],
        has_location: true,
        inspector: "test".into(),
    }
}

#[test]
fn web_optimize_large_png() {
    let p = plan(&req(
        png_info(6000, 4000, false),
        Intent::WebOptimize,
        false,
    ))
    .expect("plan");
    let img = p.image.as_ref().expect("image job");
    assert_eq!(img.output_format, Format::Webp);
    assert_eq!(img.encoder, ImageEncoder::CoreWebp);
    assert_eq!(img.max_dimension, Some(1920));
    assert!(img.convert_to_srgb);
    assert_eq!(img.metadata, ImageMetadataPolicy::StripAll);
    assert!(p.notes.iter().any(|n| n.code == "larger_than_web_display"));
}

#[test]
fn png_with_alpha_to_jpeg_flattens() {
    let p = plan(&req(
        png_info(800, 600, true),
        Intent::Convert {
            format: Format::Jpeg,
        },
        false,
    ))
    .expect("plan");
    let img = p.image.as_ref().expect("image");
    assert_eq!(img.flatten_background, Some([255, 255, 255]));
    assert!(img.quality.is_some());
}

#[test]
fn jpeg_location_removal_is_lossless() {
    let mut info = png_info(4000, 3000, false);
    info.detection = detect_bytes(&[0xFF, 0xD8, 0xFF, 0xE1], None, Some("jpg"));
    let p = plan(&req(
        info,
        Intent::RemoveMetadata {
            scope: MetadataScope::Location,
        },
        false,
    ))
    .expect("plan");
    let img = p.image.as_ref().expect("image");
    assert!(img.metadata_only);
    assert!(!p.reencode);
    assert_eq!(img.metadata, ImageMetadataPolicy::StripLocation);
}

#[test]
fn decompression_bombs_are_refused() {
    let err = plan(&req(
        png_info(50_000, 50_000, false),
        Intent::WebOptimize,
        false,
    ))
    .expect_err("bomb");
    assert_eq!(err.code, ErrorCode::ImageTooLarge);
}

#[test]
fn resize_never_upscales() {
    let p = plan(&req(
        png_info(800, 600, false),
        Intent::Resize {
            max_dimension: 1920,
        },
        false,
    ))
    .expect("plan");
    assert_eq!(p.image.as_ref().and_then(|i| i.max_dimension), None);
}

#[test]
fn actions_match_file_type() {
    let caps = caps(true);
    let video = actions_for(&[video_info(MOV, "mov", "hevc", "aac", 3840, 2160)], &caps);
    let ids: Vec<_> = video.iter().map(|a| a.id).collect();
    assert!(ids.contains(&ActionId::MakeSmaller));
    assert!(ids.contains(&ActionId::ExtractAudio));
    assert!(ids.contains(&ActionId::TargetSize));
    assert!(ids.contains(&ActionId::RemoveLocation));
    assert!(!ids.contains(&ActionId::WebOptimize));
    let convert = video
        .iter()
        .find(|a| a.id == ActionId::Convert)
        .expect("convert");
    assert!(convert.formats.contains(&Format::Mp4));

    let img = actions_for(&[png_info(6000, 4000, false)], &caps);
    let ids: Vec<_> = img.iter().map(|a| a.id).collect();
    assert!(ids.contains(&ActionId::WebOptimize));
    assert!(!ids.contains(&ActionId::ExtractAudio));
    let convert = img
        .iter()
        .find(|a| a.id == ActionId::Convert)
        .expect("convert");
    assert!(convert.formats.contains(&Format::Webp));
    assert!(
        !convert.formats.contains(&Format::Png),
        "same-format convert is a no-op"
    );

    let mut pdf = png_info(1, 1, false);
    pdf.family = Family::Pdf;
    pdf.detection = detect_bytes(b"%PDF-1.7", None, Some("pdf"));
    assert!(
        actions_for(&[pdf], &caps).is_empty(),
        "no fake PDF actions yet"
    );
}

#[test]
fn mixed_selection_only_offers_shared_actions() {
    let caps = caps(true);
    let files = vec![png_info(800, 600, false), wav_info()];
    let ids: Vec<_> = actions_for(&files, &caps).iter().map(|a| a.id).collect();
    assert!(!ids.contains(&ActionId::Convert));
    assert!(ids.contains(&ActionId::MakeSmaller));
}

#[test]
fn executables_are_never_planned() {
    let mut info = png_info(10, 10, false);
    info.detection = detect_bytes(b"MZ\x90\0", None, Some("jpg"));
    assert!(plan(&req(info, Intent::WebOptimize, true)).is_err());
}
