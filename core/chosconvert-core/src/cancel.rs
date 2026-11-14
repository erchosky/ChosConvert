//! Cooperative cancellation that can also terminate an attached child process.

use std::process::Child;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Clone, Default)]
pub struct CancelToken {
    inner: Arc<Inner>,
}

#[derive(Default)]
struct Inner {
    cancelled: AtomicBool,
    child: Mutex<Option<Arc<Mutex<Child>>>>,
}

impl CancelToken {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_cancelled(&self) -> bool {
        self.inner.cancelled.load(Ordering::SeqCst)
    }

    /// Requests cancellation and kills the attached process, if any. Idempotent.
    pub fn cancel(&self) {
        self.inner.cancelled.store(true, Ordering::SeqCst);
        let attached = self.inner.child.lock().ok().and_then(|g| g.clone());
        if let Some(child) = attached {
            if let Ok(mut c) = child.lock() {
                // Already-exited processes return an error here; that's fine.
                let _ = c.kill();
            }
        }
    }

    /// Attaches a running child. If cancellation already happened it is killed immediately.
    pub(crate) fn attach(&self, child: Arc<Mutex<Child>>) {
        if let Ok(mut slot) = self.inner.child.lock() {
            *slot = Some(child);
        }
        if self.is_cancelled() {
            self.cancel();
        }
    }

    pub(crate) fn detach(&self) {
        if let Ok(mut slot) = self.inner.child.lock() {
            *slot = None;
        }
    }
}
