; ============================================================================
; ...
; ============================================================================


XIncludeFile "../Packets.pbi"

; S2C, answers an UploadStart: send the data with UploadChunks for UploadId, in
; order, ChunkSize bytes each (the last one what's left).
Structure BakaShrot_UploadStarted Extends BakaShrot_PacketBase
    UploadId.q
    ChunkSize.l
EndStructure


; Encodes *Started into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_UploadStartedPacket_Encode(*Started.BakaShrot_UploadStarted, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Started\Magic      = #BakaShrot_ProtocolMagic
    *Started\Version    = #BakaShrot_ProtocolVersion
    *Started\PacketType = #BakaShrot_PacketType_UploadStarted

    If *Started\UploadId < 1 Or *Started\ChunkSize < 1 Or *Started\ChunkSize > #BakaShrot_AttachmentChunkSize
        ProcedureReturn 0
    EndIf

    *MsgPackData = MsgPackCreate(64)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Started, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Started\UploadId) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Started\ChunkSize) <> #MsgPack_Error_Success
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
Procedure.i BakaShrot_UploadStartedPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Started.BakaShrot_UploadStarted, Value.q

    *Started = AllocateStructure(BakaShrot_UploadStarted)
    If Not *Started
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Started, *MsgPackData) Or *Started\PacketType <> #BakaShrot_PacketType_UploadStarted
        Goto DecodeFailed
    EndIf

    ; UploadId
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 1
        Goto DecodeFailed
    EndIf
    *Started\UploadId = Value

    ; ChunkSize
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 1 Or Value > #BakaShrot_AttachmentChunkSize
        Goto DecodeFailed
    EndIf
    *Started\ChunkSize = Value

    ProcedureReturn *Started

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Started)
    ProcedureReturn 0
EndProcedure
