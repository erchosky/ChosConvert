//! Smart actions: the intent-first menu for a set of files.
//!
//! Availability is decided by asking the planner, so an action is only listed when this
//! installation can actually perform it on these files.

use serde::{Deserialize, Serialize};

use crate::capabilities::Capabilities;
use crate::formats::{Family, Format};
use crate::media::MediaInfo;
use crate::planner::{self, AdvancedOptions, Intent, MetadataScope, PlanRequest, QualityLevel};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionId {
    MakeSmaller,
    TargetSize,
    Convert,
    ExtractAudio,
    CreateGif,
    Resize,
    WebOptimize,
    RemoveMetadata,
    RemoveLocation,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SmartAction {
    pub id: ActionId,
    /// Shown in the first row of the menu.
    pub primary: bool,
    /// For `convert` / `extract_audio`: the output formats that work for every file.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub formats: Vec<Format>,
}

const IMAGE_TARGETS: &[Format] = &[
    Format::Jpeg,
    Format::Png,
    Format::Webp,
    Format::Heic,
    Format::Avif,
    Format::Tiff,
    Format::Gif,
    Format::Bmp,
];
const VIDEO_TARGETS: &[Format] = &[
    Format::Mp4,
    Format::Mov,
    Format::Mkv,
    Format::Webm,
    Format::Gif,
];
const AUDIO_TARGETS: &[Format] = &[
    Format::Mp3,
    Format::M4a,
    Format::Wav,
    Format::Flac,
    Format::Opus,
    Format::Aiff,
    Format::Ogg,
];

fn works(info: &MediaInfo, caps: &Capabilities, intent: Intent) -> bool {
    let req = PlanRequest {
        input: info.clone(),
        intent,
        options: AdvancedOptions::default(),
        capabilities: caps.clone(),
        engine_override: None,
    };
    planner::plan(&req).is_ok()
}

fn works_all(files: &[MediaInfo], caps: &Capabilities, intent: &Intent) -> bool {
    !files.is_empty() && files.iter().all(|f| works(f, caps, intent.clone()))
}

/// Computes the ordered action list for the given files.
pub fn actions_for(files: &[MediaInfo], caps: &Capabilities) -> Vec<SmartAction> {
    let mut out = Vec::new();
    if files.is_empty() {
        return out;
    }
    let family = files[0].family;
    let uniform = files.iter().all(|f| f.family == family);
    let push = |out: &mut Vec<SmartAction>, id: ActionId, primary: bool, intent: Intent| {
        if works_all(files, caps, &intent) {
            out.push(SmartAction {
                id,
                primary,
                formats: Vec::new(),
            });
        }
    };

    push(
        &mut out,
        ActionId::MakeSmaller,
        true,
        Intent::MakeSmaller {
            level: QualityLevel::Balanced,
        },
    );
    if uniform && family == Family::Video {
        push(
            &mut out,
            ActionId::TargetSize,
            true,
            Intent::TargetSize {
                target_bytes: 25_000_000,
            },
        );
    }

    if uniform {
        let candidates: &[Format] = match family {
            Family::Image => IMAGE_TARGETS,
            Family::Video => VIDEO_TARGETS,
            Family::Audio => AUDIO_TARGETS,
            _ => &[],
        };
        let formats: Vec<Format> = candidates
            .iter()
            .copied()
            .filter(|f| {
                // Offer converting to the same format only when it isn't a no-op.
                files.iter().any(|i| i.detection.format != *f)
                    && works_all(files, caps, &Intent::Convert { format: *f })
            })
            .collect();
        if !formats.is_empty() {
            out.push(SmartAction {
                id: ActionId::Convert,
                primary: true,
                formats,
            });
        }
    }

    if uniform && family == Family::Video {
        let formats: Vec<Format> = AUDIO_TARGETS
            .iter()
            .copied()
            .filter(|f| works_all(files, caps, &Intent::ExtractAudio { format: Some(*f) }))
            .collect();
        if works_all(files, caps, &Intent::ExtractAudio { format: None }) {
            out.push(SmartAction {
                id: ActionId::ExtractAudio,
                primary: true,
                formats,
            });
        }
        push(
            &mut out,
            ActionId::CreateGif,
            false,
            Intent::CreateGif {
                start_s: 0.0,
                duration_s: 6.0,
                width: 480,
                fps: 12,
            },
        );
    }
    if uniform && family == Family::Image {
        push(&mut out, ActionId::WebOptimize, true, Intent::WebOptimize);
        push(
            &mut out,
            ActionId::Resize,
            false,
            Intent::Resize {
                max_dimension: 1920,
            },
        );
    }
    if uniform && family == Family::Video {
        push(
            &mut out,
            ActionId::Resize,
            false,
            Intent::Resize {
                max_dimension: 1080,
            },
        );
    }

    let has_location = files
        .iter()
        .any(|f| f.has_location || f.image.as_ref().is_some_and(|i| i.has_gps));
    push(
        &mut out,
        ActionId::RemoveMetadata,
        false,
        Intent::RemoveMetadata {
            scope: MetadataScope::All,
        },
    );
    if has_location {
        push(
            &mut out,
            ActionId::RemoveLocation,
            true,
            Intent::RemoveMetadata {
                scope: MetadataScope::Location,
            },
        );
    }
    out
}
