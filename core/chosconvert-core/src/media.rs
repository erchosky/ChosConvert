//! Inspection model shared by all engines, plus the FFprobe JSON parser.
//!
//! Platform inspectors (ImageIO/AVFoundation/PDFKit on macOS, WIC/Media Foundation on
//! Windows) and FFprobe all produce the same [`MediaInfo`] shape.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::detect::Detection;
use crate::error::{AppError, CoreResult, ErrorCode, Recovery};
use crate::formats::Family;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct VideoStream {
    pub index: u32,
    pub codec: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    pub width: u32,
    pub height: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fps: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bit_rate: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pix_fmt: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bit_depth: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_transfer: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_primaries: Option<String>,
    #[serde(default)]
    pub hdr: bool,
    /// Display rotation in degrees (0, 90, 180, 270).
    #[serde(default)]
    pub rotation: i32,
}

impl VideoStream {
    /// Dimensions after applying rotation.
    pub fn display_size(&self) -> (u32, u32) {
        if self.rotation.rem_euclid(180) == 90 {
            (self.height, self.width)
        } else {
            (self.width, self.height)
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct AudioStream {
    pub index: u32,
    pub codec: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sample_rate: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channels: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channel_layout: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bit_rate: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bit_depth: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SubtitleStream {
    pub index: u32,
    pub codec: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ImageInfo {
    pub width: u32,
    pub height: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bit_depth: Option<u32>,
    #[serde(default)]
    pub has_alpha: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_profile: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dpi: Option<f64>,
    /// EXIF orientation 1-8.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub orientation: Option<u32>,
    #[serde(default = "one")]
    pub frame_count: u32,
    #[serde(default)]
    pub has_exif: bool,
    #[serde(default)]
    pub has_gps: bool,
}

fn one() -> u32 {
    1
}

impl ImageInfo {
    /// Dimensions after applying EXIF orientation.
    pub fn display_size(&self) -> (u32, u32) {
        match self.orientation {
            Some(5..=8) => (self.height, self.width),
            _ => (self.width, self.height),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct PdfInfo {
    pub page_count: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(default)]
    pub encrypted: bool,
    #[serde(default)]
    pub locked: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MetadataEntry {
    pub key: String,
    pub value: String,
    /// Personal or identifying data (location, device, people, timestamps).
    #[serde(default)]
    pub sensitive: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MediaInfo {
    pub path: String,
    pub file_name: String,
    pub size_bytes: u64,
    pub detection: Detection,
    /// Effective family after inspection (an MP4 with only audio is `audio`).
    pub family: Family,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub container: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_s: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bit_rate: Option<u64>,
    #[serde(default)]
    pub video: Vec<VideoStream>,
    #[serde(default)]
    pub audio: Vec<AudioStream>,
    #[serde(default)]
    pub subtitles: Vec<SubtitleStream>,
    #[serde(default)]
    pub chapters: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<ImageInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pdf: Option<PdfInfo>,
    #[serde(default)]
    pub metadata: Vec<MetadataEntry>,
    #[serde(default)]
    pub has_location: bool,
    /// Which inspector produced this (e.g. "ffprobe", "avfoundation", "imageio").
    #[serde(default)]
    pub inspector: String,
}

impl MediaInfo {
    pub fn primary_video(&self) -> Option<&VideoStream> {
        self.video.first()
    }
    pub fn primary_audio(&self) -> Option<&AudioStream> {
        self.audio.first()
    }
}

const SENSITIVE_KEYS: &[&str] = &[
    "location",
    "location-eng",
    "com.apple.quicktime.location.iso6709",
    "com.apple.quicktime.make",
    "com.apple.quicktime.model",
    "com.apple.quicktime.software",
    "com.apple.quicktime.creationdate",
    "com.android.manufacturer",
    "com.android.model",
    "creation_time",
    "date",
    "artist",
    "album_artist",
    "author",
    "composer",
    "copyright",
    "comment",
    "description",
    "encoder",
    "make",
    "model",
    "gps",
];

pub fn is_sensitive_key(key: &str) -> bool {
    let k = key.to_ascii_lowercase();
    SENSITIVE_KEYS
        .iter()
        .any(|s| k == *s || k.contains("location") || k.contains("gps"))
}

pub fn is_location_key(key: &str) -> bool {
    let k = key.to_ascii_lowercase();
    k.contains("location") || k.contains("gps") || k == "\u{a9}xyz" || k.contains("iso6709")
}

/// Arguments for running ffprobe. The input path is passed as a single argument, never
/// through a shell, and prefixed with `file:` so names like `concat:x` aren't protocols.
pub fn ffprobe_args(input: &str) -> Vec<String> {
    vec![
        "-v".into(),
        "error".into(),
        "-hide_banner".into(),
        "-print_format".into(),
        "json".into(),
        "-show_format".into(),
        "-show_streams".into(),
        "-show_chapters".into(),
        crate::ffmpeg::file_url(input),
    ]
}

fn num_u64(v: &Value) -> Option<u64> {
    match v {
        Value::Number(n) => n.as_u64(),
        Value::String(s) => s.parse::<u64>().ok(),
        _ => None,
    }
}

fn num_f64(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.parse::<f64>().ok(),
        _ => None,
    }
}

fn str_of(v: &Value) -> Option<String> {
    v.as_str()
        .map(str::to_owned)
        .filter(|s| !s.is_empty() && s != "unknown")
}

/// Parses "30000/1001" style rationals.
pub fn parse_rational(s: &str) -> Option<f64> {
    let (n, d) = s.split_once('/')?;
    let n: f64 = n.trim().parse().ok()?;
    let d: f64 = d.trim().parse().ok()?;
    (d != 0.0 && n > 0.0).then_some(n / d)
}

fn tags(v: &Value) -> Vec<(String, String)> {
    v.get("tags")
        .and_then(Value::as_object)
        .map(|m| {
            m.iter()
                .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                .collect()
        })
        .unwrap_or_default()
}

fn rotation_of(stream: &Value) -> i32 {
    let from_side = stream
        .get("side_data_list")
        .and_then(Value::as_array)
        .and_then(|list| {
            list.iter()
                .find_map(|sd| sd.get("rotation").and_then(num_f64))
        });
    let from_tag = stream
        .get("tags")
        .and_then(|t| t.get("rotate"))
        .and_then(num_f64);
    let deg = from_side.or(from_tag).unwrap_or(0.0).round() as i32;
    // FFmpeg reports counter-clockwise display matrix rotation as negative values.
    deg.rem_euclid(360)
}

fn bit_depth_from_pix_fmt(pix: &str) -> Option<u32> {
    if pix.contains("p10") || pix.contains("10le") || pix.contains("10be") {
        Some(10)
    } else if pix.contains("p12") || pix.contains("12le") {
        Some(12)
    } else if pix.contains("p16") || pix.contains("16le") || pix.contains("64") {
        Some(16)
    } else if pix.starts_with("yuv") || pix.starts_with("nv12") || pix.starts_with("rgb") {
        Some(8)
    } else {
        None
    }
}

/// Parses `ffprobe -print_format json -show_format -show_streams -show_chapters` output.
pub fn parse_ffprobe(json: &str, path: &str, detection: Detection) -> CoreResult<MediaInfo> {
    let root: Value = serde_json::from_str(json).map_err(|e| {
        AppError::new(
            ErrorCode::CorruptFile,
            "This file couldn't be read. It may be damaged.",
        )
        .with_details(format!("ffprobe json: {e}"))
        .with_recovery(&[Recovery::CheckFile])
    })?;
    let format = root.get("format").cloned().unwrap_or(Value::Null);
    let streams = root
        .get("streams")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    let mut info = MediaInfo {
        path: path.to_string(),
        file_name: std::path::Path::new(path)
            .file_name()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default(),
        size_bytes: format
            .get("size")
            .and_then(num_u64)
            .unwrap_or(detection.size_bytes),
        family: detection.family,
        detection,
        container: format.get("format_name").and_then(str_of),
        duration_s: format
            .get("duration")
            .and_then(num_f64)
            .filter(|d| *d > 0.0),
        bit_rate: format.get("bit_rate").and_then(num_u64),
        video: Vec::new(),
        audio: Vec::new(),
        subtitles: Vec::new(),
        chapters: root
            .get("chapters")
            .and_then(Value::as_array)
            .map(|c| c.len() as u32)
            .unwrap_or(0),
        image: None,
        pdf: None,
        metadata: Vec::new(),
        has_location: false,
        inspector: "ffprobe".into(),
    };

    for s in &streams {
        let index = s.get("index").and_then(num_u64).unwrap_or(0) as u32;
        let codec = s
            .get("codec_name")
            .and_then(str_of)
            .unwrap_or_else(|| "unknown".into());
        let attached_pic = s
            .get("disposition")
            .and_then(|d| d.get("attached_pic"))
            .and_then(num_u64)
            == Some(1);
        let lang = s
            .get("tags")
            .and_then(|t| t.get("language"))
            .and_then(str_of);
        match s.get("codec_type").and_then(Value::as_str) {
            Some("video") if !attached_pic => {
                let pix_fmt = s.get("pix_fmt").and_then(str_of);
                let transfer = s.get("color_transfer").and_then(str_of);
                let hdr = matches!(transfer.as_deref(), Some("smpte2084" | "arib-std-b67"))
                    || s.get("side_data_list")
                        .and_then(Value::as_array)
                        .is_some_and(|l| {
                            l.iter().any(|sd| {
                                sd.get("side_data_type")
                                    .and_then(Value::as_str)
                                    .is_some_and(|t| t.contains("DOVI") || t.contains("Mastering"))
                            })
                        });
                let fps = s
                    .get("avg_frame_rate")
                    .and_then(Value::as_str)
                    .and_then(parse_rational)
                    .or_else(|| {
                        s.get("r_frame_rate")
                            .and_then(Value::as_str)
                            .and_then(parse_rational)
                    })
                    .filter(|f| *f < 1000.0);
                info.video.push(VideoStream {
                    index,
                    codec,
                    profile: s.get("profile").and_then(str_of),
                    width: s.get("width").and_then(num_u64).unwrap_or(0) as u32,
                    height: s.get("height").and_then(num_u64).unwrap_or(0) as u32,
                    fps,
                    bit_rate: s.get("bit_rate").and_then(num_u64),
                    bit_depth: s
                        .get("bits_per_raw_sample")
                        .and_then(num_u64)
                        .map(|b| b as u32)
                        .or_else(|| pix_fmt.as_deref().and_then(bit_depth_from_pix_fmt)),
                    pix_fmt,
                    color_transfer: transfer,
                    color_primaries: s.get("color_primaries").and_then(str_of),
                    hdr,
                    rotation: rotation_of(s),
                });
            }
            Some("audio") => info.audio.push(AudioStream {
                index,
                codec,
                sample_rate: s.get("sample_rate").and_then(num_u64).map(|v| v as u32),
                channels: s.get("channels").and_then(num_u64).map(|v| v as u32),
                channel_layout: s.get("channel_layout").and_then(str_of),
                bit_rate: s.get("bit_rate").and_then(num_u64),
                bit_depth: s
                    .get("bits_per_raw_sample")
                    .and_then(num_u64)
                    .map(|b| b as u32)
                    .filter(|b| *b > 0),
                language: lang,
            }),
            Some("subtitle") => info.subtitles.push(SubtitleStream {
                index,
                codec,
                language: lang,
            }),
            _ => {}
        }
        for (k, _) in tags(s) {
            if is_location_key(&k) {
                info.has_location = true;
            }
        }
    }

    for (key, value) in tags(&format) {
        if is_location_key(&key) {
            info.has_location = true;
        }
        info.metadata.push(MetadataEntry {
            sensitive: is_sensitive_key(&key),
            key,
            value,
        });
    }

    // Refine the family: containers can be audio-only, images can be probed too.
    info.family = match info.detection.family {
        Family::Video | Family::Audio => {
            if !info.video.is_empty() {
                Family::Video
            } else if !info.audio.is_empty() {
                Family::Audio
            } else {
                return Err(AppError::new(
                    ErrorCode::CorruptFile,
                    "This file doesn't contain any playable audio or video.",
                )
                .with_recovery(&[Recovery::CheckFile]));
            }
        }
        other => other,
    };

    Ok(info)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::detect::detect_bytes;

    const MOV_JSON: &str = r#"{
      "streams": [
        {"index":0,"codec_name":"hevc","profile":"Main 10","codec_type":"video","width":3840,"height":2160,
         "pix_fmt":"yuv420p10le","color_transfer":"arib-std-b67","color_primaries":"bt2020",
         "avg_frame_rate":"30000/1001","bit_rate":"45000000",
         "side_data_list":[{"side_data_type":"Display Matrix","rotation":-90}]},
        {"index":1,"codec_name":"aac","codec_type":"audio","sample_rate":"48000","channels":2,
         "channel_layout":"stereo","bit_rate":"256000","tags":{"language":"und"}},
        {"index":2,"codec_name":"mjpeg","codec_type":"video","width":320,"height":240,
         "disposition":{"attached_pic":1}}
      ],
      "chapters": [{"id":0},{"id":1}],
      "format": {"format_name":"mov,mp4,m4a,3gp,3g2,mj2","duration":"2608.4","size":"1524713390",
         "bit_rate":"4676000","tags":{"com.apple.quicktime.location.ISO6709":"+40.4168-003.7038/",
         "com.apple.quicktime.make":"Apple","major_brand":"qt  "}}
    }"#;

    #[test]
    fn parses_hdr_hevc_mov() {
        let det = detect_bytes(b"\0\0\0\x14ftypqt  \0\0\0\0qt  ", None, Some("mov"));
        let info = parse_ffprobe(MOV_JSON, "/tmp/grabacion.mov", det).expect("parse");
        assert_eq!(info.family, Family::Video);
        assert_eq!(
            info.video.len(),
            1,
            "attached pictures are not video streams"
        );
        let v = &info.video[0];
        assert_eq!(v.codec, "hevc");
        assert!(v.hdr);
        assert_eq!(v.bit_depth, Some(10));
        assert_eq!(v.rotation, 270);
        assert_eq!(v.display_size(), (2160, 3840));
        assert!((v.fps.unwrap_or_default() - 29.97).abs() < 0.01);
        assert_eq!(info.audio[0].channels, Some(2));
        assert_eq!(info.chapters, 2);
        assert!(info.has_location);
        assert_eq!(info.size_bytes, 1_524_713_390);
        assert!(
            info.metadata
                .iter()
                .any(|m| m.sensitive && m.key.contains("make"))
        );
        assert_eq!(info.file_name, "grabacion.mov");
    }

    #[test]
    fn audio_only_mp4_is_audio() {
        let json = r#"{"streams":[{"index":0,"codec_name":"aac","codec_type":"audio","channels":1}],
                       "format":{"duration":"3.0"}}"#;
        let det = detect_bytes(b"\0\0\0\x14ftypisom\0\0\0\0isom", None, Some("mp4"));
        let info = parse_ffprobe(json, "/x/a.mp4", det).expect("parse");
        assert_eq!(info.family, Family::Audio);
    }

    #[test]
    fn empty_container_is_corrupt() {
        let det = detect_bytes(b"\0\0\0\x14ftypisom\0\0\0\0isom", None, Some("mp4"));
        let err = parse_ffprobe(r#"{"streams":[],"format":{}}"#, "/x/a.mp4", det)
            .expect_err("should fail");
        assert_eq!(err.code, ErrorCode::CorruptFile);
        let err = parse_ffprobe("not json", "/x/a.mp4", detect_bytes(b"", None, None))
            .expect_err("should fail");
        assert_eq!(err.code, ErrorCode::CorruptFile);
    }

    #[test]
    fn rationals() {
        assert_eq!(parse_rational("25/1"), Some(25.0));
        assert_eq!(parse_rational("0/0"), None);
        assert_eq!(parse_rational("garbage"), None);
    }

    #[test]
    fn ffprobe_args_protect_paths() {
        let args = ffprobe_args("/Users/me/concat:a|b.mov");
        assert_eq!(
            args.last().map(String::as_str),
            Some("file:/Users/me/concat:a|b.mov")
        );
    }
}
