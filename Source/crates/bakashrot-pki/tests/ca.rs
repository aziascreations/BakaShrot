//! Issuing: what certificates and CRLs hold, and OpenSSL agreeing.

use bakashrot_pki::{Ca, Identity, Revocations, Usage, summarize};
use std::path::PathBuf;
use std::process::Command;

fn ca() -> (Ca, String) {
    let issued = Ca::create("Test CA", 30).unwrap();
    (
        Ca::load(&issued.certificate, &issued.key).unwrap(),
        issued.certificate,
    )
}

#[test]
fn certificates_say_who_and_what_for() {
    let (ca, ca_certificate) = ca();
    let identity = Identity::new("kitchen", &["sensor", "reader"]).unwrap();
    let client = ca.issue(&identity, Usage::Client, 365).unwrap();
    let server = ca
        .issue(
            &Identity::new("server-1", &["peer"]).unwrap(),
            Usage::Server,
            365,
        )
        .unwrap();

    let summary = summarize(&client.certificate).unwrap();
    assert_eq!(summary.identity, Some(identity));
    assert_eq!(summary.subject, "kitchen");
    assert_eq!(summary.issuer, "Test CA");
    assert_eq!(summary.usage, Some(Usage::Client));
    assert!(!summary.is_ca);
    assert!(!summary.serial.is_empty());

    assert_eq!(
        summarize(&server.certificate).unwrap().usage,
        Some(Usage::Server)
    );
    let ca_summary = summarize(&ca_certificate).unwrap();
    assert!(ca_summary.is_ca);
    assert_eq!(ca_summary.identity, None);

    assert!(ca.issued(&client.certificate).unwrap());
    let (other, _) = self::ca();
    assert!(!other.issued(&client.certificate).unwrap());
}

#[test]
fn a_ca_needs_its_own_key() {
    let first = Ca::create("First", 30).unwrap();
    let second = Ca::create("Second", 30).unwrap();
    assert!(Ca::load(&first.certificate, &second.key).is_err());
    assert!(Ca::load(&first.certificate, &first.key).is_ok());

    let ca = Ca::load(&first.certificate, &first.key).unwrap();
    let client = ca
        .issue(&Identity::new("kitchen", &[]).unwrap(), Usage::Client, 30)
        .unwrap();
    assert!(
        Ca::load(&client.certificate, &client.key).is_err(),
        "not a CA"
    );
    assert!(Ca::create(" ", 30).is_err());
}

