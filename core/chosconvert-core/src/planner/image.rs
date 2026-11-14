//! Planning for still images (platform codecs + bundled libwebp).

use super::{
    ConversionPlan, EngineKind, ImageEncoder, ImageJob, ImageMetadataPolicy, Intent, MetadataScope,
    PlanNote, PlanRequest, PlanStep, QualityLevel, VerifySpec, unsupported,
};
use crate::error::{AppError, CoreResult, ErrorCode};
use crate::formats::{Family, Format};

/// Decompression-bomb guard: refuse to decode more than this many pixels.
pub const MAX_PIXELS: u64 = 400_000_000;

fn supports_alpha(f: Format) -> bool {
    matches!(
        f,
        Format::Png | Format::Webp | Format::Avif | Format::Heic | Format::Tiff | Format::Gif
    )
}

fn lossy(f: Format) -> bool {
    matches!(f, Format::Jpeg | Format::Webp | Format::Avif | Format::Heic)
}

fn default_quality(f: Format, level: QualityLevel) -> Option<f64> {
    if !lossy(f) {
        return None;
    }
    let (s, b, h) = match f {
        Format::Jpeg => (0.62, 0.78, 0.9),
        Format::Webp => (0.6, 0.78, 0.9),
        Format::Heic => (0.5, 0.65, 0.82),
        Format::Avif => (0.45, 0.6, 0.78),
        _ => (0.7, 0.8, 0.9),
    };
    Some(match level {
        QualityLevel::Smaller => s,
        QualityLevel::Balanced => b,
        QualityLevel::High => h,
    })
}

