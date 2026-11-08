; ============================================================================
; BakaShrot KeyGen
;
; Generates a new Ed25519 keypair and prints it as two ini-style lines:
;   PrivateKey = <Base64>
;   PublicKey = <Base64>
;
; The private key goes in the node's own [BakaShrot] PrivateKey, the public
; key goes in the configs of whoever needs to trust that node.
;
; Compile as a console program, exits with 0 on success, 1 on failure.
; ============================================================================

EnableExplicit

XIncludeFile "../../Commons/Cryptography/Libsodium.pbi"


Define *PublicKey, *PrivateKey

OpenConsole()

If Not InitCryptography()
	PrintN("Failed to initialize libsodium")
	End 1
EndIf

*PublicKey = AllocateMemory(#BakaShrot_Ed25519_PublicKeySize)
If Not *PublicKey
	PrintN("Failed to allocate the public key")
	End 1
EndIf

*PrivateKey = AllocateMemory(#BakaShrot_Ed25519_PrivateKeySize)
If Not *PrivateKey
	PrintN("Failed to allocate the private key")
	End 1
EndIf

GenerateKeyPair(*PublicKey, *PrivateKey)

PrintN("PrivateKey = " + EncodeKeyToString(*PrivateKey, #BakaShrot_Ed25519_PrivateKeySize))
PrintN("PublicKey = " + EncodeKeyToString(*PublicKey, #BakaShrot_Ed25519_PublicKeySize))

; Don't leave the private key lying around in freed memory.
FillMemory(*PrivateKey, #BakaShrot_Ed25519_PrivateKeySize, 0)
FreeMemory(*PrivateKey)
FreeMemory(*PublicKey)

End 0
