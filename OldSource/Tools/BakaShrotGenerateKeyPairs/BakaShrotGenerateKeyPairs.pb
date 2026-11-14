;{- Code Header
; ==- Basic Info -================================
;     Name: BakaShrotGenerateKeyPairs.pb
;  Version: 0.0.1
;   Author: Herwin Bozet (NibblePoker)
;
; ==- Compatibility -=============================
;  Tested compiler versions:
;    * PureBasic 5.73 LTS (Windows x64, Linux x64)
;    * PureBasic 6.40 C Backend (Windows x64)
;    * PureBasic 6.41 (Linux x64)
;    * PureBasic 6.41 C Backend (Linux x64)
;
; ==- Links -=====================================
;  GitHub: https://github.com/aziascreations/BakaShrot
;}

; ============================================================================
; BakaShrotGenerateKeyPairs
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

XIncludeFile "../Common/ToolConsole.pbi"
XIncludeFile "../../Commons/Cryptography/Libsodium.pbi"


Define *PublicKey, *PrivateKey

OpenConsole()

If Not InitCryptography()
	PrintN("Failed to initialize libsodium")
	ToolConsole_End(1)
EndIf

*PublicKey = AllocateMemory(#BakaShrot_Ed25519_PublicKeySize)
If Not *PublicKey
	PrintN("Failed to allocate the public key")
	ToolConsole_End(1)
EndIf

*PrivateKey = AllocateMemory(#BakaShrot_Ed25519_PrivateKeySize)
If Not *PrivateKey
	PrintN("Failed to allocate the private key")
	ToolConsole_End(1)
EndIf

GenerateKeyPair(*PublicKey, *PrivateKey)

PrintN("PrivateKey = " + EncodeKeyToString(*PrivateKey, #BakaShrot_Ed25519_PrivateKeySize))
PrintN("PublicKey = " + EncodeKeyToString(*PublicKey, #BakaShrot_Ed25519_PublicKeySize))

; Don't leave the private key lying around in freed memory.
FillMemory(*PrivateKey, #BakaShrot_Ed25519_PrivateKeySize, 0)
FreeMemory(*PrivateKey)
FreeMemory(*PublicKey)

ToolConsole_End(0)
