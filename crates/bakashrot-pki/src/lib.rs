//! BakaShrot's certificates, and the TLS they're used with.
//!
//! - [`Identity`]: who a certificate is (a node's name, its roles), in an
//!   extension of BakaShrot's own.
//! - [`Ca`]: a CA issuing client and server certificates, and CRLs.
//! - [`Revocations`]: the certificates a CRL revokes, for servers to check
//!   (and reload when the CRL file changes).
//! - [`tls`]: the server's and the client's rustls configurations, at the
//!   strongest settings rustls has.
//!
//! Everything is PEM text in and out, as files hold it. The profile and the
//! reasons behind it: `docs/certificates.md`.

mod ca;
mod identity;
mod revocation;
pub mod tls;

pub use ca::{Ca, Issued, Summary, Usage, summarize};
pub use identity::Identity;
pub use revocation::{Revocations, SharedRevocations, serial};

use std::fmt;
use x509_parser::certificate::X509Certificate;

/// The identity extension's OID: `1.3.6.1.4.1.67681.1.1`, under
/// NibblePoker's Private Enterprise Number (67681, from IANA), BakaShrot's
/// branch (`.1`), its identity extension (`.1`). `docs/oid.md` has the
/// branches. It never changes: certificates made with another one aren't
/// read (those of 0.2.0 and before had a placeholder).
pub const IDENTITY_OID: &[u64] = &[1, 3, 6, 1, 4, 1, 67681, 1, 1];

/// The DNS name every server certificate has, and every client asks for:
/// a label, not a host. Servers are known by their certificate, wherever
/// they are.
pub const SERVER_NAME: &str = "bakashrot-server";

/// Default lifetimes, in days.
pub const CA_DAYS: u32 = 3650;
/// See [`CA_DAYS`].
pub const CERTIFICATE_DAYS: u32 = 365;

/// What went wrong, in words: everything here fails on a file or a value
/// that isn't right, which people fix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error(String);

impl Error {
    pub(crate) fn new(what: impl fmt::Display) -> Self {
        Error(what.to_string())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

/// A result of this crate.
pub type Result<T> = std::result::Result<T, Error>;

/// Reads one PEM block of `label`, its DER.
fn pem_der(text: &str, label: &str) -> Result<Vec<u8>> {
    let (_, pem) = x509_parser::pem::parse_x509_pem(text.as_bytes())
        .map_err(|error| Error::new(format!("not PEM: {error}")))?;
    if pem.label != label {
        return Err(Error::new(format!("a {}, not a {label}", pem.label)));
    }
    Ok(pem.contents)
}

/// Reads a certificate (DER).
fn parse_certificate(der: &[u8]) -> Result<X509Certificate<'_>> {
    let (_, certificate) = x509_parser::parse_x509_certificate(der)
        .map_err(|error| Error::new(format!("not a certificate: {error}")))?;
    Ok(certificate)
}
