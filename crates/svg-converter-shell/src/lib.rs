//! Windows 11 primary-menu integration for SVG Converter.
//!
//! This crate builds an in-process COM server (`svg_converter_shell.dll`) that
//! implements [`IExplorerCommand`]. Registered through a sparse or full MSIX
//! package (see `packaging/`), it adds a **Convert SVG** flyout to the Windows
//! 11 compact context menu (and the Windows 10 classic menu) for `.svg` files.
//!
//! Architecture:
//! - The top-level command reports `ECF_HASSUBCOMMANDS` and exposes the
//!   format × scale matrix (plus a Quick PNG 1× default) via
//!   [`IExplorerCommand::EnumSubCommands`].
//! - Each leaf command performs the conversion **in-process** by calling
//!   [`svg_converter::convert_menu_batch`] — the exact same core the CLI uses.
//!
//! ## Why in-process (and not a child exe)
//!
//! Earlier revisions shelled out to `svg-converterw.exe` via `CreateProcessW`.
//! When installed as an MSIX, the binaries live under
//! `C:\Program Files\WindowsApps\…`, whose ACLs deny launching the packaged exe
//! by path from the surrogate — `CreateProcessW` fails with
//! `ERROR_ACCESS_DENIED (5)`, so the menu silently did nothing. Linking the
//! conversion core statically into this DLL and converting in-process removes
//! the subprocess entirely: it is faster, avoids the WindowsApps-exec problem,
//! and needs no runtime executable lookup.

#![cfg(windows)]

use std::ffi::c_void;
use std::iter::once;
use std::path::{Path, PathBuf};
use std::ptr::null_mut;
use std::sync::atomic::{AtomicUsize, Ordering};

use svg_converter::cli::{Format, Scale};
use svg_converter::{convert_menu_batch, diag, RunOutcome};

use windows::core::{implement, Error, Interface, Ref, Result, GUID, HRESULT, PCWSTR, PWSTR};
use windows::Win32::Foundation::{
    CLASS_E_CLASSNOTAVAILABLE, CLASS_E_NOAGGREGATION, E_FAIL, E_NOTIMPL, E_POINTER, HMODULE,
    S_FALSE, S_OK,
};
use windows::Win32::System::Com::{CoTaskMemFree, IBindCtx, IClassFactory, IClassFactory_Impl};
use windows::Win32::System::LibraryLoader::{
    GetModuleFileNameW, GetModuleHandleExW, GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
    GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
};
use windows::Win32::UI::Shell::{
    IEnumExplorerCommand, IEnumExplorerCommand_Impl, IExplorerCommand, IExplorerCommand_Impl,
    IShellItemArray, SHStrDupW, SIGDN_FILESYSPATH,
};
use windows::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONERROR, MB_OK, MB_SETFOREGROUND};

/// CLSID of the Convert SVG explorer command. Must match the `Clsid`/`Id`
/// attributes in the MSIX manifests under `packaging/`.
const CLSID_CONVERT_SVG: GUID = GUID::from_u128(0xb6e3a1c2_9f47_4d5e_8a1b_2c3d4e5f6a70);

/// `ECF_HASSUBCOMMANDS` from `EXPCMDFLAGS`: this command owns a subcommand flyout.
const ECF_HASSUBCOMMANDS: u32 = 0x0000_0010;
/// `ECF_DEFAULT`: a plain, invokable command.
const ECF_DEFAULT: u32 = 0x0000_0000;
/// `ECS_ENABLED` from `EXPCMDSTATE`: the command is shown and clickable.
const ECS_ENABLED: u32 = 0x0000_0000;

/// A concrete conversion (format + scale) run in-process by the core library.
#[derive(Clone, Copy)]
struct Action {
    format: Format,
    scale: Scale,
}

/// One entry in the Explorer context menu: either the top-level flyout
/// (`action == None`, `has_subcommands == true`) or a leaf command.
#[implement(IExplorerCommand)]
struct ExplorerCommand {
    /// Null-terminated UTF-16 menu label.
    title: Vec<u16>,
    /// Null-terminated UTF-16 icon reference (`"<path>,0"`); length ≤ 1 means none.
    icon: Vec<u16>,
    has_subcommands: bool,
    action: Option<Action>,
}