#[test]
fn crls_revoke_what_they_list() {
    let (ca, ca_certificate) = ca();
    let certificates: Vec<String> = (0..8)
        .map(|n| {
            let identity = Identity::new(&format!("node-{n}"), &[]).unwrap();
            ca.issue(&identity, Usage::Client, 30).unwrap().certificate
        })
        .collect();
    let serials: Vec<Vec<u8>> = certificates[..4]
        .iter()
        .map(|certificate| summarize(certificate).unwrap().serial)
        .collect();
    let crl = ca.revocation_list(&serials, 30).unwrap();
    let revocations = Revocations::load(&crl, &ca_certificate).unwrap();
    assert_eq!(revocations.len(), 4);
    for (n, certificate) in certificates.iter().enumerate() {
        assert_eq!(revocations.revokes(&der(certificate)), n < 4, "node-{n}");
    }
    assert!(Revocations::none().is_empty());
    assert!(!Revocations::none().revokes(&der(&certificates[0])));

    let empty = ca.revocation_list(&[], 30).unwrap();
    assert!(
        Revocations::load(&empty, &ca_certificate)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn only_the_cas_crls_are_taken() {
    let (ca, ca_certificate) = ca();
    let (other, other_certificate) = self::ca();
    let crl = other.revocation_list(&[vec![1]], 30).unwrap();
    assert!(
        Revocations::load(&crl, &ca_certificate).is_err(),
        "another CA's"
    );
    assert!(Revocations::load(&crl, &other_certificate).is_ok());

    // Tampered: a character of its Base64 changed.
    let crl = ca.revocation_list(&[vec![1]], 30).unwrap();
    let at = crl.len() / 2;
    let swapped = if &crl[at..=at] == "A" { "B" } else { "A" };
    let tampered = format!("{}{}{}", &crl[..at], swapped, &crl[at + 1..]);
    assert!(Revocations::load(&tampered, &ca_certificate).is_err());

    assert!(Revocations::load("not a CRL", &ca_certificate).is_err());
    assert!(
        Revocations::load(&ca_certificate, &ca_certificate).is_err(),
        "a certificate"
    );
}

fn der(certificate: &str) -> Vec<u8> {
    use rustls::pki_types::{CertificateDer, pem::PemObject};
    CertificateDer::from_pem_slice(certificate.as_bytes())
        .unwrap()
        .to_vec()
}

/// OpenSSL, from the PATH or Git for Windows'.
fn openssl() -> Option<PathBuf> {
    let candidates = [
        PathBuf::from("openssl"),
        PathBuf::from(r"C:\Program Files\Git\ucrt64\bin\openssl.exe"),
        PathBuf::from(r"C:\Program Files\Git\mingw64\bin\openssl.exe"),
        PathBuf::from(r"C:\Program Files\Git\usr\bin\openssl.exe"),
    ];
    candidates.into_iter().find(|candidate| {
        Command::new(candidate)
            .arg("version")
            .output()
            .is_ok_and(|output| output.status.success())
    })
}

#[test]
fn openssl_agrees() {
    let Some(openssl) = openssl() else {
        eprintln!("SKIP: no openssl");
        return;
    };
    let folder = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("pki-openssl");
    let _ = std::fs::remove_dir_all(&folder);
    std::fs::create_dir_all(&folder).unwrap();

    let issued = Ca::create("Test CA", 30).unwrap();
    let ca = Ca::load(&issued.certificate, &issued.key).unwrap();
    let client = ca
        .issue(
            &Identity::new("kitchen", &["sensor"]).unwrap(),
            Usage::Client,
            30,
        )
        .unwrap();
    let server = ca
        .issue(&Identity::new("server-1", &[]).unwrap(), Usage::Server, 30)
        .unwrap();
    let serial = summarize(&client.certificate).unwrap().serial;
    let files = [
        ("ca.crt", issued.certificate.clone()),
        ("client.crt", client.certificate),
        ("server.crt", server.certificate),
        ("ca.crl", ca.revocation_list(&[serial], 30).unwrap()),
    ];
    for (name, text) in &files {
        std::fs::write(folder.join(name), text).unwrap();
    }
    let run = |args: &[&str]| {
        let output = Command::new(&openssl)
            .args(args)
            .current_dir(&folder)
            .output()
            .unwrap();
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        (output.status.success(), text)
    };

    let (ok, text) = run(&[
        "verify",
        "-CAfile",
        "ca.crt",
        "-purpose",
        "sslclient",
        "client.crt",
    ]);
    assert!(ok, "{text}");
    let (ok, text) = run(&[
        "verify",
        "-CAfile",
        "ca.crt",
        "-purpose",
        "sslserver",
        "server.crt",
    ]);
    assert!(ok, "{text}");
    let (ok, _) = run(&[
        "verify",
        "-CAfile",
        "ca.crt",
        "-purpose",
        "sslserver",
        "client.crt",
    ]);
    assert!(!ok, "a client's certificate isn't a server's");
    let (ok, text) = run(&["crl", "-in", "ca.crl", "-CAfile", "ca.crt", "-noout"]);
    assert!(ok && text.contains("verify OK"), "{text}");
    let (ok, text) = run(&[
        "verify",
        "-CAfile",
        "ca.crt",
        "-CRLfile",
        "ca.crl",
        "-crl_check",
        "client.crt",
    ]);
    assert!(!ok && text.contains("revoked"), "{text}");
    let (ok, text) = run(&["x509", "-in", "server.crt", "-noout", "-text"]);
    assert!(
        ok && text.contains("NIST CURVE: P-384") && text.contains("DNS:bakashrot-server"),
        "{text}"
    );
}
