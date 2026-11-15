//! Handshakes in memory, no sockets: what's accepted and what's refused.

use bakashrot_pki::tls::{self, peer_identity};
use bakashrot_pki::{Ca, Identity, Issued, Revocations, SharedRevocations, Usage, summarize};
use bakashrot_proto::limits::ALPN;
use rustls::{ClientConfig, ClientConnection, ConnectionCommon, ServerConfig, ServerConnection};
use std::io::{Read, Write};
use std::sync::Arc;

struct Pki {
    ca: Ca,
    ca_certificate: String,
    ca_key: String,
}

impl Pki {
    fn new(name: &str) -> Pki {
        let issued = Ca::create(name, 30).unwrap();
        Pki {
            ca: Ca::load(&issued.certificate, &issued.key).unwrap(),
            ca_certificate: issued.certificate,
            ca_key: issued.key,
        }
    }

    fn issue(&self, name: &str, roles: &[&str], usage: Usage) -> Issued {
        self.ca
            .issue(&Identity::new(name, roles).unwrap(), usage, 30)
            .unwrap()
    }

    fn server(&self, issued: &Issued, revocations: SharedRevocations) -> Arc<ServerConfig> {
        tls::server_config(
            &self.ca_certificate,
            &issued.certificate,
            &issued.key,
            revocations,
        )
        .unwrap()
    }

    fn client(&self, issued: &Issued) -> Arc<ClientConfig> {
        self.client_checking(issued, Revocations::none().shared())
    }

    fn client_checking(
        &self,
        issued: &Issued,
        revocations: SharedRevocations,
    ) -> Arc<ClientConfig> {
        tls::client_config(
            &self.ca_certificate,
            &issued.certificate,
            &issued.key,
            revocations,
        )
        .unwrap()
    }

    /// Revocations listing these certificates.
    fn revoking(&self, certificates: &[&Issued]) -> SharedRevocations {
        let serials: Vec<Vec<u8>> = certificates
            .iter()
            .map(|issued| summarize(&issued.certificate).unwrap().serial)
            .collect();
        let crl = self.ca.revocation_list(&serials, 30).unwrap();
        Revocations::load(&crl, &self.ca_certificate)
            .unwrap()
            .shared()
    }
}

fn transfer<A, B>(from: &mut ConnectionCommon<A>, to: &mut ConnectionCommon<B>) {
    while from.wants_write() {
        let mut bytes = Vec::new();
        from.write_tls(&mut bytes).unwrap();
        let mut rest = &bytes[..];
        while !rest.is_empty() {
            to.read_tls(&mut rest).unwrap();
        }
    }
}

/// A handshake, then a byte each way: the connections, or which end
/// refused and why.
fn connect(
    client: Arc<ClientConfig>,
    server: Arc<ServerConfig>,
) -> Result<(ClientConnection, ServerConnection), String> {
    let mut client = ClientConnection::new(client, tls::server_name()).unwrap();
    let mut server = ServerConnection::new(server).unwrap();
    for _ in 0..10 {
        transfer(&mut client, &mut server);
        server
            .process_new_packets()
            .map_err(|e| format!("server: {e}"))?;
        transfer(&mut server, &mut client);
        client
            .process_new_packets()
            .map_err(|e| format!("client: {e}"))?;
        if !client.is_handshaking() && !server.is_handshaking() {
            break;
        }
    }
    client.writer().write_all(b"c").unwrap();
    transfer(&mut client, &mut server);
    server
        .process_new_packets()
        .map_err(|e| format!("server: {e}"))?;
    server.writer().write_all(b"s").unwrap();
    transfer(&mut server, &mut client);
    client
        .process_new_packets()
        .map_err(|e| format!("client: {e}"))?;

    let mut byte = [0];
    server
        .reader()
        .read_exact(&mut byte)
        .map_err(|e| format!("server read: {e}"))?;
    assert_eq!(&byte, b"c");
    client
        .reader()
        .read_exact(&mut byte)
        .map_err(|e| format!("client read: {e}"))?;
    assert_eq!(&byte, b"s");
    Ok((client, server))
}

