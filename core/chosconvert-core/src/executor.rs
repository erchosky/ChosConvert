//! Executes FFmpeg plans: passes, hardware→software fallback, verification and target-size
//! refinement. Produces a verified temp file; finalization is a separate, explicit step.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::cancel::CancelToken;
use crate::detect;
use crate::error::{AppError, CoreResult, ErrorCode, Recovery};
use crate::ffmpeg::{self, runner};
use crate::formats::Family;
use crate::media::{self, MediaInfo};
use crate::planner::{self, ConversionPlan, EngineKind, FfmpegJob, PlanRequest, VerifySpec};
use crate::target_size::{self, TargetSizeBudget, Verdict};
use crate::temp;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecuteRequest {
    pub plan_request: PlanRequest,
    /// Job directory created with `temp.create_job_dir`.
    pub job_dir: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ExecEvent {
    Status {
        phase: String,
    },
    Progress {
        #[serde(skip_serializing_if = "Option::is_none")]
        fraction: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        speed: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        out_time_s: Option<f64>,
        pass: u32,
        passes: u32,
        attempt: u32,
    },
    Log {
        level: String,
        code: String,
        message: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExecuteResult {
    pub temp_output: String,
    pub size_bytes: u64,
    pub attempts: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub encoder: Option<String>,
    pub hardware: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fallback_reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output_info: Option<MediaInfo>,
    pub plan: ConversionPlan,
}

/// Runs ffprobe on a file and builds a MediaInfo.
pub fn probe(ffprobe: &Path, path: &Path, cancel: &CancelToken) -> CoreResult<MediaInfo> {
    let detection = detect::detect_processable(path)?;
    let path_str = path.to_string_lossy();
    let args = media::ffprobe_args(&path_str);
    let out = runner::run_capture(
        ffprobe,
        &args,
        Duration::from_secs(30),
        32 * 1024 * 1024,
        cancel,
    )?;
    if !out.status.success() {
        return Err(AppError::new(
            ErrorCode::CorruptFile,
            "This file couldn't be read. It may be damaged or incomplete.",
        )
        .with_details(out.stderr_tail)
        .with_recovery(&[Recovery::CheckFile]));
    }
    media::parse_ffprobe(&String::from_utf8_lossy(&out.stdout), &path_str, detection)
}

struct Attempt {
    path: PathBuf,
    size: u64,
    encoder: Option<String>,
    hardware: bool,
    info: Option<MediaInfo>,
}

struct RunCtx<'a> {
    ffmpeg_path: &'a Path,
    input: &'a str,
    job_dir: &'a Path,
    ext: &'a str,
    cancel: &'a CancelToken,
}

fn run_job(
    ctx: &RunCtx,
    job: &FfmpegJob,
    attempt: u32,
    emit: &mut dyn FnMut(ExecEvent),
) -> CoreResult<PathBuf> {
    let RunCtx {
        ffmpeg_path,
        input,
        job_dir,
        ext,
        cancel,
    } = *ctx;
    let out = temp::temp_file_in(job_dir, ext);
    let passlog = job_dir.join(format!("passlog-{attempt}"));
    let passes = job.passes.len() as u32;
    for (i, pass) in job.passes.iter().enumerate() {
        let args = ffmpeg::materialize(
            &pass.args,
            input,
            &out.to_string_lossy(),
            Some(&passlog.to_string_lossy()),
        );
        let pass_no = i as u32 + 1;
        let outcome = runner::run_ffmpeg(ffmpeg_path, &args, job.duration_s, cancel, |p| {
            emit(ExecEvent::Progress {
                fraction: p.fraction,
                speed: p.speed,
                out_time_s: p.out_time_s,
                pass: pass_no,
                passes,
                attempt,
            });
        })?;
        if !outcome.success() {
            let _ = std::fs::remove_file(&out);
            let mut err = AppError::new(ErrorCode::EncoderFailed, "The conversion failed.")
                .with_details(outcome.stderr_tail.trim().to_string());
            if job.hardware {
                err = err.with_recovery(&[Recovery::TrySoftwareEncoding]);
            } else {
                err = err.with_recovery(&[Recovery::ChooseOtherFormat, Recovery::CheckFile]);
            }
            return Err(err);
        }
    }
    Ok(out)
}

fn verify(
    path: &Path,
    spec: &VerifySpec,
    ffprobe: Option<&Path>,
    cancel: &CancelToken,
) -> CoreResult<(u64, Option<MediaInfo>)> {
    let size = std::fs::metadata(path)
        .map_err(|e| AppError::io(&e, "stat output"))?
        .len();
    let invalid = |why: String| {
        AppError::new(
            ErrorCode::OutputInvalid,
            "The converted file didn't pass verification.",
        )
        .with_details(why)
        .with_recovery(&[Recovery::Retry])
    };
    if size == 0 {
        return Err(invalid("empty output".into()));
    }
    let Some(ffprobe) = ffprobe else {
        return Ok((size, None));
    };
    let info =
        probe(ffprobe, path, cancel).map_err(|e| invalid(format!("probe: {}", e.message)))?;
    if let Some(fam) = spec.expect_family {
        let ok = match fam {
            Family::Video => !info.video.is_empty(),
            Family::Audio => !info.audio.is_empty() && info.video.is_empty(),
            Family::Image => info.detection.family == Family::Image || !info.video.is_empty(),
            _ => true,
        };
        if !ok {
            return Err(invalid(format!("expected {fam:?} output")));
        }
    }
    if let (Some(expected), Some(actual)) = (spec.expect_duration_s, info.duration_s) {
        let tolerance = (expected * 0.03).max(1.0);
        if (expected - actual).abs() > tolerance {
            return Err(invalid(format!(
                "duration {actual:.2}s, expected {expected:.2}s"
            )));
        }
    }
    if spec.expect_no_location && info.has_location {
        return Err(invalid("location metadata still present".into()));
    }
    Ok((size, Some(info)))
}

fn check_size_rules(spec: &VerifySpec, size: u64) -> CoreResult<()> {
    if let Some(limit) = spec.must_be_smaller_than {
        if size >= limit {
            return Err(AppError::new(
                ErrorCode::NotSmaller,
                "This file is already well compressed; the result wasn't smaller.",
            )
            .with_recovery(&[Recovery::ReduceQuality, Recovery::ChooseOtherFormat]));
        }
    }
    Ok(())
}

/// Runs the full FFmpeg pipeline for one input.
pub fn execute(
    req: &ExecuteRequest,
    cancel: &CancelToken,
    emit: &mut dyn FnMut(ExecEvent),
) -> CoreResult<ExecuteResult> {
    let ff = req
        .plan_request
        .capabilities
        .ffmpeg()
        .ok_or_else(planner::engine_missing)?
        .clone();
    let ffmpeg_path = PathBuf::from(&ff.path);
    let ffprobe_path = ff.ffprobe_path.as_ref().map(PathBuf::from);
    let job_dir = PathBuf::from(&req.job_dir);
    if !job_dir.join(temp::MARKER).is_file() {
        return Err(AppError::invalid_request(
            "job_dir is not a ChosConvert job directory",
        ));
    }
    let input = req.plan_request.input.path.clone();
    if !Path::new(&input).is_absolute() {
        return Err(AppError::invalid_request("input path must be absolute"));
    }

    emit(ExecEvent::Status {
        phase: "preparing".into(),
    });
    let mut plan = planner::plan(&req.plan_request)?;
    if plan.engine != EngineKind::Ffmpeg {
        return Err(AppError::invalid_request(
            "plan does not use the FFmpeg engine",
        ));
    }

    let mut attempt_no = 1u32;
    let mut fallback_reason: Option<String> = None;
    let mut best: Option<Attempt> = None;
    let mut history: Vec<(u32, u64)> = Vec::new();

    loop {
        let job = plan
            .ffmpeg
            .clone()
            .ok_or_else(|| AppError::internal("ffmpeg plan without job"))?;
        emit(ExecEvent::Status {
            phase: "processing".into(),
        });
        let ext = plan.output_extension.clone();
        let ctx = RunCtx {
            ffmpeg_path: &ffmpeg_path,
            input: &input,
            job_dir: &job_dir,
            ext: &ext,
            cancel,
        };
        let (out, used) = match run_job(&ctx, &job, attempt_no, emit) {
            Ok(p) => (p, job.clone()),
            Err(e) if e.code == ErrorCode::EncoderFailed && job.fallback.is_some() => {
                let fb = job
                    .fallback
                    .as_deref()
                    .cloned()
                    .ok_or_else(|| AppError::internal("fallback"))?;
                let reason = e.details.clone().unwrap_or_default();
                emit(ExecEvent::Log {
                    level: "warning".into(),
                    code: "hardware_fallback".into(),
                    message: format!(
                        "{} failed; retrying with {}",
                        job.video_encoder.clone().unwrap_or_default(),
                        fb.video_encoder.clone().unwrap_or_default()
                    ),
                });
                fallback_reason = Some(reason.chars().take(2000).collect());
                let p = run_job(&ctx, &fb, attempt_no, emit)?;
                // Later refinement passes go straight to the working encoder.
                if let Some(f) = plan.ffmpeg.as_mut() {
                    *f = fb.clone();
                }
                (p, fb)
            }
            Err(e) => return Err(e),
        };

        emit(ExecEvent::Status {
            phase: "verifying".into(),
        });
        let (size, info) = match verify(&out, &plan.verify, ffprobe_path.as_deref(), cancel) {
            Ok(v) => v,
            Err(e) => {
                let _ = std::fs::remove_file(&out);
                return Err(e);
            }
        };
        let this = Attempt {
            path: out,
            size,
            encoder: used.video_encoder.clone(),
            hardware: used.hardware,
            info,
        };

        // Not a target-size job: done.
        let Some(budget) = plan.target_budget.clone() else {
            if let Err(e) = check_size_rules(&plan.verify, size) {
                let _ = std::fs::remove_file(&this.path);
                return Err(e);
            }
            if let Some(max) = plan.verify.max_bytes {
                if size > max {
                    let _ = std::fs::remove_file(&this.path);
                    return Err(AppError::new(
                        ErrorCode::TargetSizeUnreachable,
                        "The result is larger than the requested size.",
                    )
                    .with_recovery(&[Recovery::IncreaseTargetSize]));
                }
            }
            return Ok(finish(this, attempt_no, fallback_reason, plan));
        };

        history.push((budget.video_kbps, size));
        let verdict = target_size::evaluate(budget.target_bytes, size);
        emit(ExecEvent::Log {
            level: "info".into(),
            code: "target_attempt".into(),
            message: format!(
                "attempt {attempt_no}: {size} bytes for target {} ({verdict:?})",
                budget.target_bytes
            ),
        });
        // Keep the largest result that fits.
        if size <= budget.target_bytes {
            let better = best.as_ref().is_none_or(|b| size > b.size);
            if better {
                if let Some(old) = best.take() {
                    let _ = std::fs::remove_file(&old.path);
                }
                best = Some(this);
            } else {
                let _ = std::fs::remove_file(&this.path);
            }
        } else {
            let _ = std::fs::remove_file(&this.path);
        }
        if verdict == Verdict::Accept {
            break;
        }
        let duration = req.plan_request.input.duration_s.unwrap_or(0.0);
        match target_size::refine(&budget, duration, size, &history) {
            Some(next) => {
                emit(ExecEvent::Status {
                    phase: "refining".into(),
                });
                let new_plan = plan_for_budget(&req.plan_request, &next, plan.ffmpeg.as_ref())?;
                plan = new_plan;
                attempt_no += 1;
            }
            None => break,
        }
    }

    match best {
        Some(b) => Ok(finish(b, attempt_no, fallback_reason, plan)),
        None => Err(AppError::new(
            ErrorCode::TargetSizeUnreachable,
            "ChosConvert couldn't get this video under the requested size.",
        )
        .with_recovery(&[Recovery::IncreaseTargetSize])),
    }
}

fn plan_for_budget(
    req: &PlanRequest,
    budget: &TargetSizeBudget,
    current: Option<&FfmpegJob>,
) -> CoreResult<ConversionPlan> {
    let mut r = req.clone();
    // Stick to the encoder that already worked (e.g. after a hardware fallback).
    if let Some(name) = current.and_then(|j| j.video_encoder.clone()) {
        r.options.encoder = Some(planner::EncoderChoice::Specific(name));
    }
    planner::plan_with_budget(&r, Some(budget))
}

fn finish(
    a: Attempt,
    attempts: u32,
    fallback_reason: Option<String>,
    plan: ConversionPlan,
) -> ExecuteResult {
    ExecuteResult {
        temp_output: a.path.to_string_lossy().into_owned(),
        size_bytes: a.size,
        attempts,
        encoder: a.encoder,
        hardware: a.hardware,
        fallback_reason,
        output_info: a.info,
        plan,
    }
}
