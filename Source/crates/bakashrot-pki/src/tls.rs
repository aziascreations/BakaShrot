//! The TLS setup of servers and clients: TLS 1.3 only, AES-256-GCM-SHA384
//! only, the X25519MLKEM768 key exchange only, ALPN `bakashrot`, and a
//! certificate from the CA on both ends.
//!
//! Each end checks the other with rustls' own verifier (a server's
//! certificate for the name they all have, [`SERVER_NAME`]: no host names
//! or IPs), then that it isn't revoked and has an identity. Both ends take
//! [`SharedRevocations`]: a server dialing its peer is that peer's client,
//! so servers block each other the same way. Once connected, either end
//! reads the other's [`Identity`] with [`peer_identity`].

use crate::{Error, Identity, Result, SERVER_NAME, SharedRevocations};
use bakashrot_proto::limits::ALPN;
use rustls::client::WebPkiServerVerifier;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{CryptoProvider, aws_lc_rs};
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use rustls::server::WebPkiClientVerifier;
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{
    CertificateError, ClientConfig, DigitallySignedStruct, DistinguishedName, RootCertStore,
    ServerConfig, SignatureScheme,
};
use std::sync::Arc;

/// aws-lc, with only the strongest cipher suite and key exchange.
pub fn provider() -> Arc<CryptoProvider> {
    Arc::new(CryptoProvider {
        cipher_suites: vec![aws_lc_rs::cipher_suite::TLS13_AES_256_GCM_SHA384],
        kx_groups: vec![aws_lc_rs::kx_group::X25519MLKEM768],
        ..aws_lc_rs::default_provider()
    })
}

/// The name a client asks for: [`SERVER_NAME`].
pub fn server_name() -> ServerName<'static> {
    ServerName::try_from(SERVER_NAME).expect("SERVER_NAME is a DNS name")
}

/// A server's configuration: its certificate and key (PEM), the CA it takes
/// clients from (PEM), and the revocations it checks them against.
pub fn server_config(
    ca: &str,
    certificate: &str,
    key: &str,
    revocations: SharedRevocations,
) -> Result<Arc<ServerConfig>> {
    let provider = provider();
    let webpki = WebPkiClientVerifier::builder_with_provider(roots(ca)?, provider.clone())
        .build()
        .map_err(|error| Error::new(format!("the CA: {error}")))?;
    let mut config = ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(tls_error)?
        .with_client_cert_verifier(Arc::new(ClientCheck {
            webpki,
            revocations,
        }))
        .with_single_cert(chain(certificate)?, private_key(key)?)
        .map_err(tls_error)?;
    config.alpn_protocols = vec![ALPN.to_vec()];
    Ok(Arc::new(config))
}

/// A client's configuration: its certificate and key (PEM), the CA it takes
/// servers from (PEM), and the revocations it checks them against
/// (`Revocations::none()` without a CRL). Connect with [`server_name`].
pub fn client_config(
    ca: &str,
    certificate: &str,
    key: &str,
    revocations: SharedRevocations,
) -> Result<Arc<ClientConfig>> {
    let provider = provider();
    let webpki = WebPkiServerVerifier::builder_with_provider(roots(ca)?, provider.clone())
        .build()
        .map_err(|error| Error::new(format!("the CA: {error}")))?;
    let mut config = ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(tls_error)?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(ServerCheck {
            webpki,
            revocations,
        }))
        .with_client_auth_cert(chain(certificate)?, private_key(key)?)
        .map_err(tls_error)?;
    config.alpn_protocols = vec![ALPN.to_vec()];
    Ok(Arc::new(config))
}

/// The identity of the other end, from its certificates once connected
/// (`peer_certificates()` of a rustls connection).
pub fn peer_identity(certificates: Option<&[CertificateDer<'_>]>) -> Result<Identity> {
    let certificate = certificates
        .and_then(<[_]>::first)
        .ok_or_else(|| Error::new("no certificate from the other end"))?;
    Identity::from_certificate(certificate)
}

fn tls_error(error: rustls::Error) -> Error {
    Error::new(format!("TLS: {error}"))
}

fn roots(ca: &str) -> Result<Arc<RootCertStore>> {
    let mut roots = RootCertStore::empty();
    for certificate in CertificateDer::pem_slice_iter(ca.as_bytes()) {
        let certificate = certificate.map_err(|error| Error::new(format!("the CA: {error}")))?;
        roots.add(certificate).map_err(tls_error)?;
    }
    if roots.is_empty() {
        return Err(Error::new("the CA: no certificate"));
    }
    Ok(Arc::new(roots))
}

fn chain(certificate: &str) -> Result<Vec<CertificateDer<'static>>> {
    let chain = CertificateDer::pem_slice_iter(certificate.as_bytes())
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|error| Error::new(format!("the certificate: {error}")))?;
    if chain.is_empty() {
        return Err(Error::new("the certificate: none in it"));
    }
    Ok(chain)
}

fn private_key(key: &str) -> Result<PrivateKeyDer<'static>> {
    PrivateKeyDer::from_pem_slice(key.as_bytes())
        .map_err(|error| Error::new(format!("the key: {error}")))
}

/// What both ends check once rustls' verifier took the other's certificate:
/// not revoked, an identity.
fn ours(
    certificate: &CertificateDer<'_>,
    revocations: &SharedRevocations,
) -> std::result::Result<(), rustls::Error> {
    // A poisoned lock: refuse rather than guess.
    let revoked = revocations
        .read()
        .map_or(true, |revocations| revocations.revokes(certificate));
    if revoked {
        return Err(rustls::Error::InvalidCertificate(CertificateError::Revoked));
    }
    if Identity::from_certificate(certificate).is_err() {
        return Err(rustls::Error::InvalidCertificate(
            CertificateError::ApplicationVerificationFailure,
        ));
    }
    Ok(())
}

/// The server's check of clients: rustls', then [`ours`].
#[derive(Debug)]
struct ClientCheck {
    webpki: Arc<dyn ClientCertVerifier>,
    revocations: SharedRevocations,
}

impl ClientCertVerifier for ClientCheck {
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        self.webpki.root_hint_subjects()
    }

    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        now: UnixTime,
    ) -> std::result::Result<ClientCertVerified, rustls::Error> {
        let verified = self
            .webpki
            .verify_client_cert(end_entity, intermediates, now)?;
        ours(end_entity, &self.revocations)?;
        Ok(verified)
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        self.webpki
            .verify_tls12_signature(message, certificate, signature)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        self.webpki
            .verify_tls13_signature(message, certificate, signature)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.webpki.supported_verify_schemes()
    }
}

/// The client's check of servers: rustls', then [`ours`].
#[derive(Debug)]
struct ServerCheck {
    webpki: Arc<WebPkiServerVerifier>,
    revocations: SharedRevocations,
}

impl ServerCertVerifier for ServerCheck {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &ServerName<'_>,
        ocsp_response: &[u8],
        now: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
        let verified = self.webpki.verify_server_cert(
            end_entity,
            intermediates,
            server_name,
            ocsp_response,
            now,
        )?;
        ours(end_entity, &self.revocations)?;
        Ok(verified)
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        self.webpki
            .verify_tls12_signature(message, certificate, signature)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        self.webpki
            .verify_tls13_signature(message, certificate, signature)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.webpki.supported_verify_schemes()
    }
}
