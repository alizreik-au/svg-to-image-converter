//! Windows 11 primary-menu integration for SVG Converter.
//!
//! Each context-menu action is a **manifest-registered** `IExplorerCommand` with
//! its own CLSID (see [`commands::COMMAND_DEFS`]). Win11 reliably calls
//! `Invoke` only for verbs declared in the Appx manifest — flyout subcommands
//! created via `EnumSubCommands` are displayed but `Invoke` is often never
//! called, which looks like "nothing happens" with zero `[dll]` diagnostics.

#![cfg(windows)]

mod commands;

use std::ffi::c_void;
use std::iter::once;
use std::path::{Path, PathBuf};
use std::ptr::null_mut;

use commands::{find_command, CommandDef};
use svg_converter::{convert_menu_batch, diag, RunOutcome};

use windows::core::{implement, Error, Interface, Ref, Result, BOOL, GUID, HRESULT, PCWSTR, PWSTR};
use windows::Win32::Foundation::{
    CLASS_E_CLASSNOTAVAILABLE, CLASS_E_NOAGGREGATION, E_FAIL, E_NOTIMPL, E_POINTER, HINSTANCE,
    HMODULE, S_FALSE, TRUE,
};
use windows::Win32::System::Com::{CoTaskMemFree, IBindCtx, IClassFactory, IClassFactory_Impl};
use windows::Win32::System::LibraryLoader::{
    GetModuleFileNameW, GetModuleHandleExW, GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
    GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
};
use windows::Win32::System::SystemServices::DLL_PROCESS_ATTACH;
use windows::Win32::UI::Shell::{
    IExplorerCommand, IExplorerCommand_Impl, IShellItemArray, SHStrDupW, SIGDN_FILESYSPATH,
};
use windows::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONERROR, MB_OK, MB_SETFOREGROUND};

/// `ECF_DEFAULT`: a plain, invokable command (no flyout).
const ECF_DEFAULT: u32 = 0x0000_0000;
/// `ECS_ENABLED` from `EXPCMDSTATE`: the command is shown and clickable.
const ECS_ENABLED: u32 = 0x0000_0000;

/// One manifest-registered leaf command that converts in-process on `Invoke`.
#[implement(IExplorerCommand)]
struct ExplorerCommand {
    def: CommandDef,
    icon: Vec<u16>,
}

#[allow(non_snake_case)]
impl IExplorerCommand_Impl for ExplorerCommand_Impl {
    fn GetTitle(&self, _items: Ref<'_, IShellItemArray>) -> Result<PWSTR> {
        diag::log("dll", &format!("GetTitle: {}", self.def.title));
        unsafe { SHStrDupW(PCWSTR(wide(self.def.title).as_ptr())) }
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
        // Unique per verb — required for Explorer to route Invoke correctly.
        Ok(self.def.clsid)
    }

    fn GetState(
        &self,
        _items: Ref<'_, IShellItemArray>,
        _slow: windows::core::BOOL,
    ) -> Result<u32> {
        diag::log("dll", &format!("GetState: {}", self.def.verb_id));
        Ok(ECS_ENABLED)
    }

    fn GetFlags(&self) -> Result<u32> {
        Ok(ECF_DEFAULT)
    }

    fn EnumSubCommands(&self) -> Result<windows::Win32::UI::Shell::IEnumExplorerCommand> {
        Err(Error::from(E_NOTIMPL))
    }

    fn Invoke(
        &self,
        psiitemarray: Ref<'_, IShellItemArray>,
        _pbc: Ref<'_, IBindCtx>,
    ) -> Result<()> {
        diag::log(
            "dll",
            &format!(
                "Invoke start: verb={} format={:?} scale={:?}",
                self.def.verb_id, self.def.format, self.def.scale
            ),
        );

        let array = psiitemarray.ok()?;
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
            &format!("Invoke converting {} file(s): {:?}", inputs.len(), inputs),
        );

        let outcome = convert_menu_batch(&inputs, self.def.format, self.def.scale);
        log_outcome(&outcome);

