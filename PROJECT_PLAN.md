# SVG Converter — Project Plan

**Project folder:** `svg-converter/` (repository root)  
**Working name:** `svg-converter` (binary: `svg-converter.exe`)  
**Status:** Planning / pre-implementation  
**Target platform:** Windows 10 and Windows 11  
**Last updated:** 2026-07-07

---

## 1. Executive Summary

SVG Converter is a Windows-focused utility that rasterizes SVG files to **PNG**, **JPEG**, and **WebP** at configurable scale factors (**×3.0**, **×2.0**, **×1.0**, **×0.5**), exposed through **right-click context menu** actions on `.svg` files.

The recommended approach is a **custom Rust CLI** built on the **resvg / usvg / tiny-skia** ecosystem (not wrapping the upstream `resvg` CLI alone), plus **registry-based static shell verbs** installed via PowerShell. This delivers fast, portable, single-binary rendering without system dependencies, with a clear upgrade path to Windows 11 primary-menu integration later.

---

## 2. Workspace Context

`WebApps` is a **multi-project container**, not a monorepo:

| Folder | Stack | Notes |
|--------|-------|-------|
| `ClickUpTasker/` | Tauri 2 + Bun + Rust | Most recent; has `src-tauri/` Rust experience |
| `chep-ai-repair/` | (separate app) | Older project |
| `Unreal-mcp-bun/` | Bun + MCP | Tooling project |

**Placement decision:** `svg-converter/` as a **standalone Rust CLI project** at the WebApps root. No changes to existing projects. Initialize its own git repo when implementation begins (WebApps root is not currently a git repository).

**Conventions to follow:**
- Rust edition 2021 (matches ClickUpTasker)
- Clear `README.md` + installer scripts
- Windows-first packaging; keep dependencies minimal
- Avoid inline imports; exhaustive enum matching in Rust

---

## 3. Goals

### Primary goals
1. Convert a single `.svg` file to PNG, JPG, or WebP from Explorer right-click.
2. Support scale factors: **3.0**, **2.0**, **1.0**, **0.5** (relative to SVG intrinsic size).
3. Expose **all format × scale combinations** via context menu (12 actions) plus a sensible **one-click default**.
4. Fast conversion suitable for interactive use (< 1 s for typical icons on modern hardware).
5. Zero runtime dependencies (no ImageMagick, Inkscape, or Node required on end-user machines).
6. Reproducible output across machines (same pixels for same input/settings).

### Secondary goals
- Batch conversion when multiple SVGs are selected.
- Optional output naming convention (`icon.svg` → `icon@2x.png`).
- Install/uninstall scripts with elevation checks.
- Structured logging and user-visible error toasts on failure.

---

## 4. Non-Goals (v1)

| Non-goal | Rationale |
|----------|-----------|
| SVG animation or scripting | resvg is static-only; out of scope |
| In-place overwrite of source SVG | Safety risk; always write sibling raster file |
| macOS / Linux context menus | Windows-only target for v1 |
| GUI settings app | CLI + context menu is sufficient |
| Full SVG 2.0 / every edge case | resvg documents unsupported features; good enough for production assets |
| Win11 primary menu (IExplorerCommand) in v1 | Higher complexity; planned Phase 3 |
| COM in-process shell extension DLL | Crash risk in Explorer; avoid unless necessary |

---

## 5. Technology Stack Recommendation

### 5.1 Renderer: resvg ecosystem (recommended)

| Component | Role | Why |
|-----------|------|-----|
| **usvg** | Parse, normalize, flatten SVG tree | Handles inheritance, units, text shaping, filters preprocessing |
| **resvg** | Render normalized tree to pixels | Mature, actively maintained (v0.47+, MSRV 1.87) |
| **tiny-skia** | CPU raster backend | Portable, no system libs; good x86-64 performance |

**Research findings:**

