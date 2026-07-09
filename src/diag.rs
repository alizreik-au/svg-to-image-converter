//! Opt-in diagnostics logging for debugging the context-menu invocation chain.
//!
//! Normal use stays completely silent: nothing is written unless the user
//! explicitly turns diagnostics on. Logging is enabled when **either**:
//!   * the environment variable `SVG_CONVERTER_LOG` is set to a truthy value
//!     (anything other than empty or `0`), or
//!   * the sentinel file `%LOCALAPPDATA%\SvgConverter\diagnostics.on` exists.
//!
//! The sentinel file is the friendliest switch for context-menu debugging: the
//! DLL and the child exe both check it at invocation time, so it takes effect
//! without restarting Explorer (unlike a user environment variable).
//!
//! Log lines are appended to
//! `%LOCALAPPDATA%\SvgConverter\logs\svg-converter.log`. Every helper here is
//! best-effort and never panics or propagates errors, so diagnostics can never
//! turn into a new failure mode of the conversion itself.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

/// Environment variable that force-enables logging when truthy.
pub const LOG_ENV: &str = "SVG_CONVERTER_LOG";

/// Base directory (`%LOCALAPPDATA%\SvgConverter`) for all diagnostics state.
fn base_dir() -> Option<PathBuf> {
    let local = std::env::var_os("LOCALAPPDATA")?;
    let mut path = PathBuf::from(local);
    path.push("SvgConverter");
    Some(path)
}

/// Sentinel file whose mere existence enables logging.
pub fn sentinel_path() -> Option<PathBuf> {
    base_dir().map(|mut p| {
        p.push("diagnostics.on");
        p
    })
}

/// Directory that receives the log file.
pub fn log_dir() -> Option<PathBuf> {
    base_dir().map(|mut p| {
        p.push("logs");
        p
    })
}

/// Full path to the shared log file.
pub fn log_path() -> Option<PathBuf> {
    log_dir().map(|mut p| {
        p.push("svg-converter.log");
        p
    })
}

/// Whether diagnostics logging is currently enabled.
pub fn is_enabled() -> bool {
    if let Ok(value) = std::env::var(LOG_ENV) {
        let value = value.trim();
        if !value.is_empty() && value != "0" {
            return true;
        }
    }
    sentinel_path().map(|p| p.exists()).unwrap_or(false)
}

/// Append one line to the log file, tagged with `source`. No-op unless enabled.
///
/// Writes to `%LOCALAPPDATA%\SvgConverter\logs\` first, then falls back to
/// `%TEMP%\SvgConverter\` if the primary path fails (the packaged COM surrogate
/// can load our DLL before user env vars are fully available).
pub fn log(source: &str, message: &str) {
    if !is_enabled() {
        return;
    }
    if let Some(path) = log_path() {
        if write_line_at(&path, source, message).is_ok() {
            return;
        }
    }
    if let Some(path) = temp_log_path() {
        let _ = write_line_at(&path, source, message);
    }
}

fn temp_log_path() -> Option<PathBuf> {
    let temp = std::env::var_os("TEMP")?;
    let mut path = PathBuf::from(temp);
    path.push("SvgConverter");
    path.push("svg-converter.log");
    Some(path)
}

fn write_line_at(path: &PathBuf, source: &str, message: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let pid = std::process::id();
    writeln!(file, "{millis} pid={pid} [{source}] {message}")
}

/// Snapshot of the current process context for the log (exe, cwd, args).
pub fn process_context() -> String {
    let exe = std::env::current_exe()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "<unknown-exe>".to_string());
    let cwd = std::env::current_dir()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "<unknown-cwd>".to_string());
    let args: Vec<String> = std::env::args().collect();
    format!("exe={exe} cwd={cwd} args={args:?}")
}
