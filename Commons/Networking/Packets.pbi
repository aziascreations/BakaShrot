
XIncludeFile "../../Includes/PB-MessagePack/Includes/MessagePack.pbi"
XIncludeFile "Names.pbi"


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
; 2: topics and nodes by name (Commons/Networking/Names.pbi), see Design/Packets.md.
; 3: the Hello sealed for the server, a key per connection, everything after
;    the ChallengeRequest encrypted (Connections.pbi). Messages carry when
;    they were pushed (PushedAt).
#BakaShrot_ProtocolVersion = 3

; Size in bytes of the nonce sent in a challenge request and echoed in its response.
; It MUST be filled with CryptRandomData(), never reused, and be checked against the one the
; server issued for that connection, so a captured response can't be replayed.
#BakaShrot_NonceSize = 32

; Size in bytes of the random challenge sent Base64-encoded in a challenge request.
; The client proves it holds its private key by signing the challenge followed by the nonce.
#BakaShrot_ChallengeSize = 32

; Size in bytes of the public half of a connection's key pair, sent by the
; client in its Hello and by the server in its ChallengeRequest
; (#BakaShrot_Session_PublicKeySize, Commons/Cryptography/Session.pbi).
#BakaShrot_SessionKeySize = 32

; Size in bytes of the server's signature in a ChallengeRequest
; (#BakaShrot_Ed25519_SignatureSize).
#BakaShrot_HandshakeSignatureSize = 64

; When a message was pushed: milliseconds since 1970-01-01 00:00:00 UTC, set
; by the server it was pushed to, and kept as is by every server it's
; replicated to. Anything outside 1 to #BakaShrot_MaxTimestamp (9999-12-31)
; is invalid on the wire.
#BakaShrot_MaxTimestamp = 253402300799999

Procedure.i BakaShrot_IsValidTimestamp(Timestamp.q)
	ProcedureReturn Bool(Timestamp >= 1 And Timestamp <= #BakaShrot_MaxTimestamp)
EndProcedure

; Biggest packet accepted on the wire once authenticated, anything bigger
; aborts the connection. Before that, only #BakaShrot_MaxHandshakePacketSize
; (Connections.pbi).
#BakaShrot_MaxPacketSize = 16 * 1024 * 1024

; Biggest message a client may push (its JSON, in UTF-8 bytes). Leaves room
; for the fields around it, so a stored message fits in every packet that
; carries one: LatestMessage, a ReplicateMessages batch of one.
#BakaShrot_MaxMessageSize = #BakaShrot_MaxPacketSize - 4096

Enumeration BakaShrot_PacketTypes
	; Safety fallback value, should be dropped when encountered
	#BakaShrot_PacketType_None = 0

	; 1-3 were used by the removed AuthenticationPacket.pbi, don't reuse them.
	#BakaShrot_PacketType_ClientHello       = 4
	#BakaShrot_PacketType_ChallengeRequest  = 5
	#BakaShrot_PacketType_ChallengeResponse = 6
	#BakaShrot_PacketType_AuthAccepted      = 7

	; Only accepted once authenticated.
	#BakaShrot_PacketType_PushMessage       = 8
	#BakaShrot_PacketType_MessagePushed     = 9
	#BakaShrot_PacketType_GetLatestMessage  = 10
	#BakaShrot_PacketType_LatestMessage     = 11
	#BakaShrot_PacketType_RequestRefused    = 12

	; Replication, only accepted from peers once authenticated.
	#BakaShrot_PacketType_SyncStateRequest  = 13
	#BakaShrot_PacketType_SyncState         = 14
	#BakaShrot_PacketType_ReplicateMessages = 15

	; Raw read-only SQL, only accepted once authenticated, from clients allowed to.
	#BakaShrot_PacketType_QueryRequest      = 16
	#BakaShrot_PacketType_QueryResult       = 17

	; Name <-> id of a topic or node, only accepted once authenticated.
	#BakaShrot_PacketType_ResolveName       = 18
	#BakaShrot_PacketType_NameResolved      = 19

	; Every topic or node the client may see, only accepted once authenticated.
	#BakaShrot_PacketType_ListNames         = 20
	#BakaShrot_PacketType_NamesList         = 21

	; A run of messages of a topic/node, only accepted once authenticated.
	#BakaShrot_PacketType_GetMessages       = 22
	#BakaShrot_PacketType_Messages          = 23
EndEnumeration


; Checks and reads the given MsgPack data into a packet structure's common fields.
; The caller can handle the MsgPack data validation however it see fit.
; On success, the structure's fields will be populated, and the MsgPack structure will be ready to ready the packet's remaining fields.
; On failure, all data should be discarded and be treated as tainted.
Procedure.b BakaShrot_ReadPacketBase(*PacketStruct.BakaShrot_PacketBase, *MsgPackData.MsgPackData)
	; Returns true on success, false otherwise
	; The caller will usually drop all data and tell the remote client to fuck off if this fails.
	Protected TempValue.q

	If Not *PacketStruct Or Not *MsgPackData
		ProcedureReturn #False
	EndIf

	; Magic
	If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
		ProcedureReturn #False
	EndIf
	TempValue = MsgPackReadInteger(*MsgPackData)
	If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or TempValue <> #BakaShrot_ProtocolMagic
		ProcedureReturn #False
	EndIf
	*PacketStruct\Magic = TempValue

	; Version
	If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
		ProcedureReturn #False
	EndIf
	TempValue = MsgPackReadInteger(*MsgPackData)
	If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or TempValue <> #BakaShrot_ProtocolVersion
		ProcedureReturn #False
	EndIf
	*PacketStruct\Version = TempValue

	; PacketType
	If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
		ProcedureReturn #False
	EndIf
	TempValue = MsgPackReadInteger(*MsgPackData)
	If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or TempValue <= #BakaShrot_PacketType_None Or TempValue > 2147483647
		ProcedureReturn #False
	EndIf
	*PacketStruct\PacketType = TempValue

	ProcedureReturn #True
EndProcedure

; Writes a packet structure's common fields into the given MsgPack data.
; On success, the MsgPack structure will be ready to write the packet's remaining fields.
; On failure, the MsgPack data should be discarded and be treated as tainted.
Procedure.b BakaShrot_WritePacketBase(*PacketStruct.BakaShrot_PacketBase, *MsgPackData.MsgPackData)
	; Returns true on success, false otherwise
	If MsgPackWriteInteger(*MsgPackData, *PacketStruct\Magic) <> #MsgPack_Error_Success
		ProcedureReturn #False
	EndIf

	If MsgPackWriteInteger(*MsgPackData, *PacketStruct\Version) <> #MsgPack_Error_Success
		ProcedureReturn #False
	EndIf

	If MsgPackWriteInteger(*MsgPackData, *PacketStruct\PacketType) <> #MsgPack_Error_Success
		ProcedureReturn #False
	EndIf

	ProcedureReturn #True
EndProcedure
