//! SVG Converter core library.
//!
//! Phase 1 implements the conversion pipeline (load → scale → render → encode);
//! Phase 2 adds the registry context-menu scripts; Phase 3/4 add the Windows 11
//! primary-menu `IExplorerCommand` handler (see the `svg-converter-shell` crate).
//!
//! The binaries (`svg-converter`, the console entry point, and `svg-converterw`,
//! the no-console GUI-subsystem entry point) are thin wrappers over [`run`] and
//! [`run_quiet`] so that both share the exact same conversion behavior.

pub mod cli;
pub mod convert;
pub mod diag;
pub mod encode;
pub mod error;
pub mod output;

use std::path::{Path, PathBuf};

use clap::Parser;
use tracing::error;
use tracing_subscriber::EnvFilter;

use crate::cli::{Cli, Command, ConvertArgs, Format, Scale};
use crate::convert::{convert_one, ConvertRequest, JobOutcome};
use crate::encode::{parse_color, Rgb};
use crate::error::{ConvertError, EXIT_USER_ERROR};

/// Structured result of a full CLI invocation, used by the no-console binary to
/// surface failures (e.g. via a message box) without a terminal.
#[derive(Debug, Default)]
pub struct RunOutcome {
    /// Worst process exit code encountered (see [`crate::error`]).
    pub exit_code: i32,
    /// Human-readable success lines (`input -> output (WxH)`).
    pub successes: Vec<String>,
    /// Human-readable error lines for failed inputs.
    pub errors: Vec<String>,
}

/// Console entry point: parse args, log to stderr, print results to stdout, and
/// return the worst exit code. Used by `svg-converter.exe`.
pub fn run() -> i32 {
    let cli = Cli::parse();
    match cli.command {
        Command::Convert(args) => {
            init_tracing(args.verbose, args.quiet);
            diag::log("cli", &format!("run start: {}", diag::process_context()));
            let outcome = convert_all(&args);
            for line in &outcome.successes {
                println!("{line}");
            }
            for line in &outcome.errors {
                error!("{line}");
            }
            log_outcome("cli", &outcome);
            outcome.exit_code
        }
    }
}

/// No-console entry point: parse args and convert without initializing stderr
/// logging, returning a structured [`RunOutcome`] the caller can present in a
/// GUI. Used by `svg-converterw.exe`.
///
/// Uses [`Cli::try_parse`] rather than [`Cli::parse`]: in the GUI subsystem
/// there is no console for clap to print to, so a plain `parse()` would call
/// `process::exit` after writing an error nobody can see — the exact
/// "nothing happens, no error" symptom for any argument the handler passes that
/// clap rejects. Instead we capture the parse error (and `--help`/`--version`
/// text) into the outcome so the caller can surface it in a message box.
pub fn run_quiet() -> RunOutcome {
    diag::log(
        "exe",
        &format!("run_quiet start: {}", diag::process_context()),
    );

    let outcome = match Cli::try_parse() {
        Ok(cli) => match cli.command {
            Command::Convert(args) => convert_all(&args),
        },
        Err(err) => RunOutcome {
            exit_code: err.exit_code(),
            successes: Vec::new(),
            errors: vec![err.render().to_string()],
        },
    };

    log_outcome("exe", &outcome);
    outcome
}

/// Record a run's result to the diagnostics log (no-op unless enabled).
fn log_outcome(source: &str, outcome: &RunOutcome) {
    if !diag::is_enabled() {
        return;
    }
    for line in &outcome.successes {
        diag::log(source, &format!("ok: {line}"));
    }
    for line in &outcome.errors {
        diag::log(source, &format!("err: {line}"));
    }
    diag::log(source, &format!("exit_code={}", outcome.exit_code));
}

/// Drive one or more conversions, collecting per-input results and the worst
/// exit code. Shared by both entry points.
fn convert_all(args: &ConvertArgs) -> RunOutcome {
    let background = match parse_color(&args.background) {
        Ok(color) => color,
        Err(err) => {
            return RunOutcome {
                exit_code: err.exit_code(),
                successes: Vec::new(),
                errors: vec![err.to_string()],
            };
        }
    };

    if args.output.is_some() && args.inputs.len() > 1 {
        return RunOutcome {
            exit_code: EXIT_USER_ERROR,
            successes: Vec::new(),
            errors: vec!["--output cannot be used with multiple input files".to_string()],
        };
    }

    let options = convert::build_options();
    let single_input = args.inputs.len() == 1;
    let mut outcome = RunOutcome::default();

    for input in &args.inputs {
        let explicit = if single_input {
            args.output.as_deref()
        } else {
            None
        };

        let request = ConvertRequest {
            input,
            format: args.format,
            scale: args.scale,
            explicit_output: explicit,
            quality: args.quality,
            background,
            overwrite: args.overwrite,
        };

        push_result(&mut outcome, input, convert_one(&request, &options));
    }

    outcome
}

/// Convert a batch of files for a **context-menu action**: a fixed [`Format`]
/// and [`Scale`] with the CLI's default quality/background and no overwrite.
///
/// This is the shared, subprocess-free entry point used by the in-process
/// Windows 11 COM handler (`svg-converter-shell`). Because it drives the same
/// [`convert_one`] core as the CLI, a right-click conversion produces exactly
/// the same output as `svg-converter convert … -f <fmt> -s <scale>`, with no
/// child process — which sidesteps the `C:\Program Files\WindowsApps\…` ACLs
/// that block launching a packaged exe by path.
pub fn convert_menu_batch(inputs: &[PathBuf], format: Format, scale: Scale) -> RunOutcome {
    let background = parse_color(cli::DEFAULT_BACKGROUND).unwrap_or(Rgb {
        r: 255,
        g: 255,
        b: 255,
    });
    let options = convert::build_options();
    let mut outcome = RunOutcome::default();

    for input in inputs {
        let request = ConvertRequest {
            input,
            format,
            scale,
            explicit_output: None,
            quality: cli::DEFAULT_QUALITY,
            background,
            overwrite: false,
        };
        push_result(&mut outcome, input, convert_one(&request, &options));
    }

    outcome
}

/// Fold one conversion result into the running [`RunOutcome`]. Shared by the
/// CLI and the in-process menu handler so both format results identically.
fn push_result(outcome: &mut RunOutcome, input: &Path, result: Result<JobOutcome, ConvertError>) {
    match result {
        Ok(job) => {
            outcome.successes.push(format!(
                "{} -> {} ({}x{})",
                job.input.display(),
                job.output.display(),
                job.width,
                job.height
            ));
        }
        Err(err) => {
            outcome.exit_code = outcome.exit_code.max(err.exit_code());
            outcome.errors.push(format!("{}: {err}", input.display()));
        }
    }
}

/// Configure stderr logging. `--quiet` disables it entirely; `-v`/`-vv`
/// raise verbosity. `RUST_LOG` overrides when set.
fn init_tracing(verbose: u8, quiet: bool) {
    if quiet {
        return;
    }

    let default_level = match verbose {
        0 => "info",
        1 => "debug",
        _ => "trace",
    };

    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(format!("svg_converter={default_level}")));

    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_target(false)
        .without_time()
        .init();
}
