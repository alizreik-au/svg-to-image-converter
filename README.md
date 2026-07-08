# SVG Converter

Windows utility to rasterize `.svg` files to **PNG**, **JPEG**, and **WebP** from the Explorer right-click menu, with fixed scale factors (×3.0, ×2.0, ×1.0, ×0.5).

> **Status:** Phase 1 (core CLI), Phase 2 (legacy context-menu installer), and Phase 4 (Windows 11 primary-menu `IExplorerCommand` handler via a sparse MSIX package) implemented. See [PROJECT_PLAN.md](./PROJECT_PLAN.md) for the full architecture and roadmap.

## Binaries

| Binary | Subsystem | Purpose |
|--------|-----------|---------|
| `svg-converter.exe` | console | CLI for terminal use — stderr logging (`-v`, `RUST_LOG`) and stdout results |
| `svg-converterw.exe` | windows (no console) | Same conversion behavior, but never flashes a console window; used by the **legacy registry** context menu. Errors are shown in a message box. |
| `svg_converter_shell.dll` | — | Windows 11/10 `IExplorerCommand` COM handler (packaged MSIX menu). Converts **in-process** — links the conversion core statically; launches no exe. |

Both executables are thin wrappers over the shared `svg_converter` library crate, so the CLI and the context menu always behave identically.

## Build

```powershell
# From the repository root:
cargo build --release
# Output: target\release\svg-converter.exe
```

## Usage

```powershell
# One-click default: PNG at 1.0x, written beside the source
svg-converter convert "C:\path\to\icon.svg"
# -> icon.png

# PNG at 2.0x
svg-converter convert "icon.svg" -f png -s 2.0
# -> icon@2x.png

# JPEG at 3.0x (transparency flattened onto --background, default white)
svg-converter convert "icon.svg" -f jpg -s 3.0 -q 90 --background "#FFFFFF"
# -> icon@3x.jpg

# WebP (lossless) at 0.5x
svg-converter convert "icon.svg" -f webp -s 0.5
# -> icon@0.5x.webp

# Batch: multiple inputs (one output per file)
svg-converter convert a.svg b.svg c.svg -f png -s 2.0

# Explicit output path (single input only)
svg-converter convert "icon.svg" -o "C:\out\logo.png"
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-f, --format <png\|jpg\|webp>` | Output format | `png` |
| `-s, --scale <0.5\|1.0\|2.0\|3.0>` | Scale relative to intrinsic SVG size | `1.0` |
| `-o, --output <PATH>` | Explicit output path (single input) | auto beside input |
| `-q, --quality <1-100>` | JPEG quality (WebP is lossless in v1) | `90` |
| `--background <COLOR>` | Background for JPEG alpha flattening (`#RGB`/`#RRGGBB`) | `#FFFFFF` |
| `--overwrite` | Replace an existing output file | off |
| `-v, --verbose` | Log timing/dimensions (repeatable) | off |
| `--quiet` | Suppress logging (used by context menu) | off |

**Naming convention:** `1.0x` → `name.ext`; other scales → `name@2x.ext`, `name@0.5x.ext`, etc. The source `.svg` is never overwritten.

**Exit codes:** `0` success · `1` user error · `2` render/encode failure · `3` I/O error.

## Install (end users)

The friendliest way to install is the **one‑file MSIX installer**. From the
built `target\installer` folder, the user runs:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-SvgConverter.ps1
```

This trusts the bundled signing certificate (one UAC prompt) and installs a
self‑contained **MSIX package** that:

- adds **Convert SVG** to the right‑click menu on `.svg` files — the **Windows 11
  primary menu** *and* the **Windows 10 (1809+) classic menu**, from one
  packaged `IExplorerCommand` handler;
- appears in **Settings → Installed apps** with one‑click uninstall;
- needs no Developer Mode.

To uninstall: *Settings → Installed apps → SVG Converter*, or
`Uninstall-SvgConverter.ps1`.

A **Classic** fallback (`Install-SvgConverter.ps1 -Mode Classic`) installs
without any package or certificate for locked‑down environments. Full step‑by‑step
instructions, including the certificate/SmartScreen explanation, are in
[INSTALL.md](./INSTALL.md).

### Building the installer

```powershell
# Builds release binaries, packs a full MSIX (makeappx), signs it (signtool),
# and stages the installer in target\installer:
.\scripts\build-installer.ps1
# Output: target\installer\SvgConverter-<version>-x64.msix (+ .cer + scripts)
```

Requires the Windows 10/11 SDK (`makeappx.exe`, `signtool.exe`). Use
`-PfxPath <prod.pfx>` to sign with a production certificate instead of the
self‑signed dev cert. This full MSIX is the distribution artifact; the sparse
package below remains a developer‑only convenience.

## Context menu (Phase 2)

Register the cascading right-click menu (`Convert SVG ▸ PNG/JPEG/WebP ▸ scale`, plus a Quick PNG 1× entry):

```powershell
# Per-user (no admin)
.\scripts\install-context-menu.ps1 -InstallDir "$env:LOCALAPPDATA\Programs\SvgConverter" -PerUser

