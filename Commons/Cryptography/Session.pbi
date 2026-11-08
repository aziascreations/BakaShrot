; ============================================================================
; BakaShrot Session
;
; The handshake's cryptography, so the connections only call these
; (the handshake itself is in Commons/Networking/Connections.pbi):
;
;   - The Hello is sealed for the server's identity key: crypto_box_seal,
;     for the X25519 key matching the server's Ed25519 one. Only that
;     server can read it, and someone watching doesn't learn who connects.
;     BakaShrot_Session_SealHello() / _OpenHello().
;   - Each end makes a key pair for this one connection (crypto_kx). The
;     client's public half travels in the sealed Hello, the server's in the
;     ChallengeRequest; both ends sign them with their identity keys
;     (Connections.pbi), so nobody in the middle can swap them.
;     BakaShrot_Session_NewKeyPair().
;   - From its own pair and the other end's public half, each end gets a
;     key per direction and sets its BakaShrot_Cipher (Cipher.pbi) up with
;     them: every packet after the ChallengeRequest is encrypted.
;     BakaShrot_Session_StartClient() / _StartServer().
;
; The key pair's secret and the derived keys are wiped once the cipher has
; them: a recorded connection can't be decrypted later, even with the
; identity keys (forward secrecy).
;
; libsodium does all of it (Libsodium.pbi), InitCryptography() must have
; been called.
; ============================================================================

XIncludeFile "Cipher.pbi"


#BakaShrot_Session_PublicKeySize = #BakaShrot_X25519_PublicKeySize


Structure BakaShrot_SessionKey
	Bytes.a[32]
EndStructure


