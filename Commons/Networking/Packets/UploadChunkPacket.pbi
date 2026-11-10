; ============================================================================
; ...
; ============================================================================


XIncludeFile "../Packets.pbi"

; C2S, the next part of an upload: ChunkIndex (0 for the first) of UploadId.
; Answered with a ChunkStored, or a RequestRefused (the upload is then dropped).
Structure BakaShrot_UploadChunk Extends BakaShrot_PacketBase
    UploadId.q
    ChunkIndex.l
    *Data
    DataSize.l
EndStructure


; Encodes *Chunk into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_UploadChunkPacket_Encode(*Chunk.BakaShrot_UploadChunk, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Chunk\Magic      = #BakaShrot_ProtocolMagic
    *Chunk\Version    = #BakaShrot_ProtocolVersion
    *Chunk\PacketType = #BakaShrot_PacketType_UploadChunk

    If *Chunk\UploadId < 1 Or *Chunk\ChunkIndex < 0 Or *Chunk\ChunkIndex > #BakaShrot_MaxAttachmentChunks Or Not *Chunk\Data Or *Chunk\DataSize < 1 Or *Chunk\DataSize > #BakaShrot_AttachmentChunkSize
        ProcedureReturn 0
    EndIf

    *MsgPackData = MsgPackCreate(#BakaShrot_AttachmentChunkSize + 256)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Chunk, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Chunk\UploadId) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Chunk\ChunkIndex) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteBinary(*MsgPackData, *Chunk\Data, *Chunk\DataSize) <> #MsgPack_Error_Success
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

; Frees a decoded *Chunk and the data it holds.
Procedure BakaShrot_UploadChunkPacket_Free(*Chunk.BakaShrot_UploadChunk)
    If Not *Chunk
        ProcedureReturn
    EndIf
    If *Chunk\Data
        FreeMemory(*Chunk\Data)
    EndIf
    FreeStructure(*Chunk)
EndProcedure

; Decodes the packet at *MsgPackData's current offset into a freshly allocated struct.
; *MsgPackData stays owned by the caller, and should be discarded on failure.
; Returns 0 on failure, the caller owns the returned struct - free it with BakaShrot_UploadChunkPacket_Free().
Procedure.i BakaShrot_UploadChunkPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Chunk.BakaShrot_UploadChunk, Value.q

    *Chunk = AllocateStructure(BakaShrot_UploadChunk)
    If Not *Chunk
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Chunk, *MsgPackData) Or *Chunk\PacketType <> #BakaShrot_PacketType_UploadChunk
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
    *Chunk\UploadId = Value

    ; ChunkIndex
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 0 Or Value > #BakaShrot_MaxAttachmentChunks
        Goto DecodeFailed
    EndIf
    *Chunk\ChunkIndex = Value

    ; Data
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Binary
        Goto DecodeFailed
    EndIf
    ; A copy, freed with the packet (_Free()).
    *Chunk\Data = MsgPackCopyBinary(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Not *Chunk\Data
        Goto DecodeFailed
    EndIf
    *Chunk\DataSize = MemorySize(*Chunk\Data)
    If *Chunk\DataSize > #BakaShrot_AttachmentChunkSize
        Goto DecodeFailed
    EndIf

    ProcedureReturn *Chunk

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    BakaShrot_UploadChunkPacket_Free(*Chunk)
    ProcedureReturn 0
EndProcedure