        if !outcome.errors.is_empty() {
            report_outcome(&outcome);
        }

        diag::log(
            "dll",
            &format!("Invoke done: exit_code={}", outcome.exit_code),
        );
        Ok(())
    }
}

/// COM class factory for one manifest-registered CLSID.
#[implement(IClassFactory)]
struct ClassFactory {
    clsid: GUID,
}

#[allow(non_snake_case)]
impl IClassFactory_Impl for ClassFactory_Impl {
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

        let def = find_command(self.clsid).ok_or_else(|| Error::from(E_FAIL))?;
        diag::log(
            "dll",
            &format!(
                "CreateInstance: verb={} clsid={:?}",
                def.verb_id, self.clsid
            ),
        );

        let command: IExplorerCommand = ExplorerCommand {
            def: *def,
            icon: icon_reference(),
        }
        .into();
        unsafe { command.query(riid, ppvobject).ok() }
    }

    fn LockServer(&self, _flock: windows::core::BOOL) -> Result<()> {
        Ok(())
    }
}

/// COM entry point: hand Explorer a class factory for a manifest-registered CLSID.
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

    let clsid = unsafe { *rclsid };
    let known = find_command(clsid).is_some();
    diag::log(
        "dll",
        &format!("DllGetClassObject: clsid={:?} known={known}", clsid),
    );

    if !known {
        return CLASS_E_CLASSNOTAVAILABLE;
    }

    let factory: IClassFactory = ClassFactory { clsid }.into();
    unsafe { factory.query(riid, ppv) }
}

/// The DLL lives in a packaged surrogate host; keep it resident for the host's
/// lifetime rather than trying to unload it mid-session.
#[no_mangle]
extern "system" fn DllCanUnloadNow() -> HRESULT {
    S_FALSE
}

/// Best-effort log when the surrogate loads our DLL (gated by diagnostics).
#[no_mangle]
#[allow(non_snake_case)]
extern "system" fn DllMain(_module: HINSTANCE, reason: u32, _reserved: *mut c_void) -> BOOL {
    if reason == DLL_PROCESS_ATTACH {
        diag::log("dll", "DllMain: PROCESS_ATTACH (handler DLL loaded)");
    }
    TRUE
}

/// Record a menu conversion's result to the shared diagnostics log.
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

/// Show a modal error dialog summarizing every failed conversion.
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

/// Encode a Rust string as a null-terminated UTF-16 buffer.
fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(once(0)).collect()
}

/// Show a modal error dialog.
fn report_failure(message: &str) {
    let text = wide(message);
    let caption = wide("SVG Converter");
    unsafe {
        MessageBoxW(
            None,
            PCWSTR(text.as_ptr()),
            PCWSTR(caption.as_ptr()),
            MB_OK | MB_ICONERROR | MB_SETFOREGROUND,
        );
    }
}

/// Icon reference for menu glyphs (`"<dir>\\svg-converter.exe,0"`).
fn icon_reference() -> Vec<u16> {
    match dll_dir() {
        Some(dir) => {
            let exe = dir.join("svg-converter.exe");
            wide(&format!("{},0", exe.display()))
        }
        None => vec![0],
    }
}

/// Directory containing this DLL (icon lookup only).
fn dll_dir() -> Option<PathBuf> {
    let mut module = HMODULE::default();
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
    use commands::{CLSID_CONVERT_SVG, COMMAND_DEFS};

    #[test]
    fn links_conversion_core() {
        assert_eq!(COMMAND_DEFS[0].format.extension(), "png");
        assert_eq!(COMMAND_DEFS[0].scale.factor(), 1.0);
        assert_eq!(wide("a"), vec![0x61_u16, 0]);
    }

    #[test]
    fn manifest_command_count() {
        assert_eq!(COMMAND_DEFS.len(), 13);
    }

    #[test]
    fn legacy_clsid_is_quick_png() {
        assert_eq!(CLSID_CONVERT_SVG, COMMAND_DEFS[0].clsid);
        assert_eq!(COMMAND_DEFS[0].verb_id, "QuickPng1x");
    }
}
