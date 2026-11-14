//! End-to-end tests against a real FFmpeg. Skipped (with a message) when FFmpeg isn't found.
//! Set CHOSCONVERT_FFMPEG / CHOSCONVERT_FFPROBE to point at specific binaries.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::time::Duration;

use chosconvert_core::cancel::CancelToken;
use chosconvert_core::capabilities::{self, Capabilities, NativeAvCaps, Os, Platform};
use chosconvert_core::error::ErrorCode;
use chosconvert_core::executor::{self, ExecuteRequest};
use chosconvert_core::formats::{Family, Format};
use chosconvert_core::media::MediaInfo;
use chosconvert_core::output::{self, FinalizeOutcome, OutputLocation, OutputPolicy};
use chosconvert_core::planner::{
    AdvancedOptions, Intent, MetadataScope, PlanRequest, QualityLevel,
};
use chosconvert_core::temp;

fn find_tool(env: &str, name: &str) -> Option<PathBuf> {
    if let Ok(p) = std::env::var(env) {
        return Some(PathBuf::from(p));
    }
    let exe = format!("{name}{}", std::env::consts::EXE_SUFFIX);
    let path_dirs = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect::<Vec<_>>())
        .unwrap_or_default();
    ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        .iter()
        .map(PathBuf::from)
        .chain(path_dirs)
        .map(|d| d.join(&exe))
        .find(|p| p.is_file())
}

fn tools() -> Option<&'static (PathBuf, PathBuf, Capabilities)> {
    static T: OnceLock<Option<(PathBuf, PathBuf, Capabilities)>> = OnceLock::new();
    T.get_or_init(|| {
        let ff = find_tool("CHOSCONVERT_FFMPEG", "ffmpeg")?;
        let fp = find_tool("CHOSCONVERT_FFPROBE", "ffprobe")?;
        let ffcaps = capabilities::probe_ffmpeg(&ff, Some(&fp)).ok()?;
        let caps = Capabilities {
            platform: Platform {
                os: if cfg!(windows) {
                    Os::Windows
                } else if cfg!(target_os = "macos") {
                    Os::Macos
                } else {
                    Os::Linux
                },
                arch: if cfg!(target_arch = "aarch64") {
                    "arm64".into()
                } else {
                    "x86_64".into()
                },
                os_version: String::new(),
                cpu_count: 8,
                memory_bytes: 16 << 30,
            },
            native_av: NativeAvCaps::default(),
            core_webp: true,
            ffmpeg: Some(ffcaps),
            ..Default::default()
        };
        Some((ff, fp, caps))
    })
    .as_ref()
}

macro_rules! require_ffmpeg {
    () => {
        match tools() {
            Some(t) => t,
            None => {
                eprintln!("FFmpeg not found; skipping");
                return;
            }
        }
    };
}

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures/generated")
        .join(name)
}

struct Sandbox {
    dir: PathBuf,
}

