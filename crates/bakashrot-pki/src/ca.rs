//! A CA: issuing client and server certificates, and CRLs.
//!
//! Every key is ECDSA P-384, every signature SHA-384. A server certificate
//! is for servers and clients both (servers are their peers' clients), and
//! has the DNS name [`SERVER_NAME`] its clients ask for.

use crate::{Error, IDENTITY_OID, Identity, Result, SERVER_NAME, parse_certificate, pem_der};
use rcgen::{
    BasicConstraints, CertificateParams, CertificateRevocationListParams, CustomExtension,
    DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa, Issuer, KeyIdMethod, KeyPair,
    KeyUsagePurpose, PKCS_ECDSA_P384_SHA384, PublicKeyData, RevokedCertParams, SanType,
    SerialNumber,
};
use time::{Duration, OffsetDateTime};
use x509_parser::x509::X509Name;

/// What a certificate is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Usage {
    /// A client's: it connects to servers.
    Client,
    /// A server's: clients and peers connect to it, and it connects to its
    /// peers.
    Server,
}

/// A certificate and its private key, PEM.
#[derive(Debug, Clone)]
pub struct Issued {
    /// The certificate: public, goes wherever it's needed.
    pub certificate: String,
    /// Its private key: stays with its owner.
    pub key: String,
}

/// A CA, loaded from its certificate and its key.
pub struct Ca {
    certificate: Vec<u8>,
    issuer: Issuer<'static, KeyPair>,
}

fn rcgen_error(what: &str) -> impl Fn(rcgen::Error) -> Error + '_ {
    move |error| Error::new(format!("{what}: {error}"))
}

fn new_key() -> Result<KeyPair> {
    KeyPair::generate_for(&PKCS_ECDSA_P384_SHA384).map_err(rcgen_error("making a key"))
}

/// Parameters valid from now on, for `days`, with `name` as the CN.
fn params(name: &str, days: u32) -> CertificateParams {
    let mut params = CertificateParams::default();
    let mut subject = DistinguishedName::new();
    subject.push(DnType::CommonName, name);
    params.distinguished_name = subject;
    let now = OffsetDateTime::now_utc();
    params.not_before = now;
    params.not_after = now + Duration::days(days.into());
    params
}

impl Ca {
    /// Makes a new CA named `name` (its CN), valid `days`: its certificate
    /// and its key. Keep the key off the servers: whoever has it can make
    /// any identity.
    pub fn create(name: &str, days: u32) -> Result<Issued> {
        if name.trim().is_empty() {
            return Err(Error::new("a CA needs a name"));
        }
        let key = new_key()?;
        let mut params = params(name, days);
        params.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
        params.key_usages = vec![
            KeyUsagePurpose::KeyCertSign,
            KeyUsagePurpose::CrlSign,
            KeyUsagePurpose::DigitalSignature,
        ];
        let certificate = params
            .self_signed(&key)
            .map_err(rcgen_error("making the CA"))?;
        Ok(Issued {
            certificate: certificate.pem(),
            key: key.serialize_pem(),
        })
    }

    /// Loads a CA from its certificate and its key (PEM). Fails if the
    /// certificate isn't a CA's, or the key isn't its.
    pub fn load(certificate: &str, key: &str) -> Result<Ca> {
        let key = KeyPair::from_pem(key).map_err(rcgen_error("the CA's key"))?;
        let der = pem_der(certificate, "CERTIFICATE")?;
        {
            let parsed = parse_certificate(&der)?;
            if !parsed.is_ca() {
                return Err(Error::new("the certificate isn't a CA's"));
            }
            if parsed.public_key().raw != key.subject_public_key_info() {
                return Err(Error::new("the key isn't the CA certificate's"));
            }
        }
        let issuer = Issuer::from_ca_cert_pem(certificate, key)
            .map_err(rcgen_error("the CA's certificate"))?;
        Ok(Ca {
            certificate: der,
            issuer,
        })
    }

