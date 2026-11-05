

; Represents the root of all BakaShrot packets.
; Any packets below this size MUST be thrown out.
Structure BakaShrot_PacketBase
	Magic.l
	Version.l
	PacketType.l
EndStructure

; Fixed values every BakaShrot_PacketBase must carry. Checked on decode so a
; packet from a different protocol/version is thrown out instead of being
; misparsed.
#BakaShrot_ProtocolMagic   = $42534854 ; "BSHT"
#BakaShrot_ProtocolVersion = 1

Enumeration BakaShrot_PacketTypes
	; Safety fallback value, should be dropped when encountered
	#BakaShrot_PacketType_None = 0

	#BakaShrot_PacketType_AuthenticationRequest   = 1
	#BakaShrot_PacketType_AuthenticationChallenge = 2
	#BakaShrot_PacketType_AuthenticationResult    = 3
EndEnumeration


