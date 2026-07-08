//! Conversion pipeline: load → scale → render → encode → write.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use tiny_skia::{Pixmap, Transform};
use tracing::{debug, info};
use usvg::{Options, Tree};

use crate::cli::{Format, Scale};
use crate::encode::{self, Rgb};
use crate::error::ConvertError;
use crate::output;

/// Result of a single successful conversion.
#[derive(Debug)]
pub struct JobOutcome {
    pub input: PathBuf,
    pub output: PathBuf,
    pub width: u32,
    pub height: u32,
}

/// All inputs needed to convert one file.
#[derive(Debug)]
pub struct ConvertRequest<'a> {
    pub input: &'a Path,
    pub format: Format,
    pub scale: Scale,
    /// Overrides default sibling naming (single-input use only).
    pub explicit_output: Option<&'a Path>,
    pub quality: u8,
    pub background: Rgb,
    pub overwrite: bool,
}

/// Build shared usvg options with system fonts loaded once for a batch.
pub fn build_options() -> Options<'static> {
    let mut options = Options::default();
    options.fontdb_mut().load_system_fonts();
    options
}

/// Convert a single SVG file into a raster file.
pub fn convert_one(
    request: &ConvertRequest<'_>,
    options: &Options<'static>,
) -> Result<JobOutcome, ConvertError> {
    let &ConvertRequest {
        input,
        format,
        scale,
        explicit_output,
        quality,
        background,
        overwrite,
    } = request;

    validate_input_extension(input)?;

    let output_path = output::resolve_output_path(input, format, scale, explicit_output)?;
    output::check_collision(&output_path, overwrite)?;

    let data = fs::read(input).map_err(|source| match source.kind() {
        std::io::ErrorKind::NotFound => ConvertError::InputNotFound(input.to_path_buf()),
        _ => ConvertError::ReadInput {
            path: input.to_path_buf(),
            source,
        },
    })?;

    let parse_start = Instant::now();
    let tree = Tree::from_data(&data, options).map_err(|source| ConvertError::ParseSvg {
        path: input.to_path_buf(),
        source,
    })?;
    debug!(elapsed_ms = parse_start.elapsed().as_millis(), "parsed SVG");

    let factor = scale.factor();
    let size = tree.size();
    let width = f32_to_dim(size.width() * factor);
    let height = f32_to_dim(size.height() * factor);
    if width == 0 || height == 0 {
        return Err(ConvertError::InvalidDimensions { width, height });
    }

    let mut pixmap =
        Pixmap::new(width, height).ok_or(ConvertError::PixmapAlloc { width, height })?;

    let render_start = Instant::now();
    let transform = Transform::from_scale(factor, factor);
    resvg::render(&tree, transform, &mut pixmap.as_mut());
    debug!(
        elapsed_ms = render_start.elapsed().as_millis(),
        width, height, "rendered pixmap"
    );

    let encode_start = Instant::now();
    let rgba = encode::pixmap_to_rgba(&pixmap);
    encode::encode(&rgba, format, &output_path, quality, background)?;
    debug!(
        elapsed_ms = encode_start.elapsed().as_millis(),
        "encoded output"
    );

    info!(
        input = %input.display(),
        output = %output_path.display(),
        width,
        height,
        "converted"
    );

    Ok(JobOutcome {
        input: input.to_path_buf(),
        output: output_path,
        width,
        height,
    })
}

/// Round a scaled dimension to a valid pixel count (minimum 1 px), guarding
/// against non-finite values and overflow.
fn f32_to_dim(value: f32) -> u32 {
    if !value.is_finite() || value < 0.0 {
        return 0;
    }
    let rounded = value.round();
    if rounded > u32::MAX as f32 {
        return 0;
    }
    (rounded as u32).max(1)
}

/// Ensure the input has an `.svg` extension (case-insensitive).
fn validate_input_extension(input: &Path) -> Result<(), ConvertError> {
    let is_svg = input
        .extension()
        .map(|ext| ext.eq_ignore_ascii_case("svg"))
        .unwrap_or(false);
    if is_svg {
        Ok(())
    } else {
        Err(ConvertError::NotSvg(input.to_path_buf()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dim_clamps_to_min_one() {
        assert_eq!(f32_to_dim(0.4), 1);
        assert_eq!(f32_to_dim(0.0), 1);
    }

    #[test]
    fn dim_rounds() {
        assert_eq!(f32_to_dim(2.4), 2);
        assert_eq!(f32_to_dim(2.5), 3);
    }

    #[test]
    fn dim_rejects_non_finite() {
        assert_eq!(f32_to_dim(f32::NAN), 0);
        assert_eq!(f32_to_dim(f32::INFINITY), 0);
        assert_eq!(f32_to_dim(-5.0), 0);
    }

    #[test]
    fn non_svg_extension_is_rejected() {
        let err = validate_input_extension(Path::new("image.png")).unwrap_err();
        assert!(matches!(err, ConvertError::NotSvg(_)));
    }

    #[test]
    fn svg_extension_case_insensitive() {
        assert!(validate_input_extension(Path::new("a.SVG")).is_ok());
        assert!(validate_input_extension(Path::new("a.svg")).is_ok());
    }
}
