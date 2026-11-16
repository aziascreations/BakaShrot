# Certificates

Who connects to whom, and how it's checked. The code is
`crates/bakashrot-pki` (the library) and `crates/bakashrot-tools`
(`bakashrot-cert`, the tool). Decided in `../revamp.md`, "Decided".

## The idea

One CA per deployment. Every client and every server has a certificate
from it, saying who it is: a node's name and its roles. Servers trust the
CA, not lists of keys; clients trust the CA, not a server's key. Revoking
is a CRL file from the CA, pushed to the servers.

## Certificates

- **Keys:** ECDSA P-384, signatures SHA-384 (the strongest rustls checks).
- **The identity**, an extension of BakaShrot's own, non-critical (rustls
  refuses critical extensions it doesn't know):

  ```
  BakaShrotIdentity ::= SEQUENCE {
      version  INTEGER,                  -- 1
      name     UTF8String,               -- the node: "kitchen"
      roles    SEQUENCE OF UTF8String    -- free: "sensor", "peer"...
  }
  ```

  Names and roles follow the name rules (1-64 of `A-Z a-z 0-9 _ . -`, not
  only digits), 64 roles at most. Roles mean nothing to the certificates:
  the server's config says what each may do.
- **Its OID is `1.3.6.1.4.1.67681.1.1`** (`IDENTITY_OID`), under
  NibblePoker's own PEN (67681), since 0.3.0. Certificates made before
  (a placeholder OID) aren't read: issue them again. The branches:
  `oid.md`.
- **The CN is the name too**, for people (`openssl x509 -text`, logs). Only
  the extension is trusted.
- **Clients' certificates** are for `clientAuth`. **Servers'** are for
  `serverAuth` and `clientAuth` (a server is its peers' client), and have
  one DNS name, `bakashrot-server` (`SERVER_NAME`): a label, not a host.
- **No host names or IPs:** a client connects to any address and asks for
  `bakashrot-server`; rustls' own verifier then checks the server's
  certificate is the CA's, valid, not revoked... and for servers. A
  client's certificate can't pose as a server's: it isn't for `serverAuth`
  and doesn't have the name.
- **Lifetimes:** the CA 10 years, the others 1 year, by default.
- **The CA's key stays off the servers:** whoever has it can make any
  identity, peers included.

## TLS

`bakashrot_pki::tls`: TLS 1.3 only, through aws-lc, offering only the
strongest of everything (both ends are ours, nothing to negotiate down to):

- cipher suite `TLS13_AES_256_GCM_SHA384`;
- key exchange `X25519MLKEM768`, the X25519 + ML-KEM hybrid (holds against
  quantum computers too);
- ALPN `bakashrot`: what isn't BakaShrot is refused in the handshake (the
  protocol's version is checked right after, `protocol.md`);
- a certificate from the CA on both ends;
- randomness (keys, nonces) from the OS: aws-lc's generator seeded from
  Windows' `ProcessPrng` or Linux's `getrandom`, plus RDRAND, as BoringSSL
  and `ring` do. Built without its CPU Jitter Entropy
  (`AWS_LC_SYS_NO_JITTER_ENTROPY`, `../.cargo/config.toml`), which only adds
  a source and cost 25 ms in every process, at its first connection.

`server_config()` checks clients with rustls' verifier, `client_config()`
checks the server with rustls' verifier too (for `bakashrot-server`). Then
both check the certificate isn't revoked and has an identity. Once
connected, `peer_identity()` gives the other end's `Identity`.

## Revocation

- `bakashrot-cert revoke` writes `ca.crl`, signed by the CA, with every
  certificate revoked before (written aside, then moved in place).
- A server reads it into `Revocations`, which its TLS setup shares
  (`SharedRevocations`): replacing what's inside takes effect for the next
  handshake, no new configuration needed. `Revocations::revokes()` tells
  the server which open connections to drop.
- **Both ends check it:** `server_config()` and `client_config()` both take
  the revocations (`Revocations::none()` without a CRL, or when the
  server's config or `client.toml` names a CRL file that isn't there
  yet: never blocking, the server warns in its log; a path given to
  the DLL is a `FileError`). A server dialing its peer is the peer's
  client, with the same CRL: servers block each other, whichever end
  dials.
- **Revoking is by certificate, not by name:** each certificate has its own
  key and its own serial number (made from that key), so two of the same
  name (two servers named alike, a new one before the old one goes) are
  revoked one at a time.
- A CRL is only taken if it's the CA's: issued by it, its signature
  checked. One that isn't is refused, the server keeps the previous one.
  Its "next update" isn't held against it: CRLs are pushed by hand.
- The server watches the file (its time and size, every 5 s), reloads
  it, and drops a revoked certificate's connection at its next request
  (`server.md`).

## The tool

```
bakashrot-cert ca --name "Home CA"                       ca.crt, ca.key
bakashrot-cert issue --name kitchen --role sensor        kitchen.crt, kitchen.key
bakashrot-cert issue --name server-1 --role peer --server
bakashrot-cert revoke kitchen.crt                         ca.crl
bakashrot-cert show kitchen.crt
```

`--ca` (the folder of `ca.crt` / `ca.key`, `.` by default), `--out` (where
to write), `--days`, `--file` (the files' name when it isn't the node's:
another certificate of the same name, `--file server-1b`). Files are
PEM. Nothing is ever written over an existing certificate or key, and a
certificate and its key are written both or neither (one of them there
already: nothing written); keys are readable by their owner only on
Unix. `revoke` only takes certificates the CA issued.

## Tests

- `bakashrot-pki/tests/tls.rs`: handshakes in memory. The strongest
  settings negotiated, identities both ways, a server as its peer's
  client; refused: a client or a server of another CA, a client's
  certificate posing as a server's, a revoked client (and taken again once
  the CRL changes, on the same configuration), a certificate without an
  identity, another protocol; clients given the CRL refusing a revoked
  server, servers blocking each other both ways, two servers of the same
  name each with its own certificate, revoked one at a time.
- `bakashrot-pki/tests/ca.rs`: what certificates say, a CA's key that isn't
  its own, CRLs revoking exactly what they list, another CA's or a
  tampered CRL refused, and OpenSSL agreeing (`openssl verify` for clients
  and servers, the CRL's signature, a revoked certificate; skipped without
  OpenSSL, Git's is found).
- `bakashrot-tools/tests/cert.rs`: the tool end to end, two certificates
  of the same name, and what it refuses (overwriting, bad names and roles,
  another CA's certificate).

## For later

- **`AllowedServerNames`** in a client's config and for the peers a
  server dials: the server names it accepts (any of the CA's servers
  without it).
