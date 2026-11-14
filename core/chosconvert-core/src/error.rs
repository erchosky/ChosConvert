//! Structured, user-presentable errors.
//!
//! Every error that can reach the UI carries a stable `code`, a `category`, an English
//! fallback message, suggested recovery actions and optional backend details. The UI
//! localizes using `error.<code>` keys and only shows `details` behind "View technical details".

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCategory {
    Input,
    Unsupported,
    Io,
    Permission,
    Engine,
    Cancelled,
    Validation,
    Resource,
    Internal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    FileNotFound,
    NotARegularFile,
    Unreadable,
    UnknownFormat,
    ExecutableRejected,
    CorruptFile,
    UnsupportedOperation,
    EngineUnavailable,
    EngineFailed,
    EncoderFailed,
    OutputNotWritable,
    OutputInvalid,
    OutputExists,
    NotSmaller,
    TargetSizeUnreachable,
    ImageTooLarge,
    Timeout,
    DiskFull,
    Cancelled,
    InvalidRequest,
    InvalidRecipe,
    PasswordRequired,
    Internal,
}

impl ErrorCode {
    pub fn category(self) -> ErrorCategory {
        use ErrorCode::*;
        match self {
            FileNotFound | NotARegularFile | UnknownFormat | ExecutableRejected | CorruptFile
            | PasswordRequired => ErrorCategory::Input,
            UnsupportedOperation => ErrorCategory::Unsupported,
            Unreadable | OutputExists | DiskFull => ErrorCategory::Io,
            OutputNotWritable => ErrorCategory::Permission,
            EngineUnavailable
            | EngineFailed
            | EncoderFailed
            | OutputInvalid
            | NotSmaller
            | TargetSizeUnreachable
            | Timeout => ErrorCategory::Engine,
            ImageTooLarge => ErrorCategory::Resource,
            Cancelled => ErrorCategory::Cancelled,
            InvalidRequest | InvalidRecipe => ErrorCategory::Validation,
            Internal => ErrorCategory::Internal,
        }
    }
}

/// Recovery actions the UI can offer as buttons.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Recovery {
    TrySoftwareEncoding,
    ChooseOtherFormat,
    ChooseOutputFolder,
    GrantFolderAccess,
    InstallEngine,
    Retry,
    ReduceQuality,
    IncreaseTargetSize,
    CheckFile,
    FreeDiskSpace,
    EnterPassword,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, thiserror::Error)]
#[error("{code:?}: {message}")]
pub struct AppError {
    pub code: ErrorCode,
    pub category: ErrorCategory,
    /// English fallback. UIs should prefer the localized `error.<code>` string.
    pub message: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub recovery: Vec<Recovery>,
    /// Original backend details (stderr tail, OS error). Never contains file contents.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
}

impl AppError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            category: code.category(),
            message: message.into(),
            recovery: Vec::new(),
            details: None,
        }
    }

    pub fn with_details(mut self, details: impl Into<String>) -> Self {
        self.details = Some(details.into());
        self
    }

    pub fn with_recovery(mut self, recovery: &[Recovery]) -> Self {
        self.recovery.extend_from_slice(recovery);
        self
    }

    pub fn cancelled() -> Self {
        Self::new(ErrorCode::Cancelled, "The operation was cancelled.")
    }

    pub fn invalid_request(details: impl Into<String>) -> Self {
        Self::new(ErrorCode::InvalidRequest, "The request was not valid.").with_details(details)
    }

    pub fn internal(details: impl Into<String>) -> Self {
        Self::new(
            ErrorCode::Internal,
            "Something went wrong inside ChosConvert.",
        )
        .with_details(details)
    }

    /// Maps an I/O error to a structured error. `what` describes the operation, without paths.
    pub fn io(err: &std::io::Error, what: &str) -> Self {
        use std::io::ErrorKind::*;
        let (code, msg) = match err.kind() {
            NotFound => (ErrorCode::FileNotFound, "The file could not be found."),
            PermissionDenied => (
                ErrorCode::OutputNotWritable,
                "ChosConvert doesn't have permission to access this location.",
            ),
            AlreadyExists => (
                ErrorCode::OutputExists,
                "A file with that name already exists.",
            ),
            StorageFull | QuotaExceeded => (ErrorCode::DiskFull, "There isn't enough disk space."),
            _ => (
                ErrorCode::Unreadable,
                "The file couldn't be read or written.",
            ),
        };
        let mut e = AppError::new(code, msg).with_details(format!("{what}: {err}"));
        match code {
            ErrorCode::OutputNotWritable => {
                e.recovery = vec![Recovery::GrantFolderAccess, Recovery::ChooseOutputFolder]
            }
            ErrorCode::DiskFull => e.recovery = vec![Recovery::FreeDiskSpace],
            _ => {}
        }
        e
    }
}

pub type CoreResult<T> = Result<T, AppError>;