#[allow(non_snake_case)]
impl IExplorerCommand_Impl for ExplorerCommand_Impl {
    fn GetTitle(&self, _items: Ref<'_, IShellItemArray>) -> Result<PWSTR> {
        unsafe { SHStrDupW(PCWSTR(self.title.as_ptr())) }
    }

    fn GetIcon(&self, _items: Ref<'_, IShellItemArray>) -> Result<PWSTR> {
        if self.icon.len() <= 1 {
            return Err(Error::from(E_NOTIMPL));
        }
        unsafe { SHStrDupW(PCWSTR(self.icon.as_ptr())) }
    }

    fn GetToolTip(&self, _items: Ref<'_, IShellItemArray>) -> Result<PWSTR> {
        Err(Error::from(E_NOTIMPL))
    }

    fn GetCanonicalName(&self) -> Result<GUID> {
        Ok(GUID::zeroed())
    }

    fn GetState(
        &self,
        _items: Ref<'_, IShellItemArray>,
        _slow: windows::core::BOOL,
    ) -> Result<u32> {
        Ok(ECS_ENABLED)
    }

    fn GetFlags(&self) -> Result<u32> {
        Ok(if self.has_subcommands {
            ECF_HASSUBCOMMANDS
        } else {
            ECF_DEFAULT
        })
    }

    fn EnumSubCommands(&self) -> Result<IEnumExplorerCommand> {
        if !self.has_subcommands {
            return Err(Error::from(E_NOTIMPL));
        }
        let items = build_subcommands(&self.icon);
        Ok(CommandEnum::new(items).into())
    }

    fn Invoke(
        &self,
        psiitemarray: Ref<'_, IShellItemArray>,
        _pbc: Ref<'_, IBindCtx>,
    ) -> Result<()> {
        let action = match &self.action {
            Some(action) => *action,
            // Top-level flyout: Explorer opens the submenu instead of invoking.
            None => return Ok(()),
        };

        let array = psiitemarray.ok()?;

        // Collect the selected filesystem paths (Explorer invokes once per verb
        // even for multi-selection, but a selection can contain several items).
        let count = unsafe { array.GetCount()? };
        let mut inputs: Vec<PathBuf> = Vec::with_capacity(count as usize);
        for i in 0..count {
            let item = unsafe { array.GetItemAt(i)? };
            let raw = unsafe { item.GetDisplayName(SIGDN_FILESYSPATH)? };
            let path = unsafe { raw.to_string() };
            unsafe { CoTaskMemFree(Some(raw.0 as *const c_void)) };
            let path = path.map_err(|_| Error::from(E_FAIL))?;
            inputs.push(PathBuf::from(path));
        }

        diag::log(
            "dll",
            &format!(
                "Invoke in-process: format={:?} scale={:?} on {} file(s): {:?}",
                action.format,
                action.scale,
                inputs.len(),
                inputs
            ),
        );

        // Convert in-process using the shared core (no child process).
        let outcome = convert_menu_batch(&inputs, action.format, action.scale);
        log_outcome(&outcome);

        if !outcome.errors.is_empty() {
            report_outcome(&outcome);
        }

        Ok(())
    }
}

/// Record a menu conversion's result to the shared diagnostics log (no-op
/// unless logging is enabled). Mirrors the exe-side logging so a single toggle
/// captures both menu mechanisms.
fn log_outcome(outcome: &RunOutcome) {
    if !diag::is_enabled() {
        return;
    }
    for line in &outcome.successes {
        diag::log("dll", &format!("ok: {line}"));
    }
    for line in &outcome.errors {
        diag::log("dll", &format!("err: {line}"));
    }
    diag::log("dll", &format!("exit_code={}", outcome.exit_code));
}

/// Show a modal error dialog summarizing every failed conversion, so failures
/// are visible instead of vanishing when Explorer discards our `HRESULT`.
fn report_outcome(outcome: &RunOutcome) {
    let mut body = String::from("SVG Converter could not convert the following:\r\n\r\n");
    body.push_str(&outcome.errors.join("\r\n"));
    if !outcome.successes.is_empty() {
        body.push_str(&format!(
            "\r\n\r\n{} file(s) converted successfully.",
            outcome.successes.len()
        ));
    }
    report_failure(&body);
}

