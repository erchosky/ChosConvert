//! Job model and concurrency policy.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobStatus {
    Waiting,
    Inspecting,
    Preparing,
    Processing,
    Finalizing,
    Completed,
    Cancelled,
    Failed,
}

impl JobStatus {
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            JobStatus::Completed | JobStatus::Cancelled | JobStatus::Failed
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkloadKind {
    Image,
    Audio,
    VideoSoftware,
    VideoHardware,
    Remux,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct ConcurrencyInput {
    pub kind: WorkloadKind,
    pub cpu_count: u32,
    pub memory_bytes: u64,
    pub queued: u32,
}

/// Recommends how many jobs of one kind run at once. FFmpeg encoders are internally
/// multithreaded, so running many in parallel only adds memory pressure and thrashing.
pub fn recommended_concurrency(input: &ConcurrencyInput) -> u32 {
    let cpus = input.cpu_count.max(1);
    let gib = (input.memory_bytes / (1024 * 1024 * 1024)).max(1) as u32;
    let by_kind = match input.kind {
        // Image decode+encode is mostly single-threaded per image; bounded by RAM for big images.
        WorkloadKind::Image => cpus.min(8).min(gib.max(2) / 2 + 1),
        WorkloadKind::Audio => (cpus / 2).clamp(1, 4),
        WorkloadKind::Remux => 2,
        // Media engines (VideoToolbox, NVENC…) expose a small number of encode sessions.
        WorkloadKind::VideoHardware => 2,
        WorkloadKind::VideoSoftware => {
            if cpus >= 16 && gib >= 16 {
                2
            } else {
                1
            }
        }
    };
    by_kind.clamp(1, input.queued.max(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn concurrency_is_bounded() {
        let mk = |kind, cpus, gib: u64, queued| ConcurrencyInput {
            kind,
            cpu_count: cpus,
            memory_bytes: gib * 1024 * 1024 * 1024,
            queued,
        };
        assert_eq!(
            recommended_concurrency(&mk(WorkloadKind::VideoSoftware, 8, 16, 50)),
            1
        );
        assert_eq!(
            recommended_concurrency(&mk(WorkloadKind::VideoSoftware, 16, 32, 50)),
            2
        );
        assert_eq!(
            recommended_concurrency(&mk(WorkloadKind::VideoHardware, 10, 16, 50)),
            2
        );
        assert!(recommended_concurrency(&mk(WorkloadKind::Image, 12, 32, 5000)) <= 8);
        assert_eq!(
            recommended_concurrency(&mk(WorkloadKind::Image, 12, 32, 1)),
            1
        );
        assert!(recommended_concurrency(&mk(WorkloadKind::Image, 4, 4, 100)) >= 1);
        assert_eq!(
            recommended_concurrency(&mk(WorkloadKind::Audio, 0, 0, 0)),
            1
        );
    }

    #[test]
    fn terminal_states() {
        assert!(JobStatus::Completed.is_terminal());
        assert!(!JobStatus::Processing.is_terminal());
    }
}