; One end's key pair for one connection.
Structure BakaShrot_SessionKeyPair
	PublicKey.a[#BakaShrot_X25519_PublicKeySize]
	SecretKey.a[#BakaShrot_X25519_SecretKeySize]
EndStructure


; A server's keys to open the Hellos sealed for it, from its Ed25519
; private key. Read-only once loaded, every client thread may use them.
Structure BakaShrot_HelloKeys
	PublicKey.a[#BakaShrot_X25519_PublicKeySize]
	SecretKey.a[#BakaShrot_X25519_SecretKeySize]
EndStructure


Structure BakaShrot_SessionDirections
	Rx.a[#BakaShrot_KxSessionKeySize]
	Tx.a[#BakaShrot_KxSessionKeySize]
EndStructure


; Fills *Keys from *PrivateKey (Ed25519, #BakaShrot_Ed25519_PrivateKeySize
; bytes), for a server to open the Hellos sealed for its public key.
; Returns #False if it isn't a usable key.
Procedure.i BakaShrot_Session_LoadHelloKeys(*Keys.BakaShrot_HelloKeys, *PrivateKey)
	Protected Ed25519PublicKey.BakaShrot_SessionKey, IsValid.i

	crypto_sign_ed25519_sk_to_pk(@Ed25519PublicKey, *PrivateKey)
	IsValid = Bool(crypto_sign_ed25519_pk_to_curve25519(@*Keys\PublicKey[0], @Ed25519PublicKey) = 0)
	If IsValid
		IsValid = Bool(crypto_sign_ed25519_sk_to_curve25519(@*Keys\SecretKey[0], *PrivateKey) = 0)
	EndIf
	If Not IsValid
		sodium_memzero(*Keys, SizeOf(BakaShrot_HelloKeys))
	EndIf
	ProcedureReturn IsValid
EndProcedure


; Wipes *Keys.
Procedure BakaShrot_Session_ClearHelloKeys(*Keys.BakaShrot_HelloKeys)
	sodium_memzero(*Keys, SizeOf(BakaShrot_HelloKeys))
EndProcedure


; Seals *Data (Size bytes, at least 1) for the server whose Ed25519 public
; key is *ServerPublicKey (#BakaShrot_Ed25519_PublicKeySize bytes), into a
; freshly allocated buffer of Size + #BakaShrot_SealedBoxOverhead bytes,
; its size in *OutSize\i.
; Returns 0 if *ServerPublicKey isn't a valid key, or out of memory. The
; caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_Session_SealHello(*ServerPublicKey, *Data, Size.i, *OutSize.Integer)
	Protected BoxPublicKey.BakaShrot_SessionKey, *Sealed

	If Not *ServerPublicKey Or Not *Data Or Size < 1
		ProcedureReturn 0
	EndIf
	If crypto_sign_ed25519_pk_to_curve25519(@BoxPublicKey, *ServerPublicKey) <> 0
		ProcedureReturn 0
	EndIf

	*Sealed = AllocateMemory(Size + #BakaShrot_SealedBoxOverhead, #PB_Memory_NoClear)
	If Not *Sealed
		ProcedureReturn 0
	EndIf
	If crypto_box_seal(*Sealed, *Data, Size, @BoxPublicKey) <> 0
		FreeMemory(*Sealed)
		ProcedureReturn 0
	EndIf

	*OutSize\i = Size + #BakaShrot_SealedBoxOverhead
	ProcedureReturn *Sealed
EndProcedure


; Opens *Sealed (Size bytes), sealed by BakaShrot_Session_SealHello() for
; *Keys' server, into a freshly allocated buffer, its size in *OutSize\i.
; Returns 0 if it wasn't sealed for this server, was tampered with, is too
; short, or out of memory. The caller owns the returned buffer - free it
; with FreeMemory.
Procedure.i BakaShrot_Session_OpenHello(*Keys.BakaShrot_HelloKeys, *Sealed, Size.i, *OutSize.Integer)
	Protected *Data, DataSize.i

	If Not *Sealed Or Size <= #BakaShrot_SealedBoxOverhead
		ProcedureReturn 0
	EndIf

	DataSize = Size - #BakaShrot_SealedBoxOverhead
	*Data = AllocateMemory(DataSize, #PB_Memory_NoClear)
	If Not *Data
		ProcedureReturn 0
	EndIf
	If crypto_box_seal_open(*Data, *Sealed, Size, @*Keys\PublicKey[0], @*Keys\SecretKey[0]) <> 0
		FreeMemory(*Data)
		ProcedureReturn 0
	EndIf

	*OutSize\i = DataSize
	ProcedureReturn *Data
EndProcedure


; Fills *KeyPair with a fresh key pair, for one connection. Its PublicKey
; goes to the other end.
Procedure BakaShrot_Session_NewKeyPair(*KeyPair.BakaShrot_SessionKeyPair)
	crypto_kx_keypair(@*KeyPair\PublicKey[0], @*KeyPair\SecretKey[0])
EndProcedure


; Wipes *KeyPair.
Procedure BakaShrot_Session_ClearKeyPair(*KeyPair.BakaShrot_SessionKeyPair)
	sodium_memzero(*KeyPair, SizeOf(BakaShrot_SessionKeyPair))
EndProcedure


; Sets *Cipher up for the client's end of the connection, from the client's
; *KeyPair and the server's public half (*ServerSessionKey,
; #BakaShrot_Session_PublicKeySize bytes). *KeyPair is wiped either way.
; Returns #False if the server's half isn't acceptable: abort then.
Procedure.i BakaShrot_Session_StartClient(*Cipher.BakaShrot_Cipher, *KeyPair.BakaShrot_SessionKeyPair, *ServerSessionKey)
	Protected Keys.BakaShrot_SessionDirections, IsReady.i

	BakaShrot_Cipher_Clear(*Cipher)
	If crypto_kx_client_session_keys(@Keys\Rx[0], @Keys\Tx[0], @*KeyPair\PublicKey[0], @*KeyPair\SecretKey[0], *ServerSessionKey) = 0
		IsReady = BakaShrot_Cipher_InitWithKeys(*Cipher, @Keys\Tx[0], @Keys\Rx[0])
	EndIf

	sodium_memzero(@Keys, SizeOf(BakaShrot_SessionDirections))
	BakaShrot_Session_ClearKeyPair(*KeyPair)
	ProcedureReturn IsReady
EndProcedure


; Same for the server's end, from the server's *KeyPair and the client's
; public half (*ClientSessionKey).
Procedure.i BakaShrot_Session_StartServer(*Cipher.BakaShrot_Cipher, *KeyPair.BakaShrot_SessionKeyPair, *ClientSessionKey)
	Protected Keys.BakaShrot_SessionDirections, IsReady.i

	BakaShrot_Cipher_Clear(*Cipher)
	If crypto_kx_server_session_keys(@Keys\Rx[0], @Keys\Tx[0], @*KeyPair\PublicKey[0], @*KeyPair\SecretKey[0], *ClientSessionKey) = 0
		IsReady = BakaShrot_Cipher_InitWithKeys(*Cipher, @Keys\Tx[0], @Keys\Rx[0])
	EndIf

	sodium_memzero(@Keys, SizeOf(BakaShrot_SessionDirections))
	BakaShrot_Session_ClearKeyPair(*KeyPair)
	ProcedureReturn IsReady
EndProcedure