- **resvg** is the leading pure-Rust SVG rasterizer for correctness and speed. It ships a CLI (~1.4 MB Windows zip) but outputs **PNG only** — JPG/WebP require additional encoding in our tool.
- **~1,600+ regression tests**; reproducible cross-platform pixels.
- **tiny-skia** is 20–100% slower than full Skia on x86-64 but faster than cairo/raqote in many cases; MSVC builds are usable on Windows (clang optional for SIMD).
- **Alternatives considered:**
  - **lunasvg / nanosvg / wxSvg:** Fail resvg's feature threshold (<25% test pass); not suitable for general SVG.
  - **librsvg (C/Rust):** Heavier dependency chain; resvg already outperforms on feature coverage.
  - **Inkscape CLI:** High quality but slow, large install, poor fit for one-click context menu.
  - **ImageMagick / rsvg-convert:** External dependencies; slower cold start; harder to distribute.
  - **Wrap upstream resvg CLI:** Possible for PNG-only MVP, but cannot satisfy JPG/WebP/scale menu matrix without a wrapper layer anyway — custom Rust binary is simpler long-term.

**Verdict:** Build a **thin custom Rust application** using `usvg` + `resvg` + `tiny-skia` directly. Do not fork resvg; depend on crates.

### 5.2 Encoding: image + WebP strategy

| Format | Crate | Notes |
|--------|-------|-------|
| **PNG** | `image` (png codec) or `png` | Lossless; default output |
| **JPEG** | `image` (jpeg encoder) | Strip alpha before encode; quality ~90 default |
| **WebP** | `image` lossless **or** `webp` crate (libwebp) | See below |

**WebP options:**

| Option | Pros | Cons |
|--------|------|------|
| `image::codecs::webp` (lossless) | Pure Rust, no C deps | No lossy; larger files than lossy WebP |
| `image-webp` | Pure Rust, fast lossless | No lossy encoder yet |
| `webp` crate (libwebp-sys) | Lossy + quality knob, smaller files | C dependency, build complexity on Windows |
| `zenwebp` | Pure Rust lossy+lossless | Newer; evaluate during implementation |

**v1 recommendation:** PNG/JPEG via `image` crate. WebP via **`image` lossless** for simplicity (zero C deps). Add **lossy WebP** behind a feature flag (`lossy-webp`) using `webp` or `zenwebp` in Phase 2 if file size matters.

### 5.3 CLI / UX layer

| Piece | Choice |
|-------|--------|
| Language | Rust 2021 |
| CLI parser | `clap` v4 (derive) |
| Error handling | `anyhow` + `thiserror` for library boundary |
| Logging | `tracing` + `tracing-subscriber` (stderr; `--quiet` for context menu) |
| Windows notifications | `winrt-notification` or simple `MessageBox` fallback on error |

### 5.4 Context menu integration

| Approach | v1 | v2+ |
|----------|----|-----|
| Registry static verbs | **Yes** | Keep as fallback |
| PowerShell install/uninstall | **Yes** | |
| Cascading submenu (registry) | **Yes** | |
| IExplorerCommand COM DLL | No | Phase 3 |
| MSIX / Sparse Package | No | Phase 3 |

---

## 6. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Windows Explorer                             │
│  Right-click .svg → Context menu verbs (registry-installed)    │
└────────────────────────────┬────────────────────────────────────┘
                             │ "%1" file path + CLI flags
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│              svg-converter.exe (Rust CLI)                        │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────────┐ │
│  │ clap args   │→ │ ConvertJob   │→ │ Encoder (png/jpeg/webp)│ │
│  │ validation  │  │ orchestrator │  └────────────────────────┘ │
│  └─────────────┘  └──────┬───────┘                               │
│                          │                                       │
│              ┌───────────▼───────────┐                           │
│              │ usvg::Tree::from_file│                           │
│              │ resvg::render →Pixmap │                           │
│              └───────────────────────┘                           │
└────────────────────────────┬────────────────────────────────────┘
                             ▼
                   Output: sibling raster file
                   e.g. logo@2x.png next to logo.svg
