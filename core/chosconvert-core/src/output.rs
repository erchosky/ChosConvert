//! Output naming, collision handling and safe finalization.
//!
//! Finalization never overwrites the source, never clobbers an existing file unless the
//! policy is `Replace`, and is race-free: candidate names are claimed with an atomic
//! no-clobber operation (hard link, or `create_new` copy as a fallback).

use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::error::{AppError, CoreResult, ErrorCode, Recovery};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum OutputLocation {
    #[default]
    SameFolder,
    Custom {
        directory: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Collision {
    /// `file.mp4` → `file (1).mp4`
    #[default]
    Rename,
    Replace,
    Skip,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct OutputPolicy {
    #[serde(default)]
    pub location: OutputLocation,
    #[serde(default)]
    pub collision: Collision,
}

const MAX_NAME_BYTES: usize = 255;
const RESERVED_SUFFIX_BYTES: usize = 16; // " (9999)" + "." + extension headroom

/// Makes a file stem safe on macOS and Windows file systems.
pub fn sanitize_stem(stem: &str) -> String {
    let mut s: String = stem
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            c if c.is_control() => '_',
            c => c,
        })
        .collect();
    // Windows disallows trailing dots/spaces; leading dots would create hidden files.
    s = s
        .trim_end_matches(['.', ' '])
        .trim_start_matches('.')
        .trim()
        .to_string();
    let upper = s.to_ascii_uppercase();
    let base = upper.split('.').next().unwrap_or("");
    let reserved = matches!(base, "CON" | "PRN" | "AUX" | "NUL")
        || ((base.starts_with("COM") || base.starts_with("LPT"))
            && base.len() == 4
            && base.as_bytes()[3].is_ascii_digit());
    if reserved {
        s.insert(0, '_');
    }
    if s.is_empty() {
        s = "output".into();
    }
    truncate_to_bytes(&s, MAX_NAME_BYTES - RESERVED_SUFFIX_BYTES)
}

fn truncate_to_bytes(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

fn sanitize_extension(ext: &str) -> String {
    let e: String = ext
        .trim_start_matches('.')
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(10)
        .collect::<String>()
        .to_ascii_lowercase();
    if e.is_empty() { "out".into() } else { e }
}

fn candidate_name(stem: &str, ext: &str, n: u32) -> String {
    if n == 0 {
        format!("{stem}.{ext}")
    } else {
        format!("{stem} ({n}).{ext}")
    }
}

/// Resolves the output directory for a source file.
pub fn output_directory(source: &Path, policy: &OutputPolicy) -> CoreResult<PathBuf> {
    match &policy.location {
        OutputLocation::SameFolder => source
            .parent()
            .map(Path::to_path_buf)
            .ok_or_else(|| AppError::invalid_request("source has no parent directory")),
        OutputLocation::Custom { directory } => {
            let p = PathBuf::from(directory);
            if !p.is_absolute() {
                return Err(AppError::invalid_request(
                    "custom output directory must be absolute",
                ));
            }
            Ok(p)
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NamePreview {
    pub path: String,
    pub file_name: String,
    pub collided: bool,
}

/// Preview of the output path (the authoritative name is decided at finalization).
pub fn preview_output(
    source: &Path,
    extension: &str,
    stem_override: Option<&str>,
    policy: &OutputPolicy,
) -> CoreResult<NamePreview> {
    let dir = output_directory(source, policy)?;
    let stem = sanitize_stem(stem_override.unwrap_or_else(|| {
        source
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("output")
    }));
    let ext = sanitize_extension(extension);
    let src_canon = fs::canonicalize(source).ok();
    let mut n = 0;
    loop {
        let path = dir.join(candidate_name(&stem, &ext, n));
        let is_source = src_canon.is_some() && fs::canonicalize(&path).ok() == src_canon;
        let exists = fs::symlink_metadata(&path).is_ok();
        let free = !exists || (policy.collision == Collision::Replace && !is_source);
        if free || n >= 9999 {
            return Ok(NamePreview {
                file_name: candidate_name(&stem, &ext, n),
                path: path.to_string_lossy().into_owned(),
                collided: n > 0 || exists,
            });
        }
        n += 1;
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum FinalizeOutcome {
    Written {
        path: String,
        size_bytes: u64,
        replaced: bool,
    },
    Skipped {
        existing: String,
    },
}

/// Verifies a finished temp file and moves it to its final location.
pub fn finalize(
    temp_file: &Path,
    source: &Path,
    extension: &str,
    stem_override: Option<&str>,
    policy: &OutputPolicy,
) -> CoreResult<FinalizeOutcome> {
    let meta = fs::symlink_metadata(temp_file).map_err(|e| AppError::io(&e, "stat temp output"))?;
    if !meta.is_file() || meta.len() == 0 {
        return Err(AppError::new(
            ErrorCode::OutputInvalid,
            "The conversion produced an empty or invalid file.",
        )
        .with_recovery(&[Recovery::Retry]));
    }
    let size = meta.len();
    let dir = output_directory(source, policy)?;
    let dir_meta = fs::metadata(&dir).map_err(|e| AppError::io(&e, "stat output directory"))?;
    if !dir_meta.is_dir() {
        return Err(AppError::new(
            ErrorCode::OutputNotWritable,
            "The output folder isn't available.",
        )
        .with_recovery(&[Recovery::ChooseOutputFolder]));
    }
    let stem = sanitize_stem(stem_override.unwrap_or_else(|| {
        source
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("output")
    }));
    let ext = sanitize_extension(extension);
    let src_canon = fs::canonicalize(source).ok();

    // Stage next to the destination so the final step is a same-volume operation.
    let staged = stage_in_directory(temp_file, &dir)?;
    let result = claim(
        &staged,
        &dir,
        &stem,
        &ext,
        src_canon.as_deref(),
        policy.collision,
        size,
    );
    if staged != temp_file {
        let _ = fs::remove_file(&staged);
    }
    if matches!(result, Ok(FinalizeOutcome::Written { .. })) {
        let _ = fs::remove_file(temp_file);
    }
    result
}

fn claim(
    staged: &Path,
    dir: &Path,
    stem: &str,
    ext: &str,
    source: Option<&Path>,
    collision: Collision,
    size: u64,
) -> CoreResult<FinalizeOutcome> {
    for n in 0..=9999u32 {
        let target = dir.join(candidate_name(stem, ext, n));
        let is_source = source.is_some() && fs::canonicalize(&target).ok().as_deref() == source;
        let exists = fs::symlink_metadata(&target).is_ok();
        if exists {
            match collision {
                _ if is_source => continue, // the original is never touched
                Collision::Skip => {
                    return Ok(FinalizeOutcome::Skipped {
                        existing: target.to_string_lossy().into_owned(),
                    });
                }
                Collision::Replace => {
                    let tmp = dir.join(format!(".cc-replace-{}", uuid::Uuid::new_v4().simple()));
                    copy_or_link_new(staged, &tmp)
                        .map_err(|e| AppError::io(&e, "stage replace"))?;
                    if let Err(e) = fs::rename(&tmp, &target) {
                        let _ = fs::remove_file(&tmp);
                        return Err(AppError::io(&e, "replace output"));
                    }
                    return Ok(FinalizeOutcome::Written {
                        path: target.to_string_lossy().into_owned(),
                        size_bytes: size,
                        replaced: true,
                    });
                }
                Collision::Rename => continue,
            }
        }
        match copy_or_link_new(staged, &target) {
            Ok(()) => {
                return Ok(FinalizeOutcome::Written {
                    path: target.to_string_lossy().into_owned(),
                    size_bytes: size,
                    replaced: false,
                });
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue, // lost a race
            Err(e) => return Err(AppError::io(&e, "write output")),
        }
    }
    Err(AppError::new(
        ErrorCode::OutputExists,
        "Too many files with this name already exist.",
    ))
}

/// Atomically creates `dst` with the content of `src`, failing if `dst` exists.
fn copy_or_link_new(src: &Path, dst: &Path) -> io::Result<()> {
    match fs::hard_link(src, dst) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => Err(e),
        Err(_) => {
            // File systems without hard links (FAT/exFAT, some network volumes).
            let mut out = OpenOptions::new().write(true).create_new(true).open(dst)?;
            let mut inp = File::open(src)?;
            let res = io::copy(&mut inp, &mut out).and_then(|_| out.sync_all());
            if res.is_err() {
                drop(out);
                let _ = fs::remove_file(dst);
            }
            res
        }
    }
}

/// Ensures the staged file lives on the destination volume. Returns `src` if a hard link
/// into `dir` is possible, else copies to a hidden partial file in `dir`.
fn stage_in_directory(src: &Path, dir: &Path) -> CoreResult<PathBuf> {
    let probe = dir.join(format!(".cc-partial-{}", uuid::Uuid::new_v4().simple()));
    match fs::hard_link(src, &probe) {
        Ok(()) => {
            let _ = fs::remove_file(&probe);
            Ok(src.to_path_buf())
        }
        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => {
            Err(AppError::io(&e, "write to output directory"))
        }
        Err(_) => {
            let mut out = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&probe)
                .map_err(|e| AppError::io(&e, "create staged output"))?;
            let mut inp = File::open(src).map_err(|e| AppError::io(&e, "open temp output"))?;
            if let Err(e) = io::copy(&mut inp, &mut out).and_then(|_| out.sync_all()) {
                drop(out);
                let _ = fs::remove_file(&probe);
                return Err(AppError::io(&e, "copy staged output"));
            }
            Ok(probe)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir() -> PathBuf {
        let d = std::env::temp_dir().join(format!("cc-out-{}", uuid::Uuid::new_v4().simple()));
        fs::create_dir_all(&d).expect("mkdir");
        d
    }

    #[test]
    fn sanitizes_hostile_stems() {
        assert_eq!(sanitize_stem("a/b\\c:d"), "a_b_c_d");
        assert_eq!(sanitize_stem("..hidden"), "hidden");
        assert_eq!(sanitize_stem("trailing. . "), "trailing");
        assert_eq!(sanitize_stem("CON"), "_CON");
        assert_eq!(sanitize_stem("com1"), "_com1");
        assert_eq!(sanitize_stem("vídeo ñ"), "vídeo ñ");
        assert_eq!(sanitize_stem("line\nbreak"), "line_break");
        assert_eq!(sanitize_stem(""), "output");
        let long = "é".repeat(300);
        let s = sanitize_stem(&long);
        assert!(s.len() <= MAX_NAME_BYTES - RESERVED_SUFFIX_BYTES);
        assert!(s.chars().all(|c| c == 'é'));
    }

    #[test]
    fn collision_rename_produces_numbered_names() {
        let d = tmpdir();
        let src = d.join("photo.png");
        fs::write(&src, b"src").expect("w");
        fs::write(d.join("photo.webp"), b"existing").expect("w");
        let p = preview_output(&src, "webp", None, &OutputPolicy::default()).expect("preview");
        assert_eq!(p.file_name, "photo (1).webp");

        for expected in ["photo (1).webp", "photo (2).webp"] {
            let tmp = d.join(format!("tmp-{}", uuid::Uuid::new_v4().simple()));
            fs::write(&tmp, b"new").expect("w");
            let out = finalize(&tmp, &src, "webp", None, &OutputPolicy::default()).expect("fin");
            match out {
                FinalizeOutcome::Written { path, replaced, .. } => {
                    assert!(path.ends_with(expected), "{path}");
                    assert!(!replaced);
                }
                other => panic!("unexpected {other:?}"),
            }
            assert!(!tmp.exists(), "temp removed after success");
        }
        assert_eq!(fs::read(d.join("photo.webp")).expect("r"), b"existing");
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn never_overwrites_source_even_with_replace() {
        let d = tmpdir();
        let src = d.join("clip.mp4");
        fs::write(&src, b"original").expect("w");
        let tmp = d.join("t");
        fs::write(&tmp, b"converted").expect("w");
        let policy = OutputPolicy {
            collision: Collision::Replace,
            ..Default::default()
        };
        let out = finalize(&tmp, &src, "mp4", None, &policy).expect("fin");
        match out {
            FinalizeOutcome::Written { path, .. } => assert!(path.ends_with("clip (1).mp4")),
            other => panic!("unexpected {other:?}"),
        }
        assert_eq!(fs::read(&src).expect("r"), b"original");
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn replace_and_skip_policies() {
        let d = tmpdir();
        let src = d.join("a.wav");
        fs::write(&src, b"src").expect("w");
        fs::write(d.join("a.mp3"), b"old").expect("w");

        let tmp = d.join("t1");
        fs::write(&tmp, b"new").expect("w");
        let skip = OutputPolicy {
            collision: Collision::Skip,
            ..Default::default()
        };
        assert!(matches!(
            finalize(&tmp, &src, "mp3", None, &skip).expect("skip"),
            FinalizeOutcome::Skipped { .. }
        ));
        assert_eq!(fs::read(d.join("a.mp3")).expect("r"), b"old");

        let replace = OutputPolicy {
            collision: Collision::Replace,
            ..Default::default()
        };
        let out = finalize(&tmp, &src, "mp3", None, &replace).expect("replace");
        assert!(matches!(
            out,
            FinalizeOutcome::Written { replaced: true, .. }
        ));
        assert_eq!(fs::read(d.join("a.mp3")).expect("r"), b"new");
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn rejects_empty_output() {
        let d = tmpdir();
        let src = d.join("a.png");
        fs::write(&src, b"x").expect("w");
        let tmp = d.join("empty");
        fs::write(&tmp, b"").expect("w");
        let err = finalize(&tmp, &src, "jpg", None, &OutputPolicy::default()).expect_err("empty");
        assert_eq!(err.code, ErrorCode::OutputInvalid);
        fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn custom_directory_must_be_absolute() {
        let policy = OutputPolicy {
            location: OutputLocation::Custom {
                directory: "relative/dir".into(),
            },
            ..Default::default()
        };
        assert!(output_directory(Path::new("/x/a.png"), &policy).is_err());
    }
}
