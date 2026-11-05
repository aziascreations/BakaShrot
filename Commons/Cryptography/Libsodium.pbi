; ============================================================================
; BakaShrot Cryptography
;
; Authenticates packets using Ed25519 signatures (via libsodium - this does
; NOT reimplement any cryptographic primitive).
;
; EncodeData signs a buffer with the sending node's own private key.
; DecodeData checks that signature against the claimed sender's public key.
;
; This buys integrity + authenticity, NOT confidentiality: anyone who can see
; the packet can still read it, but they cannot forge one or tamper with one
; without the signature check failing. That matches BakaShrot's
; replication/broadcast model, where a message is meant to be read by every
; peer in the group - encrypting it for a single recipient would defeat that.
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
;   - Windows: the official libsodium release's "libsodium.lib" (import
;     library) and "libsodium.dll" alongside the executable.
;   - Linux:   libsodium-dev (Debian/Ubuntu) or libsodium-devel (Fedora)
;              installed, so "-lsodium" resolves at link time and
;              libsodium.so.* is available at runtime.
; libsodium itself is the same standard, audited library on both platforms,
; so signatures made on one are verifiable on the other without change.
; ============================================================================


#BakaShrot_Ed25519_PublicKeySize  = 32
#BakaShrot_Ed25519_PrivateKeySize = 64
#BakaShrot_Ed25519_SignatureSize  = 64


CompilerIf #PB_Compiler_OS = #PB_OS_Windows
	ImportC "libsodium.lib"
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
