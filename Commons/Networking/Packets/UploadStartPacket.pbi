; ============================================================================
; ...
; ============================================================================


XIncludeFile "../Packets.pbi"

; C2S, starts uploading an attachment, before pushing the message it goes with
; (PushMessage's UploadId): Size bytes (1 to #BakaShrot_MaxAttachmentSize, and the
; server's [BakaShrot.Server] MaxAttachmentSize), whose SHA-256 is Sha256.
; Topic: where the message will be pushed, as PushMessage's: "" for the client's
; own. The client's PushTopics must allow it.
; Answered with an UploadStarted, or a RequestRefused.
Structure BakaShrot_UploadStart Extends BakaShrot_PacketBase
    Topic.s
    Size.q
    Sha256.a[#BakaShrot_Sha256Size]
EndStructure


; Encodes *Start into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_UploadStartPacket_Encode(*Start.BakaShrot_UploadStart, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Start\Magic      = #BakaShrot_ProtocolMagic
    *Start\Version    = #BakaShrot_ProtocolVersion
    *Start\PacketType = #BakaShrot_PacketType_UploadStart

    If *Start\Size < 1 Or *Start\Size > #BakaShrot_MaxAttachmentSize
        ProcedureReturn 0
    EndIf

    *MsgPackData = MsgPackCreate(64)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Start, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Start\Topic) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Start\Size) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteBinary(*MsgPackData, @*Start\Sha256[0], #BakaShrot_Sha256Size) <> #MsgPack_Error_Success
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
Procedure.i BakaShrot_UploadStartPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Start.BakaShrot_UploadStart, Value.q, ReadSize.q

    *Start = AllocateStructure(BakaShrot_UploadStart)
    If Not *Start
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Start, *MsgPackData) Or *Start\PacketType <> #BakaShrot_PacketType_UploadStart
        Goto DecodeFailed
    EndIf

    ; Topic
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Start\Topic = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ; Size
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 1 Or Value > #BakaShrot_MaxAttachmentSize
        Goto DecodeFailed
    EndIf
    *Start\Size = Value

    ; Sha256
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Binary
        Goto DecodeFailed
    EndIf
    ; Anything bigger than the struct's array is rejected by MsgPackReadBinary, anything smaller by the size check.
    ReadSize = MsgPackReadBinary(*MsgPackData, @*Start\Sha256[0], #BakaShrot_Sha256Size)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or ReadSize <> #BakaShrot_Sha256Size
        Goto DecodeFailed
    EndIf

    ProcedureReturn *Start

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Start)
    ProcedureReturn 0
EndProcedure
