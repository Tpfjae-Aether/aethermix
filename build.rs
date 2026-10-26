// lang: Rust, file: build.rs
// embeds the app icon into the exe (taskbar + title bar) via windres
fn main() {
    // the crate resolves its data folders from this at compile time, so a
    // clone anywhere on disk works; nothing is pinned to one directory
    let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default();
    println!("cargo:rustc-env=AETHER_ROOT={}", manifest.replace('\\', "/"));
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let out_dir = std::path::PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let obj = out_dir.join("app_icon.o");
    let windres = std::env::var("AETHER_WINDRES")
        .unwrap_or_else(|_| "windres".to_string());

    let status = std::process::Command::new(windres)
        .args(["icon.rc", "-O", "coff", "-o"])
        .arg(&obj)
        .status();

    match status {
        Ok(s) if s.success() => {
            println!("cargo:rustc-link-arg-bins={}", obj.display());
        }
        Ok(s) => println!("cargo:warning=windres exited {s}; exe icon not embedded"),
        Err(e) => println!("cargo:warning=windres not runnable ({e}); exe icon not embedded"),
    }
    println!("cargo:rerun-if-changed=icon.rc");
    println!("cargo:rerun-if-changed=assets/app.ico");
}
