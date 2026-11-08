; ============================================================================
; Tests of Commons/Cryptography/Cipher.pbi, no sockets: round trips in both
; directions, and everything that must be refused (tampering, replay,
; reordering, reflection, wrong key), empty and 16 MB buffers.
; And of Session.pbi: the sealed Hello (only its server opens it, tampering
; refused) and the key exchange (both ends agree, a swapped half or another
; connection's keys don't work, the key pairs are wiped).
; Compile as a console program into Build\ (libsodium.dll is there), run it
; from there. Exits with 0 if every check passed, 1 otherwise.
; ============================================================================

EnableExplicit

XIncludeFile "../Commons/Cryptography/Session.pbi"

Global Fails.i = 0

Procedure Check(What.s, Ok.i, Detail.s = "")
	If Ok
		PrintN("PASS " + What)
	Else
		PrintN("FAIL " + What)
		Fails + 1
	EndIf
	If Detail <> ""
		PrintN("      -> " + Detail)
	EndIf
EndProcedure

; Text as a UTF-8 buffer, its size in *Size\i.
Procedure.i ToUtf8(Text.s, *Size.Integer)
	Protected *Buffer
	*Size\i = StringByteLength(Text, #PB_UTF8)
	*Buffer = AllocateMemory(*Size\i + 1)
	PokeS(*Buffer, Text, -1, #PB_UTF8)
	ProcedureReturn *Buffer
EndProcedure

; Encrypts Text with *From, decrypts it with *To, returns what came out ("" and
; *Ok\i #False if refused).
Procedure.s RoundTrip(*From.BakaShrot_Cipher, *To.BakaShrot_Cipher, Text.s, *Ok.Integer)
	Protected *Plain, PlainSize.Integer, *Sealed, SealedSize.Integer, *Opened, OpenedSize.Integer, Result.s
	*Ok\i = #False
	*Plain = ToUtf8(Text, @PlainSize)
	*Sealed = BakaShrot_Cipher_Encrypt(*From, *Plain, PlainSize\i, @SealedSize)
	FreeMemory(*Plain)
	If Not *Sealed
		ProcedureReturn ""
	EndIf
	*Opened = BakaShrot_Cipher_Decrypt(*To, *Sealed, SealedSize\i, @OpenedSize)
	FreeMemory(*Sealed)
	If Not *Opened
		ProcedureReturn ""
	EndIf
	Result = PeekS(*Opened, OpenedSize\i, #PB_UTF8 | #PB_ByteLength)
	FreeMemory(*Opened)
	*Ok\i = #True
	ProcedureReturn Result
EndProcedure

; Whether Text's UTF-8 bytes appear anywhere in *Buffer (Size bytes).
Procedure.i ContainsText(*Buffer, Size.i, Text.s)
	Protected *Needle, NeedleSize.Integer, i.i, Found.i
	*Needle = ToUtf8(Text, @NeedleSize)
	For i = 0 To Size - NeedleSize\i
		If CompareMemory(*Buffer + i, *Needle, NeedleSize\i)
			Found = #True
			Break
		EndIf
	Next
	FreeMemory(*Needle)
	ProcedureReturn Found
EndProcedure

; Whether *Sealed (Size bytes) is refused by *To, without changing it.
Procedure.i IsRefused(*To.BakaShrot_Cipher, *Sealed, Size.i)
	Protected *Opened, OpenedSize.Integer
	*Opened = BakaShrot_Cipher_Decrypt(*To, *Sealed, Size, @OpenedSize)
	If *Opened
		FreeMemory(*Opened)
		ProcedureReturn #False
	EndIf
	ProcedureReturn #True
EndProcedure

; A copy of Size bytes at *Source.
Procedure.i Copy(*Source, Size.i)
	Protected *Copy = AllocateMemory(Size)
	CopyMemory(*Source, *Copy, Size)
	ProcedureReturn *Copy
EndProcedure


Define *Key, *OtherKey
Define Client.BakaShrot_Cipher, Server.BakaShrot_Cipher, Other.BakaShrot_Cipher, Uninitialized.BakaShrot_Cipher
Define Ok.Integer, Text.s, i.i, Zero.i
Define *Plain, PlainSize.Integer, *Sealed, SealedSize.Integer, *Sealed2, Sealed2Size.Integer, *Opened, OpenedSize.Integer
Define *Tampered, Offset.i, Refused.i, StartTime.q, Elapsed.q

OpenConsole()

If Not InitCryptography()
	PrintN("FAIL libsodium couldn't initialize")
	End 1
EndIf

*Key      = AllocateMemory(#BakaShrot_Cipher_KeySize)
*OtherKey = AllocateMemory(#BakaShrot_Cipher_KeySize)
BakaShrot_Cipher_GenerateKey(*Key)
BakaShrot_Cipher_GenerateKey(*OtherKey)
Check("Two generated keys differ", Bool(Not CompareMemory(*Key, *OtherKey, #BakaShrot_Cipher_KeySize)))

Check("Init as client", BakaShrot_Cipher_Init(@Client, *Key, #BakaShrot_Cipher_Client))
Check("Init as server", BakaShrot_Cipher_Init(@Server, *Key, #BakaShrot_Cipher_Server))
Check("Init with role 0 refused", Bool(Not BakaShrot_Cipher_Init(@Other, *Key, 0)))

; --- Round trips ---------------------------------------------------------------

Text = RoundTrip(@Client, @Server, "hello, server", @Ok)
Check("Client -> server", Bool(Ok\i And Text = "hello, server"), Text)
Text = RoundTrip(@Server, @Client, "hello, client", @Ok)
Check("Server -> client", Bool(Ok\i And Text = "hello, client"), Text)
For i = 1 To 100
	Text = RoundTrip(@Client, @Server, "message " + Str(i), @Ok)
	If Not Ok\i Or Text <> "message " + Str(i)
		Break
	EndIf
Next
Check("100 more in order", Bool(i = 101), Str(i - 1) + " went through")
Text = RoundTrip(@Client, @Server, "héllo wörld, 🌍", @Ok)
Check("Non-ASCII data", Bool(Ok\i And Text = "héllo wörld, 🌍"), Text)

; --- What a sealed buffer looks like ------------------------------------------

*Plain = ToUtf8("same text", @PlainSize)
*Sealed  = BakaShrot_Cipher_Encrypt(@Client, *Plain, PlainSize\i, @SealedSize)
*Sealed2 = BakaShrot_Cipher_Encrypt(@Client, *Plain, PlainSize\i, @Sealed2Size)
Check("Sealed size is the data + " + Str(#BakaShrot_Cipher_Overhead), Bool(SealedSize\i = PlainSize\i + #BakaShrot_Cipher_Overhead), Str(SealedSize\i) + " bytes for " + Str(PlainSize\i))
Check("The data doesn't appear in it", Bool(Not CompareMemory(*Sealed + #BakaShrot_Cipher_SequenceSize, *Plain, PlainSize\i)))
Check("The same data twice seals differently", Bool(Not CompareMemory(*Sealed + #BakaShrot_Cipher_SequenceSize, *Sealed2 + #BakaShrot_Cipher_SequenceSize, PlainSize\i)))
Check("Each carries its sequence number", Bool(PeekQ(*Sealed2) = PeekQ(*Sealed) + 1), Str(PeekQ(*Sealed)) + ", " + Str(PeekQ(*Sealed2)))

; --- Refused ---------------------------------------------------------------------

; Reordered: the second one first.
Check("The next-but-one first: refused (reordered)", IsRefused(@Server, *Sealed2, Sealed2Size\i))

; Tampered anywhere: the sequence number, the data, the tag.
Refused = 0
For Offset = 0 To SealedSize\i - 1
	*Tampered = Copy(*Sealed, SealedSize\i)
	PokeA(*Tampered + Offset, PeekA(*Tampered + Offset) ! $01)
	If IsRefused(@Server, *Tampered, SealedSize\i)
		Refused + 1
	EndIf
	FreeMemory(*Tampered)
Next
Check("One bit flipped anywhere: refused, at every one of its " + Str(SealedSize\i) + " bytes", Bool(Refused = SealedSize\i), Str(Refused) + " refused")
Check("Cut short by one byte: refused", IsRefused(@Server, *Sealed, SealedSize\i - 1))
Check("Shorter than the overhead: refused", IsRefused(@Server, *Sealed, #BakaShrot_Cipher_Overhead - 1))

; None of that moved the receiver on: the genuine ones still go through, in order.
*Opened = BakaShrot_Cipher_Decrypt(@Server, *Sealed, SealedSize\i, @OpenedSize)
Check("After all that, the genuine one still decrypts", Bool(*Opened And OpenedSize\i = PlainSize\i And CompareMemory(*Opened, *Plain, PlainSize\i)))
If *Opened : FreeMemory(*Opened) : EndIf
Check("Replayed: refused", IsRefused(@Server, *Sealed, SealedSize\i))
*Opened = BakaShrot_Cipher_Decrypt(@Server, *Sealed2, Sealed2Size\i, @OpenedSize)
Check("Then the next one", Bool(*Opened <> 0))
If *Opened : FreeMemory(*Opened) : EndIf

; Reflected: sent back to its sender, or to another client with the same key.
*Sealed2 = BakaShrot_Cipher_Encrypt(@Client, *Plain, PlainSize\i, @Sealed2Size)
BakaShrot_Cipher_Init(@Other, *Key, #BakaShrot_Cipher_Client)
; Same sequence number, so only the direction differs.
Other\ReceiveSequence = PeekQ(*Sealed2)
Check("Reflected to a client with the same key, same sequence number: refused", IsRefused(@Other, *Sealed2, Sealed2Size\i))

; Another key.
BakaShrot_Cipher_Init(@Other, *OtherKey, #BakaShrot_Cipher_Server)
Other\ReceiveSequence = PeekQ(*Sealed2)
Check("Another key: refused", IsRefused(@Other, *Sealed2, Sealed2Size\i))
FreeMemory(*Sealed)
FreeMemory(*Sealed2)
FreeMemory(*Plain)

Check("Not set up: refuses to encrypt", Bool(BakaShrot_Cipher_Encrypt(@Uninitialized, @Zero, 4, @SealedSize) = 0))

; --- Sizes ---------------------------------------------------------------------

BakaShrot_Cipher_Init(@Client, *Key, #BakaShrot_Cipher_Client)
BakaShrot_Cipher_Init(@Server, *Key, #BakaShrot_Cipher_Server)
*Sealed = BakaShrot_Cipher_Encrypt(@Client, 0, 0, @SealedSize)
*Opened = 0
If *Sealed
	*Opened = BakaShrot_Cipher_Decrypt(@Server, *Sealed, SealedSize\i, @OpenedSize)
EndIf
Check("Empty data: sealed in " + Str(#BakaShrot_Cipher_Overhead) + " bytes, opens to 0 bytes", Bool(*Sealed And SealedSize\i = #BakaShrot_Cipher_Overhead And *Opened And OpenedSize\i = 0))
If *Sealed : FreeMemory(*Sealed) : EndIf
If *Opened : FreeMemory(*Opened) : EndIf

PlainSize\i = 16 * 1024 * 1024
*Plain = AllocateMemory(PlainSize\i)
RandomData(*Plain, PlainSize\i)
StartTime = ElapsedMilliseconds()
*Sealed = BakaShrot_Cipher_Encrypt(@Client, *Plain, PlainSize\i, @SealedSize)
*Opened = BakaShrot_Cipher_Decrypt(@Server, *Sealed, SealedSize\i, @OpenedSize)
Elapsed = ElapsedMilliseconds() - StartTime
Check("16 MB both ways, intact", Bool(*Opened And OpenedSize\i = PlainSize\i And CompareMemory(*Opened, *Plain, PlainSize\i)), Str(Elapsed) + " ms to encrypt and decrypt")
FreeMemory(*Plain)
If *Sealed : FreeMemory(*Sealed) : EndIf
If *Opened : FreeMemory(*Opened) : EndIf

; --- A key per direction -----------------------------------------------------

Check("Two keys: the same one twice refused", Bool(Not BakaShrot_Cipher_InitWithKeys(@Client, *Key, *Key)))
Check("Two keys: client sends with A, receives with B", BakaShrot_Cipher_InitWithKeys(@Client, *Key, *OtherKey))
Check("Two keys: server the other way around", BakaShrot_Cipher_InitWithKeys(@Server, *OtherKey, *Key))
Text = RoundTrip(@Client, @Server, "with two keys", @Ok)
Check("Two keys: client -> server", Bool(Ok\i And Text = "with two keys"), Text)
Text = RoundTrip(@Server, @Client, "and back", @Ok)
Check("Two keys: server -> client", Bool(Ok\i And Text = "and back"), Text)
BakaShrot_Cipher_InitWithKeys(@Other, *Key, *OtherKey)
*Plain = ToUtf8("to myself", @PlainSize)
*Sealed = BakaShrot_Cipher_Encrypt(@Other, *Plain, PlainSize\i, @SealedSize)
Check("Two keys: reflected to its sender, refused", IsRefused(@Other, *Sealed, SealedSize\i))
FreeMemory(*Sealed)
FreeMemory(*Plain)

; --- Clear -------------------------------------------------------------------------

BakaShrot_Cipher_Clear(@Client)
Zero = #True
For i = 0 To #BakaShrot_Cipher_KeySize - 1
	If Client\SendKey[i] Or Client\ReceiveKey[i]
		Zero = #False
	EndIf
Next
Check("Clear wipes both keys", Zero)
Check("Cleared: refuses to encrypt", Bool(BakaShrot_Cipher_Encrypt(@Client, @Zero, 4, @SealedSize) = 0))

sodium_memzero(*Key, #BakaShrot_Cipher_KeySize)
sodium_memzero(*OtherKey, #BakaShrot_Cipher_KeySize)


; --- Into a given buffer ---------------------------------------------------------

BakaShrot_Cipher_Init(@Client, *Key, #BakaShrot_Cipher_Client)
BakaShrot_Cipher_Init(@Server, *Key, #BakaShrot_Cipher_Server)
*Plain = ToUtf8("in place", @PlainSize)
*Sealed = AllocateMemory(PlainSize\i + #BakaShrot_Cipher_Overhead)
Check("EncryptTo writes a sealed buffer", BakaShrot_Cipher_EncryptTo(@Client, *Plain, PlainSize\i, *Sealed))
*Opened = BakaShrot_Cipher_Decrypt(@Server, *Sealed, PlainSize\i + #BakaShrot_Cipher_Overhead, @OpenedSize)
Check("EncryptTo's buffer decrypts", Bool(*Opened And PeekS(*Opened, OpenedSize\i, #PB_UTF8 | #PB_ByteLength) = "in place"))
If *Opened : FreeMemory(*Opened) : EndIf
Check("EncryptTo refuses without a cipher", Bool(Not BakaShrot_Cipher_EncryptTo(@Uninitialized, *Plain, PlainSize\i, *Sealed)))
FreeMemory(*Sealed)
FreeMemory(*Plain)
BakaShrot_Cipher_Clear(@Client)
BakaShrot_Cipher_Clear(@Server)


; --- Session: the sealed Hello ---------------------------------------------------

Define *ServerPublic = AllocateMemory(#BakaShrot_Ed25519_PublicKeySize)
Define *ServerPrivate = AllocateMemory(#BakaShrot_Ed25519_PrivateKeySize)
Define *OtherPublic = AllocateMemory(#BakaShrot_Ed25519_PublicKeySize)
Define *OtherPrivate = AllocateMemory(#BakaShrot_Ed25519_PrivateKeySize)
Define *ZeroKey = AllocateMemory(32)
Define HelloKeys.BakaShrot_HelloKeys, OtherHelloKeys.BakaShrot_HelloKeys
Define ClientPair.BakaShrot_SessionKeyPair, ServerPair.BakaShrot_SessionKeyPair, MiddlePair.BakaShrot_SessionKeyPair
Define ClientHalf.BakaShrot_SessionKey, ServerHalf.BakaShrot_SessionKey, MiddleHalf.BakaShrot_SessionKey

GenerateKeyPair(*ServerPublic, *ServerPrivate)
GenerateKeyPair(*OtherPublic, *OtherPrivate)
Check("Hello keys from a server's private key", BakaShrot_Session_LoadHelloKeys(@HelloKeys, *ServerPrivate))
BakaShrot_Session_LoadHelloKeys(@OtherHelloKeys, *OtherPrivate)

*Plain = ToUtf8("hello, I'm logs:kitchen", @PlainSize)
*Sealed = BakaShrot_Session_SealHello(*ServerPublic, *Plain, PlainSize\i, @SealedSize)
Check("Hello sealed, 48 bytes more", Bool(*Sealed And SealedSize\i = PlainSize\i + #BakaShrot_SealedBoxOverhead))
Check("The sealed hello doesn't show the identity", Bool(*Sealed And Not ContainsText(*Sealed, SealedSize\i, "kitchen")))
*Opened = BakaShrot_Session_OpenHello(@HelloKeys, *Sealed, SealedSize\i, @OpenedSize)
Check("The server opens it", Bool(*Opened And PeekS(*Opened, OpenedSize\i, #PB_UTF8 | #PB_ByteLength) = "hello, I'm logs:kitchen"))
If *Opened : FreeMemory(*Opened) : EndIf
*Opened = BakaShrot_Session_OpenHello(@OtherHelloKeys, *Sealed, SealedSize\i, @OpenedSize)
Check("Another server can't open it", Bool(Not *Opened))
If *Opened : FreeMemory(*Opened) : EndIf

Refused = #True
For Offset = 0 To SealedSize\i - 1 Step 7
	*Tampered = Copy(*Sealed, SealedSize\i)
	PokeA(*Tampered + Offset, PeekA(*Tampered + Offset) ! $01)
	*Opened = BakaShrot_Session_OpenHello(@HelloKeys, *Tampered, SealedSize\i, @OpenedSize)
	If *Opened
		Refused = #False
		FreeMemory(*Opened)
	EndIf
	FreeMemory(*Tampered)
Next
Check("A tampered hello isn't opened", Refused)
*Opened = BakaShrot_Session_OpenHello(@HelloKeys, *Sealed, #BakaShrot_SealedBoxOverhead, @OpenedSize)
Check("A hello cut short isn't opened", Bool(Not *Opened))
FreeMemory(*Sealed)

*Sealed = BakaShrot_Session_SealHello(*ZeroKey, *Plain, PlainSize\i, @SealedSize)
Check("Sealing for an invalid server key refused", Bool(Not *Sealed))
If *Sealed : FreeMemory(*Sealed) : EndIf
FreeMemory(*Plain)


; --- Session: the key exchange ---------------------------------------------------

BakaShrot_Session_NewKeyPair(@ClientPair)
BakaShrot_Session_NewKeyPair(@ServerPair)
CopyMemory(@ClientPair\PublicKey[0], @ClientHalf, 32)
CopyMemory(@ServerPair\PublicKey[0], @ServerHalf, 32)
Check("Server starts from the client's half", BakaShrot_Session_StartServer(@Server, @ServerPair, @ClientHalf))
Check("Client starts from the server's half", BakaShrot_Session_StartClient(@Client, @ClientPair, @ServerHalf))
Zero = #True
For i = 0 To #BakaShrot_X25519_SecretKeySize - 1
	If ClientPair\SecretKey[i] Or ServerPair\SecretKey[i]
		Zero = #False
	EndIf
Next
Check("Both key pairs wiped once started", Zero)

Text = RoundTrip(@Client, @Server, "push over a session", @Ok)
Check("Session: client -> server", Bool(Ok\i And Text = "push over a session"), Text)
Text = RoundTrip(@Server, @Client, "answer over a session", @Ok)
Check("Session: server -> client", Bool(Ok\i And Text = "answer over a session"), Text)
Check("Session: a key per direction", Bool(Not CompareMemory(@Client\SendKey[0], @Client\ReceiveKey[0], #BakaShrot_Cipher_KeySize)))
Check("Session: the client's send key is the server's receive key", CompareMemory(@Client\SendKey[0], @Server\ReceiveKey[0], #BakaShrot_Cipher_KeySize))

*Plain = ToUtf8("back to me", @PlainSize)
*Sealed = BakaShrot_Cipher_Encrypt(@Client, *Plain, PlainSize\i, @SealedSize)
Check("Session: reflected to the client, refused", IsRefused(@Client, *Sealed, SealedSize\i))
FreeMemory(*Sealed)

; Someone in the middle swapping the server's half for theirs: the client
; ends up with keys the real server doesn't have. (The server's signature
; of the halves catches it first, in the handshake.)
BakaShrot_Session_NewKeyPair(@ClientPair)
BakaShrot_Session_NewKeyPair(@ServerPair)
BakaShrot_Session_NewKeyPair(@MiddlePair)
CopyMemory(@ClientPair\PublicKey[0], @ClientHalf, 32)
CopyMemory(@MiddlePair\PublicKey[0], @MiddleHalf, 32)
BakaShrot_Session_StartServer(@Server, @ServerPair, @ClientHalf)
BakaShrot_Session_StartClient(@Client, @ClientPair, @MiddleHalf)
*Sealed = BakaShrot_Cipher_Encrypt(@Client, *Plain, PlainSize\i, @SealedSize)
Check("Session: halves swapped, the server can't decrypt", IsRefused(@Server, *Sealed, SealedSize\i))
FreeMemory(*Sealed)

; Another connection of the same client gets other keys.
Define Server2.BakaShrot_Cipher
CopyMemory(@Server, @Other, SizeOf(BakaShrot_Cipher))
BakaShrot_Session_NewKeyPair(@ClientPair)
BakaShrot_Session_NewKeyPair(@ServerPair)
CopyMemory(@ClientPair\PublicKey[0], @ClientHalf, 32)
CopyMemory(@ServerPair\PublicKey[0], @ServerHalf, 32)
BakaShrot_Session_StartServer(@Server2, @ServerPair, @ClientHalf)
BakaShrot_Session_StartClient(@Client, @ClientPair, @ServerHalf)
Check("Session: another connection, other keys", Bool(Not CompareMemory(@Server2\ReceiveKey[0], @Other\ReceiveKey[0], #BakaShrot_Cipher_KeySize)))
*Sealed = BakaShrot_Cipher_Encrypt(@Client, *Plain, PlainSize\i, @SealedSize)
Check("Session: replayed into another connection, refused", IsRefused(@Other, *Sealed, SealedSize\i))
FreeMemory(*Sealed)
FreeMemory(*Plain)

BakaShrot_Session_NewKeyPair(@ServerPair)
Check("Session: an all-zero half refused", Bool(Not BakaShrot_Session_StartServer(@Server, @ServerPair, *ZeroKey)))
Check("Session: refused, the cipher isn't usable", Bool(Not Server\IsReady))

BakaShrot_Session_ClearHelloKeys(@HelloKeys)
BakaShrot_Session_ClearHelloKeys(@OtherHelloKeys)
sodium_memzero(*ServerPrivate, #BakaShrot_Ed25519_PrivateKeySize)
sodium_memzero(*OtherPrivate, #BakaShrot_Ed25519_PrivateKeySize)
BakaShrot_Cipher_Clear(@Client)
BakaShrot_Cipher_Clear(@Server)
BakaShrot_Cipher_Clear(@Server2)
BakaShrot_Cipher_Clear(@Other)

PrintN("")
If Fails
	PrintN(Str(Fails) + " check(s) failed")
	End 1
EndIf
PrintN("All checks passed")
End 0
