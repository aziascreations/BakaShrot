; ============================================================================
; BakaShrot Cryptography
;
; Ed25519 signatures via libsodium (this does NOT reimplement any
; cryptographic primitive).
;
; EncodeData signs a buffer with the sending node's own private key.
; DecodeData checks that signature against the claimed sender's public key.
; (Misnamed: they sign and verify, nothing is encoded or decoded.)
;
; The signatures prove each end's identity in the handshake. The sealed
; boxes, key exchange and XChaCha20-Poly1305 below encrypt the connections:
; Session.pbi and Cipher.pbi use them, nothing else should.
; What's done, what isn't, and the plan to abstract it:
; Design/Cryptography.md.
;
; Key material:
;   - Public key:  #BakaShrot_Ed25519_PublicKeySize  (32) raw bytes.
;   - Private key: #BakaShrot_Ed25519_PrivateKeySize (64) raw bytes.
;     (libsodium's Ed25519 secret key already embeds the seed and the public
;     key, which is why it is twice the size of the public key.)
; A node's private key lives in BakaShrot_CoreConfig\PrivateKey (Config.pbi);
; the public key it hands out to peers lives in each
; BakaShrot_PeerConfig\PublicKey. Both are stored as Base64 text in the ini
; file - see EncodeKeyToString()/DecodeKeyFromString() below.
;
; Setup required to build/run this:
;   - Windows: the official libsodium MSVC release's dynamic build, extracted
;     to Libs/libsodium/<x64|x86>/ by Build.ps1, and "libsodium.dll"
;     alongside the executable.
;   - Linux:   libsodium-dev (Debian/Ubuntu) or libsodium-devel (Fedora)
;              installed, so "-lsodium" resolves at link time and
;              libsodium.so.* is available at runtime.
; libsodium itself is the same standard, audited library on both platforms,
; so signatures made on one are verifiable on the other without change.
; ============================================================================


#BakaShrot_Ed25519_PublicKeySize  = 32
#BakaShrot_Ed25519_PrivateKeySize = 64
#BakaShrot_Ed25519_SignatureSize  = 64

; XChaCha20-Poly1305 (IETF), libsodium's crypto_aead_xchacha20poly1305_ietf_*:
; encryption and authentication of a buffer with a shared key, used by
; Commons/Cryptography/Cipher.pbi.
#BakaShrot_XChaCha20Poly1305_KeySize   = 32
#BakaShrot_XChaCha20Poly1305_NonceSize = 24
#BakaShrot_XChaCha20Poly1305_TagSize   = 16

; X25519 (crypto_box_seal, crypto_kx_*): sealed Hellos and the key exchange,
; used by Commons/Cryptography/Session.pbi.
#BakaShrot_X25519_PublicKeySize = 32
#BakaShrot_X25519_SecretKeySize = 32
#BakaShrot_SealedBoxOverhead    = 48
#BakaShrot_KxSessionKeySize     = 32


; Windows: the dynamic build's import library, libsodium.dll must be next to
; the program. Both are extracted from Libs/libsodium-*-msvc.zip by Build.ps1.
CompilerIf #PB_Compiler_OS = #PB_OS_Windows And #PB_Compiler_Processor = #PB_Processor_x64
	ImportC "../../Libs/libsodium/x64/libsodium.lib"
CompilerElseIf #PB_Compiler_OS = #PB_OS_Windows
	ImportC "../../Libs/libsodium/x86/libsodium.lib"
CompilerElse
	ImportC "-lsodium"
