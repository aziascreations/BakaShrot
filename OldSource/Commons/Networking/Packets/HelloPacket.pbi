;{- Code Header
; ==- Basic Info -================================
;     Name: HelloPacket.pbi
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
; ...
; ============================================================================


XIncludeFile "../Packets.pbi"

; C2S auth request, sent sealed for the server's public key (Connections.pbi).
; ClientNode: who the client is, the node it writes as, a name or an id in
; digits (Commons/Networking/Names.pbi), resolved by the server in its own
; names. Its default topic is the server's to say, not the client's.
; ClientSessionKey: the public half of the client's key pair for this
; connection (Commons/Cryptography/Session.pbi).
Structure BakaShrot_AuthHello Extends BakaShrot_PacketBase
    ClientNode.s
    ClientPubKeyB64.s
    ClientSessionKey.a[#BakaShrot_SessionKeySize]
EndStructure


; Encodes *Hello into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_HelloPacket_Encode(*Hello.BakaShrot_AuthHello, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Hello\Magic      = #BakaShrot_ProtocolMagic
    *Hello\Version    = #BakaShrot_ProtocolVersion
    *Hello\PacketType = #BakaShrot_PacketType_ClientHello

    *MsgPackData = MsgPackCreate(64)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Hello, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Hello\ClientNode) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Hello\ClientPubKeyB64) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteBinary(*MsgPackData, @*Hello\ClientSessionKey[0], #BakaShrot_SessionKeySize) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    ; Frees *MsgPackData on success, leaves it untouched on failure.
    *Buffer = MsgPackFinalize(*MsgPackData)
    If Not *Buffer
        Goto EncodeFailed
    EndIf

    *OutSize\i = MemorySize(*Buffer)
    ProcedureReturn *Buffer

    EncodeFailed:
    MsgPackFree(*MsgPackData, #True)
    ProcedureReturn 0
EndProcedure

; Decodes the packet at *MsgPackData's current offset into a freshly allocated struct.
; *MsgPackData stays owned by the caller, and should be discarded on failure.
; Returns 0 on failure, the caller owns the returned struct - free it with FreeStructure.
Procedure.i BakaShrot_HelloPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Hello.BakaShrot_AuthHello
    Protected ReadSize.q

    *Hello = AllocateStructure(BakaShrot_AuthHello)
    If Not *Hello
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Hello, *MsgPackData) Or *Hello\PacketType <> #BakaShrot_PacketType_ClientHello
        Goto DecodeFailed
    EndIf

    ; ClientNode
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Hello\ClientNode = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ; ClientPubKeyB64
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Hello\ClientPubKeyB64 = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ; ClientSessionKey
    ; Anything bigger than the struct's array is rejected by MsgPackReadBinary, anything smaller by the size check.
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Binary
        Goto DecodeFailed
    EndIf
    ReadSize = MsgPackReadBinary(*MsgPackData, @*Hello\ClientSessionKey[0], #BakaShrot_SessionKeySize)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or ReadSize <> #BakaShrot_SessionKeySize
        Goto DecodeFailed
    EndIf

    ProcedureReturn *Hello

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Hello)
    ProcedureReturn 0
EndProcedure
