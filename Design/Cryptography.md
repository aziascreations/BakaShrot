# Cryptography - what's done, what isn't

Status (protocol 3, 2026-11-08): every connection is encrypted and
authenticated, and both ends prove who they are.

- The client seals its Hello for the server's public key: only that server
  can read it, and nobody watching learns who connects.
- Both ends make a key pair for this connection, sign the exchange with
  their identity keys, and get the connection's keys from it.
- Everything after the ChallengeRequest is encrypted, both ways.

Still not done: messages aren't signed by the node that wrote them, and
keys sit in plain-text ini files (see the end).

## Library

- **libsodium 1.0.22**, the official MSVC release's dynamic build.
  - `Build.ps1` extracts it from `Libs/libsodium-1.0.22-msvc.zip` to
    `Libs/libsodium/{x64,x86}/`, and copies `libsodium.dll` next to the
    programs.
  - Linux would link `-lsodium` instead (untested).
  - It needs the Visual C++ runtime (`vcruntime140.dll`), packaged with the
    release from `Libs/redist/` (`Libs/redist/README.md`).
- **Wrappers:** `Commons/Cryptography/Libsodium.pbi` is the only file that
  imports it. On top of it, nothing else calls libsodium:
  - `Cipher.pbi`: encrypting and decrypting buffers with a connection's keys.
  - `Session.pbi`: the handshake's part, the sealed Hello and the key
    exchange.
  - The handshake itself, what's signed and in which order, is in
    `Commons/Networking/Connections.pbi`.
- **Imported functions:**

| libsodium | Wrapper | Notes |
|---|---|---|
| `sodium_init` | `InitCryptography()` | Called before any use; repeated calls are fine. |
| `crypto_sign_keypair` | `GenerateKeyPair()` | Used by `Tools/KeyGen`. |
| `crypto_sign_detached` | `EncodeData()`, `BakaShrot_SignHandshake()` | **Signs**, the name `EncodeData` is wrong. |
| `crypto_sign_verify_detached` | `DecodeData()`, `BakaShrot_VerifyHandshake()` | **Verifies**, the name `DecodeData` is wrong. |
| `crypto_sign_ed25519_sk_to_pk` | `GetPublicKeyFromPrivateKey()` | Lets a server only keep its private key in its config. |
| `crypto_sign_ed25519_pk_to_curve25519` / `_sk_to_curve25519` | `BakaShrot_Session_SealHello()` / `_LoadHelloKeys()` | The X25519 key of an Ed25519 identity, for the sealed Hello. |
| `crypto_box_seal` / `_seal_open` | `BakaShrot_Session_SealHello()` / `_OpenHello()` | The Hello, sealed for the server. |
| `crypto_kx_keypair` | `BakaShrot_Session_NewKeyPair()` | One per connection and end. |
| `crypto_kx_client_session_keys` / `_server_session_keys` | `BakaShrot_Session_StartClient()` / `_StartServer()` | A key per direction, into the cipher. |
| `crypto_aead_xchacha20poly1305_ietf_encrypt` / `_decrypt` | `BakaShrot_Cipher_Encrypt()`, `_EncryptTo()` / `_Decrypt()` | Every packet after the ChallengeRequest. |
| `crypto_aead_xchacha20poly1305_ietf_keygen` | `BakaShrot_Cipher_GenerateKey()` | Tests only, real keys come from the handshake. |
| `sodium_memzero` | `BakaShrot_Cipher_Clear()`, the `_Clear*()` of `Session.pbi` | Wipes keys. |

- **Base64 helpers**, in `Libsodium.pbi`:
  - `EncodeKeyToString()` encodes a key or signature.
  - `DecodeKeyFromString()` refuses anything that doesn't decode to exactly
    the expected size.

## Keys