# Machine-wide (elevated PowerShell)
.\scripts\install-context-menu.ps1 -InstallDir "C:\Program Files\SvgConverter"

# Remove
.\scripts\uninstall-context-menu.ps1 -PerUser   # or elevated, without -PerUser
```

This registry approach works on Windows 10 (classic menu) and Windows 11 (under **Show more options**). For the Windows 11 **primary/compact** menu, use the sparse package below. The two integrations coexist: keep the registry menu as the Win10 / "Show more options" fallback and add the sparse package for the Win11 primary menu.

## Windows 11 primary menu (Phase 4)

The compact menu shown on first right-click can only be extended by an `IExplorerCommand` COM handler registered through a package with identity. We ship that as a **sparse (external-location) MSIX package**: a tiny identity package (`AppxManifest.xml`) that points at your existing, externally-installed binaries — no full MSIX repackaging of the exe.

### Architecture

- **`svg_converter_shell.dll`** (crate `crates/svg-converter-shell`) implements `IExplorerCommand` with the `windows` crate (windows-rs). The top-level **Convert SVG** command reports `ECF_HASSUBCOMMANDS` and exposes the format × scale matrix (plus **Quick: PNG (1×)**) via `IExplorerCommand::EnumSubCommands`.
- The DLL is an in-process COM server hosted by the packaged **surrogate** (`dllhost.exe`) via `com:SurrogateServer`.
- On invoke, each leaf **converts in-process** by calling `svg_converter::convert_menu_batch(...)` — the DLL links the shared `svg_converter` conversion core **statically**, so a right-click produces exactly the same output as `svg-converter convert … -f <fmt> -s <scale>` with **no child process**. This is required for MSIX: the binaries live under `C:\Program Files\WindowsApps\…`, whose ACLs deny launching the packaged exe by path (`CreateProcessW` → `ERROR_ACCESS_DENIED`), which is why an earlier "shell out to `svg-converterw.exe`" design made the menu silently do nothing. Multi-selection is converted item-by-item and errors are aggregated into one message box.
- The `AppxManifest.xml` uses `desktop4:FileExplorerContextMenus` (attach to `.svg`) + `com:ComServer` (register the CLSID), with `uap10:AllowExternalContent` so the manifest can reference the external binaries. The CLSID in the manifest matches `CLSID_CONVERT_SVG` in the DLL.

### Install (run these yourself)

These steps register a package and change your machine's Appx state, so they are not run for you:

```powershell
# 1. Build release binaries + stage the "external location" (binaries, DLL,
#    AppxManifest.xml, and generated MSIX logo assets):
.\scripts\build-sparse-package.ps1
#    -> stages into %LOCALAPPDATA%\Programs\SvgConverter by default
#       (use -InstallDir "C:\Program Files\SvgConverter" for machine-wide)

# 2. Enable Developer Mode (required to register a loose/unsigned manifest):
#    Settings > Privacy & security > For developers > Developer Mode = On

# 3. Register the sparse package (per-user):
.\scripts\install-sparse-package.ps1
#    or:  .\scripts\install-sparse-package.ps1 -ExternalLocation "C:\Program Files\SvgConverter"

# 4. Right-click any .svg -> Convert SVG (primary Windows 11 menu).
#    If it doesn't appear immediately:  Stop-Process -Name explorer -Force

# Remove:
.\scripts\uninstall-sparse-package.ps1
```

### Production signing (distribution)

Dev registration (`-Register`) needs only Developer Mode. To distribute, pack and sign a real `.msix` with a certificate the target machine trusts:

```powershell
# Pack (requires Windows SDK: makeappx.exe)
makeappx pack /d "C:\Program Files\SvgConverter" /p SvgConverter.msix /o