#[test]
fn connected_at_the_strongest_settings() {
    let pki = Pki::new("Test CA");
    let server = pki.issue("server-1", &["peer"], Usage::Server);
    let client = pki.issue("kitchen", &["sensor"], Usage::Client);
    let (client, server) = connect(
        pki.client(&client),
        pki.server(&server, Revocations::none().shared()),
    )
    .unwrap();

    assert_eq!(
        client.protocol_version(),
        Some(rustls::ProtocolVersion::TLSv1_3)
    );
    assert_eq!(
        client.negotiated_cipher_suite().unwrap().suite(),
        rustls::CipherSuite::TLS13_AES_256_GCM_SHA384
    );
    assert_eq!(
        client.negotiated_key_exchange_group().unwrap().name(),
        rustls::NamedGroup::X25519MLKEM768
    );
    assert_eq!(client.alpn_protocol(), Some(ALPN));
    assert_eq!(server.alpn_protocol(), Some(ALPN));

    // Each end knows who the other is.
    let client_identity = peer_identity(server.peer_certificates()).unwrap();
    assert_eq!(
        client_identity,
        Identity::new("kitchen", &["sensor"]).unwrap()
    );
    let server_identity = peer_identity(client.peer_certificates()).unwrap();
    assert_eq!(server_identity.name, "server-1");
    assert!(server_identity.has_role("peer"));
}

#[test]
fn servers_connect_to_their_peers() {
    let pki = Pki::new("Test CA");
    let first = pki.issue("server-1", &["peer"], Usage::Server);
    let second = pki.issue("server-2", &["peer"], Usage::Server);
    // A server's certificate is a client's too.
    let (_, server) = connect(
        pki.client(&first),
        pki.server(&second, Revocations::none().shared()),
    )
    .unwrap();
    assert_eq!(
        peer_identity(server.peer_certificates()).unwrap().name,
        "server-1"
    );
}

#[test]
fn a_client_of_another_ca_is_refused() {
    let pki = Pki::new("Test CA");
    let other = Pki::new("Other CA");
    let server = pki.server(
        &pki.issue("server-1", &[], Usage::Server),
        Revocations::none().shared(),
    );
    let stranger = other.issue("kitchen", &[], Usage::Client);
    let client = tls::client_config(
        &pki.ca_certificate,
        &stranger.certificate,
        &stranger.key,
        Revocations::none().shared(),
    )
    .unwrap();
    let error = connect(client, server).unwrap_err();
    assert!(error.starts_with("server:"), "{error}");
}

#[test]
fn a_server_of_another_ca_is_refused() {
    let pki = Pki::new("Test CA");
    let other = Pki::new("Other CA");
    let client = pki.client(&pki.issue("kitchen", &[], Usage::Client));
    let impostor = other.issue("server-1", &[], Usage::Server);
    let server = tls::server_config(
        &pki.ca_certificate,
        &impostor.certificate,
        &impostor.key,
        Revocations::none().shared(),
    )
    .unwrap();
    let error = connect(client, server).unwrap_err();
    assert!(error.starts_with("client:"), "{error}");
}

#[test]
fn a_clients_certificate_isnt_a_servers() {
    let pki = Pki::new("Test CA");
    let client = pki.client(&pki.issue("kitchen", &[], Usage::Client));
    let posing = pki.issue("server-1", &[], Usage::Client);
    let error = connect(client, pki.server(&posing, Revocations::none().shared())).unwrap_err();
    assert!(error.starts_with("client:"), "{error}");
}

#[test]
fn revoked_clients_are_refused_and_reloading_takes_effect() {
    let pki = Pki::new("Test CA");
    let revocations = Revocations::none().shared();
    let server = pki.server(
        &pki.issue("server-1", &[], Usage::Server),
        revocations.clone(),
    );
    let kitchen = pki.issue("kitchen", &[], Usage::Client);
    let garage = pki.issue("garage", &[], Usage::Client);
    assert!(connect(pki.client(&kitchen), server.clone()).is_ok());

    // The CRL changes: the same server configuration refuses at once.
    let serial = summarize(&kitchen.certificate).unwrap().serial;
    let crl = pki.ca.revocation_list(&[serial], 30).unwrap();
    *revocations.write().unwrap() = Revocations::load(&crl, &pki.ca_certificate).unwrap();
    let error = connect(pki.client(&kitchen), server.clone()).unwrap_err();
    assert!(
        error.starts_with("server:") && error.contains("Revoked"),
        "{error}"
    );
    assert!(
        connect(pki.client(&garage), server.clone()).is_ok(),
        "only kitchen"
    );

    *revocations.write().unwrap() = Revocations::none();
    assert!(connect(pki.client(&kitchen), server).is_ok());
}

