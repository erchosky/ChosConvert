//! Background task registry with cancellation, used by the C ABI.
//!
//! Contract: for every started task the callback receives zero or more progress events and
//! then exactly one terminal event (`completed`, `failed` or `cancelled`), after which it is
//! never called again for that task id.

use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::thread;

use serde_json::{Value, json};

use crate::api;
use crate::cancel::CancelToken;
use crate::error::{AppError, ErrorCode};

pub type EventSink = Box<dyn Fn(&str) + Send + 'static>;

fn registry() -> &'static Mutex<HashMap<u64, CancelToken>> {
    static R: OnceLock<Mutex<HashMap<u64, CancelToken>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

/// Starts `method` on a background thread. Returns the task id (never 0).
pub fn start(method: String, payload: String, sink: EventSink) -> u64 {
    let id = NEXT_ID.fetch_add(1, Ordering::SeqCst);
    let token = CancelToken::new();
    if let Ok(mut r) = registry().lock() {
        r.insert(id, token.clone());
    }
    let spawned = thread::Builder::new()
        .name(format!("cc-task-{id}"))
        .spawn(move || {
            let result = catch_unwind(AssertUnwindSafe(|| {
                let mut emit = |v: Value| sink(&v.to_string());
                api::run_task(&method, &payload, &token, &mut emit)
            }));
            if let Ok(mut r) = registry().lock() {
                r.remove(&id);
            }
            let terminal = match result {
                Ok(Ok(v)) => json!({ "type": "completed", "result": v }),
                Ok(Err(e)) if e.code == ErrorCode::Cancelled || token.is_cancelled() => {
                    json!({ "type": "cancelled" })
                }
                Ok(Err(e)) => json!({ "type": "failed", "error": e }),
                Err(_) => json!({ "type": "failed", "error": AppError::internal("task panicked") }),
            };
            sink(&terminal.to_string());
        });
    if spawned.is_err() {
        if let Ok(mut r) = registry().lock() {
            r.remove(&id);
        }
    }
    id
}

/// Requests cancellation. Returns false if the task is unknown or already finished.
pub fn cancel(id: u64) -> bool {
    let token = registry().lock().ok().and_then(|r| r.get(&id).cloned());
    match token {
        Some(t) => {
            t.cancel();
            true
        }
        None => false,
    }
}

/// Number of tasks currently running.
pub fn active_count() -> usize {
    registry().lock().map(|r| r.len()).unwrap_or(0)
}
