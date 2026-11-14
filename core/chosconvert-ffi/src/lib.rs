//! Stable C ABI for the ChosConvert core.
//!
//! Design: a handful of functions exchanging UTF-8 JSON documents. Rust types never cross
//! the boundary, so the Swift and C# sides depend only on documented JSON shapes plus
//! `cc_abi_version()` (binary contract) and `api_version` (JSON contract, from `core.info`).
//!
//! Memory: strings and buffers returned by the core must be released with `cc_string_free`
//! / `cc_buffer_free`. Inputs are borrowed for the duration of the call only.
//! No function unwinds across the boundary: panics become structured errors.

#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used))]

use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};

use chosconvert_core::api;
use chosconvert_core::error::AppError;
use chosconvert_core::tasks;

/// Bumped when a function signature or ownership rule changes.
pub const CC_ABI_VERSION: u32 = 1;

/// Callback for task events. `event_json` is only valid during the call.
pub type CcEventCallback =
    Option<unsafe extern "C" fn(user_data: *mut c_void, task_id: u64, event_json: *const c_char)>;

fn into_c_string(s: String) -> *mut c_char {
    // JSON never contains interior NULs (they are escaped), but stay defensive.
    CString::new(s.replace('\0', "\\u0000"))
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// `ptr` must be null or a valid NUL-terminated string.
unsafe fn borrow_str<'a>(ptr: *const c_char) -> Result<&'a str, AppError> {
    if ptr.is_null() {
        return Err(AppError::invalid_request("null string"));
    }
    // SAFETY: caller guarantees a valid NUL-terminated string.
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|_| AppError::invalid_request("string is not valid UTF-8"))
}

/// Binary interface version.
#[unsafe(no_mangle)]
pub extern "C" fn cc_abi_version() -> u32 {
    CC_ABI_VERSION
}

/// Core version string (static, do not free).
#[unsafe(no_mangle)]
pub extern "C" fn cc_core_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

/// Synchronous call. Returns a JSON envelope that must be freed with `cc_string_free`.
///
/// # Safety
/// `method` and `payload_json` must be valid NUL-terminated UTF-8 strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cc_call(
    method: *const c_char,
    payload_json: *const c_char,
) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: forwarded caller guarantees.
        let m = unsafe { borrow_str(method) }?;
        // SAFETY: forwarded caller guarantees.
        let p = unsafe { borrow_str(payload_json) }?;
        api::call(m, p)
    }));
    let envelope = match result {
        Ok(Ok(v)) => api::envelope_ok(v),
        Ok(Err(e)) => api::envelope_err(&e),
        Err(_) => api::envelope_err(&AppError::internal("core panicked")),
    };
    into_c_string(envelope)
}

/// Frees a string returned by the core. Null is ignored.
///
/// # Safety
/// `s` must come from this library and not be freed twice.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cc_string_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: allocated by CString::into_raw in this library.
        drop(unsafe { CString::from_raw(s) });
    }
}

struct SendPtr(*mut c_void);
// SAFETY: the caller promises (see cc_task_start) that user_data may be used from any thread.
unsafe impl Send for SendPtr {}

/// Starts a background task and returns its id (non-zero), or 0 on invalid arguments.
/// Events are delivered on a core-owned background thread; exactly one terminal event
/// (`completed`, `failed`, `cancelled`) is delivered last.
///
/// # Safety
/// Strings must be valid NUL-terminated UTF-8. `callback` must be safe to call from any
/// thread with `user_data` until the terminal event has been delivered.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cc_task_start(
    method: *const c_char,
    payload_json: *const c_char,
    callback: CcEventCallback,
    user_data: *mut c_void,
) -> u64 {
    let Some(cb) = callback else { return 0 };
    // SAFETY: forwarded caller guarantees.
    let (Ok(m), Ok(p)) = (unsafe { borrow_str(method) }, unsafe {
        borrow_str(payload_json)
    }) else {
        return 0;
    };
    let (m, p) = (m.to_owned(), p.to_owned());
    let ud = SendPtr(user_data);
    let id_cell = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
    let id_for_sink = id_cell.clone();
    let sink = move |json: &str| {
        let ud = &ud;
        if let Ok(c) = CString::new(json.replace('\0', "\\u0000")) {
            let id = id_for_sink.load(std::sync::atomic::Ordering::SeqCst);
            // SAFETY: caller guarantees the callback/user_data contract.
            unsafe { cb(ud.0, id, c.as_ptr()) };
        }
    };
    let result = catch_unwind(AssertUnwindSafe(|| tasks::start(m, p, Box::new(sink))));
    match result {
        Ok(id) => {
            id_cell.store(id, std::sync::atomic::Ordering::SeqCst);
            id
        }
        Err(_) => 0,
    }
}

/// Requests cancellation of a task. Returns false if it is unknown or already finished.
#[unsafe(no_mangle)]
pub extern "C" fn cc_task_cancel(task_id: u64) -> bool {
    catch_unwind(|| tasks::cancel(task_id)).unwrap_or(false)
}

