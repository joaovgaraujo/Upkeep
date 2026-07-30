//! Pending-reboot detection via the registry (port of Functions.ps1's
//! Get-PendingRebootStatus). Every check degrades to `false` on any error
//! (missing key, access denied, etc.) instead of panicking.

use winreg::enums::*;
use winreg::RegKey;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RebootFlags {
    pub cbs: bool,
    pub windows_update: bool,
    pub pending_file_rename: bool,
}

impl RebootFlags {
    /// Whether Windows actually needs a restart to finish servicing.
    ///
    /// `pending_file_rename` is deliberately NOT part of this. smss.exe
    /// consumes and clears `PendingFileRenameOperations` on every boot, but
    /// Office Click-to-Run, the print spooler and ordinary temp-file cleanup
    /// queue fresh delete-on-reboot entries within hours of one -- so on a
    /// machine in normal use the value is populated essentially always. It
    /// used to gate `start_run`, which meant a confirmation prompt before
    /// every single run that no amount of rebooting could ever clear, and it
    /// kept a permanent amber banner on screen. CBS and Windows Update are
    /// the two keys Windows itself treats as authoritative, so only those
    /// two speak for a real pending reboot.
    pub fn requires_reboot(&self) -> bool {
        self.cbs || self.windows_update
    }
}

pub fn check_pending_reboot() -> RebootFlags {
    let hklm = RegKey::predef(HKEY_LOCAL_MACHINE);

    let cbs = hklm
        .open_subkey(
            r"SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        )
        .is_ok();

    let windows_update = hklm
        .open_subkey(
            r"SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        )
        .is_ok();

    let pending_file_rename = hklm
        .open_subkey(r"SYSTEM\CurrentControlSet\Control\Session Manager")
        .and_then(|key| key.get_raw_value("PendingFileRenameOperations"))
        .is_ok_and(|v| !v.bytes.is_empty());

    RebootFlags {
        cbs,
        windows_update,
        pending_file_rename,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pending_file_rename_alone_is_not_a_reboot() {
        // The regression this guards: PendingFileRenameOperations is
        // populated on essentially any machine that runs Office or prints,
        // so treating it as authoritative pinned the warning banner on and
        // put a confirmation prompt in front of every run, permanently.
        let flags = RebootFlags {
            cbs: false,
            windows_update: false,
            pending_file_rename: true,
        };
        assert!(!flags.requires_reboot());
    }

    #[test]
    fn cbs_and_windows_update_each_mean_a_reboot() {
        assert!(RebootFlags {
            cbs: true,
            ..Default::default()
        }
        .requires_reboot());
        assert!(RebootFlags {
            windows_update: true,
            ..Default::default()
        }
        .requires_reboot());
    }

    #[test]
    fn a_quiet_machine_needs_no_reboot() {
        assert!(!RebootFlags::default().requires_reboot());
    }

    #[test]
    fn the_real_registry_check_does_not_panic() {
        // Every probe degrades to false on error, so this must hold even
        // unelevated or with the keys absent.
        let _ = check_pending_reboot();
    }
}
