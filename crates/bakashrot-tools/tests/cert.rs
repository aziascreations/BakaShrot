//! `bakashrot-cert` end to end, in a folder of the build's.

use bakashrot_pki::{Revocations, summarize};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn folder(name: &str) -> PathBuf {
    let folder = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = fs::remove_dir_all(&folder);
    fs::create_dir_all(&folder).unwrap();
    folder
}

/// Runs the tool in `folder`: whether it succeeded, and what it printed.
fn cert(folder: &Path, args: &[&str]) -> (bool, String) {
    let output = Command::new(env!("CARGO_BIN_EXE_bakashrot-cert"))
        .args(args)
        .current_dir(folder)
        .output()
        .unwrap();
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    (output.status.success(), text)
}

fn read(folder: &Path, name: &str) -> String {
    fs::read_to_string(folder.join(name)).unwrap()
}

#[test]
fn a_ca_issues_and_revokes() {
    let folder = folder("cert-tool");
    let (ok, text) = cert(&folder, &["ca", "--name", "Test CA"]);
    assert!(ok, "{text}");
    assert!(
        cert(
            &folder,
            &[
                "issue", "--name", "kitchen", "--role", "sensor", "--role", "reader"
            ]
        )
        .0
    );
    assert!(cert(&folder, &["issue", "--name", "garage"]).0);
    assert!(
        cert(
            &folder,
            &["issue", "--name", "server-1", "--role", "peer", "--server"]
        )
        .0
    );

    let (ok, text) = cert(&folder, &["show", "kitchen.crt"]);
    assert!(ok, "{text}");
    assert!(
        text.contains("name:    kitchen") && text.contains("roles:   sensor, reader"),
        "{text}"
    );
    assert!(
        text.contains("usage:   client") && text.contains("issuer:  Test CA"),
        "{text}"
    );
    let (_, text) = cert(&folder, &["show", "server-1.crt"]);
    assert!(text.contains("usage:   server"), "{text}");
    let (_, text) = cert(&folder, &["show", "ca.crt"]);
    assert!(text.contains("usage:   CA"), "{text}");

    // Revoking twice keeps the first.
    assert!(cert(&folder, &["revoke", "kitchen.crt"]).0);
    let (ok, text) = cert(&folder, &["revoke", "garage.crt", "kitchen.crt"]);
    assert!(ok && text.contains("(2 revoked)"), "{text}");
    let revocations =
        Revocations::load(&read(&folder, "ca.crl"), &read(&folder, "ca.crt")).unwrap();
    assert_eq!(revocations.len(), 2);
    for (name, revoked) in [("kitchen", true), ("garage", true), ("server-1", false)] {
        let serial = summarize(&read(&folder, &format!("{name}.crt")))
            .unwrap()
            .serial;
        assert_eq!(
            revocations.serials().any(|s| s == serial),
            revoked,
            "{name}"
        );
    }
    assert!(!folder.join("ca.crl.new").exists());
}

#[test]
fn a_name_can_have_several_certificates() {
    let folder = folder("cert-tool-same-name");
    assert!(cert(&folder, &["ca", "--name", "Test CA"]).0);
    let server = ["issue", "--name", "server-1", "--role", "peer", "--server"];
    assert!(cert(&folder, &server).0);
    assert!(!cert(&folder, &server).0, "server-1.crt is there already");
    let (ok, text) = cert(&folder, &[&server[..], &["--file", "server-1b"]].concat());
    assert!(ok, "{text}");

    let first = summarize(&read(&folder, "server-1.crt")).unwrap();
    let second = summarize(&read(&folder, "server-1b.crt")).unwrap();
    assert_eq!(first.identity, second.identity);
    assert_ne!(first.serial, second.serial);

    // Revoking one leaves the other.
    assert!(cert(&folder, &["revoke", "server-1b.crt"]).0);
    let revocations =
        Revocations::load(&read(&folder, "ca.crl"), &read(&folder, "ca.crt")).unwrap();
    assert!(revocations.serials().any(|s| s == second.serial));
    assert!(!revocations.serials().any(|s| s == first.serial));
}

#[test]
fn nothing_is_overwritten_or_mixed_up() {
    let folder = folder("cert-tool-refusals");
    assert!(cert(&folder, &["ca", "--name", "Test CA"]).0);
    let key = read(&folder, "ca.key");
    let (ok, text) = cert(&folder, &["ca", "--name", "Another"]);
    assert!(!ok, "{text}");
    assert_eq!(read(&folder, "ca.key"), key, "the CA's key is still there");

    assert!(cert(&folder, &["issue", "--name", "kitchen"]).0);
    assert!(
        !cert(&folder, &["issue", "--name", "kitchen"]).0,
        "already there"
    );
    assert!(!cert(&folder, &["issue", "--name", "12"]).0, "not a name");
    assert!(
        !cert(&folder, &["issue", "--name", "garage", "--role", "a b"]).0,
        "not a role"
    );

    // A certificate of another CA isn't revoked by this one.
    let other = folder.join("other");
    fs::create_dir_all(&other).unwrap();
    assert!(cert(&other, &["ca", "--name", "Other CA"]).0);
    assert!(cert(&other, &["issue", "--name", "stranger"]).0);
    let (ok, text) = cert(&folder, &["revoke", "other/stranger.crt"]);
    assert!(!ok && text.contains("not issued by this CA"), "{text}");
    assert!(!folder.join("ca.crl").exists());

    let (ok, text) = cert(&folder, &["show", "missing.crt"]);
    assert!(!ok && text.contains("missing.crt"), "{text}");
}