/// Encodes straight-alpha RGBA8 pixels to WebP.
/// Returns 0 on success (`*out_data`/`*out_len` set, free with `cc_buffer_free`), or -1 with
/// `*out_error_json` set to an AppError JSON (free with `cc_string_free`).
///
/// # Safety
/// `rgba` must point to at least `stride * height` readable bytes. Out pointers must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cc_webp_encode(
    rgba: *const u8,
    width: u32,
    height: u32,
    stride: u32,
    quality: f32,
    lossless: bool,
    out_data: *mut *mut u8,
    out_len: *mut usize,
    out_error_json: *mut *mut c_char,
) -> i32 {
    if out_data.is_null() || out_len.is_null() || out_error_json.is_null() {
        return -2;
    }
    // SAFETY: out pointers checked non-null; caller guarantees validity.
    unsafe {
        *out_data = std::ptr::null_mut();
        *out_len = 0;
        *out_error_json = std::ptr::null_mut();
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        if rgba.is_null() || height == 0 {
            return Err(AppError::invalid_request("null pixel buffer"));
        }
        let len = stride as usize * height as usize;
        // SAFETY: caller guarantees `len` readable bytes.
        let px = unsafe { std::slice::from_raw_parts(rgba, len) };
        chosconvert_core::webp::encode_rgba(px, width, height, stride, quality, lossless)
    }));
    let result = result.unwrap_or_else(|_| Err(AppError::internal("webp encoder panicked")));
    match result {
        Ok(bytes) => {
            let boxed = bytes.into_boxed_slice();
            let n = boxed.len();
            let ptr = Box::into_raw(boxed).cast::<u8>();
            // SAFETY: out pointers validated above.
            unsafe {
                *out_data = ptr;
                *out_len = n;
            }
            0
        }
        Err(e) => {
            // SAFETY: out pointer validated above.
            unsafe { *out_error_json = into_c_string(api::envelope_err(&e)) };
            -1
        }
    }
}

/// Frees a buffer returned by `cc_webp_encode`.
///
/// # Safety
/// `data`/`len` must be exactly what the core returned, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cc_buffer_free(data: *mut u8, len: usize) {
    if !data.is_null() {
        // SAFETY: reconstructs the boxed slice created in cc_webp_encode.
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(data, len)) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    fn call(method: &str, payload: &str) -> serde_json::Value {
        let m = CString::new(method).expect("c");
        let p = CString::new(payload).expect("c");
        // SAFETY: valid C strings.
        let out = unsafe { cc_call(m.as_ptr(), p.as_ptr()) };
        // SAFETY: returned by cc_call.
        let s = unsafe { CStr::from_ptr(out) }
            .to_str()
            .expect("utf8")
            .to_owned();
        // SAFETY: returned by cc_call.
        unsafe { cc_string_free(out) };
        serde_json::from_str(&s).expect("json")
    }

    #[test]
    fn abi_roundtrip() {
        assert_eq!(cc_abi_version(), CC_ABI_VERSION);
        let v = call("core.info", "{}");
        assert_eq!(v["ok"], true);
        let e = call("detect.path", "{\"path\":42}");
        assert_eq!(e["ok"], false);
        // SAFETY: null pointers are handled.
        let out = unsafe { cc_call(std::ptr::null(), std::ptr::null()) };
        // SAFETY: returned by cc_call.
        unsafe { cc_string_free(out) };
    }

    unsafe extern "C" fn on_event(ud: *mut c_void, _id: u64, json: *const c_char) {
        // SAFETY: test passes a leaked Sender.
        let tx = unsafe { &*(ud as *const mpsc::Sender<String>) };
        // SAFETY: valid during the call.
        let s = unsafe { CStr::from_ptr(json) }
            .to_string_lossy()
            .into_owned();
        let _ = tx.send(s);
    }

    #[test]
    fn task_reports_terminal_failure_for_unknown_method() {
        let (tx, rx) = mpsc::channel::<String>();
        let tx = Box::into_raw(Box::new(tx));
        let m = CString::new("nope").expect("c");
        let p = CString::new("{}").expect("c");
        // SAFETY: valid strings; callback is thread-safe; tx outlives the task.
        let id = unsafe { cc_task_start(m.as_ptr(), p.as_ptr(), Some(on_event), tx.cast()) };
        assert_ne!(id, 0);
        let ev = rx
            .recv_timeout(std::time::Duration::from_secs(5))
            .expect("event");
        assert!(ev.contains("\"failed\""), "{ev}");
        // SAFETY: no more events after the terminal one.
        drop(unsafe { Box::from_raw(tx) });
    }

    #[test]
    fn webp_roundtrip() {
        let px = vec![200u8; 16 * 16 * 4];
        let mut data = std::ptr::null_mut();
        let mut len = 0usize;
        let mut err = std::ptr::null_mut();
        // SAFETY: valid buffers.
        let rc = unsafe {
            cc_webp_encode(
                px.as_ptr(),
                16,
                16,
                64,
                80.0,
                false,
                &mut data,
                &mut len,
                &mut err,
            )
        };
        assert_eq!(rc, 0);
        assert!(len > 12);
        // SAFETY: returned by cc_webp_encode.
        unsafe { cc_buffer_free(data, len) };
        // SAFETY: invalid dims produce an error string.
        let rc = unsafe {
            cc_webp_encode(
                px.as_ptr(),
                0,
                16,
                64,
                80.0,
                false,
                &mut data,
                &mut len,
                &mut err,
            )
        };
        assert_eq!(rc, -1);
        assert!(!err.is_null());
        // SAFETY: returned by cc_webp_encode.
        unsafe { cc_string_free(err) };
    }
}