pub fn plan(req: &PlanRequest) -> CoreResult<ConversionPlan> {
    let info = &req.input;
    let caps = &req.capabilities;
    let opts = &req.options;
    let src = info.detection.format;
    let img = info.image.clone().unwrap_or_default();
    let (w, h) = img.display_size();
    let pixels = w as u64 * h as u64;
    if pixels > MAX_PIXELS {
        return Err(AppError::new(
            ErrorCode::ImageTooLarge,
            "This image is too large to process safely.",
        )
        .with_details(format!("{w}x{h}")));
    }
    if !caps.can_read_image(src) {
        return Err(unsupported(
            "This image format can't be read on this computer.",
        ));
    }
    if img.frame_count > 1 && src == Format::Gif {
        return Err(unsupported(
            "Animated GIFs aren't supported for this action yet.",
        ));
    }

    let mut notes = Vec::new();
    let mut steps = vec![PlanStep::Inspect];
    let mut metadata = if opts.strip_metadata == Some(true) {
        ImageMetadataPolicy::StripAll
    } else {
        ImageMetadataPolicy::Keep
    };
    let mut srgb = opts.convert_to_srgb.unwrap_or(false);
    let mut max_dim = opts.image_max_dimension;
    let mut metadata_only = false;
    let mut must_be_smaller = false;

    let (format, level) = match &req.intent {
        Intent::Convert { format } => (*format, QualityLevel::High),
        Intent::MakeSmaller { level } => {
            must_be_smaller = true;
            let target = match src {
                // Lossless sources compress far better in a modern lossy-capable format.
                Format::Png | Format::Tiff | Format::Bmp if caps.can_write_image(Format::Webp) => {
                    notes.push(PlanNote::with("format_changed_for_size", &["WebP".into()]));
                    Format::Webp
                }
                Format::Png | Format::Tiff | Format::Bmp if !img.has_alpha => {
                    notes.push(PlanNote::with("format_changed_for_size", &["JPEG".into()]));
                    Format::Jpeg
                }
                f if caps.can_write_image(f) && lossy(f) => f,
                _ => Format::Jpeg,
            };
            if *level == QualityLevel::Smaller && max_dim.is_none() && w.max(h) > 2560 {
                max_dim = Some(2560);
            }
            (target, *level)
        }
        Intent::Resize { max_dimension } => {
            max_dim = Some(*max_dimension);
            let f = if caps.can_write_image(src) {
                src
            } else {
                Format::Png
            };
            (f, QualityLevel::High)
        }
        Intent::WebOptimize => {
            srgb = true;
            metadata = ImageMetadataPolicy::StripAll;
            if max_dim.is_none() && w.max(h) > 1920 {
                max_dim = Some(1920);
                notes.push(PlanNote::with(
                    "larger_than_web_display",
                    &[format!("{w}x{h}")],
                ));
            }
            let f = if caps.can_write_image(Format::Webp) {
                Format::Webp
            } else {
                Format::Jpeg
            };
            (f, QualityLevel::Balanced)
        }
        Intent::RemoveMetadata { scope } => {
            metadata = match scope {
                MetadataScope::All => ImageMetadataPolicy::StripAll,
                MetadataScope::Location => ImageMetadataPolicy::StripLocation,
            };
            // JPEG/PNG/TIFF/HEIC metadata can be rewritten without re-encoding pixels.
            metadata_only = matches!(
                src,
                Format::Jpeg | Format::Png | Format::Tiff | Format::Heic
            );
            let f = if caps.can_write_image(src) {
                src
            } else {
                Format::Png
            };
            (f, QualityLevel::High)
        }
        _ => return Err(unsupported("This action isn't available for images.")),
    };

    if !caps.can_write_image(format) {
        return Err(unsupported(
            "This image format can't be written on this computer.",
        ));
    }
    if format.family() != Family::Image || format == Format::Svg {
        return Err(unsupported("That isn't an output image format."));
    }

    let encoder = if format == Format::Webp && !caps.native_image.write.contains(&Format::Webp) {
        ImageEncoder::CoreWebp
    } else {
        ImageEncoder::Native
    };
    let lossless = opts.image_lossless.unwrap_or(!lossy(format));
    let quality = if lossless {
        None
    } else {
        opts.image_quality
            .map(|q| q.clamp(0.0, 1.0))
            .or_else(|| default_quality(format, level))
    };
    let flatten = (img.has_alpha && !supports_alpha(format)).then_some([255, 255, 255]);
    if let Some(d) = max_dim {
        if d == 0 {
            return Err(AppError::invalid_request("max dimension must be positive"));
        }
        if d >= w.max(h) {
            max_dim = None; // never upscale
        }
    }
    if src == Format::Svg {
        notes.push(PlanNote::new("svg_rasterized"));
    }

    if metadata_only {
        steps.push(match metadata {
            ImageMetadataPolicy::StripLocation => PlanStep::StripLocation,
            _ => PlanStep::StripMetadata,
        });
        notes.push(PlanNote::new("metadata_only_no_reencode"));
    } else {
        if max_dim.is_some() {
            steps.push(PlanStep::ResizeImage);
        }
        if srgb {
            steps.push(PlanStep::ConvertColorProfile);
        }
        if flatten.is_some() {
            steps.push(PlanStep::FlattenAlpha);
            notes.push(PlanNote::new("alpha_flattened"));
        }
        steps.push(PlanStep::EncodeImage);
        match metadata {
            ImageMetadataPolicy::StripAll => steps.push(PlanStep::StripMetadata),
            ImageMetadataPolicy::StripLocation => steps.push(PlanStep::StripLocation),
            ImageMetadataPolicy::Keep => {}
        }
    }
    steps.extend([PlanStep::Verify, PlanStep::Finalize]);

    Ok(ConversionPlan {
        engine: EngineKind::NativeImage,
        output_format: format,
        output_extension: format.primary_extension().to_string(),
        reencode: !metadata_only,
        steps,
        notes,
        estimate: None,
        image: Some(ImageJob {
            output_format: format,
            encoder,
            quality,
            lossless,
            max_dimension: max_dim,
            metadata,
            convert_to_srgb: srgb,
            flatten_background: flatten,
            metadata_only,
            max_pixels: MAX_PIXELS,
        }),
        ffmpeg: None,
        native_av: None,
        target_budget: None,
        verify: VerifySpec {
            expect_family: Some(Family::Image),
            must_be_smaller_than: must_be_smaller.then_some(info.size_bytes),
            expect_no_location: metadata != ImageMetadataPolicy::Keep,
            ..Default::default()
        },
    })
}
