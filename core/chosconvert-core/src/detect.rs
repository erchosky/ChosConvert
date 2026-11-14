//! Content-based file type detection.
//!
//! The extension is only a hint: the real format comes from magic bytes and lightweight
//! container probing. Reads are bounded (head + tail windows) so detection is cheap even for
//! multi-gigabyte files.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::error::{AppError, CoreResult, ErrorCode, Recovery};
use crate::formats::{Family, Format};

pub const HEAD_LEN: usize = 8 * 1024;
pub const TAIL_LEN: usize = 64 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Confidence {
    High,
    Medium,
    Low,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DetectionWarning {
    /// The extension says one thing, the content says another.
    ExtensionMismatch,
    /// The path was a symbolic link; the target was inspected.
    Symlink,
    /// The file is empty.
    Empty,
    /// The container's end marker is missing (e.g. a partially downloaded JPEG/PNG).
    Truncated,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Detection {
    pub format: Format,
    pub family: Family,
    pub mime: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extension: Option<String>,
    pub extension_matches: bool,
    pub confidence: Confidence,
    pub size_bytes: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub warnings: Vec<DetectionWarning>,
}

impl Detection {
    /// True when the content can safely be handed to a media/document engine.
    pub fn is_processable(&self) -> bool {
        !matches!(self.family, Family::Executable | Family::Unknown)
    }
}

/// Detects the format of a file on disk.
pub fn detect_path(path: &Path) -> CoreResult<Detection> {
    let link_meta = std::fs::symlink_metadata(path).map_err(|e| AppError::io(&e, "stat input"))?;
    let is_symlink = link_meta.file_type().is_symlink();
    let meta = std::fs::metadata(path).map_err(|e| AppError::io(&e, "stat input"))?;
    if !meta.is_file() {
        return Err(AppError::new(
            ErrorCode::NotARegularFile,
            "This item isn't a regular file.",
        ));
    }
    let size = meta.len();
    let mut file = File::open(path).map_err(|e| AppError::io(&e, "open input"))?;

    let mut head = vec![0u8; HEAD_LEN.min(size as usize)];
    file.read_exact(&mut head)
        .map_err(|e| AppError::io(&e, "read input header"))?;

    let tail = if size as usize > HEAD_LEN {
        let len = TAIL_LEN.min(size as usize);
        file.seek(SeekFrom::End(-(len as i64)))
            .map_err(|e| AppError::io(&e, "seek input"))?;
        let mut buf = vec![0u8; len];
        file.read_exact(&mut buf)
            .map_err(|e| AppError::io(&e, "read input trailer"))?;
        Some(buf)
    } else {
        None
    };

    let ext = path.extension().and_then(|e| e.to_str());
    let mut det = detect_bytes(&head, tail.as_deref(), ext);
    det.size_bytes = size;
    if is_truncated(det.format, tail.as_deref().unwrap_or(&head)) {
        det.warnings.push(DetectionWarning::Truncated);
    }
    if is_symlink {
        det.warnings.push(DetectionWarning::Symlink);
    }
    if size == 0 {
        det.warnings.push(DetectionWarning::Empty);
    }
    Ok(det)
}

/// Checks end-of-stream markers for formats that have them. `tail` is the end of the file.
pub fn is_truncated(format: Format, tail: &[u8]) -> bool {
    match format {
        // EOI must appear near the end; tolerate trailing padding/vendor trailers in the window.
        Format::Jpeg => !tail.windows(2).any(|w| w == [0xFF, 0xD9]),
        Format::Png => !contains(&tail[tail.len().saturating_sub(64)..], b"IEND"),
        Format::Gif => !tail.iter().rev().take(64).any(|b| *b == 0x3B),
        _ => false,
    }
}

/// Like [`detect_path`] but fails for content ChosConvert must never process.
pub fn detect_processable(path: &Path) -> CoreResult<Detection> {
    let det = detect_path(path)?;
    match det.family {
        Family::Executable => Err(AppError::new(
            ErrorCode::ExecutableRejected,
            "This file is a program, not a document or media file. ChosConvert won't process it.",
        )),
        Family::Unknown => Err(AppError::new(
            ErrorCode::UnknownFormat,
            "ChosConvert doesn't recognize this file's format.",
        )
        .with_recovery(&[Recovery::CheckFile])),
        _ if det.warnings.contains(&DetectionWarning::Truncated) => Err(AppError::new(
            ErrorCode::CorruptFile,
            "This file is incomplete. It may not have finished downloading or copying.",
        )
        .with_recovery(&[Recovery::CheckFile])),
        _ => Ok(det),
    }
}

/// Pure detection from a header window, an optional trailer window and an extension hint.
pub fn detect_bytes(head: &[u8], tail: Option<&[u8]>, ext: Option<&str>) -> Detection {
    let (format, confidence) = sniff(head, tail, ext);
    let extension = ext.map(|e| e.to_ascii_lowercase());
    let extension_matches = match &extension {
        Some(e) => format.matches_extension(e),
        None => false,
    };
    let mut warnings = Vec::new();
    if extension.is_some() && !extension_matches && format != Format::Unknown {
        warnings.push(DetectionWarning::ExtensionMismatch);
    }
    Detection {
        format,
        family: format.family(),
        mime: format.mime().to_string(),
        extension,
        extension_matches,
        confidence,
        size_bytes: head.len() as u64,
        warnings,
    }
}

fn starts(b: &[u8], sig: &[u8]) -> bool {
    b.len() >= sig.len() && &b[..sig.len()] == sig
}

fn at(b: &[u8], off: usize, sig: &[u8]) -> bool {
    b.len() >= off + sig.len() && &b[off..off + sig.len()] == sig
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty() && hay.windows(needle.len()).any(|w| w == needle)
}

fn sniff(head: &[u8], tail: Option<&[u8]>, ext: Option<&str>) -> (Format, Confidence) {
    use Confidence::*;
    use Format::*;

    // Executables first: never let a renamed binary through as media.
    if starts(head, b"MZ")
        || starts(head, &[0x7F, b'E', b'L', b'F'])
        || starts(head, &[0xFE, 0xED, 0xFA, 0xCE])
        || starts(head, &[0xFE, 0xED, 0xFA, 0xCF])
        || starts(head, &[0xCE, 0xFA, 0xED, 0xFE])
        || starts(head, &[0xCF, 0xFA, 0xED, 0xFE])
        || starts(head, &[0xCA, 0xFE, 0xBA, 0xBE])
        || starts(head, b"#!")
    {
        return (Executable, High);
    }

    if starts(head, &[0xFF, 0xD8, 0xFF]) {
        return (Jpeg, High);
    }
    if starts(head, &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        return (Png, High);
    }
    if starts(head, b"GIF87a") || starts(head, b"GIF89a") {
        return (Gif, High);
    }
    if starts(head, b"RIFF") && head.len() >= 12 {
        match &head[8..12] {
            b"WEBP" => return (Webp, High),
            b"WAVE" => return (Wav, High),
            b"AVI " => return (Avi, High),
            _ => {}
        }
    }
    if starts(head, b"RF64") && at(head, 8, b"WAVE") {
        return (Wav, High);
    }
    if starts(head, b"II*\0") || starts(head, b"MM\0*") {
        return (Tiff, High);
    }
    if starts(head, b"BM") && head.len() >= 14 {
        // BMP header: file size (LE u32) + reserved zeros; reserved check cuts false positives.
        if head[6..10] == [0, 0, 0, 0] {
            return (Bmp, High);
        }
    }
    if at(head, 4, b"ftyp") {
        return (iso_bmff(head), High);
    }
    if starts(head, &[0x1A, 0x45, 0xDF, 0xA3]) {
        let window = &head[..head.len().min(64)];
        return if contains(window, b"webm") {
            (Webm, High)
        } else {
            (Mkv, High)
        };
    }
    if starts(head, b"fLaC") {
        return (Flac, High);
    }
    if starts(head, b"OggS") {
        let window = &head[..head.len().min(128)];
        return if contains(window, b"OpusHead") {
            (Opus, High)
        } else {
            (Ogg, High)
        };
    }
    if starts(head, b"FORM") && (at(head, 8, b"AIFF") || at(head, 8, b"AIFC")) {
        return (Aiff, High);
    }
    if starts(head, b"caff") {
        return (Caf, High);
    }
    if starts(head, b"ID3") {
        return (Mp3, High);
    }
    if head.len() >= 2 && head[0] == 0xFF {
        let b1 = head[1];
        if b1 & 0xF6 == 0xF0 {
            return (Aac, Medium); // ADTS
        }
        if b1 & 0xE0 == 0xE0 && (b1 & 0x06) != 0 {
            return (Mp3, Medium); // MPEG audio frame sync, layer bits non-zero
        }
    }
    // PDF header may be preceded by junk; the spec allows it within the first 1024 bytes.
    if contains(&head[..head.len().min(1024)], b"%PDF-") {
        return (Pdf, High);
    }
    if starts(head, b"PK\x03\x04") {
        return (zip_flavour(head, tail, ext), Medium);
    }
    if starts(head, b"{\\rtf") {
        return (Rtf, High);
    }

    // Text-based formats.
    if let Some(text) = as_text(head) {
        let trimmed = text.trim_start_matches('\u{feff}').trim_start();
        let lower: String = trimmed
            .chars()
            .take(512)
            .collect::<String>()
            .to_ascii_lowercase();
        if lower.starts_with("<svg") || (lower.starts_with("<?xml") && lower.contains("<svg")) {
            return (Svg, High);
        }
        if lower.starts_with("<!doctype html") || lower.starts_with("<html") {
            return (Html, High);
        }
        if lower.contains("<svg") && !lower.contains("<html") {
            return (Svg, Medium);
        }
        let ext_fmt = ext.and_then(Format::from_extension);
        return match ext_fmt {
            Some(Markdown) => (Markdown, Medium),
            Some(Html) => (Html, Low),
            _ => (Txt, Medium),
        };
    }

    (Unknown, Low)
}

fn iso_bmff(head: &[u8]) -> Format {
    use Format::*;
    let box_len = if head.len() >= 4 {
        u32::from_be_bytes([head[0], head[1], head[2], head[3]]) as usize
    } else {
        0
    };
    let major = head.get(8..12).unwrap_or(&[]);
    let end = box_len.clamp(16, head.len());
    let compat: Vec<&[u8]> = head.get(16..end).unwrap_or(&[]).chunks_exact(4).collect();
    let has = |b: &[u8]| major == b || compat.contains(&b);

    if has(b"avif") || has(b"avis") {
        return Avif;
    }
    if has(b"heic")
        || has(b"heix")
        || has(b"heim")
        || has(b"heis")
        || has(b"hevc")
        || has(b"hevx")
        || major == b"mif1"
        || major == b"msf1"
    {
        return Heic;
    }
    if major == b"qt  " {
        return Mov;
    }
    if major == b"M4A " || major == b"M4B " || major == b"M4P " {
        return M4a;
    }
    Mp4
}

/// Distinguishes OOXML / ODF / EPUB / plain ZIP by looking at entry names.
fn zip_flavour(head: &[u8], tail: Option<&[u8]>, ext: Option<&str>) -> Format {
    use Format::*;
    // ODF and EPUB store an uncompressed "mimetype" entry first.
    if at(head, 30, b"mimetype") {
        let content = &head[38..head.len().min(38 + 80)];
        if starts(content, b"application/epub+zip") {
            return Epub;
        }
        if starts(content, b"application/vnd.oasis.opendocument.text") {
            return Odt;
        }
        if starts(content, b"application/vnd.oasis.opendocument.spreadsheet") {
            return Ods;
        }
        if starts(content, b"application/vnd.oasis.opendocument.presentation") {
            return Odp;
        }
    }
    // OOXML: look for well-known part names in the central directory (file trailer) or head.
    let windows: [&[u8]; 2] = [head, tail.unwrap_or(&[])];
    let any = |needle: &[u8]| windows.iter().any(|w| contains(w, needle));
    if any(b"[Content_Types].xml") || any(b"_rels/.rels") {
        if any(b"word/") {
            return Docx;
        }
        if any(b"xl/") {
            return Xlsx;
        }
        if any(b"ppt/") {
            return Pptx;
        }
        // Content types present but parts not in our windows: trust an OOXML extension.
        if let Some(f) = ext.and_then(Format::from_extension) {
            if matches!(f, Docx | Xlsx | Pptx) {
                return f;
            }
        }
    }
    Zip
}

/// Returns the header as text if it looks like UTF-8/ASCII text without binary bytes.
fn as_text(head: &[u8]) -> Option<&str> {
    if head.is_empty() || head.contains(&0) {
        return None;
    }
    // The window may cut a multi-byte sequence; tolerate an incomplete tail of up to 3 bytes.
    let s = match std::str::from_utf8(head) {
        Ok(s) => s,
        Err(e) if e.error_len().is_none() && head.len() - e.valid_up_to() < 4 => {
            std::str::from_utf8(&head[..e.valid_up_to()]).ok()?
        }
        Err(_) => return None,
    };
    let control = s
        .chars()
        .filter(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t' | '\u{c}'))
        .count();
    (control * 100 <= s.len().max(1)).then_some(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn det(bytes: &[u8], ext: &str) -> Detection {
        detect_bytes(bytes, None, Some(ext))
    }

    #[test]
    fn detects_common_images() {
        assert_eq!(
            det(&[0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10], "jpg").format,
            Format::Jpeg
        );
        assert_eq!(
            det(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0], "png").format,
            Format::Png
        );
        assert_eq!(det(b"GIF89a....", "gif").format, Format::Gif);
        assert_eq!(det(b"RIFF\x10\0\0\0WEBPVP8 ", "webp").format, Format::Webp);
        assert_eq!(det(b"II*\0\x08\0\0\0", "tif").format, Format::Tiff);
    }

    #[test]
    fn detects_iso_bmff_brands() {
        let mk = |major: &[u8; 4], compat: &[u8; 4]| {
            let mut v = vec![0, 0, 0, 0x18];
            v.extend_from_slice(b"ftyp");
            v.extend_from_slice(major);
            v.extend_from_slice(&[0, 0, 0, 0]);
            v.extend_from_slice(compat);
            v.extend_from_slice(b"mif1");
            v
        };
        assert_eq!(det(&mk(b"heic", b"mif1"), "heic").format, Format::Heic);
        assert_eq!(det(&mk(b"mif1", b"avif"), "avif").format, Format::Avif);
        assert_eq!(det(&mk(b"qt  ", b"qt  "), "mov").format, Format::Mov);
        assert_eq!(det(&mk(b"isom", b"avc1"), "mp4").format, Format::Mp4);
        assert_eq!(det(&mk(b"M4A ", b"isom"), "m4a").format, Format::M4a);
    }

    #[test]
    fn renamed_executable_is_not_an_image() {
        let d = det(b"MZ\x90\0\x03\0\0\0", "jpg");
        assert_eq!(d.format, Format::Executable);
        assert_eq!(d.family, Family::Executable);
        assert!(!d.is_processable());
        assert!(d.warnings.contains(&DetectionWarning::ExtensionMismatch));

        let macho = det(&[0xCF, 0xFA, 0xED, 0xFE, 7, 0, 0, 1], "png");
        assert_eq!(macho.format, Format::Executable);
        let script = det(b"#!/bin/sh\nrm -rf ~", "mov");
        assert_eq!(script.format, Format::Executable);
    }

    #[test]
    fn png_named_jpg_is_png_with_warning() {
        let d = det(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0], "jpg");
        assert_eq!(d.format, Format::Png);
        assert!(!d.extension_matches);
        assert!(d.warnings.contains(&DetectionWarning::ExtensionMismatch));
    }

    #[test]
    fn detects_audio() {
        assert_eq!(det(b"ID3\x04\0\0\0\0\0\0", "mp3").format, Format::Mp3);
        assert_eq!(det(b"fLaC\0\0\0\x22", "flac").format, Format::Flac);
        assert_eq!(det(b"RIFF\0\0\0\0WAVEfmt ", "wav").format, Format::Wav);
        assert_eq!(
            det(b"OggS\0\x02\0\0\0\0\0\0\0\0OpusHead", "opus").format,
            Format::Opus
        );
        assert_eq!(det(b"FORM\0\0\0\0AIFFCOMM", "aiff").format, Format::Aiff);
    }

    #[test]
    fn detects_matroska_and_webm() {
        let mut webm = vec![0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x82, 0x84];
        webm.extend_from_slice(b"webm");
        assert_eq!(det(&webm, "webm").format, Format::Webm);
        let mut mkv = vec![0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x82, 0x88];
        mkv.extend_from_slice(b"matroska");
        assert_eq!(det(&mkv, "mkv").format, Format::Mkv);
    }

    #[test]
    fn detects_documents() {
        assert_eq!(det(b"%PDF-1.7\n%...", "pdf").format, Format::Pdf);
        assert_eq!(det(b"{\\rtf1\\ansi", "rtf").format, Format::Rtf);
        assert_eq!(
            det(b"<svg xmlns='http://www.w3.org/2000/svg'/>", "svg").format,
            Format::Svg
        );
        assert_eq!(
            det(b"<?xml version=\"1.0\"?>\n<svg>", "svg").format,
            Format::Svg
        );
        assert_eq!(det(b"<!DOCTYPE html><html>", "html").format, Format::Html);
        assert_eq!(
            det(b"# Title\n\nSome *markdown*.", "md").format,
            Format::Markdown
        );
        assert_eq!(det("Hola, ñandú".as_bytes(), "txt").format, Format::Txt);
    }

    #[test]
    fn detects_zip_flavours() {
        let mut odt = b"PK\x03\x04".to_vec();
        odt.resize(30, 0);
        odt.extend_from_slice(b"mimetypeapplication/vnd.oasis.opendocument.text");
        assert_eq!(det(&odt, "odt").format, Format::Odt);

        let mut docx = b"PK\x03\x04".to_vec();
        docx.resize(30, 0);
        docx.extend_from_slice(b"[Content_Types].xml....word/document.xml");
        assert_eq!(det(&docx, "docx").format, Format::Docx);

        let plain = b"PK\x03\x04\x14\0\0\0hello.txt";
        assert_eq!(det(plain, "zip").format, Format::Zip);
    }

    #[test]
    fn truncation_markers() {
        assert!(is_truncated(
            Format::Jpeg,
            &[0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]
        ));
        assert!(!is_truncated(Format::Jpeg, &[1, 2, 0xFF, 0xD9]));
        assert!(!is_truncated(Format::Png, b"....IEND\xAEB`\x82"));
        assert!(is_truncated(Format::Png, b"....IDATxxxx"));
        assert!(!is_truncated(Format::Mp4, b""));
    }

    #[test]
    fn binary_garbage_is_unknown() {
        let d = det(&[0x00, 0x13, 0x37, 0x00, 0x42, 0x99], "jpg");
        assert_eq!(d.format, Format::Unknown);
        assert!(!d.is_processable());
    }

    #[test]
    fn empty_input_is_unknown() {
        assert_eq!(det(&[], "png").format, Format::Unknown);
    }

    #[test]
    fn detect_path_reads_real_files() {
        let dir = std::env::temp_dir().join(format!("cc-detect-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("tmp");
        let p = dir.join("photo.jpg");
        std::fs::write(&p, b"MZ\x90\0this is not a photo").expect("write");
        let d = detect_path(&p).expect("detect");
        assert_eq!(d.format, Format::Executable);
        assert!(detect_processable(&p).is_err());
        assert!(detect_path(&dir).is_err());
        std::fs::remove_dir_all(&dir).ok();
    }
}
