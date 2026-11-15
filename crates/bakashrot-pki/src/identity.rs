//! The identity extension: who a certificate is.
//!
//! ```text
//! BakaShrotIdentity ::= SEQUENCE {
//!     version  INTEGER,                  -- 1
//!     name     UTF8String,               -- the node: "kitchen"
//!     roles    SEQUENCE OF UTF8String    -- free: "sensor", "peer"...
//! }
//! ```
//!
//! Non-critical (rustls refuses critical extensions it doesn't know), read
//! by BakaShrot only. Names and roles follow the name rules
//! (`bakashrot_proto::names`).

use crate::{Error, IDENTITY_OID, Result, parse_certificate};
use bakashrot_proto::names::is_valid_name;
use x509_parser::oid_registry::Oid;

/// The version written, the only one read.
const VERSION: u32 = 1;

/// The most roles a certificate may have.
pub const MAX_ROLES: usize = 64;

/// Who a certificate is: a node, and its roles (their meaning is the
/// server's config's).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    /// The node's name.
    pub name: String,
    /// Its roles, in order.
    pub roles: Vec<String>,
}

impl Identity {
    /// An identity, checked: a name, roles that are names too.
    pub fn new(name: &str, roles: &[&str]) -> Result<Identity> {
        let identity = Identity {
            name: name.to_owned(),
            roles: roles.iter().map(|role| (*role).to_owned()).collect(),
        };
        identity.check()?;
        Ok(identity)
    }

    /// Whether it has `role` (roles compare without case, like names).
    pub fn has_role(&self, role: &str) -> bool {
        self.roles.iter().any(|own| own.eq_ignore_ascii_case(role))
    }

    fn check(&self) -> Result<()> {
        if !is_valid_name(&self.name) {
            return Err(Error::new(format!("'{}' isn't a valid name", self.name)));
        }
        if self.roles.len() > MAX_ROLES {
            return Err(Error::new(format!("more than {MAX_ROLES} roles")));
        }
        if let Some(role) = self.roles.iter().find(|role| !is_valid_name(role)) {
            return Err(Error::new(format!("'{role}' isn't a valid role")));
        }
        Ok(())
    }

    /// The extension's value, DER.
    pub(crate) fn to_der(&self) -> Vec<u8> {
        yasna::construct_der(|writer| {
            writer.write_sequence(|writer| {
                writer.next().write_u32(VERSION);
                writer.next().write_utf8_string(&self.name);
                writer.next().write_sequence_of(|writer| {
                    for role in &self.roles {
                        writer.next().write_utf8_string(role);
                    }
                });
            });
        })
    }

    /// Reads the extension's value, DER.
    pub(crate) fn from_der(der: &[u8]) -> Result<Identity> {
        let (version, name, roles) = yasna::parse_der(der, |reader| {
            reader.read_sequence(|reader| {
                let version = reader.next().read_u32()?;
                let name = reader.next().read_utf8string()?;
                let roles = reader
                    .next()
                    .collect_sequence_of(|reader| reader.read_utf8string())?;
                Ok((version, name, roles))
            })
        })
        .map_err(|error| Error::new(format!("the identity extension isn't readable: {error}")))?;
        if version != VERSION {
            return Err(Error::new(format!(
                "identity version {version}, this one reads {VERSION}"
            )));
        }
        let identity = Identity { name, roles };
        identity.check()?;
        Ok(identity)
    }

    /// The identity of a certificate (DER), the one the TLS connection
    /// presented once verified.
    pub fn from_certificate(der: &[u8]) -> Result<Identity> {
        let certificate = parse_certificate(der)?;
        let oid = Oid::from(IDENTITY_OID).map_err(|_| Error::new("the identity OID is invalid"))?;
        let extension = certificate
            .get_extension_unique(&oid)
            .map_err(|error| Error::new(format!("the identity extension: {error}")))?
            .ok_or_else(|| Error::new("the certificate has no BakaShrot identity"))?;
        Identity::from_der(extension.value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let identity = Identity::new("kitchen", &["sensor", "Reader"]).unwrap();
        assert_eq!(Identity::from_der(&identity.to_der()), Ok(identity.clone()));
        assert!(identity.has_role("reader"));
        assert!(!identity.has_role("peer"));
        let alone = Identity::new("kitchen", &[]).unwrap();
        assert_eq!(Identity::from_der(&alone.to_der()), Ok(alone));
    }

    #[test]
    fn refused() {
        assert!(Identity::new("12", &[]).is_err());
        assert!(Identity::new("a b", &[]).is_err());
        assert!(Identity::new("kitchen", &["bad role"]).is_err());
        assert!(Identity::new("kitchen", &["r"; MAX_ROLES + 1]).is_err());
        assert!(Identity::from_der(b"garbage").is_err());

        // Another version.
        let other = yasna::construct_der(|writer| {
            writer.write_sequence(|writer| {
                writer.next().write_u32(2);
                writer.next().write_utf8_string("kitchen");
                writer.next().write_sequence_of(|_| {});
            });
        });
        assert!(Identity::from_der(&other).is_err());
    }
}