#[test]
fn a_certificate_without_an_identity_is_refused() {
    let pki = Pki::new("Test CA");
    let server = pki.server(
        &pki.issue("server-1", &[], Usage::Server),
        Revocations::none().shared(),
    );

    // Signed by the right CA, but not by Ca::issue: no identity extension.
    let ca_key = rcgen::KeyPair::from_pem(&pki.ca_key).unwrap();
    let issuer = rcgen::Issuer::from_ca_cert_pem(&pki.ca_certificate, ca_key).unwrap();
    let key = rcgen::KeyPair::generate_for(&rcgen::PKCS_ECDSA_P384_SHA384).unwrap();
    let mut params = rcgen::CertificateParams::default();
    params.extended_key_usages = vec![rcgen::ExtendedKeyUsagePurpose::ClientAuth];
    let certificate = params.signed_by(&key, &issuer).unwrap().pem();

    let client = tls::client_config(
        &pki.ca_certificate,
        &certificate,
        &key.serialize_pem(),
        Revocations::none().shared(),
    )
    .unwrap();
    let error = connect(client, server).unwrap_err();
    assert!(error.starts_with("server:"), "{error}");
}

#[test]
fn another_protocol_is_refused() {
    let pki = Pki::new("Test CA");
    let server = pki.server(
        &pki.issue("server-1", &[], Usage::Server),
        Revocations::none().shared(),
    );
    let client = pki.issue("kitchen", &[], Usage::Client);
    let mut config = (*pki.client(&client)).clone();
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    let error = connect(Arc::new(config), server).unwrap_err();
    assert!(error.starts_with("server:"), "{error}");
}

#[test]
fn bad_files_are_told() {
    let pki = Pki::new("Test CA");
    let client = pki.issue("kitchen", &[], Usage::Client);
    let none = || Revocations::none().shared();
    assert!(tls::client_config("", &client.certificate, &client.key, none()).is_err());
    assert!(tls::client_config(&pki.ca_certificate, "", &client.key, none()).is_err());
    assert!(tls::client_config(&pki.ca_certificate, &client.certificate, "", none()).is_err());
    assert!(peer_identity(None).is_err());
}

#[test]
fn clients_given_a_crl_refuse_revoked_servers() {
    let pki = Pki::new("Test CA");
    let server = pki.issue("server-1", &[], Usage::Server);
    let client = pki.issue("kitchen", &[], Usage::Client);
    let config = pki.server(&server, Revocations::none().shared());
    assert!(connect(pki.client(&client), config.clone()).is_ok());
    let error = connect(
        pki.client_checking(&client, pki.revoking(&[&server])),
        config,
    )
    .unwrap_err();
    assert!(
        error.starts_with("client:") && error.contains("Revoked"),
        "{error}"
    );
}

#[test]
fn servers_block_each_other() {
    let pki = Pki::new("Test CA");
    let first = pki.issue("server-1", &["peer"], Usage::Server);
    let second = pki.issue("server-2", &["peer"], Usage::Server);
    let crl = pki.revoking(&[&second]);
    // server-1 has the CRL: it refuses server-2 both ways.
    let error = connect(pki.client(&second), pki.server(&first, crl.clone())).unwrap_err();
    assert!(
        error.starts_with("server:") && error.contains("Revoked"),
        "{error}"
    );
    let error = connect(
        pki.client_checking(&first, crl),
        pki.server(&second, Revocations::none().shared()),
    )
    .unwrap_err();
    assert!(
        error.starts_with("client:") && error.contains("Revoked"),
        "{error}"
    );
}

#[test]
fn same_named_servers_have_their_own_certificates() {
    let pki = Pki::new("Test CA");
    let first = pki.issue("server-1", &["peer"], Usage::Server);
    let second = pki.issue("server-1", &["peer"], Usage::Server);
    assert_ne!(first.certificate, second.certificate);
    assert_ne!(
        summarize(&first.certificate).unwrap().serial,
        summarize(&second.certificate).unwrap().serial
    );
    let client = pki.issue("kitchen", &[], Usage::Client);
    for server in [&first, &second] {
        assert!(
            connect(
                pki.client(&client),
                pki.server(server, Revocations::none().shared())
            )
            .is_ok()
        );
    }

    // Revoking one leaves the other alone, as a server and as a client.
    let crl = pki.revoking(&[&first]);
    let checking = pki.client_checking(&client, crl.clone());
    assert!(
        connect(
            checking.clone(),
            pki.server(&first, Revocations::none().shared())
        )
        .is_err()
    );
    assert!(connect(checking, pki.server(&second, Revocations::none().shared())).is_ok());
    let gate = pki.server(&pki.issue("server-2", &[], Usage::Server), crl);
    assert!(connect(pki.client(&first), gate.clone()).is_err());
    assert!(connect(pki.client(&second), gate).is_ok());
}
