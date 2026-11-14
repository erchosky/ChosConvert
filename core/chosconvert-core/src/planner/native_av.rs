//! Plans for the platform media framework (AVFoundation export presets on macOS).
//!
//! Used when FFmpeg is not part of the distribution. Presets give less control than FFmpeg,
//! so only intents that map cleanly onto them are offered.

use super::{
    ConversionPlan, EngineKind, EstimateConfidence, Intent, NativeAvJob, PlanNote, PlanRequest,
    PlanStep, QualityLevel, SizeEstimate, VerifySpec, unsupported,
};
use crate::error::CoreResult;
use crate::formats::{Family, Format};

const PASSTHROUGH: &str = "AVAssetExportPresetPassthrough";
const M4A: &str = "AVAssetExportPresetAppleM4A";
const HEVC_HIGHEST: &str = "AVAssetExportPresetHEVCHighestQuality";
const HEVC_1080: &str = "AVAssetExportPresetHEVC1920x1080";
const H264_720: &str = "AVAssetExportPreset1280x720";
const H264_1080: &str = "AVAssetExportPreset1920x1080";

pub fn plan(req: &PlanRequest) -> CoreResult<ConversionPlan> {
    let info = &req.input;
    let caps = &req.capabilities.native_av;
    let video = info.family == Family::Video;
    let short = info
        .primary_video()
        .map(|v| {
            let (w, h) = v.display_size();
            w.min(h)
        })
        .unwrap_or(0);

    let (preset, file_type, steps, strip, verify_smaller, notes): (
        &str,
        Format,
        Vec<PlanStep>,
        bool,
        bool,
        Vec<PlanNote>,
    ) = match (&req.intent, video) {
        (Intent::MakeSmaller { level }, true) => {
            let preset = match level {
                QualityLevel::Smaller if caps.h264_encode => H264_720,
                QualityLevel::Smaller | QualityLevel::Balanced
                    if caps.hevc_encode && short > 1080 =>
                {
                    HEVC_1080
                }
                _ if caps.hevc_encode => HEVC_HIGHEST,
                _ if caps.h264_encode => H264_1080,
                _ => return Err(super::engine_missing()),
            };
            (
                preset,
                Format::Mp4,
                vec![
                    PlanStep::Inspect,
                    PlanStep::TranscodeVideo,
                    PlanStep::Verify,
                    PlanStep::Finalize,
                ],
                false,
                true,
                vec![PlanNote::new("native_preset_limited_control")],
            )
        }
        (
            Intent::Convert {
                format: f @ (Format::Mp4 | Format::Mov),
            },
            true,
        ) => (
            PASSTHROUGH,
            *f,
            vec![
                PlanStep::Inspect,
                PlanStep::Remux,
                PlanStep::Verify,
                PlanStep::Finalize,
            ],
            false,
            false,
            vec![PlanNote::new("remux_no_quality_loss")],
        ),
        (
            Intent::ExtractAudio {
                format: None | Some(Format::M4a),
            },
            true,
        )
        | (
            Intent::Convert {
                format: Format::M4a,
            },
            _,
        ) if caps.aac_encode => (
            M4A,
            Format::M4a,
            vec![
                PlanStep::Inspect,
                PlanStep::TranscodeAudio,
                PlanStep::Verify,
                PlanStep::Finalize,
            ],
            false,
            false,
            Vec::new(),
        ),
        (Intent::RemoveMetadata { .. }, _)
            if matches!(
                info.detection.format,
                Format::Mp4 | Format::Mov | Format::M4a
            ) =>
        {
            (
                PASSTHROUGH,
                info.detection.format,
                vec![
                    PlanStep::Inspect,
                    PlanStep::Remux,
                    PlanStep::StripMetadata,
                    PlanStep::Verify,
                    PlanStep::Finalize,
                ],
                true,
                false,
                vec![PlanNote::new("remux_no_quality_loss")],
            )
        }
        _ => {
            return Err(super::engine_missing()
                .with_details("intent not expressible with native export presets"));
        }
    };
    if !caps.available {
        return Err(unsupported("The system media framework isn't available."));
    }
    let estimate = (preset == PASSTHROUGH)
        .then(|| SizeEstimate::around(info.size_bytes as f64, 0.05, EstimateConfidence::High));
    Ok(ConversionPlan {
        engine: EngineKind::NativeAv,
        output_format: file_type,
        output_extension: file_type.primary_extension().to_string(),
        reencode: preset != PASSTHROUGH,
        steps,
        notes,
        estimate,
        image: None,
        ffmpeg: None,
        native_av: Some(NativeAvJob {
            preset: preset.to_string(),
            file_type,
            strip_metadata: strip,
            time_range: None,
        }),
        target_budget: None,
        verify: VerifySpec {
            expect_family: Some(file_type.family()),
            expect_duration_s: info.duration_s,
            must_be_smaller_than: verify_smaller.then_some(info.size_bytes),
            expect_no_location: strip,
            ..Default::default()
        },
    })
}
