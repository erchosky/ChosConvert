//! Capability registry: what this particular installation can actually do.
//!
//! The platform layer reports native capabilities (ImageIO destinations, AVFoundation
//! encoders, PDF/OCR availability). The core probes FFmpeg itself. The planner and the
//! smart-action list only offer what is present here, so the UI never shows impossible actions.

use std::path::Path;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::cancel::CancelToken;
use crate::error::{AppError, CoreResult, ErrorCode};
use crate::ffmpeg::runner::run_capture;
use crate::formats::Format;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Os {
    #[default]
    Macos,
    Windows,
    Linux,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Platform {
    pub os: Os,
    /// "arm64" or "x86_64".
    pub arch: String,
    #[serde(default)]
    pub os_version: String,
    #[serde(default)]
    pub cpu_count: u32,
    #[serde(default)]
    pub memory_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct NativeImageCaps {
    pub read: Vec<Format>,
    pub write: Vec<Format>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct NativeAvCaps {
    /// Platform media framework can read/transcode audio-visual files.
    pub available: bool,
    #[serde(default)]
    pub h264_encode: bool,
    #[serde(default)]
    pub hevc_encode: bool,
    #[serde(default)]
    pub aac_encode: bool,
    #[serde(default)]
    pub alac_encode: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EncoderKind {
    Video,
    Audio,
    Subtitle,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EncoderInfo {
    pub name: String,
    pub kind: EncoderKind,
    /// Codec produced (e.g. "h264" for `libx264`, `h264_videotoolbox`).
    pub codec: String,
    pub hardware: bool,
    #[serde(default)]
    pub experimental: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FfmpegLicense {
    Lgpl,
    Gpl,
    Nonfree,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FfmpegCaps {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ffprobe_path: Option<String>,
    pub version: String,
    pub license: FfmpegLicense,
    #[serde(default)]
    pub configuration: String,
    pub encoders: Vec<EncoderInfo>,
    pub muxers: Vec<String>,
}

impl FfmpegCaps {
    pub fn has_encoder(&self, name: &str) -> bool {
        self.encoders.iter().any(|e| e.name == name)
    }
    pub fn has_muxer(&self, name: &str) -> bool {
        self.muxers.iter().any(|m| m == name)
    }
    pub fn encoders_for(&self, codec: &str) -> impl Iterator<Item = &EncoderInfo> {
        self.encoders.iter().filter(move |e| e.codec == codec)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct Capabilities {
    pub platform: Platform,
    #[serde(default)]
    pub native_image: NativeImageCaps,
    #[serde(default)]
    pub native_av: NativeAvCaps,
    /// The core's bundled libwebp encoder (always true for official builds).
    #[serde(default = "yes")]
    pub core_webp: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ffmpeg: Option<FfmpegCaps>,
    #[serde(default)]
    pub pdf_native: bool,
    #[serde(default)]
    pub ocr_native: bool,
}

fn yes() -> bool {
    true
}

impl Capabilities {
    pub fn can_write_image(&self, f: Format) -> bool {
        self.native_image.write.contains(&f) || (f == Format::Webp && self.core_webp)
    }
    pub fn can_read_image(&self, f: Format) -> bool {
        self.native_image.read.contains(&f)
    }
    pub fn ffmpeg(&self) -> Option<&FfmpegCaps> {
        self.ffmpeg.as_ref()
    }
}

fn is_hw_encoder(name: &str) -> bool {
    [
        "_videotoolbox",
        "_nvenc",
        "_qsv",
        "_amf",
        "_mf",
        "_vaapi",
        "_v4l2m2m",
        "_vulkan",
        "_d3d12va",
    ]
    .iter()
    .any(|s| name.ends_with(s))
}

/// Parses `ffmpeg -hide_banner -encoders`.
pub fn parse_encoders(text: &str) -> Vec<EncoderInfo> {
    let mut past_header = false;
    let mut out = Vec::new();
    for line in text.lines() {
        let t = line.trim_start();
        if t.starts_with("------") {
            past_header = true;
            continue;
        }
        if !past_header || t.len() < 8 {
            continue;
        }
        let mut parts = t.splitn(3, char::is_whitespace);
        let (Some(flags), Some(name)) = (parts.next(), parts.next()) else {
            continue;
        };
        if flags.len() != 6 {
            continue;
        }
        let kind = match flags.as_bytes()[0] {
            b'V' => EncoderKind::Video,
            b'A' => EncoderKind::Audio,
            b'S' => EncoderKind::Subtitle,
            _ => continue,
        };
        let desc = parts.next().unwrap_or("");
        let codec = desc
            .rsplit_once("(codec ")
            .and_then(|(_, rest)| rest.split(')').next())
            .map(str::to_owned)
            .unwrap_or_else(|| name.to_string());
        out.push(EncoderInfo {
            name: name.to_string(),
            kind,
            codec,
            hardware: is_hw_encoder(name),
            experimental: flags.as_bytes().get(3) == Some(&b'X'),
        });
    }
    out
}

/// Parses `ffmpeg -hide_banner -muxers`.
pub fn parse_muxers(text: &str) -> Vec<String> {
    let mut past_header = false;
    let mut out = Vec::new();
    for line in text.lines() {
        let t = line.trim_start();
        if t.starts_with("--") {
            past_header = true;
            continue;
        }
        if !past_header {
            continue;
        }
        let mut parts = t.split_whitespace();
        let (Some(flags), Some(names)) = (parts.next(), parts.next()) else {
            continue;
        };
        if flags.contains('E') {
            out.extend(names.split(',').map(str::to_owned));
        }
    }
    out
}

/// Parses the first lines of `ffmpeg -version`.
pub fn parse_version(text: &str) -> (String, String, FfmpegLicense) {
    let version = text
        .lines()
        .next()
        .and_then(|l| l.strip_prefix("ffmpeg version "))
        .and_then(|l| l.split_whitespace().next())
        .unwrap_or("unknown")
        .to_string();
    let configuration = text
        .lines()
        .find_map(|l| l.trim().strip_prefix("configuration:"))
        .unwrap_or("")
        .trim()
        .to_string();
    let license = if configuration.contains("--enable-nonfree") {
        FfmpegLicense::Nonfree
    } else if configuration.contains("--enable-gpl") {
        FfmpegLicense::Gpl
    } else if configuration.is_empty() {
        FfmpegLicense::Unknown
    } else {
        FfmpegLicense::Lgpl
    };
    (version, configuration, license)
}

/// Probes an FFmpeg binary for version, license and available encoders/muxers.
pub fn probe_ffmpeg(ffmpeg: &Path, ffprobe: Option<&Path>) -> CoreResult<FfmpegCaps> {
    let cancel = CancelToken::new();
    let t = Duration::from_secs(15);
    let run = |args: &[&str]| -> CoreResult<String> {
        let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        let out = run_capture(ffmpeg, &args, t, 4 * 1024 * 1024, &cancel)?;
        if !out.status.success() {
            return Err(AppError::new(
                ErrorCode::EngineUnavailable,
                "The media engine isn't working correctly.",
            )
            .with_details(out.stderr_tail));
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    };
    let (version, configuration, license) = parse_version(&run(&["-hide_banner", "-version"])?);
    let encoders = parse_encoders(&run(&["-hide_banner", "-encoders"])?);
    let muxers = parse_muxers(&run(&["-hide_banner", "-muxers"])?);
    Ok(FfmpegCaps {
        path: ffmpeg.to_string_lossy().into_owned(),
        ffprobe_path: ffprobe.map(|p| p.to_string_lossy().into_owned()),
        version,
        license,
        configuration,
        encoders,
        muxers,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const ENCODERS: &str = "Encoders:
 V..... = Video
 ------
 V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)
 V....D h264_videotoolbox    VideoToolbox H.264 Encoder (codec h264)
 V....D hevc_videotoolbox    VideoToolbox H.265 Encoder (codec hevc)
 VF...D png                  PNG (Portable Network Graphics) image
 A....D aac                  AAC (Advanced Audio Coding)
 A..... aac_at               aac (AudioToolbox) (codec aac)
 A..X.D vorbis               Vorbis
 S....D mov_text             3GPP Timed Text subtitle
";

    #[test]
    fn parses_encoder_table() {
        let e = parse_encoders(ENCODERS);
        assert_eq!(e.len(), 8);
        let vt = e
            .iter()
            .find(|x| x.name == "hevc_videotoolbox")
            .expect("vt");
        assert!(vt.hardware);
        assert_eq!(vt.codec, "hevc");
        let x264 = e.iter().find(|x| x.name == "libx264").expect("x264");
        assert!(!x264.hardware);
        assert_eq!(x264.codec, "h264");
        assert_eq!(
            e.iter().find(|x| x.name == "png").map(|x| x.codec.as_str()),
            Some("png")
        );
        assert!(
            e.iter()
                .find(|x| x.name == "vorbis")
                .is_some_and(|x| x.experimental)
        );
        assert_eq!(
            e.iter().find(|x| x.name == "mov_text").map(|x| x.kind),
            Some(EncoderKind::Subtitle)
        );
    }

    #[test]
    fn parses_muxers_and_version() {
        let m = parse_muxers(
            " Muxers:\n D. = Demuxing\n --\n  E  mp4  MP4\n D   aa  Audible\n  E  ogg,oga  Ogg\n",
        );
        assert_eq!(m, vec!["mp4", "ogg", "oga"]);
        let (v, _, lic) = parse_version(
            "ffmpeg version 9.0.2 Copyright (c) 2000-2026\nbuilt with clang\nconfiguration: --enable-gpl --enable-libx264\n",
        );
        assert_eq!(v, "9.0.2");
        assert_eq!(lic, FfmpegLicense::Gpl);
        let (_, _, lic) = parse_version("ffmpeg version n8\nconfiguration: --disable-gpl\n");
        assert_eq!(lic, FfmpegLicense::Lgpl);
    }
}
