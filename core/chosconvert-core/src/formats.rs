//! File formats and families known to ChosConvert.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Family {
    Image,
    Video,
    Audio,
    Pdf,
    Document,
    Archive,
    Executable,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Format {
    // Images
    Jpeg,
    Png,
    Gif,
    Webp,
    Avif,
    Heic,
    Tiff,
    Bmp,
    Svg,
    // Video containers
    Mp4,
    Mov,
    Mkv,
    Webm,
    Avi,
    // Audio
    M4a,
    Mp3,
    Wav,
    Aiff,
    Flac,
    Ogg,
    Opus,
    Caf,
    Aac,
    // Documents
    Pdf,
    Txt,
    Rtf,
    Markdown,
    Html,
    Docx,
    Xlsx,
    Pptx,
    Odt,
    Ods,
    Odp,
    Epub,
    // Other
    Zip,
    Executable,
    Unknown,
}

impl Format {
    pub const ALL: &'static [Format] = &[
        Format::Jpeg,
        Format::Png,
        Format::Gif,
        Format::Webp,
        Format::Avif,
        Format::Heic,
        Format::Tiff,
        Format::Bmp,
        Format::Svg,
        Format::Mp4,
        Format::Mov,
        Format::Mkv,
        Format::Webm,
        Format::Avi,
        Format::M4a,
        Format::Mp3,
        Format::Wav,
        Format::Aiff,
        Format::Flac,
        Format::Ogg,
        Format::Opus,
        Format::Caf,
        Format::Aac,
        Format::Pdf,
        Format::Txt,
        Format::Rtf,
        Format::Markdown,
        Format::Html,
        Format::Docx,
        Format::Xlsx,
        Format::Pptx,
        Format::Odt,
        Format::Ods,
        Format::Odp,
        Format::Epub,
        Format::Zip,
        Format::Executable,
    ];

    pub fn family(self) -> Family {
        use Format::*;
        match self {
            Jpeg | Png | Gif | Webp | Avif | Heic | Tiff | Bmp | Svg => Family::Image,
            Mp4 | Mov | Mkv | Webm | Avi => Family::Video,
            M4a | Mp3 | Wav | Aiff | Flac | Ogg | Opus | Caf | Aac => Family::Audio,
            Pdf => Family::Pdf,
            Txt | Rtf | Markdown | Html | Docx | Xlsx | Pptx | Odt | Ods | Odp | Epub => {
                Family::Document
            }
            Zip => Family::Archive,
            Executable => Family::Executable,
            Unknown => Family::Unknown,
        }
    }

    /// Extensions in order of preference; the first is used for output files.
    pub fn extensions(self) -> &'static [&'static str] {
        use Format::*;
        match self {
            Jpeg => &["jpg", "jpeg", "jpe", "jfif"],
            Png => &["png"],
            Gif => &["gif"],
            Webp => &["webp"],
            Avif => &["avif"],
            Heic => &["heic", "heif", "hif"],
            Tiff => &["tiff", "tif"],
            Bmp => &["bmp", "dib"],
            Svg => &["svg"],
            Mp4 => &["mp4", "m4v"],
            Mov => &["mov", "qt"],
            Mkv => &["mkv"],
            Webm => &["webm"],
            Avi => &["avi"],
            M4a => &["m4a", "m4b"],
            Mp3 => &["mp3"],
            Wav => &["wav", "wave"],
            Aiff => &["aiff", "aif", "aifc"],
            Flac => &["flac"],
            Ogg => &["ogg", "oga"],
            Opus => &["opus"],
            Caf => &["caf"],
            Aac => &["aac", "adts"],
            Pdf => &["pdf"],
            Txt => &["txt", "text"],
            Rtf => &["rtf"],
            Markdown => &["md", "markdown"],
            Html => &["html", "htm"],
            Docx => &["docx"],
            Xlsx => &["xlsx"],
            Pptx => &["pptx"],
            Odt => &["odt"],
            Ods => &["ods"],
            Odp => &["odp"],
            Epub => &["epub"],
            Zip => &["zip"],
            Executable => &["exe", "dll", "app", "dylib", "so", "bin"],
            Unknown => &[],
        }
    }

    pub fn primary_extension(self) -> &'static str {
        self.extensions().first().copied().unwrap_or("bin")
    }

    pub fn mime(self) -> &'static str {
        use Format::*;
        match self {
            Jpeg => "image/jpeg",
            Png => "image/png",
            Gif => "image/gif",
            Webp => "image/webp",
            Avif => "image/avif",
            Heic => "image/heic",
            Tiff => "image/tiff",
            Bmp => "image/bmp",
            Svg => "image/svg+xml",
            Mp4 => "video/mp4",
            Mov => "video/quicktime",
            Mkv => "video/x-matroska",
            Webm => "video/webm",
            Avi => "video/x-msvideo",
            M4a => "audio/mp4",
            Mp3 => "audio/mpeg",
            Wav => "audio/wav",
            Aiff => "audio/aiff",
            Flac => "audio/flac",
            Ogg => "audio/ogg",
            Opus => "audio/ogg; codecs=opus",
            Caf => "audio/x-caf",
            Aac => "audio/aac",
            Pdf => "application/pdf",
            Txt => "text/plain",
            Rtf => "application/rtf",
            Markdown => "text/markdown",
            Html => "text/html",
            Docx => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            Xlsx => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            Pptx => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            Odt => "application/vnd.oasis.opendocument.text",
            Ods => "application/vnd.oasis.opendocument.spreadsheet",
            Odp => "application/vnd.oasis.opendocument.presentation",
            Epub => "application/epub+zip",
            Zip => "application/zip",
            Executable => "application/octet-stream",
            Unknown => "application/octet-stream",
        }
    }

    pub fn from_extension(ext: &str) -> Option<Format> {
        let lower = ext.trim_start_matches('.').to_ascii_lowercase();
        Format::ALL
            .iter()
            .copied()
            .find(|f| f.extensions().contains(&lower.as_str()))
    }

    /// Whether `ext` is one of this format's extensions (case-insensitive).
    pub fn matches_extension(self, ext: &str) -> bool {
        let lower = ext.trim_start_matches('.').to_ascii_lowercase();
        self.extensions().contains(&lower.as_str())
            // ISO-BMFF siblings are routinely interchanged by real-world tools.
            || matches!(
                (self, lower.as_str()),
                (Format::Mp4, "mov") | (Format::Mov, "mp4") | (Format::M4a, "mp4")
                    | (Format::Mp4, "m4a")
                    | (Format::Mkv, "webm")
                    | (Format::Webm, "mkv")
                    | (Format::Ogg, "opus")
                    | (Format::Opus, "ogg")
                    | (Format::Txt, "md")
                    | (Format::Txt, "markdown")
                    | (Format::Txt, "csv")
                    | (Format::Txt, "log")
                    | (Format::Markdown, "txt")
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extension_lookup_is_case_insensitive() {
        assert_eq!(Format::from_extension("JPG"), Some(Format::Jpeg));
        assert_eq!(Format::from_extension(".heif"), Some(Format::Heic));
        assert_eq!(Format::from_extension("xyz"), None);
    }

    #[test]
    fn every_format_has_family_and_mime() {
        for f in Format::ALL {
            assert!(!f.mime().is_empty());
            assert_ne!(f.family(), Family::Unknown);
            assert!(!f.extensions().is_empty());
        }
    }
}
