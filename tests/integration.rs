//! End-to-end tests that drive the built `svg-converter` binary against a
//! fixture SVG and verify the produced raster files.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

/// Path to the compiled binary, provided by Cargo for integration tests.
const BIN: &str = env!("CARGO_BIN_EXE_svg-converter");

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("sample.svg")
}

fn unique_dir(tag: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("svgconv-it-{tag}-{nanos}"));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn copy_fixture(into: &Path) -> PathBuf {
    let dst = into.join("sample.svg");
    std::fs::copy(fixture(), &dst).unwrap();
    dst
}

fn run(args: &[&str]) -> std::process::Output {
    Command::new(BIN)
        .args(args)
        .output()
        .expect("failed to launch svg-converter binary")
}

fn starts_with(path: &Path, magic: &[u8]) -> bool {
    let bytes = std::fs::read(path).unwrap();
    bytes.len() > magic.len() && bytes[..magic.len()] == *magic
}

#[test]
fn converts_png_at_2x() {
    let dir = unique_dir("png");
    let svg = copy_fixture(&dir);

    let out = run(&[
        "convert",
        svg.to_str().unwrap(),
        "-f",
        "png",
        "-s",
        "2.0",
        "--quiet",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let png = dir.join("sample@2x.png");
    assert!(png.exists(), "expected {png:?}");
    assert!(std::fs::metadata(&png).unwrap().len() > 0);
    assert!(
        starts_with(&png, &[0x89, 0x50, 0x4E, 0x47]),
        "PNG signature"
    );

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn converts_jpeg_and_webp() {
    let dir = unique_dir("jpgwebp");
    let svg = copy_fixture(&dir);

    let jpg = run(&[
        "convert",
        svg.to_str().unwrap(),
        "-f",
        "jpg",
        "-s",
        "1.0",
        "--quiet",
    ]);
    assert!(jpg.status.success());
    let jpg_path = dir.join("sample.jpg");
    assert!(
        starts_with(&jpg_path, &[0xFF, 0xD8, 0xFF]),
        "JPEG signature"
    );

    let webp = run(&[
        "convert",
        svg.to_str().unwrap(),
        "-f",
        "webp",
        "-s",
        "0.5",
        "--quiet",
    ]);
    assert!(webp.status.success());
    let webp_path = dir.join("sample@0.5x.webp");
    // RIFF....WEBP
    let bytes = std::fs::read(&webp_path).unwrap();
    assert_eq!(&bytes[0..4], b"RIFF");
    assert_eq!(&bytes[8..12], b"WEBP");

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn refuses_non_svg_input() {
    let dir = unique_dir("bad");
    let not_svg = dir.join("note.txt");
    std::fs::write(&not_svg, b"hello").unwrap();

    let out = run(&["convert", not_svg.to_str().unwrap()]);
    assert!(!out.status.success());
    assert_eq!(out.status.code(), Some(1));

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn library_convert_menu_batch_produces_output() {
    // Exercises the shared in-process API the Windows 11 COM handler uses,
    // without any subprocess. This is the code path the packaged DLL runs.
    let dir = unique_dir("libapi");
    let svg = copy_fixture(&dir);

    let outcome = svg_converter::convert_menu_batch(
        std::slice::from_ref(&svg),
        svg_converter::cli::Format::Png,
        svg_converter::cli::Scale::Two,
    );

    assert_eq!(outcome.exit_code, 0, "errors: {:?}", outcome.errors);
    assert_eq!(outcome.successes.len(), 1);
    assert!(outcome.errors.is_empty());

    let png = dir.join("sample@2x.png");
    assert!(png.exists(), "expected {png:?}");
    assert!(
        starts_with(&png, &[0x89, 0x50, 0x4E, 0x47]),
        "PNG signature"
    );

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn library_convert_menu_batch_aggregates_multi_selection_errors() {
    // Multi-selection: a valid .svg plus a non-svg. Errors must aggregate so the
    // handler can show one summary message box.
    let dir = unique_dir("libapi-multi");
    let svg = copy_fixture(&dir);
    let not_svg = dir.join("note.txt");
    std::fs::write(&not_svg, b"hello").unwrap();

    let inputs = vec![svg, not_svg];
    let outcome = svg_converter::convert_menu_batch(
        &inputs,
        svg_converter::cli::Format::Webp,
        svg_converter::cli::Scale::One,
    );

    assert_eq!(outcome.successes.len(), 1, "one valid input should convert");
    assert_eq!(outcome.errors.len(), 1, "one invalid input should error");
    assert_eq!(outcome.exit_code, 1, "non-svg is a user error");

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn respects_collision_and_overwrite() {
    let dir = unique_dir("collision");
    let svg = copy_fixture(&dir);

    let first = run(&["convert", svg.to_str().unwrap(), "--quiet"]);
    assert!(first.status.success());

    let second = run(&["convert", svg.to_str().unwrap(), "--quiet"]);
    assert_eq!(second.status.code(), Some(1), "collision should fail");

    let forced = run(&["convert", svg.to_str().unwrap(), "--overwrite", "--quiet"]);
    assert!(forced.status.success(), "overwrite should succeed");

    std::fs::remove_dir_all(&dir).ok();
}
