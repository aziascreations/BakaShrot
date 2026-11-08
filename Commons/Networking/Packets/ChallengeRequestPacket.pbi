; ============================================================================
; ...
; ============================================================================


XIncludeFile "../Packets.pbi"

; S2C challenge the client must sign with its private key, the last packet sent in plain text.
; Nonce is fresh random data tied to this connection, the client must echo it back in its response.
; ServerSessionKey: the public half of the server's key pair for this connection.
; ServerSignature: the server's signature of the handshake so far, made with its identity key
; (BakaShrot_MakeHandshakeTranscript(), Connections.pbi), so the client knows it's the right server.
Structure BakaShrot_ChallengeRequest Extends BakaShrot_PacketBase
    ChallengeB64.s
    Nonce.a[#BakaShrot_NonceSize]
    ServerSessionKey.a[#BakaShrot_SessionKeySize]
    ServerSignature.a[#BakaShrot_HandshakeSignatureSize]
EndStructure


; Encodes *Request into a freshly allocated buffer, its base fields are set by this procedure.
; *Request\Nonce must already be filled by the caller with CryptRandomData().
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_ChallengeRequestPacket_Encode(*Request.BakaShrot_ChallengeRequest, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Request\Magic      = #BakaShrot_ProtocolMagic
    *Request\Version    = #BakaShrot_ProtocolVersion
    *Request\PacketType = #BakaShrot_PacketType_ChallengeRequest

    *MsgPackData = MsgPackCreate(64)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Request, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Request\ChallengeB64) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteBinary(*MsgPackData, @*Request\Nonce[0], #BakaShrot_NonceSize) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteBinary(*MsgPackData, @*Request\ServerSessionKey[0], #BakaShrot_SessionKeySize) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteBinary(*MsgPackData, @*Request\ServerSignature[0], #BakaShrot_HandshakeSignatureSize) <> #MsgPack_Error_Success
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
Procedure.i BakaShrot_ChallengeRequestPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Request.BakaShrot_ChallengeRequest
    Protected ReadSize.q

    *Request = AllocateStructure(BakaShrot_ChallengeRequest)
    If Not *Request
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Request, *MsgPackData) Or *Request\PacketType <> #BakaShrot_PacketType_ChallengeRequest
        Goto DecodeFailed
    EndIf

    ; ChallengeB64
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Request\ChallengeB64 = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ; Nonce
    ; Anything bigger than the struct's array is rejected by MsgPackReadBinary, anything smaller by the size check.
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Binary
        Goto DecodeFailed
    EndIf
    ReadSize = MsgPackReadBinary(*MsgPackData, @*Request\Nonce[0], #BakaShrot_NonceSize)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or ReadSize <> #BakaShrot_NonceSize
        Goto DecodeFailed
    EndIf

    ; ServerSessionKey
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Binary
        Goto DecodeFailed
    EndIf
    ReadSize = MsgPackReadBinary(*MsgPackData, @*Request\ServerSessionKey[0], #BakaShrot_SessionKeySize)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or ReadSize <> #BakaShrot_SessionKeySize
        Goto DecodeFailed
    EndIf

    ; ServerSignature
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Binary
        Goto DecodeFailed
    EndIf
    ReadSize = MsgPackReadBinary(*MsgPackData, @*Request\ServerSignature[0], #BakaShrot_HandshakeSignatureSize)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or ReadSize <> #BakaShrot_HandshakeSignatureSize
        Goto DecodeFailed
    EndIf

    ProcedureReturn *Request

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Request)
    ProcedureReturn 0
EndProcedure
