//! SVG Converter — console entry point (`svg-converter.exe`).
//!
//! Keeps the console subsystem so stderr logging (`-v`, `RUST_LOG`) and stdout
//! results work when run from a terminal. The context-menu path uses the
//! no-console `svg-converterw.exe` variant instead (see `src/bin/svg-converterw.rs`).

fn main() {
    std::process::exit(svg_converter::run());
}
