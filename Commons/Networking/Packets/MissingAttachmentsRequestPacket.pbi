; ============================================================================
; ...
; ============================================================================


XIncludeFile "../Packets.pbi"

; P2S, asks which attachments the server is still missing from this peer, once
; the messages are caught up. Only the base fields.
; Answered with a MissingAttachments, or a RequestRefused.
Structure BakaShrot_MissingAttachmentsRequest Extends BakaShrot_PacketBase

EndStructure


; Encodes *Request into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_MissingAttachmentsRequestPacket_Encode(*Request.BakaShrot_MissingAttachmentsRequest, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Request\Magic      = #BakaShrot_ProtocolMagic
    *Request\Version    = #BakaShrot_ProtocolVersion
    *Request\PacketType = #BakaShrot_PacketType_MissingAttachmentsRequest

    *MsgPackData = MsgPackCreate(64)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Request, *MsgPackData)
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
Procedure.i BakaShrot_MissingAttachmentsRequestPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Request.BakaShrot_MissingAttachmentsRequest

    *Request = AllocateStructure(BakaShrot_MissingAttachmentsRequest)
    If Not *Request
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Request, *MsgPackData) Or *Request\PacketType <> #BakaShrot_PacketType_MissingAttachmentsRequest
        Goto DecodeFailed
    EndIf

    ProcedureReturn *Request

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Request)
    ProcedureReturn 0
EndProcedure
