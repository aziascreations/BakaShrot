# Certificates - X.509 with Ed25519

Status (2026-11-13): an include in `Commons/Cryptography/`, tested on its
own and against OpenSSL, **not used by anything yet**. Next: a tool that
generates certificates, then the server and the client loading and
checking them (see the end).

## Why it's written here

- **libsodium has no X.509 or ASN.1**, so the DER and the certificate
  structure are PureBasic (`Der.pbi`, `X509.pbi`). Every bit of
  cryptography is still libsodium's: Ed25519 signatures, SHA-256 (key ids,
  fingerprints), random serials, Base64 (PEM) and hex, seeds to key pairs
  (PKCS#8).
- **Not the OS's APIs:** Windows' CryptoAPI can't check Ed25519
  certificates, and the identity keys are Ed25519 already. Not OpenSSL
  either: another library to ship and load on both OSes, for what's a few
  hundred lines of DER. One code for Windows and Linux.
- **Standard certificates all the same:** OpenSSL reads them, verifies
  chains of them, reads the private keys, and they read and check OpenSSL's
  (`Tests/X509-Test.ps1`).

## Files

| File | What |
|---|---|
| `Commons/Cryptography/Der.pbi` | ASN.1 DER: a reader (strict) and a writer, integers, OIDs (any arc size), times, strings, bit strings. |
| `Commons/Cryptography/X509.pbi` | Certificates: reading, issuing, checking, PEM, PKCS#8 private keys. Includes `Der.pbi` and `Libsodium.pbi`. |
| `Tests/X509Test.pb` | 131 checks on its own, 145 with OpenSSL's certificates. |
| `Tests/X509-Test.ps1` | Runs it, makes OpenSSL's certificates for it, checks its own with OpenSSL. |

## Reading

- `BakaShrot_X509_Parse(*Der, Size)`, `_ParsePem(Text)`, `_Load(Path)`
  (PEM or DER, by its first byte) give a `BakaShrot_X509Certificate`, freed
  with `BakaShrot_X509_Free()`. Failures give 0 and a code.
- **Any certificate is read** (RSA, ECDSA...): version, serial, names,
  validity, algorithms, every extension. Only Ed25519 ones have their key
  and signature (`HasEd25519Key`, `HasEd25519Signature`), and only they can
  be checked or issue others (`Unsupported` otherwise).
- **Strict DER:** shortest lengths and integers, no indefinite lengths, real
  dates, no NUL in strings, the inner and outer signature algorithms the same
  bytes, an extension once at most, v1 never written as such, nothing after
  the certificate. A reader never reads past its buffer. Every truncation of
  a certificate is refused, and of its 503 one-bit flips, the 335 that still
  parse all fail the checks.
- **Known extensions** fill fields: BasicConstraints (`IsCa`,
  `PathLength`), KeyUsage (`KeyUsage`, `#BakaShrot_X509_KeyUsage_*` flags),
  the key ids (`SubjectKeyId`, `AuthorityKeyId`, hex). The others stay as
  they are (`Extensions()`: OID, critical, DER value).
- Names keep their attributes in order (`Subject\Attributes()`): OID, text,
  string type, RDN index. `BakaShrot_X509_NameGet(@\Subject, "CN")`,
  `_NameToString()` ("CN=kitchen, OU=clients").

## Issuing

`BakaShrot_X509_Issue(*Template, *Issuer, *IssuerPrivateKey, *OutSize)`,
the issuer 0 for a self-signed one. The template: subject, validity, the
subject's public key, CA or not and its path length, key usage, the custom
extensions. It writes:

- v3, a random positive 16-byte serial (or the template's), Ed25519.
- The issuer's subject as the issuer certificate encodes it (so names match
  byte for byte).
- Names one attribute per RDN: `C` as a PrintableString (2 letters),
  `emailAddress` and `DC` as IA5String, the rest UTF8String.
- UTCTime from 1950 to 2049, GeneralizedTime otherwise (RFC 5280).
- BasicConstraints (critical, always), KeyUsage (critical, if any), the
  subject's key id (the first 20 bytes of the key's SHA-256, RFC 7093) and
  the issuer's, then the template's extensions in order.

It refuses: a private key that isn't the issuer's (or the subject's when
self-signed), an issuer that isn't a CA or lacks keyCertSign, a path length
on a leaf, NotAfter before NotBefore, a name it can't write.

## Checking

Each returns `#BakaShrot_X509_Ok` (0) or what's wrong
(`BakaShrot_X509_ErrorName()`): BadSignature, NotYetValid, Expired,
IssuerMismatch, NotCa, PathTooLong, UnknownCritical, Unsupported...

