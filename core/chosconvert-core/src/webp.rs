//! WebP encoding through the bundled libwebp (BSD-3-Clause).
//!
//! Neither ImageIO (macOS) nor WIC (Windows) can write WebP, so the core provides it for both.
//! The platform decodes and color-manages; the core only compresses RGBA pixels.

use crate::error::{AppError, CoreResult, ErrorCode};

pub const MAX_DIMENSION: u32 = 16_383;

/// Encodes straight (non-premultiplied) RGBA8 pixels.
pub fn encode_rgba(
    rgba: &[u8],
    width: u32,
    height: u32,
    stride: u32,
    quality: f32,
    lossless: bool,
) -> CoreResult<Vec<u8>> {
    if width == 0 || height == 0 || width > MAX_DIMENSION || height > MAX_DIMENSION {
        return Err(AppError::new(
            ErrorCode::ImageTooLarge,
            "WebP images can be at most 16383 pixels on each side.",
        )
        .with_details(format!("{width}x{height}")));
    }
    let needed = (stride as u64) * (height as u64 - 1) + width as u64 * 4;
    if stride < width * 4 || (rgba.len() as u64) < needed {
        return Err(AppError::invalid_request(
            "pixel buffer smaller than declared size",
        ));
    }
    let q = quality.clamp(0.0, 100.0);
    let mut out: *mut u8 = std::ptr::null_mut();
    // SAFETY: the buffer covers `height` rows of `stride` bytes (checked above); libwebp
    // allocates `out`, which we copy and release with WebPFree.
    let size = unsafe {
        if lossless {
            libwebp_sys::WebPEncodeLosslessRGBA(
                rgba.as_ptr(),
                width as i32,
                height as i32,
                stride as i32,
                &mut out,
            )
        } else {
            libwebp_sys::WebPEncodeRGBA(
                rgba.as_ptr(),
                width as i32,
                height as i32,
                stride as i32,
                q,
                &mut out,
            )
        }
    };
    if size == 0 || out.is_null() {
        return Err(AppError::new(
            ErrorCode::EncoderFailed,
            "The WebP encoder failed.",
        ));
    }
    // SAFETY: libwebp returned `size` valid bytes at `out`.
    let bytes = unsafe { std::slice::from_raw_parts(out, size) }.to_vec();
    // SAFETY: `out` was allocated by libwebp.
    unsafe { libwebp_sys::WebPFree(out.cast()) };
    Ok(bytes)
}

/// libwebp encoder version as "major.minor.patch".
pub fn version() -> String {
    // SAFETY: pure function without arguments.
    let v = unsafe { libwebp_sys::WebPGetEncoderVersion() };
    format!("{}.{}.{}", (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gradient(w: u32, h: u32) -> Vec<u8> {
        let mut v = Vec::with_capacity((w * h * 4) as usize);
        for y in 0..h {
            for x in 0..w {
                v.extend_from_slice(&[(x * 255 / w) as u8, (y * 255 / h) as u8, 128, 255]);
            }
        }
        v
    }

    #[test]
    fn encodes_valid_webp() {
        let px = gradient(64, 48);
        let lossy = encode_rgba(&px, 64, 48, 64 * 4, 80.0, false).expect("lossy");
        assert_eq!(&lossy[0..4], b"RIFF");
        assert_eq!(&lossy[8..12], b"WEBP");
        let lossless = encode_rgba(&px, 64, 48, 64 * 4, 0.0, true).expect("lossless");
        assert_eq!(&lossless[8..12], b"WEBP");
        let det = crate::detect::detect_bytes(&lossy, None, Some("webp"));
        assert_eq!(det.format, crate::formats::Format::Webp);
    }

    #[test]
    fn rejects_bad_buffers() {
        assert!(encode_rgba(&[0; 10], 64, 48, 256, 80.0, false).is_err());
        assert!(encode_rgba(&[], 0, 0, 0, 80.0, false).is_err());
        assert!(encode_rgba(&[0; 16], 20_000, 1, 80_000, 80.0, false).is_err());
    }

    #[test]
    fn reports_version() {
        assert!(version().starts_with('1'));
    }
}
