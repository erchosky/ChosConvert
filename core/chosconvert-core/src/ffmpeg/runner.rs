//! Spawns FFmpeg/FFprobe with structured arguments, streams progress and supports
//! cancellation and timeouts.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Read};
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use crate::cancel::CancelToken;
use crate::error::{AppError, CoreResult, ErrorCode, Recovery};
use crate::ffmpeg::progress::{ProgressParser, ProgressSnapshot};

const STDERR_TAIL_BYTES: usize = 16 * 1024;

#[derive(Debug)]
pub struct RunOutcome {
    pub status: ExitStatus,
    pub stderr_tail: String,
}

impl RunOutcome {
    pub fn success(&self) -> bool {
        self.status.success()
    }
}

fn base_command(program: &Path) -> Command {
    let mut cmd = Command::new(program);
    cmd.env("AV_LOG_FORCE_NOCOLOR", "1");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    cmd
}

fn spawn_error(program: &Path, e: &std::io::Error) -> AppError {
    AppError::new(
        ErrorCode::EngineUnavailable,
        "The media engine couldn't be started.",
    )
    .with_details(format!(
        "spawn {}: {e}",
        program
            .file_name()
            .map(|s| s.to_string_lossy())
            .unwrap_or_default()
    ))
    .with_recovery(&[Recovery::InstallEngine])
}

fn collect_tail(mut reader: impl Read + Send + 'static) -> thread::JoinHandle<String> {
    thread::spawn(move || {
        let mut tail: VecDeque<u8> = VecDeque::with_capacity(STDERR_TAIL_BYTES);
        let mut buf = [0u8; 4096];
        while let Ok(n) = reader.read(&mut buf) {
            if n == 0 {
                break;
            }
            for &b in &buf[..n] {
                if tail.len() == STDERR_TAIL_BYTES {
                    tail.pop_front();
                }
                tail.push_back(b);
            }
        }
        String::from_utf8_lossy(tail.make_contiguous()).into_owned()
    })
}

fn wait_child(child: &Arc<Mutex<Child>>) -> CoreResult<ExitStatus> {
    loop {
        {
            let mut c = child
                .lock()
                .map_err(|_| AppError::internal("child mutex poisoned"))?;
            match c.try_wait() {
                Ok(Some(status)) => return Ok(status),
                Ok(None) => {}
                Err(e) => return Err(AppError::internal(format!("wait: {e}"))),
            }
        }
        thread::sleep(Duration::from_millis(15));
    }
}

/// Runs FFmpeg. `args` must already contain `-progress pipe:1`; progress snapshots are
/// delivered to `on_progress` from the calling thread.
pub fn run_ffmpeg(
    program: &Path,
    args: &[String],
    duration_s: Option<f64>,
    cancel: &CancelToken,
    mut on_progress: impl FnMut(&ProgressSnapshot),
) -> CoreResult<RunOutcome> {
    if cancel.is_cancelled() {
        return Err(AppError::cancelled());
    }
    let mut child = base_command(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| spawn_error(program, &e))?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| AppError::internal("ffmpeg stdout unavailable"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| AppError::internal("ffmpeg stderr unavailable"))?;
    let stderr_handle = collect_tail(stderr);

    let child = Arc::new(Mutex::new(child));
    cancel.attach(child.clone());

    let mut parser = ProgressParser::new(duration_s);
    for line in BufReader::new(stdout).lines() {
        let Ok(line) = line else { break };
        if let Some(snap) = parser.feed(&line) {
            on_progress(&snap);
        }
    }

    let status = wait_child(&child);
    cancel.detach();
    let stderr_tail = stderr_handle.join().unwrap_or_default();
    let status = status?;

    if cancel.is_cancelled() {
        return Err(AppError::cancelled());
    }
    Ok(RunOutcome {
        status,
        stderr_tail,
    })
}

/// Captured output of a short-lived tool invocation (ffprobe, `ffmpeg -encoders`).
pub struct Captured {
    pub status: ExitStatus,
    pub stdout: Vec<u8>,
    pub stderr_tail: String,
}

/// Runs a helper to completion with a wall-clock timeout and bounded stdout.
pub fn run_capture(
    program: &Path,
    args: &[String],
    timeout: Duration,
    max_stdout: usize,
    cancel: &CancelToken,
) -> CoreResult<Captured> {
    let mut child = base_command(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| spawn_error(program, &e))?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| AppError::internal("stdout unavailable"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| AppError::internal("stderr unavailable"))?;
    let stderr_handle = collect_tail(stderr);
    let out_handle = thread::spawn(move || {
        let mut out = Vec::new();
        let mut buf = [0u8; 16 * 1024];
        let mut overflow = false;
        while let Ok(n) = stdout.read(&mut buf) {
            if n == 0 {
                break;
            }
            if out.len() + n > max_stdout {
                overflow = true;
                continue; // keep draining so the child doesn't block
            }
            out.extend_from_slice(&buf[..n]);
        }
        (out, overflow)
    });

    let child = Arc::new(Mutex::new(child));
    cancel.attach(child.clone());
    let started = Instant::now();
    let status = loop {
        {
            let mut c = child
                .lock()
                .map_err(|_| AppError::internal("child mutex poisoned"))?;
            match c.try_wait() {
                Ok(Some(s)) => break Ok(s),
                Ok(None) if started.elapsed() > timeout => {
                    let _ = c.kill();
                    let _ = c.wait();
                    break Err(AppError::new(
                        ErrorCode::Timeout,
                        "Reading this file took too long.",
                    )
                    .with_recovery(&[Recovery::CheckFile, Recovery::Retry]));
                }
                Ok(None) => {}
                Err(e) => break Err(AppError::internal(format!("wait: {e}"))),
            }
        }
        thread::sleep(Duration::from_millis(10));
    };
    cancel.detach();
    let (stdout, overflow) = out_handle.join().unwrap_or_default();
    let stderr_tail = stderr_handle.join().unwrap_or_default();
    let status = status?;
    if cancel.is_cancelled() {
        return Err(AppError::cancelled());
    }
    if overflow {
        return Err(AppError::new(
            ErrorCode::CorruptFile,
            "This file reports an unreasonable amount of metadata.",
        ));
    }
    Ok(Captured {
        status,
        stdout,
        stderr_tail,
    })
}