CompilerEndIf

	; Must be called once (any number of extra calls are harmless) before any
	; other function below is used. Returns 0 on success, 1 if it was already
	; initialized, -1 if libsodium failed to self-check (e.g. no RNG available).
	sodium_init.l()

	; Fills *PublicKey (32 bytes) and *PrivateKey (64 bytes) with a fresh,
	; cryptographically random Ed25519 keypair.
	crypto_sign_keypair.l(*PublicKey, *PrivateKey)

	; Writes a #BakaShrot_Ed25519_SignatureSize-byte signature of *Message
	; (MessageLength bytes) to *Signature, made with *PrivateKey.
	crypto_sign_detached.l(*Signature, *SignatureLength, *Message, MessageLength.q, *PrivateKey)

	; Returns 0 if *Signature is a valid signature of *Message (MessageLength
	; bytes) made by the holder of the private key matching *PublicKey;
	; non-zero otherwise (forged, corrupted, or signed different data).
	crypto_sign_verify_detached.l(*Signature, *Message, MessageLength.q, *PublicKey)

	; Encrypts *Message (MessageLength bytes) into *Ciphertext (MessageLength +
	; #BakaShrot_XChaCha20Poly1305_TagSize bytes, the tag at the end), with
	; *Key (32 bytes) and *Nonce (24 bytes, never twice with the same key).
	; *AdditionalData (AdLength bytes, may be 0) is authenticated, not
	; encrypted. *Nsec is always 0. Always returns 0.
	crypto_aead_xchacha20poly1305_ietf_encrypt.l(*Ciphertext, *CiphertextLength, *Message, MessageLength.q, *AdditionalData, AdLength.q, *Nsec, *Nonce, *Key)

	; Checks and decrypts *Ciphertext (CiphertextLength bytes, tag included)
	; into *Message (CiphertextLength - TagSize bytes). Returns 0 if it's
	; genuine, -1 if it was tampered with, or made with another key, nonce or
	; additional data: *Message must not be used then.
	crypto_aead_xchacha20poly1305_ietf_decrypt.l(*Message, *MessageLength, *Nsec, *Ciphertext, CiphertextLength.q, *AdditionalData, AdLength.q, *Nonce, *Key)

	; Fills *Key (32 bytes) with a random XChaCha20-Poly1305 key.
	crypto_aead_xchacha20poly1305_ietf_keygen(*Key)

	; Zeroes Length bytes at *Memory, in a way the compiler can't optimize out:
	; for wiping keys.
	sodium_memzero(*Memory, Length.i)

	; Copies the public key embedded in *PrivateKey (64 bytes) into *PublicKey
	; (32 bytes). Always returns 0.
	crypto_sign_ed25519_sk_to_pk.l(*PublicKey, *PrivateKey)

	; The X25519 key (32 bytes) matching an Ed25519 public key (32 bytes) or
	; private key (64 bytes), so one identity key both signs and receives
	; sealed boxes. The public one returns -1 if it isn't a valid key.
	crypto_sign_ed25519_pk_to_curve25519.l(*X25519PublicKey, *Ed25519PublicKey)
	crypto_sign_ed25519_sk_to_curve25519.l(*X25519SecretKey, *Ed25519PrivateKey)

	; Encrypts *Message (MessageLength bytes) for the holder of *PublicKey
	; (X25519) into *Ciphertext (MessageLength + 48 bytes), with a throwaway
	; key pair: only *PublicKey's holder can open it, and it doesn't tell who
	; sealed it. Returns 0, -1 on failure.
	crypto_box_seal.l(*Ciphertext, *Message, MessageLength.q, *PublicKey)

	; Opens *Ciphertext (CiphertextLength bytes) sealed for *PublicKey into
	; *Message (CiphertextLength - 48 bytes). Returns 0, or -1 if it wasn't
	; sealed for this key or was tampered with.
	crypto_box_seal_open.l(*Message, *Ciphertext, CiphertextLength.q, *PublicKey, *SecretKey)

	; Fills *PublicKey and *SecretKey (32 bytes each) with a fresh X25519 key
	; pair, for one key exchange. Returns 0.
	crypto_kx_keypair.l(*PublicKey, *SecretKey)

	; Both ends of a key exchange get the same two 32-byte keys from their own
	; key pair and the other end's public key: *Rx decrypts what this end
	; receives, *Tx encrypts what it sends (the client's Tx is the server's
	; Rx). Return -1 if the other end's public key isn't acceptable.
	crypto_kx_client_session_keys.l(*Rx, *Tx, *ClientPublicKey, *ClientSecretKey, *ServerPublicKey)
	crypto_kx_server_session_keys.l(*Rx, *Tx, *ServerPublicKey, *ServerSecretKey, *ClientPublicKey)

	; SHA-256, a piece at a time: _init() a state (crypto_hash_sha256_statebytes()
	; bytes), _update() it with each piece, _final() writes the 32-byte hash.
	; For the attachments' checksums, see BakaShrot_Sha256_* below.
	crypto_hash_sha256_statebytes.i()
	crypto_hash_sha256_init.l(*State)
	crypto_hash_sha256_update.l(*State, *Data, DataLength.q)
	crypto_hash_sha256_final.l(*State, *Hash)

EndImport


; Must be called once at startup, before GenerateKeyPair/EncodeData/DecodeData.
; Returns #False if libsodium could not initialize - treat that as fatal,
; there is no safe fallback to running without it.
Procedure.i InitCryptography()
	ProcedureReturn Bool(sodium_init() >= 0)
EndProcedure


; Generates a new Ed25519 keypair for provisioning a node.
; *PublicKey must point to #BakaShrot_Ed25519_PublicKeySize bytes,
; *PrivateKey to #BakaShrot_Ed25519_PrivateKeySize bytes.
Procedure GenerateKeyPair(*PublicKey, *PrivateKey)
	crypto_sign_keypair(*PublicKey, *PrivateKey)
EndProcedure


; Fills *PublicKey (#BakaShrot_Ed25519_PublicKeySize bytes) with the public
; key matching *PrivateKey (#BakaShrot_Ed25519_PrivateKeySize bytes), so a
; node only needs its private key in its config.
Procedure GetPublicKeyFromPrivateKey(*PrivateKey, *PublicKey)
	crypto_sign_ed25519_sk_to_pk(*PublicKey, *PrivateKey)
EndProcedure


; Signs *Data (DataLength bytes) with *PrivateKey (this node's own private
; key, #BakaShrot_Ed25519_PrivateKeySize bytes).
; Writes the signature to *Signature, which must point to
; #BakaShrot_Ed25519_SignatureSize bytes. *Data itself is left untouched.
Procedure.i EncodeData(*Data, DataLength.i, *PrivateKey, *Signature)
	Protected SignatureLength.q
	ProcedureReturn Bool(crypto_sign_detached(*Signature, @SignatureLength, *Data, DataLength, *PrivateKey) = 0)
EndProcedure


; Verifies that *Signature (#BakaShrot_Ed25519_SignatureSize bytes) is a
; valid signature of *Data (DataLength bytes), made by the holder of the
; private key matching *PublicKey (the claimed sender's public key, from
; BakaShrot_PeerConfig\PublicKey).
; Returns #True only if the signature checks out. On #False, reject the
; packet outright - do not process it, do not fall back to trusting it.
Procedure.i DecodeData(*Data, DataLength.i, *PublicKey, *Signature)
	ProcedureReturn Bool(crypto_sign_verify_detached(*Signature, *Data, DataLength, *PublicKey) = 0)
EndProcedure


; SHA-256 of data given a piece at a time (an attachment's parts): Start, Add
; each piece, then Finish writes the 32-byte hash.
#BakaShrot_Sha256_HashSize = 32

Structure BakaShrot_Sha256
	; crypto_hash_sha256_state is 104 bytes, checked by Start.
	State.a[128]
EndStructure

; Returns #False if libsodium's state doesn't fit (a libsodium change).
Procedure.i BakaShrot_Sha256_Start(*Hash.BakaShrot_Sha256)
	If crypto_hash_sha256_statebytes() > SizeOf(BakaShrot_Sha256)
		ProcedureReturn #False
	EndIf
	ProcedureReturn Bool(crypto_hash_sha256_init(*Hash) = 0)
EndProcedure

Procedure BakaShrot_Sha256_Add(*Hash.BakaShrot_Sha256, *Data, Size.i)
	If Size > 0
		crypto_hash_sha256_update(*Hash, *Data, Size)
	EndIf
EndProcedure

Procedure BakaShrot_Sha256_Finish(*Hash.BakaShrot_Sha256, *Out)
	crypto_hash_sha256_final(*Hash, *Out)
EndProcedure


; Encodes KeySize raw bytes at *Key as a Base64 string, for storing a key in
; the ini file (PrivateKey / PublicKey fields in Config.pbi).
Procedure.s EncodeKeyToString(*Key, KeySize.i)
	ProcedureReturn Base64Encoder(*Key, KeySize)
EndProcedure


; Decodes KeyString back into KeySize raw bytes at *Key.
; Returns #False (and leaves *Key untouched) if KeyString is not valid
; Base64 or does not decode to exactly KeySize bytes - a malformed or
; truncated key in the config file must never be silently accepted as one
; that's merely different.
Procedure.i DecodeKeyFromString(KeyString.s, *Key, KeySize.i)
	; PureBasic's own docs warn the output buffer must have some slack over
	; the exact decoded size or the decoder can overflow it - at least 25%
	; extra and never under 64 bytes, hence the margin below.
	Protected *Buffer, BufferSize.i, DecodedSize.i

	BufferSize = (KeySize * 5) / 4 + 64
	*Buffer = AllocateMemory(BufferSize)
	DecodedSize = Base64Decoder(KeyString, *Buffer, BufferSize)
	If DecodedSize = KeySize
		CopyMemory(*Buffer, *Key, KeySize)
	EndIf
	FreeMemory(*Buffer)

	ProcedureReturn Bool(DecodedSize = KeySize)
EndProcedure


; Usage example. Only compiled when this file is run directly (F5 in the
; IDE), not when it's included as a module by the rest of the project.
CompilerIf #PB_Compiler_IsMainFile

	If Not InitCryptography()
		Debug "Failed to initialize libsodium."
	Else
		Define *PublicKey    = AllocateMemory(#BakaShrot_Ed25519_PublicKeySize)
		Define *PrivateKey   = AllocateMemory(#BakaShrot_Ed25519_PrivateKeySize)
		Define *Signature    = AllocateMemory(#BakaShrot_Ed25519_SignatureSize)
		Define Message.s     = ~"{\"messageData\": {\"MsgType\": \"hello\"}}"
		Define MessageLength = StringByteLength(Message, #PB_Ascii)
		Define *MessageBytes = AllocateMemory(MessageLength)

		PokeS(*MessageBytes, Message, -1, #PB_Ascii)

		GenerateKeyPair(*PublicKey, *PrivateKey)
		Debug "PublicKey:  " + EncodeKeyToString(*PublicKey, #BakaShrot_Ed25519_PublicKeySize)
		Debug "PrivateKey: " + EncodeKeyToString(*PrivateKey, #BakaShrot_Ed25519_PrivateKeySize)

		If EncodeData(*MessageBytes, MessageLength, *PrivateKey, *Signature)
			Debug "Signed ok. Signature: " + EncodeKeyToString(*Signature, #BakaShrot_Ed25519_SignatureSize)

			If DecodeData(*MessageBytes, MessageLength, *PublicKey, *Signature)
				Debug "Verified ok, as expected."
			Else
				Debug "FAILED to verify a genuine signature - something is broken."
			EndIf

			; Tamper with one byte and make sure verification then rejects it.
			PokeB(*MessageBytes, PeekB(*MessageBytes) ! 1)
			If DecodeData(*MessageBytes, MessageLength, *PublicKey, *Signature)
				Debug "FAILED: tampered data was accepted as genuine."
			Else
				Debug "Tampered data correctly rejected."
			EndIf
		Else
			Debug "Failed to sign data."
		EndIf

		FreeMemory(*PublicKey)
		FreeMemory(*PrivateKey)
		FreeMemory(*Signature)
		FreeMemory(*MessageBytes)
	EndIf

CompilerEndIf
