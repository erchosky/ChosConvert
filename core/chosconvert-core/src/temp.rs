//! Controlled temporary workspace.
//!
//! Every job gets a private directory `job-<uuid>` (mode 0700 on Unix) inside a root owned
//! by the app. Each directory carries a marker file; cleanup only ever deletes directories
//! that are direct children of the root, are not symlinks, have the `job-` prefix and contain
//! the marker. Nothing outside the root is ever removed.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};

use crate::error::{AppError, CoreResult};

pub const MARKER: &str = ".chosconvert-temp";
const PREFIX: &str = "job-";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobTempDir {
    pub job_id: String,
    pub path: String,
}

fn ensure_private_dir(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        match fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)
        {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
            Err(e) => Err(e),
        }
    }
    #[cfg(not(unix))]
    {
        fs::create_dir_all(path)
    }
}

/// Creates a fresh, private job directory under `root`.
pub fn create_job_dir(root: &Path, job_id: &str) -> CoreResult<JobTempDir> {
    if !root.is_absolute() {
        return Err(AppError::invalid_request("temp root must be absolute"));
    }
    if job_id.is_empty()
        || !job_id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-')
    {
        return Err(AppError::invalid_request("job id must be alphanumeric"));
    }
    ensure_private_dir(root).map_err(|e| AppError::io(&e, "create temp root"))?;
    if fs::symlink_metadata(root)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err(AppError::internal("temp root must not be a symlink"));
    }
    let dir = root.join(format!("{PREFIX}{job_id}"));
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&dir)
            .map_err(|e| AppError::io(&e, "create job temp dir"))?;
    }
    #[cfg(not(unix))]
    fs::create_dir(&dir).map_err(|e| AppError::io(&e, "create job temp dir"))?;

    fs::write(
        dir.join(MARKER),
        format!("{job_id}\n{}\n", std::process::id()),
    )
    .map_err(|e| AppError::io(&e, "write temp marker"))?;
    Ok(JobTempDir {
        job_id: job_id.to_string(),
        path: dir.to_string_lossy().into_owned(),
    })
}

/// Returns true when `dir` is a removable job directory owned by `root`.
fn is_owned_job_dir(root: &Path, dir: &Path) -> bool {
    let Ok(meta) = fs::symlink_metadata(dir) else {
        return false;
    };
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return false;
    }
    let (Ok(root_c), Some(parent)) = (fs::canonicalize(root), dir.parent()) else {
        return false;
    };
    let Ok(parent_c) = fs::canonicalize(parent) else {
        return false;
    };
    let named = dir
        .file_name()
        .and_then(|n| n.to_str())
        .is_some_and(|n| n.starts_with(PREFIX));
    parent_c == root_c && named && dir.join(MARKER).is_file()
}

/// Removes one job directory if (and only if) it is owned by `root`.
pub fn remove_job_dir(root: &Path, dir: &Path) -> CoreResult<bool> {
    if !is_owned_job_dir(root, dir) {
        return Ok(false);
    }
    // std's remove_dir_all does not follow symlinks inside the tree.
    fs::remove_dir_all(dir).map_err(|e| AppError::io(&e, "remove job temp dir"))?;
    Ok(true)
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CleanupReport {
    pub removed: u32,
    pub kept: u32,
    pub freed_bytes: u64,
}

fn dir_size(path: &Path) -> u64 {
    let mut total = 0;
    if let Ok(entries) = fs::read_dir(path) {
        for e in entries.flatten() {
            if let Ok(m) = e.metadata() {
                if m.is_file() {
                    total += m.len();
                }
            }
        }
    }
    total
}

/// Removes stale job directories older than `min_age`, except those listed in `active`.
pub fn cleanup_stale(
    root: &Path,
    min_age: Duration,
    active: &[String],
) -> CoreResult<CleanupReport> {
    let mut report = CleanupReport::default();
    let entries = match fs::read_dir(root) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(report),
        Err(e) => return Err(AppError::io(&e, "list temp root")),
    };
    let now = SystemTime::now();
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        let id = name.strip_prefix(PREFIX).unwrap_or("");
        if active.iter().any(|a| a == id) || !is_owned_job_dir(root, &path) {
            report.kept += 1;
            continue;
        }
        let age = fs::symlink_metadata(&path)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|m| now.duration_since(m).ok())
            .unwrap_or(Duration::ZERO);
        if age < min_age {
            report.kept += 1;
            continue;
        }
        let size = dir_size(&path);
        if remove_job_dir(root, &path)? {
            report.removed += 1;
            report.freed_bytes += size;
        }
    }
    Ok(report)
}

/// A unique file path inside a job directory.
pub fn temp_file_in(job_dir: &Path, extension: &str) -> PathBuf {
    let ext: String = extension
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect();
    job_dir.join(format!("out-{}.{}", uuid::Uuid::new_v4().simple(), ext))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root() -> PathBuf {
        std::env::temp_dir().join(format!("cc-temp-test-{}", uuid::Uuid::new_v4().simple()))
    }

    #[test]
    fn creates_private_dirs_and_cleans_them() {
        let r = root();
        let job = create_job_dir(&r, "abc-123").expect("create");
        let p = PathBuf::from(&job.path);
        assert!(p.join(MARKER).is_file());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(&p).expect("meta").permissions().mode() & 0o777;
            assert_eq!(mode, 0o700);
        }
        fs::write(temp_file_in(&p, "mp4"), b"data").expect("w");
        let rep = cleanup_stale(&r, Duration::ZERO, &[]).expect("cleanup");
        assert_eq!(rep.removed, 1);
        assert!(!p.exists());
        fs::remove_dir_all(&r).ok();
    }

    #[test]
    fn never_removes_foreign_directories() {
        let r = root();
        fs::create_dir_all(&r).expect("mkdir");
        // Looks like a job dir but has no marker.
        let fake = r.join("job-fake");
        fs::create_dir_all(&fake).expect("mkdir");
        // Outside directory with marker.
        let outside = root();
        fs::create_dir_all(&outside).expect("mkdir");
        fs::write(outside.join(MARKER), b"x").expect("w");

        assert!(!remove_job_dir(&r, &fake).expect("ok"));
        assert!(!remove_job_dir(&r, &outside).expect("ok"));
        #[cfg(unix)]
        {
            let link = r.join("job-link");
            std::os::unix::fs::symlink(&outside, &link).expect("symlink");
            assert!(!remove_job_dir(&r, &link).expect("ok"));
        }
        let rep = cleanup_stale(&r, Duration::ZERO, &[]).expect("cleanup");
        assert_eq!(rep.removed, 0);
        assert!(fake.exists() && outside.exists());
        fs::remove_dir_all(&r).ok();
        fs::remove_dir_all(&outside).ok();
    }

    #[test]
    fn active_jobs_are_kept() {
        let r = root();
        create_job_dir(&r, "live").expect("create");
        let rep = cleanup_stale(&r, Duration::ZERO, &["live".into()]).expect("cleanup");
        assert_eq!((rep.removed, rep.kept), (0, 1));
        fs::remove_dir_all(&r).ok();
    }

    #[test]
    fn rejects_bad_job_ids() {
        let r = root();
        assert!(create_job_dir(&r, "../escape").is_err());
        assert!(create_job_dir(Path::new("relative"), "a").is_err());
        fs::remove_dir_all(&r).ok();
    }
}
