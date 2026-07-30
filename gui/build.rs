// build.rs — embeds (1) a Windows application manifest requiring administrator
// elevation, so the GUI exe itself triggers the single UAC prompt and the
// child SystemUpdate_Topgrade.bat inherits the elevated token, and (2) the
// Upkeep icon + version resource via winresource.

#[cfg(windows)]
fn main() {
    use embed_manifest::manifest::{ExecutionLevel, Setting};
    use embed_manifest::{embed_manifest, new_manifest};

    let manifest = new_manifest("Upkeep")
        .requested_execution_level(ExecutionLevel::RequireAdministrator)
        .dpi_awareness(embed_manifest::manifest::DpiAwareness::PerMonitorV2)
        .long_path_aware(Setting::Enabled);

    embed_manifest(manifest).expect("unable to embed manifest file");

    // Icon + version info. winresource compiles a .rc; it must NOT also set
    // a manifest (embed-manifest above owns that). CAUTION: the resource is
    // linked into EVERY target of this package, including the unmanifested
    // `cargo test` harness - so the version strings below must never contain
    // Windows installer-detection trigger words ("update", "setup",
    // "install", "patch"), or the harness demands elevation and tests fail
    // with os error 740.
    let mut res = winresource::WindowsResource::new();
    res.set_icon("assets/upkeep.ico");
    res.set("ProductName", "Upkeep");
    res.set("FileDescription", "Upkeep - Windows maintenance dashboard");
    res.set("LegalCopyright", "");
    if let Err(e) = res.compile() {
        // In a debug build this is cosmetic, so warn and carry on. In a
        // RELEASE build it is not: without the Windows SDK resource compiler
        // the exe silently loses its icon AND its version resource, cargo
        // still exits 0, and Build-Installer.ps1 -- which only checks
        // $LASTEXITCODE -- happily ships it. `cargo:warning` scrolls past
        // unnoticed in a scripted build, so fail loudly instead.
        if std::env::var("PROFILE").as_deref() == Ok("release") {
            panic!("winresource failed, so the release exe would have no icon and no version info: {e}");
        }
        println!("cargo:warning=winresource failed (no icon embedded): {e}");
    }

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=assets/upkeep.ico");
}

#[cfg(not(windows))]
fn main() {}
