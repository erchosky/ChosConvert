//! JSON request/response API used by the C ABI.
//!
//! Every call returns an envelope: `{"ok":true,"result":…}` or `{"ok":false,"error":AppError}`.
//! Request/response shapes are the serde representations of the core's public models, which
//! are versioned through `API_VERSION`.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::actions;
use crate::cancel::CancelToken;
use crate::capabilities::{self, Capabilities};
use crate::detect;
use crate::error::{AppError, CoreResult};
use crate::executor::{self, ExecEvent, ExecuteRequest};
use crate::jobs::{self, ConcurrencyInput};
use crate::media::MediaInfo;
use crate::output::{self, OutputPolicy};
use crate::planner::{self, PlanRequest};
use crate::target_size::{self, TargetSizeInput};
use crate::temp;

/// Bumped whenever a request/response shape changes incompatibly.
pub const API_VERSION: u32 = 1;

pub fn envelope_ok(v: Value) -> String {
    json!({ "ok": true, "result": v }).to_string()
}

pub fn envelope_err(e: &AppError) -> String {
    json!({ "ok": false, "error": e }).to_string()
}

fn parse<T: DeserializeOwned>(payload: &str) -> CoreResult<T> {
    serde_json::from_str(payload).map_err(|e| AppError::invalid_request(e.to_string()))
}

fn to_value<T: Serialize>(v: &T) -> CoreResult<Value> {
    serde_json::to_value(v).map_err(|e| AppError::internal(e.to_string()))
}

#[derive(Deserialize)]
struct PathReq {
    path: String,
}

#[derive(Deserialize)]
struct ProbeReq {
    path: String,
    ffprobe_path: String,
}

#[derive(Deserialize)]
struct FfmpegProbeReq {
    ffmpeg_path: String,
    #[serde(default)]
    ffprobe_path: Option<String>,
}

#[derive(Deserialize)]
struct ActionsReq {
    files: Vec<MediaInfo>,
    capabilities: Capabilities,
}

#[derive(Deserialize)]
struct OutputReq {
    source: String,
    extension: String,
    #[serde(default)]
    stem: Option<String>,
    #[serde(default)]
    policy: OutputPolicy,
    #[serde(default)]
    temp_file: Option<String>,
}

#[derive(Deserialize)]
struct JobDirReq {
    root: String,
    job_id: String,
}

#[derive(Deserialize)]
struct RemoveDirReq {
    root: String,
    dir: String,
}

#[derive(Deserialize)]
struct CleanupReq {
    root: String,
    #[serde(default)]
    min_age_s: u64,
    #[serde(default)]
    active: Vec<String>,
}

fn abs(p: &str) -> CoreResult<PathBuf> {
    let pb = PathBuf::from(p);
    if pb.is_absolute() {
        Ok(pb)
    } else {
        Err(AppError::invalid_request("paths must be absolute"))
    }
}

/// Dispatches a synchronous call.
pub fn call(method: &str, payload: &str) -> CoreResult<Value> {
    match method {
        "core.info" => Ok(json!({
            "name": "chosconvert-core",
            "version": env!("CARGO_PKG_VERSION"),
            "api_version": API_VERSION,
            "webp_version": crate::webp::version(),
            "target": format!("{}-{}", std::env::consts::ARCH, std::env::consts::OS),
        })),
        "detect.path" => {
            let r: PathReq = parse(payload)?;
            to_value(&detect::detect_path(&abs(&r.path)?)?)
        }
        "media.probe" => {
            let r: ProbeReq = parse(payload)?;
            let info = executor::probe(
                Path::new(&r.ffprobe_path),
                &abs(&r.path)?,
                &CancelToken::new(),
            )?;
            to_value(&info)
        }
        "capabilities.probe_ffmpeg" => {
            let r: FfmpegProbeReq = parse(payload)?;
            let caps = capabilities::probe_ffmpeg(
                &abs(&r.ffmpeg_path)?,
                r.ffprobe_path.as_deref().map(Path::new),
            )?;
            to_value(&caps)
        }
        "actions.for_files" => {
            let r: ActionsReq = parse(payload)?;
            to_value(&actions::actions_for(&r.files, &r.capabilities))
        }
        "plan.create" => {
            let r: PlanRequest = parse(payload)?;
            to_value(&planner::plan(&r)?)
        }
        "output.preview" => {
            let r: OutputReq = parse(payload)?;
            to_value(&output::preview_output(
                &abs(&r.source)?,
                &r.extension,
                r.stem.as_deref(),
                &r.policy,
            )?)
        }
        "output.finalize" => {
            let r: OutputReq = parse(payload)?;
            let temp_file = r
                .temp_file
                .ok_or_else(|| AppError::invalid_request("temp_file is required"))?;
            to_value(&output::finalize(
                &abs(&temp_file)?,
                &abs(&r.source)?,
                &r.extension,
                r.stem.as_deref(),
                &r.policy,
            )?)
        }
        "temp.create_job_dir" => {
            let r: JobDirReq = parse(payload)?;
            to_value(&temp::create_job_dir(&abs(&r.root)?, &r.job_id)?)
        }
        "temp.remove_job_dir" => {
            let r: RemoveDirReq = parse(payload)?;
            to_value(&temp::remove_job_dir(&abs(&r.root)?, &abs(&r.dir)?)?)
        }
        "temp.cleanup_stale" => {
            let r: CleanupReq = parse(payload)?;
            to_value(&temp::cleanup_stale(
                &abs(&r.root)?,
                Duration::from_secs(r.min_age_s),
                &r.active,
            )?)
        }
        "target_size.compute" => {
            let r: TargetSizeInput = parse(payload)?;
            to_value(&target_size::compute(&r)?)
        }
        "jobs.recommended_concurrency" => {
            let r: ConcurrencyInput = parse(payload)?;
            Ok(json!(jobs::recommended_concurrency(&r)))
        }
        _ => Err(AppError::invalid_request(format!(
            "unknown method {method}"
        ))),
    }
}

/// Dispatches a long-running task. Events are JSON objects with a `type` field.
pub fn run_task(
    method: &str,
    payload: &str,
    cancel: &CancelToken,
    emit: &mut dyn FnMut(Value),
) -> CoreResult<Value> {
    match method {
        "media.execute" => {
            let r: ExecuteRequest = parse(payload)?;
            let mut forward = |e: ExecEvent| {
                if let Ok(v) = serde_json::to_value(&e) {
                    emit(v);
                }
            };
            let res = executor::execute(&r, cancel, &mut forward)?;
            to_value(&res)
        }
        "media.probe" => {
            let r: ProbeReq = parse(payload)?;
            let info = executor::probe(Path::new(&r.ffprobe_path), &abs(&r.path)?, cancel)?;
            to_value(&info)
        }
        _ => Err(AppError::invalid_request(format!("unknown task {method}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_method_is_structured_error() {
        let err = call("nope", "{}").expect_err("err");
        let env = envelope_err(&err);
        let v: Value = serde_json::from_str(&env).expect("json");
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"]["code"], "invalid_request");
        assert_eq!(v["error"]["category"], "validation");
    }

    #[test]
    fn core_info() {
        let v = call("core.info", "{}").expect("info");
        assert_eq!(v["api_version"], API_VERSION);
    }

    #[test]
    fn malformed_payloads_do_not_panic() {
        for m in [
            "detect.path",
            "plan.create",
            "output.finalize",
            "temp.create_job_dir",
        ] {
            assert!(call(m, "{not json").is_err());
            assert!(call(m, "{}").is_err());
        }
        assert!(call("detect.path", r#"{"path":"relative.png"}"#).is_err());
    }
}