    /// Issues a certificate for `identity`, valid `days`: its certificate and
    /// a new key.
    pub fn issue(&self, identity: &Identity, usage: Usage, days: u32) -> Result<Issued> {
        let key = new_key()?;
        let mut params = params(&identity.name, days);
        params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        params.use_authority_key_identifier_extension = true;
        params.custom_extensions = vec![CustomExtension::from_oid_content(
            IDENTITY_OID,
            identity.to_der(),
        )];
        match usage {
            Usage::Client => {
                params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ClientAuth];
            }
            Usage::Server => {
                params.extended_key_usages = vec![
                    ExtendedKeyUsagePurpose::ServerAuth,
                    ExtendedKeyUsagePurpose::ClientAuth,
                ];
                let name = SERVER_NAME
                    .try_into()
                    .map_err(rcgen_error("the server name"))?;
                params.subject_alt_names = vec![SanType::DnsName(name)];
            }
        }
        let certificate = params
            .signed_by(&key, &self.issuer)
            .map_err(rcgen_error("issuing the certificate"))?;
        Ok(Issued {
            certificate: certificate.pem(),
            key: key.serialize_pem(),
        })
    }

    /// Whether this CA issued `certificate` (PEM): its signature checks out
    /// with the CA's key.
    pub fn issued(&self, certificate: &str) -> Result<bool> {
        let ca = parse_certificate(&self.certificate)?;
        let der = pem_der(certificate, "CERTIFICATE")?;
        let certificate = parse_certificate(&der)?;
        Ok(certificate.verify_signature(Some(ca.public_key())).is_ok())
    }

    /// A CRL revoking the certificates of these serial numbers (as
    /// [`Summary::serial`] gives them), PEM. It says to expect the next one
    /// within `days`; servers don't hold it against an older one.
    pub fn revocation_list(&self, serials: &[Vec<u8>], days: u32) -> Result<String> {
        let now = OffsetDateTime::now_utc();
        let params = CertificateRevocationListParams {
            this_update: now,
            next_update: now + Duration::days(days.max(1).into()),
            crl_number: SerialNumber::from(now.unix_timestamp().max(1) as u64),
            issuing_distribution_point: None,
            revoked_certs: serials
                .iter()
                .map(|serial| RevokedCertParams {
                    serial_number: SerialNumber::from_slice(serial),
                    revocation_time: now,
                    reason_code: None,
                    invalidity_date: None,
                })
                .collect(),
            key_identifier_method: KeyIdMethod::Sha256,
        };
        let list = params
            .signed_by(&self.issuer)
            .map_err(rcgen_error("making the CRL"))?;
        list.pem().map_err(rcgen_error("writing the CRL"))
    }
}

/// What a certificate says, for people (and the tool).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Summary {
    /// Its subject's CN.
    pub subject: String,
    /// Its issuer's CN.
    pub issuer: String,
    /// Its serial number, as it's written (what a CRL lists).
    pub serial: Vec<u8>,
    /// Valid from, as written in it.
    pub not_before: String,
    /// Valid until, as written in it.
    pub not_after: String,
    /// Whether it's a CA's.
    pub is_ca: bool,
    /// What it's for, if it's one of ours.
    pub usage: Option<Usage>,
    /// Who it is, if it has an identity.
    pub identity: Option<Identity>,
}

impl Summary {
    /// The serial number in hex.
    pub fn serial_hex(&self) -> String {
        self.serial
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }
}

/// What a certificate (PEM) says.
pub fn summarize(certificate: &str) -> Result<Summary> {
    let der = pem_der(certificate, "CERTIFICATE")?;
    let parsed = parse_certificate(&der)?;
    let common_name = |name: &X509Name<'_>| {
        name.iter_common_name()
            .next()
            .and_then(|cn| cn.as_str().ok())
            .unwrap_or("")
            .to_owned()
    };
    let usage = match parsed.extended_key_usage() {
        Ok(Some(eku)) if eku.value.server_auth => Some(Usage::Server),
        Ok(Some(eku)) if eku.value.client_auth => Some(Usage::Client),
        _ => None,
    };
    Ok(Summary {
        subject: common_name(parsed.subject()),
        issuer: common_name(parsed.issuer()),
        serial: parsed.raw_serial().to_vec(),
        not_before: parsed.validity().not_before.to_string(),
        not_after: parsed.validity().not_after.to_string(),
        is_ca: parsed.is_ca(),
        usage,
        identity: Identity::from_certificate(&der).ok(),
    })
}
