; ============================================================================
; ...
; ============================================================================


XIncludeFile "../Packets.pbi"

; C2S response with the handshake (challenge included) signed by the client's private key
; (BakaShrot_MakeHandshakeTranscript(), Connections.pbi). Sent encrypted, as everything after it.
; Nonce is the one received in the challenge request, echoed back as-is.
; The server MUST compare it with the nonce it issued for this connection and drop the client on mismatch.
Structure BakaShrot_ChallengeResponse Extends BakaShrot_PacketBase
    ChallengeResponseB64.s
    Nonce.a[#BakaShrot_NonceSize]
EndStructure


; Encodes *Response into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_ChallengeResponsePacket_Encode(*Response.BakaShrot_ChallengeResponse, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Response\Magic      = #BakaShrot_ProtocolMagic
    *Response\Version    = #BakaShrot_ProtocolVersion
    *Response\PacketType = #BakaShrot_PacketType_ChallengeResponse

    *MsgPackData = MsgPackCreate(64)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Response, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Response\ChallengeResponseB64) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteBinary(*MsgPackData, @*Response\Nonce[0], #BakaShrot_NonceSize) <> #MsgPack_Error_Success
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
Procedure.i BakaShrot_ChallengeResponsePacket_Decode(*MsgPackData.MsgPackData)
    Protected *Response.BakaShrot_ChallengeResponse
    Protected ReadSize.q

    *Response = AllocateStructure(BakaShrot_ChallengeResponse)
    If Not *Response
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Response, *MsgPackData) Or *Response\PacketType <> #BakaShrot_PacketType_ChallengeResponse
        Goto DecodeFailed
    EndIf

    ; ChallengeResponseB64
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Response\ChallengeResponseB64 = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ; Nonce
    ; Anything bigger than the struct's array is rejected by MsgPackReadBinary, anything smaller by the size check.
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Binary
        Goto DecodeFailed
    EndIf
    ReadSize = MsgPackReadBinary(*MsgPackData, @*Response\Nonce[0], #BakaShrot_NonceSize)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or ReadSize <> #BakaShrot_NonceSize
        Goto DecodeFailed
    EndIf

    ProcedureReturn *Response

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Response)
    ProcedureReturn 0
EndProcedure