/// Enumerator handed to Explorer to walk the subcommand flyout.
#[implement(IEnumExplorerCommand)]
struct CommandEnum {
    items: Vec<IExplorerCommand>,
    index: AtomicUsize,
}

impl CommandEnum {
    fn new(items: Vec<IExplorerCommand>) -> Self {
        Self {
            items,
            index: AtomicUsize::new(0),
        }
    }
}

#[allow(non_snake_case)]
impl IEnumExplorerCommand_Impl for CommandEnum_Impl {
    fn Next(
        &self,
        celt: u32,
        puicommand: *mut Option<IExplorerCommand>,
        pceltfetched: *mut u32,
    ) -> HRESULT {
        if puicommand.is_null() {
            return E_POINTER;
        }
        let mut fetched = 0usize;
        let mut idx = self.index.load(Ordering::SeqCst);
        while fetched < celt as usize && idx < self.items.len() {
            unsafe { *puicommand.add(fetched) = Some(self.items[idx].clone()) };
            fetched += 1;
            idx += 1;
        }
        self.index.store(idx, Ordering::SeqCst);
        if !pceltfetched.is_null() {
            unsafe { *pceltfetched = fetched as u32 };
        }
        if fetched == celt as usize {
            S_OK
        } else {
            S_FALSE
        }
    }

    fn Skip(&self, celt: u32) -> Result<()> {
        self.index.fetch_add(celt as usize, Ordering::SeqCst);
        Ok(())
    }

    fn Reset(&self) -> Result<()> {
        self.index.store(0, Ordering::SeqCst);
        Ok(())
    }

    fn Clone(&self) -> Result<IEnumExplorerCommand> {
        let clone = CommandEnum {
            items: self.items.clone(),
            index: AtomicUsize::new(self.index.load(Ordering::SeqCst)),
        };
        Ok(clone.into())
    }
}

/// COM class factory that produces the top-level Convert SVG command.
#[implement(IClassFactory)]
struct Factory;

#[allow(non_snake_case)]
impl IClassFactory_Impl for Factory_Impl {
    fn CreateInstance(
        &self,
        punkouter: Ref<'_, windows::core::IUnknown>,
        riid: *const GUID,
        ppvobject: *mut *mut c_void,
    ) -> Result<()> {
        if ppvobject.is_null() {
            return Err(Error::from(E_POINTER));
        }
        unsafe { *ppvobject = null_mut() };
        if !punkouter.is_null() {
            return Err(Error::from(CLASS_E_NOAGGREGATION));
        }
        let command: IExplorerCommand = root_command();
        unsafe { command.query(riid, ppvobject).ok() }
    }

    fn LockServer(&self, _flock: windows::core::BOOL) -> Result<()> {
        Ok(())
    }
}

/// COM entry point: hand Explorer a class factory for our CLSID.
///
/// # Safety
/// Called by the COM runtime with valid out-pointers.
#[no_mangle]
extern "system" fn DllGetClassObject(
    rclsid: *const GUID,
    riid: *const GUID,
    ppv: *mut *mut c_void,
) -> HRESULT {
    if ppv.is_null() {
        return E_POINTER;
    }
    unsafe { *ppv = null_mut() };
    if rclsid.is_null() || riid.is_null() {
        return E_POINTER;
    }
    if unsafe { *rclsid } != CLSID_CONVERT_SVG {
        return CLASS_E_CLASSNOTAVAILABLE;
    }
    let factory: IClassFactory = Factory.into();
    unsafe { factory.query(riid, ppv) }
}

/// The DLL lives in a packaged surrogate host; keep it resident for the host's
/// lifetime rather than trying to unload it mid-session.
#[no_mangle]
extern "system" fn DllCanUnloadNow() -> HRESULT {
    S_FALSE
}

