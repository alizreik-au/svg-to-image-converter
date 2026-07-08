//! SVG Converter — no-console entry point (`svg-converterw.exe`).
//!
//! Identical conversion behavior to `svg-converter.exe`, but built for the
//! Windows GUI subsystem so context-menu invocations never flash a console
//! window. Because there is no terminal, failures are surfaced through a message
//! box instead of stderr. The naming follows the `python`/`pythonw` convention.

#![cfg_attr(windows, windows_subsystem = "windows")]

use svg_converter::run_quiet;

#[cfg(windows)]
use windows::core::{HSTRING, PCWSTR};
#[cfg(windows)]
use windows::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONERROR, MB_OK, MB_SETFOREGROUND};

fn main() {
    let outcome = run_quiet();

    #[cfg(windows)]
    if !outcome.errors.is_empty() {
        report_errors(&outcome.errors);
    }

    // On non-Windows targets (used only for `cargo check`/tests portability),
    // fall back to stderr so failures are not silently swallowed.
    #[cfg(not(windows))]
    for line in &outcome.errors {
        eprintln!("{line}");
    }

    std::process::exit(outcome.exit_code);
}

/// Show a modal error dialog listing every failed conversion.
#[cfg(windows)]
fn report_errors(errors: &[String]) {
    let body = errors.join("\r\n");
    let text = HSTRING::from(body);
    let caption = HSTRING::from("SVG Converter");
    // SAFETY: both wide strings are valid, null-terminated, and outlive the call.
    unsafe {
        MessageBoxW(
            None,
            PCWSTR(text.as_ptr()),
            PCWSTR(caption.as_ptr()),
            MB_OK | MB_ICONERROR | MB_SETFOREGROUND,
        );
    }
}