- `BakaShrot_X509_CheckIssuedBy(*Cert, *Issuer, Now, Handled)`: one link.
  The issuer names match (as encoded), the key ids too when both have one,
  the issuer may issue, the signature is its key's, `*Cert` is valid at
  `Now` (both ends included), no critical extension is left unhandled.
- `BakaShrot_X509_VerifyChain(Chain(), *Root, Now, Handled)`: the leaf
  first, then each issuer up to the one the trusted `*Root` issued. Every
  link as above, the root valid and a CA, the path lengths kept.
- `_CheckSignature()`, `_CheckValidity()`, `_CanIssue()`,
  `_CheckCriticalExtensions()` on their own.
- `Now` is seconds since 1970 UTC: `BakaShrot_X509_Now()`.
- `Handled` lists the critical extensions the caller understands
  (`"oid;oid"`). RFC 5280: a critical extension a reader doesn't know makes
  the certificate unusable.

## Custom extensions

- **BakaShrot's OID arc:** `#BakaShrot_Oid_Arc`,
  `2.25.232025699926348910519219903487382490981`, a UUID OID (ITU-T X.667),
  which needs no registration (made from a random UUID, 2026-11-13). It
  could be swapped for a registered enterprise number (`1.3.6.1.4.1.<PEN>`)
  as long as no certificate was issued for real with it.
- **Extensions:** `#BakaShrot_Oid_Extensions` (the arc + `.1`) + `.<n>`,
  numbered as they're defined, a number never reused. None is defined yet;
  the tests use 9000 and up.
- **Writing:** `BakaShrot_X509_AddTextExtension(@Template, Oid, Text)`
  (UTF8String), `_AddIntegerExtension()`, `_AddExtension()` (any one DER
  element, a `BakaShrot_DerWriter` makes them), critical or not.
- **Reading:** `BakaShrot_X509_GetExtensionText()`,
  `_GetExtensionInteger()`, or `_FindExtension()` and the raw value.
- **Critical or not:** critical means "refuse me if you don't know me". For
  fields only BakaShrot reads, non-critical is the usual choice; critical
  if a reader that ignores it would grant too much (then pass it in
  `Handled`).
- OpenSSL writes them too (`<oid> = ASN1:UTF8String:...` in an extensions
  file, as the test does), and shows them by OID.

## Private keys and PEM

- `BakaShrot_X509_PrivateKeyToPem()` / `_PrivateKeyFromPem()`: PKCS#8
  (RFC 8410), what `openssl genpkey -algorithm ed25519` writes, not
  encrypted. Reading takes v1 and v2 (with the public key, which must
  match). The seed and the DER are wiped after use.
- `BakaShrot_Pem_Encode()` / `_Decode()` for any label, LF line endings;
  CRLF, spaces and text around the block are fine on reading.

## Threads

No globals. A parsed certificate is only read once made, and its names and
extensions are arrays, not lists (`ForEach` moves a list's current element,
see `CLAUDE.md`): any number of threads may check against the same CA.

## Not done

- **Using it:** a tool generating a CA, server and client certificates and
  keys; the server and client loading them, checking the other end's. How
  they'd fit the handshake (what replaces or joins the `PublicKeys` lists,
  the ClientHello carrying a certificate, the 4 KB handshake frame limit) is
  to decide with the client auth rework: a protocol change either way.
- **Revocation:** no CRL or OCSP. Short validities, or a list of revoked
  serials or fingerprints in the configs, if it's ever needed.
- **Not interpreted:** SubjectAltName, ExtendedKeyUsage, NameConstraints,
  policies. They're read as raw extensions; marked critical (NameConstraints
  usually is), they make a certificate refused unless in `Handled`.
- **Names are matched as encoded**, byte for byte, not with RFC 5280's
  case-insensitive comparison. Fine for certificates issued here, which
  copy the issuer's encoding; another CA's could differ in string types.
- Multi-valued RDNs are read, not written (one attribute per RDN).
  Encrypted PKCS#8, certificate requests (CSR): not done.
- `BakaShrot_X509_Now()` repeats `BakaShrot_NowUtcMs()`
  (`Server/Storage/Storage.pbi`) in seconds, so `Commons/` doesn't depend on
  the server: one could move to `Commons/` for both.
- Tested on Windows (5.73, 6.40 C) only so far; the Linux side
  (`gettimeofday`, `-lsodium`) is the same code as elsewhere but unrun.