- **Identity keys: Ed25519.** A private key is 64 bytes (libsodium's
  format: the seed followed by the public key), a public key 32, a
  signature 64. One key both signs and receives the sealed Hello (its X25519
  form, libsodium's conversion).
- **Stored as Base64 in ini files, in plain text:**
  - A server's own key: `[BakaShrot] PrivateKey`. The server logs its
    public key when it starts.
  - Who it trusts: `[BakaShrot.Client.<name>] PublicKeys` and
    `[BakaShrot.Peer.<name>] PublicKey`. The peer's is also the server it
    expects at the other end of its link, so it's required.
  - A client's: whatever the app passes to `BakaShrot_SetPrivateKey()`,
    `BakaShrot_SetPublicKey()` and `BakaShrot_SetServerPublicKey()` (the
    server's). The tools and `bakashrot.py` read them from `client.ini`:
    `PrivateKey`, `PublicKey`, `ServerPublicKey`.
- **Connection keys: X25519**, made for each connection by both ends, the
  secrets wiped once the cipher has its keys. So a recorded connection
  can't be decrypted later, even with both identity keys (forward secrecy).
- **Generated** by `Tools/KeyGen`, which `Build.ps1` runs on every build.
- **Wiping:**
  - Wiped from memory after use: KeyGen; a server's key when it stops, and
    its peer links'; every connection's keys when it ends.
  - Not wiped: the client DLL's global copy of its private key, and the
    config structures holding the Base64 text.
- **No rotation or revocation**, other than editing the configs and
  restarting.

## Randomness

The challenge (32 bytes) and the nonce (32 bytes) come from PureBasic's
`OpenCryptRandom()` / `CryptRandomData()`, which use the OS's secure
generator. The connection key pairs and the sealed Hello's throwaway key
come from libsodium's.

## The handshake

See `Design/Packets.md` for the packets, `Connections.pbi` for the code.
The client knows the server's public key beforehand.

1. **Hello, sealed** (`crypto_box_seal` for the server's key): the client's
   identity (topic, node), its Base64 public key, and the public half of a
   key pair it made for this connection.
2. The server opens it (another server can't: abort), decodes the key and
   checks that a `[BakaShrot.Client.<name>]` lists both this key and this
   identity.
3. **ChallengeRequest, in plain text:** a fresh random challenge and nonce,
   the public half of the server's own pair for this connection, and the
   server's signature of the transcript.
4. The client checks the signature with the server's public key: it's the
   right server, and nobody swapped a half on the way. Both ends get the
   connection's keys from both pairs (`crypto_kx`), every packet from here
   on is encrypted (the cipher, below).
5. **ChallengeResponse:** the client signs the transcript, and echoes the
   nonce.
6. The server checks the nonce is the one it issued for this connection,
   and the signature against the key from the Hello. **AuthAccepted.**

**The transcript** (`BakaShrot_HandshakeTranscript`, 208 bytes) is what
both sign: a label (`"BakaShrot3 srv"` or `"BakaShrot3 cli"`, padded to 16
bytes, so one end's signature can't pass as the other's), the client's and
the server's identity keys, both halves, the challenge and the nonce. So
each signature only holds for this connection, between these two.

What that gets, and why:
- **Only the right server gets anywhere.** The Hello is sealed for it, and
  the client won't send anything else until the server signed this
  connection's halves with the key the client expects.
- **Only the registered client authenticates.** Same as before: it signs
  the challenge, now along with the halves.
- **Nobody in the middle.** Swapping a half breaks a signature; relaying
  untouched gets the relay nothing, it doesn't have the secrets.
- **Replays fail.** A replayed Hello gets a fresh challenge and server half,
  which the replayer can't answer: the client's half is the client's. A
  replayed packet later fails the cipher's sequence check.
- **Hijacking an authenticated connection fails:** an injected packet
  doesn't decrypt, the connection is aborted.
- **Hidden from someone watching:** who connects (sealed Hello) and
  everything after the ChallengeRequest. Not hidden: that it's BakaShrot,
  the server's half and signature, packet sizes and timing.

The nonce is redundant with the challenge (both are fresh, random, and
signed), but it's harmless and kept as designed.

## The cipher (`Commons/Cryptography/Cipher.pbi`)

The crypto of the data itself, so no packet handler or framing code has to
do any: a `BakaShrot_Cipher` per connection holds the keys, then takes
buffers. `BakaShrot_ConnectionMetadata\Cipher`, set up by the handshake.

- **`BakaShrot_Cipher_InitWithKeys(*Cipher, *SendKey, *ReceiveKey)`**: a key
  per direction, as the handshake gives them (refuses the same key twice).
  Or **`_Init(*Cipher, *Key, Role)`**, one key shared by both ends, `Role`
  `#BakaShrot_Cipher_Client` or `#BakaShrot_Cipher_Server`.
- **`BakaShrot_Cipher_Encrypt(*Cipher, *Data, Size, *OutSize)`** returns a new
  buffer: `[sequence number, 8 bytes][encrypted data][16-byte tag]`, 24 bytes
  more than the data (`#BakaShrot_Cipher_Overhead`). `_EncryptTo()` writes it
  into a given buffer (the frame, in `BakaShrot_SendPacket()`).
- **`BakaShrot_Cipher_Decrypt(*Cipher, *Sealed, Size, *OutSize)`** returns the
  data in a new buffer, or 0: then abort the connection.
- **`BakaShrot_Cipher_Clear(*Cipher)`** wipes the keys once done.

What it guarantees: nobody without the key reads, changes, forges or
truncates a buffer (XChaCha20-Poly1305, libsodium's AEAD), and nobody
replays, reorders, drops or reflects one: each carries its sequence number,
the receiver only takes the next one, and each direction has its own key
(or its own nonces with one key). Nonces never repeat within a key: a key is
only ever used for one connection.

Why XChaCha20-Poly1305 with sequence numbers rather than
`crypto_secretstream_*`: same primitives, but the buffers stay independent
(no stream state beyond the counter), the format is simple to describe in
`Design/Packets.md`, and replay/reorder protection comes from the sequence
check, which TCP's ordering makes strict.

**Where it's used:** in the framing, so the packets don't know about it.
`BakaShrot_SendPacket()` encrypts when given the connection's cipher (0 only
for the Hello and the ChallengeRequest), `BakaShrot_OpenFrame()` decrypts a
frame once the cipher is set up. On the server, the client's own thread
decrypts, outside the server's mutex; the listener only gathers bytes.
Frames are up to `#BakaShrot_MaxPacketSize + #BakaShrot_Cipher_Overhead`
once authenticated.

## Tests

- `Tests/CipherTest.pb` (56 checks, PB 5.73 and 6.40's C backend), without
  sockets:
  - The cipher: both directions, a bit flipped at every byte refused, cut
    short, replayed, reordered, reflected to its sender or to another client
    with the same key, another key, empty data, 16 MB (~33 ms both ways),
    two keys, clearing, `_EncryptTo()`.
  - The session: a sealed Hello only its server opens, without the identity
    showing, tampered or cut short refused, an invalid server key refused;
    the key exchange agrees both ways, a key per direction, the pairs wiped,
    a swapped half or another connection's keys don't decrypt, an all-zero
    half refused.
- `Tests/wire_check.py`, run by `Tests/Python-Test.ps1`: a proxy between
  the client and the server records every byte. The pushed message, the
  client's topic, node and public key never show up in it; a byte flipped
  after the handshake drops the connection ("doesn't decrypt" in the
  server's log); another server's public key can't connect ("isn't sealed
  for this server").
- `Tests/HandshakeTest.pb`: the handshake packets' fields, without crypto.
- Every end-to-end test (`Tests/*.ps1`, the release's smoke test) runs over
  encrypted connections, peer links included.

## What's NOT done (in rough order of importance)

1. **Messages aren't signed by the node that first wrote them,** so
   replicated data can't be verified: a peer is trusted with what it sends
   (`Design/ReplicationIssues.md`, issue 3).
2. **Private keys sit in plain-text ini files.**
3. **No key rotation or revocation**, and no way to pin more than one key
   for a server (to change it without a flag day).
4. **One identity key signs and opens sealed boxes** (its X25519 form).
   libsodium supports it and it's a common pattern, but a separate key for
   each would be cleaner.
5. **Anyone can make the server work a little:** each new connection costs
   it opening a sealed box, a key pair and a signature before the client
   proved anything (before: one signature check). Only the 4 KB handshake
   limit and the timeout bound it, no rate limit.
6. **The client DLL doesn't wipe its private key**, nor the configs their
   Base64 text.

## Ideas for when it gets abstracted

- **A small interface**, so libsodium can be swapped or wrapped without
  touching the networking: `Sign`, `Verify`, `GenerateKeyPair`,
  `PublicKeyFromPrivateKey`, `Random`, plus `Session.pbi` and `Cipher.pbi`
  as they are. Rename `EncodeData`/`DecodeData` to `Sign`/`Verify` while at
  it.
- **Per-message signatures** by the origin node, stored with the message and
  checked on replication, for item 1.