```

### Crate layout (recommended)

```
svg-converter/
├── Cargo.toml
├── src/
│   ├── main.rs              # CLI entry, exit codes
│   ├── cli.rs               # clap definitions
│   ├── convert.rs           # pipeline: load → scale → render → encode
│   ├── encode.rs            # format-specific writers
│   ├── output.rs            # path naming, collision handling
│   └── error.rs
├── scripts/
│   ├── install-context-menu.ps1
│   └── uninstall-context-menu.ps1
├── assets/
│   └── icon.ico             # menu icon
├── tests/
│   ├── fixtures/            # sample SVGs
│   └── integration.rs
└── PROJECT_PLAN.md
```

Optional refactor later: split `svg-converter-core` library crate if tests grow.

### Data flow

1. **Load:** `usvg::Tree::from_file(path, &Options::default())`
2. **Compute size:** `tree.size()` × scale factor → `width`, `height` (rounded, minimum 1 px)
3. **Render:** `resvg::render(&tree, transform, &mut pixmap)`
4. **Encode:** pixmap RGBA → target format
5. **Write:** `{stem}@{scale}x.{ext}` or `{stem}.{ext}` for 1.0x (configurable)

### CLI interface (draft)

```text
svg-converter convert <INPUT> [OPTIONS]

Options:
  -f, --format <png|jpg|webp>   Output format [default: png]
  -s, --scale <SCALE>           Scale multiplier: 0.5, 1.0, 2.0, 3.0 [default: 1.0]
  -o, --output <PATH>           Output path (default: auto beside input)
  -q, --quality <1-100>         JPEG/WebP quality [default: 90]
      --background <COLOR>      Background for transparent JPEG [default: #FFFFFF]
      --overwrite               Replace existing output file
  -v, --verbose                 Log timing and dimensions
  -h, --help
```

**Exit codes:** `0` success, `1` user error, `2` render failure, `3` I/O error.

---

## 7. Feature Breakdown

### 7.1 One-click default

| Menu label | Command |
|------------|---------|
| **Convert SVG to PNG** | `svg-converter.exe convert "%1" -f png -s 1.0` |

Placed at top of submenu or as single prominent entry.

### 7.2 Format × scale matrix (12 variants)

Nested registry structure:

```text
Convert SVG ▶
├── Quick: PNG (1×)                    [one-click]
├── PNG ▶
│   ├── 3.0×    … -f png -s 3.0
│   ├── 2.0×    … -f png -s 2.0
│   ├── 1.0×    … -f png -s 1.0
│   └── 0.5×    … -f png -s 0.5
├── JPEG ▶
│   └── (same 4 scales)
└── WebP ▶
    └── (same 4 scales)
```

### 7.3 Multi-select

When user selects multiple `.svg` files, Explorer invokes the verb **once per file** (`%1` per invocation). No special code required.

### 7.4 Output naming

| Input | Scale | Format | Default output |
|-------|-------|--------|----------------|
| `icon.svg` | 1.0 | png | `icon.png` |
| `icon.svg` | 2.0 | png | `icon@2x.png` |
| `icon.svg` | 0.5 | webp | `icon@0.5x.webp` |
| `icon.svg` | 3.0 | jpg | `icon@3x.jpg` |

If output exists: skip with notification unless `--overwrite`.

---

## 8. Windows Context Menu Integration Strategy

### 8.1 Recommended v1: Registry static verbs

Register under **system file association** for `.svg`:

```text
HKCR\SystemFileAssociations\.svg\shell\SvgConverter\shell\
```

**Why this approach:**
- No COM DLL loaded into `explorer.exe` (stable, simple)
- Works on **Windows 10** immediately
- Works on **Windows 11** — appears in primary menu for static verbs on file types, or under **Show more options** depending on verb registration style and OS build
- Install/uninstall via elevated PowerShell
- Matches patterns used by community tools (e.g. "Open with X" installers)

**Registry pattern (cascade example):**

```text
HKCR\SystemFileAssociations\.svg\shell\SvgConverter
  (Default) = "Convert SVG"
  Icon = "C:\Program Files\SvgConverter\svg-converter.exe,0"
  SubCommands = ""                    ; optional: use explicit child keys instead

HKCR\SystemFileAssociations\.svg\shell\SvgConverter\shell\png_2x
  (Default) = "PNG at 2×"
  Icon = ...

HKCR\SystemFileAssociations\.svg\shell\SvgConverter\shell\png_2x\command
  (Default) = "\"C:\Program Files\SvgConverter\svg-converter.exe\" convert \"%1\" -f png -s 2.0"
```

Use `MUIVerb` + `CommandFlags` for advanced placement on Win7+ if needed.

### 8.2 Windows 10 vs Windows 11 behavior

| Aspect | Windows 10 | Windows 11 |
|--------|------------|------------|
| Legacy `IContextMenu` / static verbs | Full classic menu | Often under **Show more options** |
| Primary compact menu | N/A | Requires `IExplorerCommand` + package identity |
| Registry-only cascade | Visible in classic menu | May need extra click |
| Performance | Fast for static verbs | Static verbs still fast; COM extensions can slow menu |

**User impact:** v1 is acceptable for power users. Document that Win11 users may need **Show more options** unless Phase 3 is implemented.

### 8.3 Phase 3 upgrade path: Win11 primary menu

For top-level Win11 menu visibility:

1. Implement **`IExplorerCommand`** in a small `svg-converter-shell.dll` (Rust via `windows` crate or C++).
2. Register via **Sparse Package** (`AppxManifest.xml` + `desktop4:FileExplorerContextMenus`).
3. Ship `register-sparse-package.exe` that calls `PackageManager.AddPackageAsync` with external location.
4. Reference: [Microsoft — Integrate packaged app with File Explorer](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/integrate-packaged-app-with-file-explorer)

**Defer until** v1 registry approach is validated.

### 8.4 Installation location

| Path | Purpose |
|------|---------|
| `C:\Program Files\SvgConverter\` | Binary + icon (requires admin install) |
| `%LOCALAPPDATA%\Programs\SvgConverter\` | Per-user install (no admin) |

Installer script should detect elevation and choose accordingly.

### 8.5 Security considerations

- Quote all paths in registry commands (`"%1"`).
- Validate extension is `.svg` before processing.
- Reject path traversal in `--output`.
- Do not execute scripts embedded in SVG (usvg strips non-static features).
- Sign release binaries when distributing publicly (optional v1).

---

## 9. Roadmap

### Phase 0 — Planning (current)
- [x] Research renderers and Windows integration
- [x] Write this plan
- [ ] Review plan with stakeholder

### Phase 1 — Core CLI (MVP)
**Milestone:** `svg-converter convert icon.svg -f png -s 2.0` produces `icon@2x.png`

- [ ] Cargo project scaffold
- [ ] Integrate usvg + resvg + tiny-skia
- [ ] Implement scale logic from intrinsic SVG size
- [ ] PNG + JPEG encoding via `image`
- [ ] WebP lossless encoding
- [ ] Output naming + collision policy
- [ ] Unit tests with fixture SVGs
- [ ] `cargo build --release` produces portable exe

**Acceptance:** Convert 10 diverse SVGs (icon, gradient, text, filter) without panic.

### Phase 2 — Windows context menu
**Milestone:** Right-click `.svg` → convert without opening terminal

- [ ] `install-context-menu.ps1` / `uninstall-context-menu.ps1`
- [ ] Cascading submenu (format → scale)
- [ ] One-click default PNG 1×
- [ ] Error `MessageBox` or toast on failure
- [ ] `install.ps1` copies binary to Program Files or LocalAppData
- [ ] Manual QA on Win10 + Win11

**Acceptance:** All 12 format×scale actions work; uninstall removes all keys.

### Phase 3 — Polish & distribution
**Milestone:** Releasable v1.0

- [ ] README with screenshots
- [ ] Optional lossy WebP feature flag
- [ ] `--perf` timing flag (dev)
- [ ] CI: `cargo test`, `cargo clippy`, `cargo fmt`
- [ ] GitHub release with zip + install script
- [ ] Optional NSIS/Inno Setup installer

### Phase 4 — Enhancements (post-v1)
- [x] Win11 `IExplorerCommand` + sparse package — implemented as the `svg-converter-shell` cdylib (windows-rs), a sparse MSIX manifest in `packaging/`, and `*-sparse-package.ps1` scripts. The handler converts **in-process** by statically linking the shared `svg_converter` core and calling `convert_menu_batch(...)`; it launches no executable. (An earlier design shelled out to `svg-converterw.exe`, but launching a packaged exe under `C:\Program Files\WindowsApps\…` by path is denied by ACLs — `CreateProcessW` → `ERROR_ACCESS_DENIED` — so the menu silently did nothing. In-process conversion removes that failure entirely and is also faster.) The legacy registry menu still shells out to the no-console `svg-converterw.exe`. See README "Windows 11 primary menu (Phase 4)".
- [ ] Batch folder context ("Convert all SVGs in folder")
- [ ] Config file (`%APPDATA%\SvgConverter\config.toml`)
- [ ] Explorer thumbnail provider (resvg ships `resvg-explorer-extension.exe` as reference)
- [ ] Watch folder / drag-drop mini GUI

---

## 10. Development Best Practices

### Code quality
- `cargo fmt` and `cargo clippy -- -D warnings` in CI
- Exhaustive `match` on `Format` and `Scale` enums with `never` arm
- No `unwrap()` in library path; CLI may map errors to exit codes
- Keep rendering and encoding in testable pure functions

### Performance
- Reuse `usvg::Options` and font database across batch (future)
- Release profile: `lto = true`, `codegen-units = 1`, `opt-level = 3`
- Optional: `RUSTFLAGS="-C target-cpu=haswell"` for release builds on x64
- Log parse vs render vs encode timings with `--perf`

### Windows-specific
- Test paths with spaces and unicode filenames
- Use `std::fs::canonicalize` carefully on Windows
- Hide console window for context menu invocations (`windows_subsystem = "windows"` optional; keep console for debugging via `svg-converter.exe` without subsystem)

### Versioning
- SemVer for releases
- Pin crate versions in `Cargo.lock`
- Changelog in `CHANGELOG.md`

---

## 11. Dependencies (Cargo)

```toml
[dependencies]
resvg = "0.47"
usvg = "0.47"
tiny-skia = "0.12"
image = { version = "0.25", default-features = false, features = ["png", "jpeg", "webp"] }
clap = { version = "4", features = ["derive"] }
anyhow = "1"
thiserror = "1"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }

