//! Context-menu command table: one CLSID per leaf action.
//!
//! Windows 11 reliably invokes `IExplorerCommand::Invoke` only for verbs
//! registered directly in the Appx manifest. Subcommands created via
//! `EnumSubCommands` (flyout) are shown in the menu but `Invoke` is often
//! never called on Win11 builds — the handler appears wired yet nothing happens
//! and diagnostics show zero `[dll]` lines.
//!
//! Each entry here maps 1:1 to a `<com:Class>` and `<desktop5:Verb>` in the
//! MSIX manifests under `packaging/`. CLSIDs are sequential in the
//! `…6A70`–`…6A7C` range; keep manifest and this table in sync.

use svg_converter::cli::{Format, Scale};

use windows::core::GUID;

/// One manifest-registered context-menu action.
#[derive(Clone, Copy)]
pub struct CommandDef {
    /// COM class id — must match `com:Class/@Id` and `desktop5:Verb/@Clsid`.
    pub clsid: GUID,
    /// Manifest `desktop5:Verb/@Id` (diagnostics only).
    pub verb_id: &'static str,
    /// Menu label returned from `GetTitle`.
    pub title: &'static str,
    pub format: Format,
    pub scale: Scale,
}

/// Base CLSID (`…6A70`). Each command adds its index to the low byte.
const CLSID_BASE: u128 = 0xb6e3a1c2_9f47_4d5e_8a1b_2c3d4e5f6a70;

/// Build the CLSID for table index `i` (`0..COMMAND_DEFS.len()`).
pub const fn clsid_at(index: usize) -> GUID {
    GUID::from_u128(CLSID_BASE + index as u128)
}

/// Legacy export: the first command's CLSID (Quick PNG 1×). Must match the
/// primary verb in the MSIX manifests.
#[allow(dead_code)] // public contract with packaging/ manifests; used in tests
pub const CLSID_CONVERT_SVG: GUID = clsid_at(0);

/// All manifest-registered verbs, in manifest declaration order.
pub const COMMAND_DEFS: [CommandDef; 13] = [
    CommandDef {
        clsid: clsid_at(0),
        verb_id: "QuickPng1x",
        title: "Quick: PNG (1\u{00d7})",
        format: Format::Png,
        scale: Scale::One,
    },
    CommandDef {
        clsid: clsid_at(1),
        verb_id: "Png3x",
        title: "PNG \u{2014} 3.0\u{00d7}",
        format: Format::Png,
        scale: Scale::Three,
    },
    CommandDef {
        clsid: clsid_at(2),
        verb_id: "Png2x",
        title: "PNG \u{2014} 2.0\u{00d7}",
        format: Format::Png,
        scale: Scale::Two,
    },
    CommandDef {
        clsid: clsid_at(3),
        verb_id: "Png1x",
        title: "PNG \u{2014} 1.0\u{00d7}",
        format: Format::Png,
        scale: Scale::One,
    },
    CommandDef {
        clsid: clsid_at(4),
        verb_id: "Png05x",
        title: "PNG \u{2014} 0.5\u{00d7}",
        format: Format::Png,
        scale: Scale::Half,
    },
    CommandDef {
        clsid: clsid_at(5),
        verb_id: "Jpeg3x",
        title: "JPEG \u{2014} 3.0\u{00d7}",
        format: Format::Jpeg,
        scale: Scale::Three,
    },
    CommandDef {
        clsid: clsid_at(6),
        verb_id: "Jpeg2x",
        title: "JPEG \u{2014} 2.0\u{00d7}",
        format: Format::Jpeg,
        scale: Scale::Two,
    },
    CommandDef {
        clsid: clsid_at(7),
        verb_id: "Jpeg1x",
        title: "JPEG \u{2014} 1.0\u{00d7}",
        format: Format::Jpeg,
        scale: Scale::One,
    },
    CommandDef {
        clsid: clsid_at(8),
        verb_id: "Jpeg05x",
        title: "JPEG \u{2014} 0.5\u{00d7}",
        format: Format::Jpeg,
        scale: Scale::Half,
    },
    CommandDef {
        clsid: clsid_at(9),
        verb_id: "Webp3x",
        title: "WebP \u{2014} 3.0\u{00d7}",
        format: Format::Webp,
        scale: Scale::Three,
    },
    CommandDef {
        clsid: clsid_at(10),
        verb_id: "Webp2x",
        title: "WebP \u{2014} 2.0\u{00d7}",
        format: Format::Webp,
        scale: Scale::Two,
    },
    CommandDef {
        clsid: clsid_at(11),
        verb_id: "Webp1x",
        title: "WebP \u{2014} 1.0\u{00d7}",
        format: Format::Webp,
        scale: Scale::One,
    },
    CommandDef {
        clsid: clsid_at(12),
        verb_id: "Webp05x",
        title: "WebP \u{2014} 0.5\u{00d7}",
        format: Format::Webp,
        scale: Scale::Half,
    },
];

/// Look up a command definition by CLSID.
pub fn find_command(clsid: GUID) -> Option<&'static CommandDef> {
    COMMAND_DEFS.iter().find(|def| def.clsid == clsid)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_command_has_unique_clsid() {
        for (i, def) in COMMAND_DEFS.iter().enumerate() {
            assert_eq!(def.clsid, clsid_at(i));
        }
        for (i, a) in COMMAND_DEFS.iter().enumerate() {
            for (j, b) in COMMAND_DEFS.iter().enumerate() {
                if i != j {
                    assert_ne!(a.clsid, b.clsid, "duplicate CLSID at {i} and {j}");
                }
            }
        }
    }

    #[test]
    fn legacy_clsid_matches_first_command() {
        assert_eq!(CLSID_CONVERT_SVG, COMMAND_DEFS[0].clsid);
    }
}
