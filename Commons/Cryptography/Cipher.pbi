; ============================================================================
; BakaShrot Cipher
;
; Encrypts and authenticates buffers with a shared key, and checks and
; decrypts them, so the rest of the code never touches the crypto: give it
; a key once, then hand it buffers.
;
;   Cipher.BakaShrot_Cipher
;   BakaShrot_Cipher_Init(@Cipher, *Key, #BakaShrot_Cipher_Client)
;   *Sealed = BakaShrot_Cipher_Encrypt(@Cipher, *Packet, PacketSize, @SealedSize)
;   ... send it, and on the other end, with a cipher for #BakaShrot_Cipher_Server:
;   *Packet = BakaShrot_Cipher_Decrypt(@Cipher, *Sealed, SealedSize, @PacketSize)
;   If Not *Packet : abort the connection : EndIf
;   BakaShrot_Cipher_Clear(@Cipher) once done, wipes the keys.
;
; What it guarantees, for buffers sent in order over one connection (TCP):
;   - Nobody without the key can read them (XChaCha20).
;   - Nobody without the key can change, forge or truncate one (Poly1305):
;     decrypting it fails.
;   - Nobody can replay, reorder, drop or reflect one: each buffer carries
;     its sequence number, the receiver only takes the next one it expects,
;     and each direction encrypts under its own nonces (or its own key), so
;     a buffer sent back to its sender doesn't decrypt either.
; Any failure means the stream can't be trusted anymore: abort the
; connection, don't try the next buffer.
;
; What it doesn't do: get the key. Both ends must already share it, agreed
; on for this connection only (Session.pbi does it for the handshake), never
; a key reused across connections: the sequence numbers start over at 0.
;
; A sealed buffer is:
;   [sequence number, 8 bytes, little-endian][encrypted data][tag, 16 bytes]
; #BakaShrot_Cipher_Overhead bytes more than the data. The nonce (24 bytes)
; is the direction (1 byte), zeros, then the sequence number, never sent.
; The sequence number is authenticated too (additional data).
;
; libsodium's crypto_aead_xchacha20poly1305_ietf_*, imported in
; Libsodium.pbi: nothing here implements a primitive. InitCryptography()
; must have been called.
;
; Threads: encrypting and decrypting use separate state, so one thread may
; send while another receives. Two threads must not encrypt (or decrypt)
; with the same cipher at once.
; ============================================================================

XIncludeFile "Libsodium.pbi"


#BakaShrot_Cipher_KeySize       = #BakaShrot_XChaCha20Poly1305_KeySize
#BakaShrot_Cipher_SequenceSize  = 8
#BakaShrot_Cipher_Overhead      = #BakaShrot_Cipher_SequenceSize + #BakaShrot_XChaCha20Poly1305_TagSize

; Which end of the connection a cipher is on, when both share one key: each
; encrypts under its own nonces. Never 0.
#BakaShrot_Cipher_Client = 1
#BakaShrot_Cipher_Server = 2

; Past this many buffers in one direction, encrypting refuses: never reached
; in practice (2^63), but a sequence number must never wrap around.
#BakaShrot_Cipher_MaxSequence = $7FFFFFFFFFFFFFFF


Structure BakaShrot_CipherNonce
	Bytes.a[#BakaShrot_XChaCha20Poly1305_NonceSize]
EndStructure

Structure BakaShrot_Cipher
	SendKey.a[#BakaShrot_Cipher_KeySize]
	ReceiveKey.a[#BakaShrot_Cipher_KeySize]
	; First byte of the nonces of each direction.
	SendDirection.a
	ReceiveDirection.a
	; Sequence number of the next buffer to send, and of the next one
	; expected.
	SendSequence.q
	ReceiveSequence.q
	IsReady.l
EndStructure


; Fills *Key (#BakaShrot_Cipher_KeySize bytes) with a new random key.
Procedure BakaShrot_Cipher_GenerateKey(*Key)
	crypto_aead_xchacha20poly1305_ietf_keygen(*Key)
EndProcedure


; Wipes *Cipher's keys and state, it refuses everything until initialized
; again. Call it once the connection is over.
Procedure BakaShrot_Cipher_Clear(*Cipher.BakaShrot_Cipher)
	sodium_memzero(*Cipher, SizeOf(BakaShrot_Cipher))
EndProcedure


; Sets *Cipher up with one key shared by both ends (*Key,
; #BakaShrot_Cipher_KeySize bytes, copied), Role being which end this is:
; #BakaShrot_Cipher_Client or #BakaShrot_Cipher_Server, the other end must
; take the other one.
; Returns #False if Role isn't one of them.
Procedure.i BakaShrot_Cipher_Init(*Cipher.BakaShrot_Cipher, *Key, Role.i)
	BakaShrot_Cipher_Clear(*Cipher)
	If Not *Key Or (Role <> #BakaShrot_Cipher_Client And Role <> #BakaShrot_Cipher_Server)
		ProcedureReturn #False
	EndIf

	CopyMemory(*Key, @*Cipher\SendKey[0], #BakaShrot_Cipher_KeySize)
	CopyMemory(*Key, @*Cipher\ReceiveKey[0], #BakaShrot_Cipher_KeySize)
	*Cipher\SendDirection = Role
	If Role = #BakaShrot_Cipher_Client
		*Cipher\ReceiveDirection = #BakaShrot_Cipher_Server
	Else
		*Cipher\ReceiveDirection = #BakaShrot_Cipher_Client
	EndIf
	*Cipher\IsReady = #True
	ProcedureReturn #True
EndProcedure


; Sets *Cipher up with a key per direction (each #BakaShrot_Cipher_KeySize
; bytes, copied), like libsodium's crypto_kx_* gives: the other end's
; *SendKey is this one's *ReceiveKey.
; Returns #False if they're the same key: the two directions would then
; encrypt under the same nonces, use BakaShrot_Cipher_Init() for one key.
Procedure.i BakaShrot_Cipher_InitWithKeys(*Cipher.BakaShrot_Cipher, *SendKey, *ReceiveKey)
	BakaShrot_Cipher_Clear(*Cipher)
	If Not *SendKey Or Not *ReceiveKey Or CompareMemory(*SendKey, *ReceiveKey, #BakaShrot_Cipher_KeySize)
		ProcedureReturn #False
	EndIf

	CopyMemory(*SendKey, @*Cipher\SendKey[0], #BakaShrot_Cipher_KeySize)
	CopyMemory(*ReceiveKey, @*Cipher\ReceiveKey[0], #BakaShrot_Cipher_KeySize)
	; Different keys already keep the directions apart.
	*Cipher\SendDirection    = 0
	*Cipher\ReceiveDirection = 0
	*Cipher\IsReady = #True
	ProcedureReturn #True
EndProcedure


; The nonce of the buffer with that direction and sequence number.
Procedure BakaShrot_Cipher_MakeNonce(*Nonce.BakaShrot_CipherNonce, Direction.a, Sequence.q)
	FillMemory(*Nonce, #BakaShrot_XChaCha20Poly1305_NonceSize, 0)
	*Nonce\Bytes[0] = Direction
	PokeQ(@*Nonce\Bytes[#BakaShrot_XChaCha20Poly1305_NonceSize - 8], Sequence)
EndProcedure


; Encrypts and authenticates *Data (Size bytes, may be 0) into *Sealed,
; which must have room for Size + #BakaShrot_Cipher_Overhead bytes and not
; overlap *Data. *Data is left untouched.
; Returns #False, writing nothing, if *Cipher isn't set up.
Procedure.i BakaShrot_Cipher_EncryptTo(*Cipher.BakaShrot_Cipher, *Data, Size.i, *Sealed)
	Protected Nonce.BakaShrot_CipherNonce

	If Not *Cipher\IsReady Or Not *Sealed Or Size < 0 Or (Size > 0 And Not *Data) Or *Cipher\SendSequence >= #BakaShrot_Cipher_MaxSequence
		ProcedureReturn #False
	EndIf
	; libsodium wants a valid pointer even for no data.
	If Size = 0
		*Data = *Sealed
	EndIf

	PokeQ(*Sealed, *Cipher\SendSequence)
	BakaShrot_Cipher_MakeNonce(@Nonce, *Cipher\SendDirection, *Cipher\SendSequence)
	crypto_aead_xchacha20poly1305_ietf_encrypt(*Sealed + #BakaShrot_Cipher_SequenceSize, 0, *Data, Size,
	                                          *Sealed, #BakaShrot_Cipher_SequenceSize, 0, @Nonce, @*Cipher\SendKey[0])

	*Cipher\SendSequence + 1
	ProcedureReturn #True
EndProcedure


; Same, into a freshly allocated buffer of Size + #BakaShrot_Cipher_Overhead
; bytes, its size in *OutSize\i.
; Returns 0 if *Cipher isn't set up, or out of memory. The caller owns the
; returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_Cipher_Encrypt(*Cipher.BakaShrot_Cipher, *Data, Size.i, *OutSize.Integer)
	Protected *Sealed

	If Not *Cipher\IsReady Or Size < 0
		ProcedureReturn 0
	EndIf

	*Sealed = AllocateMemory(Size + #BakaShrot_Cipher_Overhead, #PB_Memory_NoClear)
	If Not *Sealed
		ProcedureReturn 0
	EndIf
	If Not BakaShrot_Cipher_EncryptTo(*Cipher, *Data, Size, *Sealed)
		FreeMemory(*Sealed)
		ProcedureReturn 0
	EndIf

	*OutSize\i = Size + #BakaShrot_Cipher_Overhead
	ProcedureReturn *Sealed
EndProcedure


; Checks and decrypts *Sealed (Size bytes, as BakaShrot_Cipher_Encrypt()
; made it on the other end) into a freshly allocated buffer, the data's size
; in *OutSize\i (0 or more, the buffer is at least 1 byte).
; Returns 0 if it isn't the next buffer expected (replayed, reordered, one
; missing), was tampered with, made with another key, sent by this end, or
; is too short; also if *Cipher isn't set up, or out of memory. Nothing
; changes then, but the connection can't be trusted anymore: abort it.
; The caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_Cipher_Decrypt(*Cipher.BakaShrot_Cipher, *Sealed, Size.i, *OutSize.Integer)
	Protected *Data, DataSize.i, Nonce.BakaShrot_CipherNonce, Genuine.i

	If Not *Cipher\IsReady Or Not *Sealed Or Size < #BakaShrot_Cipher_Overhead
		ProcedureReturn 0
	EndIf

	; Only the next one: a replayed, reordered or missing buffer stops here.
	If PeekQ(*Sealed) <> *Cipher\ReceiveSequence
		ProcedureReturn 0
	EndIf

	DataSize = Size - #BakaShrot_Cipher_Overhead
	If DataSize > 0
		*Data = AllocateMemory(DataSize, #PB_Memory_NoClear)
	Else
		*Data = AllocateMemory(1)
	EndIf
	If Not *Data
		ProcedureReturn 0
	EndIf

	BakaShrot_Cipher_MakeNonce(@Nonce, *Cipher\ReceiveDirection, *Cipher\ReceiveSequence)
	Genuine = Bool(crypto_aead_xchacha20poly1305_ietf_decrypt(*Data, 0, 0, *Sealed + #BakaShrot_Cipher_SequenceSize, Size - #BakaShrot_Cipher_SequenceSize,
	                                                          *Sealed, #BakaShrot_Cipher_SequenceSize, @Nonce, @*Cipher\ReceiveKey[0]) = 0)
	If Not Genuine
		FreeMemory(*Data)
		ProcedureReturn 0
	EndIf

	*Cipher\ReceiveSequence + 1
	*OutSize\i = DataSize
	ProcedureReturn *Data
EndProcedure