# Create a self-signed cert whose subject matches AppxManifest Identity/Publisher
# (CN=SvgConverter Dev) — for testing only:
$cert = New-SelfSignedCertificate -Type Custom -Subject "CN=SvgConverter Dev" `
  -KeyUsage DigitalSignature -FriendlyName "SvgConverter Dev" `
  -CertStoreLocation "Cert:\CurrentUser\My" `
  -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")

# Export + sign (signtool.exe from the Windows SDK)
$pwd = ConvertTo-SecureString -String "test" -Force -AsPlainText
Export-PfxCertificate -Cert "Cert:\CurrentUser\My\$($cert.Thumbprint)" -FilePath dev.pfx -Password $pwd
signtool sign /fd SHA256 /a /f dev.pfx /p test SvgConverter.msix

# Trust the cert (test machines only): import dev.cer into
#   Cert:\LocalMachine\Root  (and TrustedPeople), then:
Add-AppxPackage -Path SvgConverter.msix -ExternalLocation "C:\Program Files\SvgConverter"
```

For public distribution use a CA-trusted certificate (e.g. Azure Trusted Signing) instead of a self-signed one.

## Troubleshooting: "Convert SVG does nothing"

If a right-click conversion produces no file and no error, use the built-in
diagnostics to tell **CLI broken** apart from **handler wiring broken**:

```powershell
# 1. One-shot health check (read-only: nothing is installed or changed):
.\scripts\diagnose.ps1
#    - locates the installed binaries,
#    - prints the exact exe the Win11 handler would launch (and whether it exists),
#    - runs `svg-converter.exe convert <temp>.svg -f png -s 1.0 -v` to prove the core works,
#    - reports the registry menu + Appx registration.

# 2. If the CLI works but the menu still does nothing, capture the handler chain:
.\scripts\diagnose.ps1 -EnableLogging     # creates %LOCALAPPDATA%\SvgConverter\diagnostics.on
#    ... now right-click a .svg in Explorer and pick a Convert action to reproduce ...
.\scripts\diagnose.ps1 -ShowLog           # prints %LOCALAPPDATA%\SvgConverter\logs\svg-converter.log
.\scripts\diagnose.ps1 -DisableLogging    # turn it back off when done
```

**How logging works.** Diagnostics are opt-in and off by default (normal use
writes nothing). They turn on when either the environment variable
`SVG_CONVERTER_LOG` is truthy **or** the sentinel file
`%LOCALAPPDATA%\SvgConverter\diagnostics.on` exists (the sentinel takes effect
immediately, with no Explorer restart). Both the in-process DLL handler (MSIX
menu) and `svg-converterw.exe` (legacy registry menu) append to
`%LOCALAPPDATA%\SvgConverter\logs\svg-converter.log`. The DLL records each
in-process conversion (format/scale, per-file result, exit reason); the exe
records the full command line, working directory, and any error — including
clap argument-parse errors that the no-console exe would otherwise swallow
silently.

## Stack

- **Render:** [resvg](https://github.com/linebender/resvg) 0.47 + usvg 0.47 + tiny-skia 0.12
- **Encode:** [image](https://crates.io/crates/image) 0.25 (PNG, JPEG, lossless WebP — pure Rust, no C deps)
- **CLI:** clap 4 · anyhow · thiserror · tracing

## Project layout

```text
svg-converter/
├── PROJECT_PLAN.md
├── README.md
├── Cargo.toml            # workspace root + svg-converter package
├── src/
│   ├── lib.rs            # shared conversion core (crate svg_converter) + run()/run_quiet()
│   ├── main.rs           # console bin: svg-converter.exe
│   ├── bin/
│   │   └── svg-converterw.rs  # no-console bin: svg-converterw.exe (GUI subsystem)
│   ├── cli.rs            # clap args, Format/Scale enums
│   ├── convert.rs        # load → scale → render → encode pipeline
│   ├── encode.rs         # PNG/JPEG/WebP encoders, color parsing
│   ├── output.rs         # naming + collision policy
│   └── error.rs          # error types + exit-code mapping
├── crates/
│   └── svg-converter-shell/   # IExplorerCommand COM DLL (svg_converter_shell.dll)
│       ├── Cargo.toml
│       └── src/lib.rs
├── packaging/
│   ├── AppxManifest.xml  # sparse package manifest (com:ComServer + FileExplorerContextMenus)
│   └── assets/icon.svg   # source icon for generated MSIX logos
├── scripts/
│   ├── install-context-menu.ps1     # legacy registry cascade (Win10 / "Show more options")
│   ├── uninstall-context-menu.ps1
│   ├── build-sparse-package.ps1     # build + stage external location + generate logos
│   ├── install-sparse-package.ps1   # register sparse package (Win11 primary menu)
│   └── uninstall-sparse-package.ps1
└── tests/
    ├── fixtures/sample.svg
    └── integration.rs
```

## Testing

```powershell
cargo test          # unit + integration
cargo clippy        # lints
```