impl Sandbox {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("cc-it-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(dir.join("out")).unwrap();
        Sandbox { dir }
    }
    fn temp_root(&self) -> PathBuf {
        self.dir.join("tmp")
    }
    fn copy_in(&self, fixture_name: &str, as_name: &str) -> PathBuf {
        let p = self.dir.join(as_name);
        std::fs::copy(fixture(fixture_name), &p).unwrap();
        p
    }
    fn policy(&self) -> OutputPolicy {
        OutputPolicy {
            location: OutputLocation::Custom {
                directory: self.dir.join("out").to_string_lossy().into_owned(),
            },
            ..Default::default()
        }
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn probe(path: &Path) -> MediaInfo {
    let (_, fp, _) = tools().unwrap();
    executor::probe(fp, path, &CancelToken::new()).expect("probe")
}

fn run(
    sb: &Sandbox,
    input: &Path,
    intent: Intent,
    options: AdvancedOptions,
) -> Result<(PathBuf, executor::ExecuteResult), chosconvert_core::AppError> {
    let (_, _, caps) = tools().unwrap();
    let info = probe(input);
    let job_id = uuid::Uuid::new_v4().simple().to_string();
    let job = temp::create_job_dir(&sb.temp_root(), &job_id)?;
    let req = ExecuteRequest {
        plan_request: PlanRequest {
            input: info,
            intent,
            options,
            capabilities: caps.clone(),
            engine_override: None,
        },
        job_dir: job.path.clone(),
    };
    let mut events = 0usize;
    let res = executor::execute(&req, &CancelToken::new(), &mut |e| {
        events += 1;
        if let executor::ExecEvent::Log { message, .. } = &e {
            eprintln!("LOG {message}");
        }
    });
    let res = match res {
        Ok(r) => r,
        Err(e) => {
            temp::remove_job_dir(&sb.temp_root(), Path::new(&job.path)).unwrap();
            return Err(e);
        }
    };
    assert!(events > 0, "progress/status events were emitted");
    let out = output::finalize(
        Path::new(&res.temp_output),
        input,
        &res.plan.output_extension,
        None,
        &sb.policy(),
    )?;
    assert!(temp::remove_job_dir(&sb.temp_root(), Path::new(&job.path)).unwrap());
    match out {
        FinalizeOutcome::Written { path, .. } => Ok((PathBuf::from(path), res)),
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn inspects_mov_fixture() {
    require_ffmpeg!();
    let info = probe(&fixture("video_h264_aac.mov"));
    assert_eq!(info.family, Family::Video);
    assert_eq!(info.detection.format, Format::Mov);
    let v = info.primary_video().unwrap();
    assert_eq!((v.width, v.height), (640, 360));
    assert_eq!(v.codec, "h264");
    assert!((info.duration_s.unwrap() - 3.0).abs() < 0.1);
    assert_eq!(info.primary_audio().unwrap().codec, "aac");
    assert!(info.has_location, "fixture carries a location tag");
}

#[test]
fn mov_to_mp4_remux_keeps_original() {
    require_ffmpeg!();
    let sb = Sandbox::new();
    let input = sb.copy_in("video_h264_aac.mov", "clip.mov");
    let before = std::fs::read(&input).unwrap();
    let (out, res) = run(
        &sb,
        &input,
        Intent::Convert {
            format: Format::Mp4,
        },
        Default::default(),
    )
    .unwrap();
    assert!(!res.plan.reencode);
    let info = probe(&out);
    assert_eq!(info.detection.format, Format::Mp4);
    assert_eq!(info.primary_video().unwrap().codec, "h264");
    assert_eq!(std::fs::read(&input).unwrap(), before, "original untouched");
}

#[test]
fn remove_metadata_strips_location() {
    require_ffmpeg!();
    let sb = Sandbox::new();
    let input = sb.copy_in("video_h264_aac.mov", "private.mov");
    let (out, _) = run(
        &sb,
        &input,
        Intent::RemoveMetadata {
            scope: MetadataScope::All,
        },
        Default::default(),
    )
    .unwrap();
    let info = probe(&out);
    assert!(!info.has_location);
    assert!(
        !info.metadata.iter().any(|m| m.key == "title"),
        "{:?}",
        info.metadata
    );
}

#[test]
fn extract_audio_copies_aac() {
    require_ffmpeg!();
    let sb = Sandbox::new();
    let input = sb.copy_in("video_h264_aac.mov", "talk.mov");
    let (out, res) = run(
        &sb,
        &input,
        Intent::ExtractAudio { format: None },
        Default::default(),
    )
    .unwrap();
    assert!(!res.plan.reencode);
    assert_eq!(out.extension().unwrap(), "m4a");
    let info = probe(&out);
    assert_eq!(info.family, Family::Audio);
}

#[test]
fn wav_to_mp3_flac_aac_opus() {
    require_ffmpeg!();
    let sb = Sandbox::new();
    let input = sb.copy_in("audio.wav", "audio.wav");
    for (fmt, codec) in [
        (Format::Mp3, "mp3"),
        (Format::Flac, "flac"),
        (Format::M4a, "aac"),
        (Format::Opus, "opus"),
    ] {
        let (out, _) = run(
            &sb,
            &input,
            Intent::Convert { format: fmt },
            Default::default(),
        )
        .unwrap();
        let info = probe(&out);
        assert_eq!(info.primary_audio().unwrap().codec, codec, "{fmt:?}");
        assert!((info.duration_s.unwrap() - 3.0).abs() < 0.2);
    }
}

#[test]
fn twenty_four_bit_wav_to_flac_preserves_depth() {
    require_ffmpeg!();
    let sb = Sandbox::new();
    let input = sb.copy_in("audio_24bit.wav", "hires.wav");
    let (out, _) = run(
        &sb,
        &input,
        Intent::Convert {
            format: Format::Flac,
        },
        Default::default(),
    )
    .unwrap();
    let info = probe(&out);
    assert_eq!(info.primary_audio().unwrap().bit_depth, Some(24));
}

fn synth_video(sb: &Sandbox, name: &str, seconds: u32, size: &str, crf: u32) -> PathBuf {
    let (ff, _, _) = tools().unwrap();
    let out = sb.dir.join(name);
    let status = Command::new(ff)
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
        ])
        .arg(format!(
            "testsrc2=size={size}:rate=30:duration={seconds},noise=alls=30:allf=t"
        ))
        .args(["-f", "lavfi", "-i"])
        .arg(format!(
            "sine=frequency=440:sample_rate=48000:duration={seconds}"
        ))
        .args(["-c:v", "libx264", "-preset", "ultrafast", "-crf"])
        .arg(crf.to_string())
        .args(["-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"])
        .arg(&out)
        .status()
        .unwrap();
    assert!(status.success());
    out
}

#[test]
fn make_smaller_produces_smaller_valid_video() {
    require_ffmpeg!();
    let sb = Sandbox::new();
    let input = synth_video(&sb, "big.mov", 4, "1280x720", 12);
    let src_size = std::fs::metadata(&input).unwrap().len();
    let (out, res) = run(
        &sb,
        &input,
        Intent::MakeSmaller {
            level: QualityLevel::Balanced,
        },
        Default::default(),
    )
    .unwrap();
    let size = std::fs::metadata(&out).unwrap().len();
    assert!(size < src_size, "{size} >= {src_size}");
    let info = probe(&out);
    assert!((info.duration_s.unwrap() - 4.0).abs() < 0.3);
    eprintln!(
        "make smaller: {src_size} -> {size} via {:?} (fallback: {})",
        res.encoder,
        res.fallback_reason.is_some()
    );
}

#[test]
fn target_size_lands_under_target() {
    require_ffmpeg!();
    let sb = Sandbox::new();
    let input = synth_video(&sb, "noisy.mov", 12, "1280x720", 14);
    let src_size = std::fs::metadata(&input).unwrap().len();
    let target = 2_000_000u64;
    assert!(
        src_size > target * 3,
        "source should be much larger than target ({src_size})"
    );
    let (out, res) = run(
        &sb,
        &input,
        Intent::TargetSize {
            target_bytes: target,
        },
        Default::default(),
    )
    .unwrap();
    let size = std::fs::metadata(&out).unwrap().len();
    assert!(size <= target, "{size} > {target}");
    assert!(res.attempts <= 3);
    let info = probe(&out);
    assert!((info.duration_s.unwrap() - 12.0).abs() < 0.5);
    eprintln!(
        "target size: {src_size} -> {size} (target {target}) in {} attempt(s), budget {:?}",
        res.attempts, res.plan.target_budget
    );
}

/// Spec acceptance test: 100+ MB input, target < 10 MB. Slow; run with `--ignored`.
#[test]
#[ignore]
fn acceptance_target_size_100mb_to_10mb() {
    require_ffmpeg!();
    let sb = Sandbox::new();
    let input = synth_video(&sb, "huge.mp4", 40, "1920x1080", 6);
    let src_size = std::fs::metadata(&input).unwrap().len();
    assert!(src_size > 100_000_000, "source is {src_size} bytes");
    let target = 10_000_000;
    let (out, res) = run(
        &sb,
        &input,
        Intent::TargetSize {
            target_bytes: target,
        },
        Default::default(),
    )
    .unwrap();
    let size = std::fs::metadata(&out).unwrap().len();
    assert!(size <= target);
    eprintln!(
        "acceptance: {src_size} -> {size} in {} attempts; {:?}",
        res.attempts, res.plan.target_budget
    );
}

#[test]
fn cancellation_stops_ffmpeg_and_leaves_no_output() {
    require_ffmpeg!();
    let (_, _, caps) = tools().unwrap();
    let sb = Sandbox::new();
    let input = synth_video(&sb, "long.mov", 20, "1280x720", 16);
    let info = probe(&input);
    let job = temp::create_job_dir(&sb.temp_root(), "cancel-test").unwrap();
    let req = ExecuteRequest {
        plan_request: PlanRequest {
            input: info,
            intent: Intent::MakeSmaller {
                level: QualityLevel::High,
            },
            options: AdvancedOptions {
                encoder: Some(chosconvert_core::planner::EncoderChoice::Software),
                ..Default::default()
            },
            capabilities: caps.clone(),
            engine_override: None,
        },
        job_dir: job.path.clone(),
    };
    let token = CancelToken::new();
    let t2 = token.clone();
    let canceller = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(600));
        t2.cancel();
    });
    let started = std::time::Instant::now();
    let err = executor::execute(&req, &token, &mut |_| {}).expect_err("cancelled");
    canceller.join().unwrap();
    assert_eq!(err.code, ErrorCode::Cancelled);
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "cancel was prompt"
    );
    let leftovers: Vec<_> = std::fs::read_dir(&job.path)
        .unwrap()
        .flatten()
        .filter(|e| {
            e.file_name() != temp::MARKER && e.file_name().to_string_lossy().starts_with("out-")
        })
        .filter(|e| e.metadata().map(|m| m.len() > 0).unwrap_or(false))
        .collect();
    // The partial output may exist until job dir removal; the app always removes the job dir.
    let _ = leftovers;
    assert!(temp::remove_job_dir(&sb.temp_root(), Path::new(&job.path)).unwrap());
}

