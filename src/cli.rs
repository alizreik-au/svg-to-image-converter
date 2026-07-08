//! Command-line interface definitions (clap derive).

use std::path::PathBuf;

use clap::{Parser, Subcommand, ValueEnum};

/// Exact format tokens the context-menu handlers pass to the CLI. Kept here so
/// the consistency test below fails loudly if the CLI ever stops accepting a
/// token that `crates/svg-converter-shell/src/lib.rs` (`build_subcommands`) or
/// `scripts/install-context-menu.ps1` still emits.
///
/// DLL `formats`:  ("PNG","png"), ("JPEG","jpg"), ("WebP","webp")
/// Registry `Flag`: 'png', 'jpg', 'webp'
pub const MENU_FORMAT_TOKENS: [&str; 3] = ["png", "jpg", "webp"];

/// Exact scale tokens the context-menu handlers pass to the CLI.
///
/// DLL `scales`:   "3.0","2.0","1.0","0.5"   Registry `Value`: '3.0','2.0','1.0','0.5'
pub const MENU_SCALE_TOKENS: [&str; 4] = ["3.0", "2.0", "1.0", "0.5"];

/// Default JPEG/WebP quality hint. Single source of truth for both the CLI's
/// `--quality` default and the in-process context-menu handler.
pub const DEFAULT_QUALITY: u8 = 90;

/// Default background used to flatten transparency for JPEG output. Shared by
/// the CLI's `--background` default and the in-process context-menu handler.
pub const DEFAULT_BACKGROUND: &str = "#FFFFFF";

/// Rasterize SVG files to PNG, JPEG, or WebP at fixed scale factors.
#[derive(Debug, Parser)]
#[command(
    name = "svg-converter",
    version,
    about = "Convert SVG files to PNG, JPEG, and WebP",
    long_about = None,
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Convert one or more SVG files to a raster format.
    Convert(ConvertArgs),
}

#[derive(Debug, Parser)]
pub struct ConvertArgs {
    /// One or more input .svg files (Explorer invokes once per file, but
    /// multiple paths are also accepted for batch conversion).
    #[arg(required = true, value_name = "INPUT")]
    pub inputs: Vec<PathBuf>,

    /// Output format.
    #[arg(short, long, value_enum, default_value_t = Format::Png)]
    pub format: Format,

    /// Scale multiplier relative to the SVG's intrinsic size.
    #[arg(short, long, value_enum, default_value_t = Scale::One)]
    pub scale: Scale,

    /// Explicit output path (single input only; defaults to a sibling file).
    #[arg(short, long, value_name = "PATH")]
    pub output: Option<PathBuf>,

    /// JPEG/WebP quality hint (1-100). WebP v1 is lossless, so this only
    /// affects JPEG output.
    #[arg(short, long, default_value_t = DEFAULT_QUALITY, value_parser = clap::value_parser!(u8).range(1..=100))]
    pub quality: u8,

    /// Background color for flattening transparency when encoding JPEG.
    #[arg(long, value_name = "COLOR", default_value = DEFAULT_BACKGROUND)]
    pub background: String,

    /// Replace an existing output file instead of failing.
    #[arg(long)]
    pub overwrite: bool,

    /// Log timing and dimension details (repeat for more verbosity).
    #[arg(short, long, action = clap::ArgAction::Count)]
    pub verbose: u8,

    /// Suppress all logging (useful for context-menu invocations).
    #[arg(long, conflicts_with = "verbose")]
    pub quiet: bool,
}

/// Supported raster output formats.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Format {
    #[value(name = "png")]
    Png,
    #[value(name = "jpg", alias = "jpeg")]
    Jpeg,
    #[value(name = "webp")]
    Webp,
}

impl Format {
    /// File extension used for output files.
    pub fn extension(self) -> &'static str {
        match self {
            Format::Png => "png",
            Format::Jpeg => "jpg",
            Format::Webp => "webp",
        }
    }
}

/// Fixed scale factors from the plan's format × scale matrix.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Scale {
    #[value(name = "0.5")]
    Half,
    #[value(name = "1.0", alias = "1")]
    One,
    #[value(name = "2.0", alias = "2")]
    Two,
    #[value(name = "3.0", alias = "3")]
    Three,
}

impl Scale {
    /// Numeric multiplier applied to the intrinsic SVG size.
    pub fn factor(self) -> f32 {
        match self {
            Scale::Half => 0.5,
            Scale::One => 1.0,
            Scale::Two => 2.0,
            Scale::Three => 3.0,
        }
    }

    /// Filename suffix per the plan's naming convention.
    ///
    /// `1.0` produces no suffix (`icon.png`); other scales append `@Nx`
    /// (`icon@2x.png`, `icon@0.5x.png`).
    pub fn suffix(self) -> &'static str {
        match self {
            Scale::Half => "@0.5x",
            Scale::One => "",
            Scale::Two => "@2x",
            Scale::Three => "@3x",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every format × scale token the DLL / registry menus emit must parse.
    /// If a `Format`/`Scale` value name changes without updating the menus (or
    /// vice-versa), this test fails instead of the change silently breaking the
    /// context menu ("nothing happens").
    #[test]
    fn every_menu_token_combination_parses() {
        for fmt in MENU_FORMAT_TOKENS {
            let expected_format = match fmt {
                "png" => Format::Png,
                "jpg" => Format::Jpeg,
                "webp" => Format::Webp,
                other => panic!("unexpected menu format token: {other}"),
            };
            for scale in MENU_SCALE_TOKENS {
                let expected_scale = match scale {
                    "0.5" => Scale::Half,
                    "1.0" => Scale::One,
                    "2.0" => Scale::Two,
                    "3.0" => Scale::Three,
                    other => panic!("unexpected menu scale token: {other}"),
                };

                let cli = Cli::try_parse_from([
                    "svg-converter",
                    "convert",
                    "input.svg",
                    "-f",
                    fmt,
                    "-s",
                    scale,
                    "--quiet",
                ])
                .unwrap_or_else(|e| panic!("menu tokens -f {fmt} -s {scale} rejected by CLI: {e}"));

                let Command::Convert(args) = cli.command;
                assert_eq!(args.format, expected_format, "format token {fmt}");
                assert_eq!(args.scale, expected_scale, "scale token {scale}");
            }
        }
    }

    #[test]
    fn quick_default_png_one_x_parses() {
        let cli = Cli::try_parse_from([
            "svg-converter",
            "convert",
            "input.svg",
            "-f",
            "png",
            "-s",
            "1.0",
            "--quiet",
        ])
        .expect("Quick PNG 1.0x default must parse");
        let Command::Convert(args) = cli.command;
        assert_eq!(args.format, Format::Png);
        assert_eq!(args.scale, Scale::One);
    }
}
