//! The certificates a CRL revokes.
//!
//! A server loads its CRL file into [`Revocations`], shares it with its TLS
//! setup ([`SharedRevocations`]), and replaces what's inside when the file
//! changes: new connections are checked against the new list at once, and
//! the server checks the open ones itself ([`Revocations::revokes_serial`],
//! their serials read once with [`serial`]).
//!
//! A CRL is only taken if it's the CA's: issued by it, its signature
//! checked. Its "next update" isn't held against it: CRLs are pushed by
//! hand, an old one still revokes what it lists.

use crate::{Error, Result, parse_certificate, pem_der};
use std::collections::HashSet;
use std::sync::{Arc, RwLock};

/// The serial numbers of the certificates a CRL revokes.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Revocations {
    serials: HashSet<Vec<u8>>,
}

/// Revocations shared between a server's TLS setup and whatever reloads
/// them.
pub type SharedRevocations = Arc<RwLock<Revocations>>;

impl Revocations {
    /// Nothing revoked: no CRL file.
    pub fn none() -> Revocations {
        Revocations::default()
    }

    /// Reads a CRL (PEM), which must be the CA's (its certificate, PEM).
    pub fn load(crl: &str, ca_certificate: &str) -> Result<Revocations> {
        let crl_der = pem_der(crl, "X509 CRL")?;
        let ca_der = pem_der(ca_certificate, "CERTIFICATE")?;
        let (_, list) = x509_parser::parse_x509_crl(&crl_der)
            .map_err(|error| Error::new(format!("not a CRL: {error}")))?;
        let ca = parse_certificate(&ca_der)
            .map_err(|error| Error::new(format!("the CA's certificate: {error}")))?;
        if list.issuer().as_raw() != ca.subject().as_raw() {
            return Err(Error::new("the CRL is another CA's"));
        }
        list.verify_signature(ca.public_key())
            .map_err(|_| Error::new("the CRL's signature isn't the CA's"))?;
        Ok(Revocations {
            serials: list
                .iter_revoked_certificates()
                .map(|revoked| revoked.raw_serial().to_vec())
                .collect(),
        })
    }

    /// Whether it revokes this certificate (DER). One that can't be read is
    /// taken as revoked.
    pub fn revokes(&self, certificate: &[u8]) -> bool {
        serial(certificate).map_or(true, |serial| self.revokes_serial(&serial))
    }

    /// Whether it revokes the certificate with this serial number
    /// ([`serial`]): checking an open connection without reading its
    /// certificate again.
    pub fn revokes_serial(&self, serial: &[u8]) -> bool {
        self.serials.contains(serial)
    }

    /// The serial numbers it revokes.
    pub fn serials(&self) -> impl Iterator<Item = &[u8]> {
        self.serials.iter().map(Vec::as_slice)
    }

    /// How many it revokes.
    pub fn len(&self) -> usize {
        self.serials.len()
    }

    /// Whether it revokes none.
    pub fn is_empty(&self) -> bool {
        self.serials.is_empty()
    }

    /// Wraps it for sharing.
    pub fn shared(self) -> SharedRevocations {
        Arc::new(RwLock::new(self))
    }
}

/// A certificate's (DER) serial number, as CRLs list them.
pub fn serial(certificate: &[u8]) -> Result<Vec<u8>> {
    Ok(parse_certificate(certificate)?.raw_serial().to_vec())
}