/// Build the top-level "Convert SVG" flyout command.
fn root_command() -> IExplorerCommand {
    ExplorerCommand {
        title: wide("Convert SVG"),
        icon: icon_reference(),
        has_subcommands: true,
        action: None,
    }
    .into()
}

/// Build the flat subcommand list: Quick PNG 1×, then the format × scale matrix.
fn build_subcommands(icon: &[u16]) -> Vec<IExplorerCommand> {
    let formats: [(&str, Format); 3] = [
        ("PNG", Format::Png),
        ("JPEG", Format::Jpeg),
        ("WebP", Format::Webp),
    ];
    let scales: [(&str, Scale); 4] = [
        ("3.0\u{00d7}", Scale::Three),
        ("2.0\u{00d7}", Scale::Two),
        ("1.0\u{00d7}", Scale::One),
        ("0.5\u{00d7}", Scale::Half),
    ];

    let mut commands = Vec::with_capacity(1 + formats.len() * scales.len());
    commands.push(leaf(
        "Quick: PNG (1\u{00d7})",
        Format::Png,
        Scale::One,
        icon,
    ));
    for (flabel, format) in formats {
        for (slabel, scale) in scales {
            let title = format!("{flabel} \u{2014} {slabel}");
            commands.push(leaf(&title, format, scale, icon));
        }
    }
    commands
}

/// Construct a single leaf command that converts in-process at `format`/`scale`.
fn leaf(title: &str, format: Format, scale: Scale, icon: &[u16]) -> IExplorerCommand {
    ExplorerCommand {
        title: wide(title),
        icon: icon.to_vec(),
        has_subcommands: false,
        action: Some(Action { format, scale }),
    }
    .into()
}

/// Encode a Rust string as a null-terminated UTF-16 buffer.
fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(once(0)).collect()
}

/// Show a modal error dialog so context-menu failures are visible to the user.
fn report_failure(message: &str) {
    let text = wide(message);
    let caption = wide("SVG Converter");
    // SAFETY: both buffers are valid, null-terminated, and outlive the call.
    unsafe {
        MessageBoxW(
            None,
            PCWSTR(text.as_ptr()),
            PCWSTR(caption.as_ptr()),
            MB_OK | MB_ICONERROR | MB_SETFOREGROUND,
        );
    }
}

/// Icon reference (`"<install-dir>\svg-converter.exe,0"`) or a single NUL if the
/// install directory cannot be resolved. Used only for the menu glyph; no
/// executable is ever launched.
fn icon_reference() -> Vec<u16> {
    match dll_dir() {
        Some(dir) => {
            let exe = dir.join("svg-converter.exe");
            wide(&format!("{},0", exe.display()))
        }
        None => vec![0],
    }
}

/// Directory containing this DLL (used only to locate the icon resource).
fn dll_dir() -> Option<PathBuf> {
    let mut module = HMODULE::default();
    // Resolve our own module from the address of this function.
    let addr = dll_dir as *const c_void;
    unsafe {
        GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            PCWSTR(addr as *const u16),
            &mut module,
        )
        .ok()?;
    }

    let mut buffer = [0u16; 32768];
    let len = unsafe { GetModuleFileNameW(Some(module), &mut buffer) } as usize;
    if len == 0 || len >= buffer.len() {
        return None;
    }
    let path = String::from_utf16_lossy(&buffer[..len]);
    Path::new(&path).parent().map(Path::to_path_buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Compiling and running this proves the cdylib is statically linked against
    /// the `svg_converter` conversion core: the enum API below resolves through
    /// the path dependency, so no runtime executable is needed.
    #[test]
    fn links_conversion_core() {
        assert_eq!(Format::Png.extension(), "png");
        assert_eq!(Format::Jpeg.extension(), "jpg");
        assert_eq!(Scale::Two.factor(), 2.0);
        assert_eq!(wide("a"), vec![0x61_u16, 0]);
    }

    /// The flyout exposes Quick PNG 1× plus the full 3 formats × 4 scales matrix.
    #[test]
    fn subcommand_matrix_has_expected_count() {
        let icon = wide("");
        assert_eq!(build_subcommands(&icon).len(), 1 + 3 * 4);
    }
}
