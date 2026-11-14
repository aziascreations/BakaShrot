//! `bindings/python/check_bakashrot.py` on the DLL against a server: the
//! Python module and the DLL as an app loads it. Skipped (said so) without
//! a Python 3.11+ on the PATH.

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;

#[test]
fn check_bakashrot_py() {
    let Some(python) = ["python3", "python"].into_iter().find(|python| {
        Command::new(python)
            .args(["-c", "import sys, tomllib; sys.exit(0)"])
            .output()
            .is_ok_and(|output| output.status.success())
    }) else {
        eprintln!("SKIPPED: no Python 3.11+ on the PATH");
        return;
    };

    let dll = built_dll();

    let running = common::Running::start("python");
    running.issue("kitchen", &["home"]);
    running.issue("lounge", &["lounge"]);
    running.issue("guest", &["guest"]);

    let bindings = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../bindings/python");
    let output = Command::new(python)
        .arg(bindings.join("check_bakashrot.py"))
        .arg(&dll)
        .arg(&running.folder)
        .env("PYTHONPATH", &bindings)
        .env("PYTHONIOENCODING", "utf-8")
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    println!("{stdout}");
    eprintln!("{}", String::from_utf8_lossy(&output.stderr));
    assert!(output.status.success(), "check_bakashrot.py failed");
    assert!(stdout.contains("All checks passed"));
}

/// The DLL cargo built with this test: next to it (cargo's older layout),
/// or the newest in this crate's build folders (`build/bakashrot-capi/*/out/`).
fn built_dll() -> PathBuf {
    let name = format!(
        "{}bakashrot{}",
        std::env::consts::DLL_PREFIX,
        std::env::consts::DLL_SUFFIX
    );
    let exe = std::env::current_exe().unwrap();
    let here = exe.parent().unwrap();
    if here.join(&name).exists() {
        return here.join(name);
    }
    let builds = here.ancestors().nth(2).unwrap();
    std::fs::read_dir(builds)
        .unwrap()
        .filter_map(|entry| Some(entry.ok()?.path().join("out").join(&name)))
        .filter_map(|dll| Some((dll.metadata().ok()?.modified().ok()?, dll)))
        .max()
        .map(|(_, dll)| dll)
        .unwrap_or_else(|| panic!("no {name} built near {}", here.display()))
}
