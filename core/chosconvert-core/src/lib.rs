//! ChosConvert core: portable logic shared by the macOS and Windows apps.
//!
//! Responsibilities: content-based detection, inspection models, capability discovery,
//! conversion planning (intent → engine instructions), FFmpeg execution with progress and
//! cancellation, target-size optimization, safe temp handling and output finalization.
//! UI and platform codecs live in the native apps.

#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used))]

pub mod actions;
pub mod api;
pub mod cancel;
pub mod capabilities;
pub mod detect;
pub mod error;
pub mod executor;
pub mod ffmpeg;
pub mod formats;
pub mod jobs;
pub mod media;
pub mod output;
pub mod planner;
pub mod target_size;
pub mod tasks;
pub mod temp;
pub mod webp;

pub use error::{AppError, CoreResult, ErrorCategory, ErrorCode, Recovery};