# Optional Phase 3+
# webp = "0.3"           # lossy WebP via libwebp
# zenwebp = "0.x"        # pure Rust lossy WebP

[target.'cfg(windows)'.dependencies]
# windows = { version = "0.58", features = ["Win32_UI_WindowsAndMessaging"] }
```

**Estimated release binary size:** 3–6 MB (similar to upstream resvg CLI).

---

## 12. Build & Distribution Plan (Windows)

### Developer build

```powershell
# From the repository root:
cargo build --release
# Output: target\release\svg-converter.exe
```

### Prerequisites
- [Rust toolchain](https://rustup.rs/) (1.87+ for resvg 0.47)
- Visual Studio Build Tools (MSVC linker)
- No libclang required unless optimizing tiny-skia with clang

### Distribution artifact

```text
SvgConverter-1.0.0-win64.zip
├── svg-converter.exe
├── assets/icon.ico
├── scripts/install.ps1
├── scripts/uninstall.ps1
├── scripts/install-context-menu.ps1
├── scripts/uninstall-context-menu.ps1
├── LICENSE
└── README.md
```

### Install flow (user)

1. Extract zip
2. Run `install.ps1` (elevated optional)
3. Right-click any `.svg` → **Convert SVG**

### Uninstall flow

1. Run `uninstall-context-menu.ps1`
2. Delete install directory

---

## 13. Testing Strategy

### Unit tests
- Output path generation for all scales/formats
- Scale math: `size * scale` rounding, min 1px
- JPEG alpha flattening with background color

### Integration tests
- Render fixtures: `fixtures/plain.svg`, `gradient.svg`, `text.svg`, `filter.svg`
- Golden file comparison (PNG byte hash) for deterministic renders
- Round-trip: file exists, non-zero size, valid image headers

### Manual QA checklist
- [ ] Single `.svg` right-click each menu item
- [ ] Multi-select 3 SVGs
- [ ] Path with spaces and `&` characters
- [ ] Large SVG (4K artboard)
- [ ] Tiny icon (16×16)
- [ ] Win10 classic menu
- [ ] Win11 menu + Show more options
- [ ] Install → uninstall leaves clean registry

### CI (GitHub Actions)

```yaml
# .github/workflows/ci.yml
- cargo fmt --check
- cargo clippy -- -D warnings
- cargo test
- cargo build --release
```

---

## 14. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Win11 menu buried under "Show more options" | High | Medium | Document; Phase 3 sparse package |
| Complex SVGs render incorrectly | Medium | Medium | usvg warnings; golden tests; link resvg unsupported docs |
| WebP lossless files too large | Medium | Low | Phase 3 lossy option |
| Font-dependent SVGs look wrong | Medium | Medium | Bundle no fonts; use system fonts via usvg/fontdb |
| Registry install needs admin | Medium | Low | Support per-user LocalAppData install |
| resvg MSRV bumps | Low | Low | Pin versions; CI on latest stable |

---

## 15. Future Enhancements

- **Preset profiles:** "App Store", "Web", "Print"
- **Clipboard output:** Copy PNG to clipboard instead of file
- **SVG optimization:** Optional usvg write-back (simplified SVG)
- **ARM64 Windows build**
- **Winget package:** `winget install SvgConverter`
- **Tauri tray app:** Optional GUI reusing same core crate (aligns with ClickUpTasker experience)

---

## 16. References

- [resvg GitHub](https://github.com/linebender/resvg) — renderer, CLI, Windows releases
- [tiny-skia](https://github.com/linebender/tiny-skia) — CPU backend
- [image crate WebP encoder docs](https://docs.rs/image/latest/image/codecs/webp/struct.WebPEncoder.html)
- [Microsoft — Creating Shortcut Menu Handlers](https://learn.microsoft.com/en-us/windows/win32/shell/context-menu-handlers)
- [Microsoft — Integrate packaged app with File Explorer](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/integrate-packaged-app-with-file-explorer)
- [ShellEx — Win10 to Win11 migration guide](https://shellex.info/dev/migrate-shell-extension-from-windows-10-to-windows-11/)

---

## 17. Implementation Readiness Checklist

Before starting Phase 1 in a follow-up session:

- [ ] Confirm project name (`svg-converter` vs `svg-raster`)
- [ ] Confirm install path preference (Program Files vs LocalAppData)
- [ ] Confirm WebP v1 = lossless only OK?
- [ ] Confirm output naming (`@2x` suffix convention)
- [ ] Initialize git repo in `svg-converter/`
- [ ] `cargo init` and add dependencies from §11

**Estimated effort:**
- Phase 1: 1–2 sessions
- Phase 2: 1 session
- Phase 3: 1 session
