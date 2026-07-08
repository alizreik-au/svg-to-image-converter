//! Error types and process exit-code mapping.
//!
//! Exit codes follow PROJECT_PLAN.md §6:
//! `0` success, `1` user error, `2` render failure, `3` I/O error.

use std::path::PathBuf;

use thiserror::Error;

/// Process exit codes as defined by the plan.
pub const EXIT_SUCCESS: i32 = 0;
pub const EXIT_USER_ERROR: i32 = 1;
pub const EXIT_RENDER_FAILURE: i32 = 2;
pub const EXIT_IO_ERROR: i32 = 3;

/// All failure modes of a single conversion.
#[derive(Debug, Error)]
pub enum ConvertError {
    #[error("input file not found: {0}")]
    InputNotFound(PathBuf),

    #[error("input is not an .svg file: {0}")]
    NotSvg(PathBuf),

    #[error("refusing to write output outside the input directory: {0}")]
    OutputTraversal(PathBuf),

    #[error("output already exists: {0} (use --overwrite to replace)")]
    OutputExists(PathBuf),

    #[error("failed to read input {path}: {source}")]
    ReadInput {
        path: PathBuf,
        source: std::io::Error,
    },

    #[error("failed to parse SVG {path}: {source}")]
    ParseSvg { path: PathBuf, source: usvg::Error },

    #[error("computed image dimensions are invalid ({width}x{height})")]
    InvalidDimensions { width: u32, height: u32 },

    #[error("failed to allocate a {width}x{height} pixel buffer")]
    PixmapAlloc { width: u32, height: u32 },

    #[error("failed to encode image: {0}")]
    Encode(#[from] image::ImageError),

    #[error("failed to write output {path}: {source}")]
    WriteOutput {
        path: PathBuf,
        source: std::io::Error,
    },

    #[error("invalid background color '{0}': expected #RGB or #RRGGBB")]
    BadColor(String),
}

impl ConvertError {
    /// Map an error to the process exit code category from the plan.
    pub fn exit_code(&self) -> i32 {
        match self {
            ConvertError::InputNotFound(_)
            | ConvertError::NotSvg(_)
            | ConvertError::OutputTraversal(_)
            | ConvertError::OutputExists(_)
            | ConvertError::BadColor(_) => EXIT_USER_ERROR,

            ConvertError::ParseSvg { .. }
            | ConvertError::InvalidDimensions { .. }
            | ConvertError::PixmapAlloc { .. }
            | ConvertError::Encode(_) => EXIT_RENDER_FAILURE,

            ConvertError::ReadInput { .. } | ConvertError::WriteOutput { .. } => EXIT_IO_ERROR,
        }
    }
}
