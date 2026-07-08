//! Format-specific encoding: PNG (lossless), JPEG (flattened), WebP (lossless).

use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::Path;

use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::PngEncoder;
use image::codecs::webp::WebPEncoder;
use image::{ExtendedColorType, ImageEncoder, RgbImage, RgbaImage};
use tiny_skia::Pixmap;

use crate::cli::Format;
use crate::error::ConvertError;

/// An opaque background color used to flatten alpha for JPEG output.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

/// Parse a `#RGB` or `#RRGGBB` (hash optional) color string.
pub fn parse_color(input: &str) -> Result<Rgb, ConvertError> {
    let hex = input.strip_prefix('#').unwrap_or(input);
    let bad = || ConvertError::BadColor(input.to_string());

    let byte = |s: &str| u8::from_str_radix(s, 16).map_err(|_| bad());

    match hex.len() {
        3 => {
            let expand = |c: &str| format!("{c}{c}");
            Ok(Rgb {
                r: byte(&expand(&hex[0..1]))?,
                g: byte(&expand(&hex[1..2]))?,
                b: byte(&expand(&hex[2..3]))?,
            })
        }
        6 => Ok(Rgb {
            r: byte(&hex[0..2])?,
            g: byte(&hex[2..4])?,
            b: byte(&hex[4..6])?,
        }),
        _ => Err(bad()),
    }
}

/// Convert a rendered tiny-skia pixmap (premultiplied) into a straight-alpha
/// RGBA image suitable for the `image` crate encoders.
pub fn pixmap_to_rgba(pixmap: &Pixmap) -> RgbaImage {
    let width = pixmap.width();
    let height = pixmap.height();
    let mut buf = Vec::with_capacity((width as usize) * (height as usize) * 4);
    for pixel in pixmap.pixels() {
        let color = pixel.demultiply();
        buf.push(color.red());
        buf.push(color.green());
        buf.push(color.blue());
        buf.push(color.alpha());
    }
    RgbaImage::from_raw(width, height, buf)
        .expect("pixmap dimensions always match the RGBA buffer length")
}

/// Composite an RGBA image over an opaque background, producing RGB.
fn flatten_over(rgba: &RgbaImage, bg: Rgb) -> RgbImage {
    let mut out = RgbImage::new(rgba.width(), rgba.height());
    for (x, y, pixel) in rgba.enumerate_pixels() {
        let [r, g, b, a] = pixel.0;
        let alpha = f32::from(a) / 255.0;
        let blend = |fg: u8, back: u8| {
            (f32::from(fg) * alpha + f32::from(back) * (1.0 - alpha)).round() as u8
        };
        out.put_pixel(
            x,
            y,
            image::Rgb([blend(r, bg.r), blend(g, bg.g), blend(b, bg.b)]),
        );
    }
    out
}

/// Encode `rgba` to `path` in the requested format.
pub fn encode(
    rgba: &RgbaImage,
    format: Format,
    path: &Path,
    quality: u8,
    background: Rgb,
) -> Result<(), ConvertError> {
    let file = File::create(path).map_err(|source| ConvertError::WriteOutput {
        path: path.to_path_buf(),
        source,
    })?;
    let mut writer = BufWriter::new(file);
    let (width, height) = (rgba.width(), rgba.height());

    match format {
        Format::Png => {
            PngEncoder::new(&mut writer).write_image(
                rgba.as_raw(),
                width,
                height,
                ExtendedColorType::Rgba8,
            )?;
        }
        Format::Jpeg => {
            let rgb = flatten_over(rgba, background);
            JpegEncoder::new_with_quality(&mut writer, quality).write_image(
                rgb.as_raw(),
                width,
                height,
                ExtendedColorType::Rgb8,
            )?;
        }
        Format::Webp => {
            // v1: pure-Rust lossless WebP (no C dependency).
            WebPEncoder::new_lossless(&mut writer).write_image(
                rgba.as_raw(),
                width,
                height,
                ExtendedColorType::Rgba8,
            )?;
        }
    }

    writer.flush().map_err(|source| ConvertError::WriteOutput {
        path: path.to_path_buf(),
        source,
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_six_digit_hex() {
        assert_eq!(
            parse_color("#FF8800").unwrap(),
            Rgb {
                r: 255,
                g: 136,
                b: 0
            }
        );
    }

    #[test]
    fn parses_three_digit_hex() {
        assert_eq!(
            parse_color("#f80").unwrap(),
            Rgb {
                r: 255,
                g: 136,
                b: 0
            }
        );
    }

    #[test]
    fn parses_without_hash() {
        assert_eq!(
            parse_color("FFFFFF").unwrap(),
            Rgb {
                r: 255,
                g: 255,
                b: 255
            }
        );
    }

    #[test]
    fn rejects_bad_color() {
        assert!(parse_color("#zzz").is_err());
        assert!(parse_color("#12").is_err());
        assert!(parse_color("notacolor").is_err());
    }

    #[test]
    fn flatten_opaque_pixel_is_unchanged() {
        let mut rgba = RgbaImage::new(1, 1);
        rgba.put_pixel(0, 0, image::Rgba([10, 20, 30, 255]));
        let rgb = flatten_over(
            &rgba,
            Rgb {
                r: 255,
                g: 255,
                b: 255,
            },
        );
        assert_eq!(rgb.get_pixel(0, 0).0, [10, 20, 30]);
    }

    #[test]
    fn flatten_transparent_pixel_becomes_background() {
        let mut rgba = RgbaImage::new(1, 1);
        rgba.put_pixel(0, 0, image::Rgba([10, 20, 30, 0]));
        let rgb = flatten_over(
            &rgba,
            Rgb {
                r: 200,
                g: 100,
                b: 50,
            },
        );
        assert_eq!(rgb.get_pixel(0, 0).0, [200, 100, 50]);
    }
}
