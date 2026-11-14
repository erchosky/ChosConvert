//! ConversionPlanner: turns (input, intent, options, capabilities) into a ConversionPlan.
//!
//! The UI never builds engine commands. It expresses an intent; the planner picks the engine,
//! decides whether re-encoding is necessary (remux whenever possible), and produces concrete
//! engine instructions plus human-readable steps, notes and estimates.

mod encoders;
mod image;
mod media;
mod native_av;

use serde::{Deserialize, Serialize};

pub use encoders::{EncoderChoice, SelectedEncoder};

use crate::capabilities::Capabilities;
use crate::error::{AppError, CoreResult, ErrorCode, Recovery};
use crate::formats::{Family, Format};
use crate::media::MediaInfo;
use crate::target_size::{TargetSizeBudget, VideoCodec};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum QualityLevel {
    Smaller,
    #[default]
    Balanced,
    High,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum MetadataScope {
    #[default]
    All,
    Location,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Intent {
    MakeSmaller {
        #[serde(default)]
        level: QualityLevel,
    },
    Convert {
        format: Format,
    },
    ExtractAudio {
        #[serde(default)]
        format: Option<Format>,
    },
    RemoveMetadata {
        #[serde(default)]
        scope: MetadataScope,
    },
    Resize {
        max_dimension: u32,
    },
    WebOptimize,
    TargetSize {
        target_bytes: u64,
    },
    CreateGif {
        #[serde(default)]
        start_s: f64,
        #[serde(default = "gif_duration")]
        duration_s: f64,
        #[serde(default = "gif_width")]
        width: u32,
        #[serde(default = "gif_fps")]
        fps: u32,
    },
}

fn gif_duration() -> f64 {
    6.0
}
fn gif_width() -> u32 {
    480
}
fn gif_fps() -> u32 {
    12
}

/// Advanced-mode overrides. Every field is optional; `None` means "let ChosConvert decide".
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct AdvancedOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub container: Option<Format>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_codec: Option<VideoCodec>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encoder: Option<EncoderChoice>,
    /// CRF/CQ-style quality value in the encoder's native scale.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub crf: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_kbps: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub two_pass: Option<bool>,
    /// Limit the short side of the video (e.g. 1080).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_short_side: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fps: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_codec: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_kbps: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub audio_channels: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sample_rate: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remove_audio: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub strip_metadata: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keep_subtitles: Option<bool>,
    /// 0…1 for image encoders.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_quality: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_max_dimension: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_lossless: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub convert_to_srgb: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanRequest {
    pub input: MediaInfo,
    pub intent: Intent,
    #[serde(default)]
    pub options: AdvancedOptions,
    pub capabilities: Capabilities,
    /// Engine override for diagnostics/dev builds: "ffmpeg", "native_av", "native_image".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub engine_override: Option<EngineKind>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EngineKind {
    NativeImage,
    NativeAv,
    Ffmpeg,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PlanStep {
    Inspect,
    Remux,
    CopyVideo,
    TranscodeVideo,
    Scale,
    ReduceFrameRate,
    CopyAudio,
    TranscodeAudio,
    RemoveAudio,
    ConvertSubtitles,
    StripMetadata,
    StripLocation,
    CalculateBudget,
    TwoPassEncode,
    EncodeImage,
    ResizeImage,
    ConvertColorProfile,
    FlattenAlpha,
    RenderGif,
    Verify,
    Refine,
    Finalize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanNote {
    /// Localization id: `note.<code>`.
    pub code: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
}

impl PlanNote {
    pub fn new(code: &str) -> Self {
        Self {
            code: code.into(),
            args: Vec::new(),
        }
    }
    pub fn with(code: &str, args: &[String]) -> Self {
        Self {
            code: code.into(),
            args: args.to_vec(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EstimateConfidence {
    High,
    Medium,
    Low,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SizeEstimate {
    pub bytes: u64,
    pub low_bytes: u64,
    pub high_bytes: u64,
    pub confidence: EstimateConfidence,
}

impl SizeEstimate {
    fn around(bytes: f64, spread: f64, confidence: EstimateConfidence) -> Self {
        Self {
            bytes: bytes.max(0.0) as u64,
            low_bytes: (bytes * (1.0 - spread)).max(0.0) as u64,
            high_bytes: (bytes * (1.0 + spread)).max(0.0) as u64,
            confidence,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ImageMetadataPolicy {
    #[default]
    Keep,
    StripLocation,
    StripAll,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ImageEncoder {
    /// Platform codec (ImageIO / WIC).
    Native,
    /// The core's bundled libwebp.
    CoreWebp,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ImageJob {
    pub output_format: Format,
    pub encoder: ImageEncoder,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quality: Option<f64>,
    pub lossless: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_dimension: Option<u32>,
    pub metadata: ImageMetadataPolicy,
    pub convert_to_srgb: bool,
    /// RGB background for flattening alpha into formats without transparency.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub flatten_background: Option<[u8; 3]>,
    /// Rewrite metadata without re-encoding pixels (lossless metadata edit).
    pub metadata_only: bool,
    /// Max decoded pixel count accepted (decompression-bomb guard).
    pub max_pixels: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FfmpegPass {
    /// Argument template; see `ffmpeg::materialize` for placeholders.
    pub args: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FfmpegJob {
    pub passes: Vec<FfmpegPass>,
    /// Expected output duration, for progress.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_s: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_encoder: Option<String>,
    #[serde(default)]
    pub hardware: bool,
    /// Software alternative used automatically if a hardware encode fails.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback: Option<Box<FfmpegJob>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NativeAvJob {
    /// AVAssetExportSession preset name (macOS) or equivalent identifier.
    pub preset: String,
    /// Output container.
    pub file_type: Format,
    pub strip_metadata: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub time_range: Option<(f64, f64)>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct VerifySpec {
    pub expect_family: Option<Family>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expect_duration_s: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_bytes: Option<u64>,
    /// Fail with `not_smaller` when the result isn't smaller than this.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub must_be_smaller_than: Option<u64>,
    #[serde(default)]
    pub expect_no_location: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConversionPlan {
    pub engine: EngineKind,
    pub output_format: Format,
    pub output_extension: String,
    pub reencode: bool,
    pub steps: Vec<PlanStep>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<PlanNote>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub estimate: Option<SizeEstimate>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<ImageJob>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ffmpeg: Option<FfmpegJob>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub native_av: Option<NativeAvJob>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_budget: Option<TargetSizeBudget>,
    pub verify: VerifySpec,
}

pub(crate) fn unsupported(msg: &str) -> AppError {
    AppError::new(ErrorCode::UnsupportedOperation, msg)
        .with_recovery(&[Recovery::ChooseOtherFormat])
}

pub(crate) fn engine_missing() -> AppError {
    AppError::new(
        ErrorCode::EngineUnavailable,
        "This conversion needs a media engine that isn't available on this Mac.",
    )
    .with_recovery(&[Recovery::InstallEngine, Recovery::ChooseOtherFormat])
}

/// Creates a plan for one input.
pub fn plan(req: &PlanRequest) -> CoreResult<ConversionPlan> {
    plan_with_budget(req, None)
}

/// Creates a plan, optionally forcing a target-size budget (used by refinement passes).
pub fn plan_with_budget(
    req: &PlanRequest,
    budget: Option<&TargetSizeBudget>,
) -> CoreResult<ConversionPlan> {
    let det = &req.input.detection;
    if !det.is_processable() {
        return Err(AppError::new(
            ErrorCode::UnknownFormat,
            "ChosConvert can't process this kind of file.",
        ));
    }
    match req.input.family {
        Family::Image => image::plan(req),
        Family::Video | Family::Audio => media::plan(req, budget),
        Family::Pdf | Family::Document => Err(unsupported(
            "Conversions for this kind of document aren't available yet.",
        )),
        _ => Err(unsupported("ChosConvert can't process this kind of file.")),
    }
}

#[cfg(test)]
mod tests;