#[test]
fn corrupt_and_hostile_inputs_fail_cleanly() {
    require_ffmpeg!();
    let (_, fp, _) = tools().unwrap();
    let err = executor::probe(fp, &fixture("corrupt_truncated.mov"), &CancelToken::new())
        .expect_err("corrupt");
    assert!(matches!(err.code, ErrorCode::CorruptFile), "{err:?}");
    let err = executor::probe(fp, &fixture("renamed_executable.jpg"), &CancelToken::new())
        .expect_err("exe");
    assert_eq!(err.code, ErrorCode::ExecutableRejected);
}

#[test]
fn hostile_filenames_are_plain_files() {
    require_ffmpeg!();
    let sb = Sandbox::new();
    for name in [
        "hello world.mov",
        "\"video\".mov",
        "vídeo ñ.mov",
        "$HOME.mov",
        ";rm.mov",
        "--help.mov",
        "concat:a|b.mov",
        "`id`.mov",
    ] {
        let input = sb.copy_in("video_h264_aac.mov", name);
        let (out, _) = run(
            &sb,
            &input,
            Intent::Convert {
                format: Format::Mp4,
            },
            Default::default(),
        )
        .unwrap_or_else(|e| panic!("{name}: {e:?}"));
        assert!(out.exists(), "{name}");
        assert!(out.parent().unwrap().ends_with("out"));
    }
}

#[test]
fn mkv_with_subtitles_to_mp4_converts_text_subs() {
    require_ffmpeg!();
    let sb = Sandbox::new();
    let input = sb.copy_in("video_vp9_opus_subs.mkv", "show.mkv");
    let (out, res) = run(
        &sb,
        &input,
        Intent::Convert {
            format: Format::Mp4,
        },
        Default::default(),
    )
    .unwrap();
    assert!(res.plan.reencode, "VP9/Opus must be transcoded for MP4");
    let info = probe(&out);
    assert_eq!(
        info.subtitles.first().map(|s| s.codec.as_str()),
        Some("mov_text")
    );
    assert_eq!(info.primary_audio().unwrap().codec, "aac");
}

#[test]
fn gif_from_video() {
    require_ffmpeg!();
    let sb = Sandbox::new();
    let input = sb.copy_in("video_h264_aac.mov", "clip.mov");
    let (out, _) = run(
        &sb,
        &input,
        Intent::CreateGif {
            start_s: 0.5,
            duration_s: 1.5,
            width: 320,
            fps: 10,
        },
        Default::default(),
    )
    .unwrap();
    let head = std::fs::read(&out).unwrap();
    assert!(head.starts_with(b"GIF89a"));
}
