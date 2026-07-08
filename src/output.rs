//! Output path resolution and collision handling.

use std::path::{Component, Path, PathBuf};

use crate::cli::{Format, Scale};
use crate::error::ConvertError;

/// Compute the destination path for a conversion.
///
/// With no explicit `--output`, follows the plan's naming convention:
/// `icon.svg` @ 1.0 → `icon.png`, @ 2.0 → `icon@2x.png`,
/// @ 0.5 → `icon@0.5x.png`, written beside the input file.
pub fn resolve_output_path(
    input: &Path,
    format: Format,
    scale: Scale,
    explicit: Option<&Path>,
) -> Result<PathBuf, ConvertError> {
    if let Some(out) = explicit {
        if out.components().any(|c| matches!(c, Component::ParentDir)) {
            return Err(ConvertError::OutputTraversal(out.to_path_buf()));
        }
        return Ok(out.to_path_buf());
    }

    let stem = input
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "output".to_string());

    let filename = format!("{stem}{}.{}", scale.suffix(), format.extension());

    let path = match input.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.join(filename),
        _ => PathBuf::from(filename),
    };
    Ok(path)
}

/// Guard against clobbering an existing file unless the user opted in.
pub fn check_collision(output: &Path, overwrite: bool) -> Result<(), ConvertError> {
    if !overwrite && output.exists() {
        return Err(ConvertError::OutputExists(output.to_path_buf()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn png_one_x_has_no_suffix() {
        let out =
            resolve_output_path(Path::new("dir/icon.svg"), Format::Png, Scale::One, None).unwrap();
        assert_eq!(out, PathBuf::from("dir/icon.png"));
    }

    #[test]
    fn png_two_x_uses_at_2x() {
        let out =
            resolve_output_path(Path::new("dir/icon.svg"), Format::Png, Scale::Two, None).unwrap();
        assert_eq!(out, PathBuf::from("dir/icon@2x.png"));
    }

    #[test]
    fn webp_half_uses_at_half_x() {
        let out =
            resolve_output_path(Path::new("icon.svg"), Format::Webp, Scale::Half, None).unwrap();
        assert_eq!(out, PathBuf::from("icon@0.5x.webp"));
    }

    #[test]
    fn jpg_three_x_extension_is_jpg() {
        let out = resolve_output_path(Path::new("a/b/icon.svg"), Format::Jpeg, Scale::Three, None)
            .unwrap();
        assert_eq!(out, PathBuf::from("a/b/icon@3x.jpg"));
    }

    #[test]
    fn explicit_output_is_respected() {
        let out = resolve_output_path(
            Path::new("icon.svg"),
            Format::Png,
            Scale::One,
            Some(Path::new("custom/name.png")),
        )
        .unwrap();
        assert_eq!(out, PathBuf::from("custom/name.png"));
    }

    #[test]
    fn explicit_output_rejects_traversal() {
        let err = resolve_output_path(
            Path::new("icon.svg"),
            Format::Png,
            Scale::One,
            Some(Path::new("../evil.png")),
        )
        .unwrap_err();
        assert!(matches!(err, ConvertError::OutputTraversal(_)));
    }
}
