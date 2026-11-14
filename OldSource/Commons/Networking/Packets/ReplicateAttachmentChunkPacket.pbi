;{- Code Header
; ==- Basic Info -================================
;     Name: ReplicateAttachmentChunkPacket.pbi
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

; P2S, part ChunkIndex of the attachment of Topic:Node#MessageId (names, never
; digits), a message the server already has, as MissingAttachments asked for.
; The size and SHA-256 came with the message (ReplicateMessages).
; Answered with a ChunkStored, or a RequestRefused.
Structure BakaShrot_ReplicateAttachmentChunk Extends BakaShrot_PacketBase
    Topic.s
    Node.s
    MessageId.q
    ChunkIndex.l
    *Data
    DataSize.l
EndStructure


; Encodes *Chunk into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_ReplicateAttachmentChunkPacket_Encode(*Chunk.BakaShrot_ReplicateAttachmentChunk, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Chunk\Magic      = #BakaShrot_ProtocolMagic
    *Chunk\Version    = #BakaShrot_ProtocolVersion
    *Chunk\PacketType = #BakaShrot_PacketType_ReplicateAttachmentChunk

    If Not BakaShrot_IsValidName(*Chunk\Topic) Or Not BakaShrot_IsValidName(*Chunk\Node) Or *Chunk\MessageId < 1 Or *Chunk\ChunkIndex < 0 Or *Chunk\ChunkIndex > #BakaShrot_MaxAttachmentChunks Or Not *Chunk\Data Or *Chunk\DataSize < 1 Or *Chunk\DataSize > #BakaShrot_AttachmentChunkSize
        ProcedureReturn 0
    EndIf

    *MsgPackData = MsgPackCreate(#BakaShrot_AttachmentChunkSize + 256)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Chunk, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Chunk\Topic) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Chunk\Node) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Chunk\MessageId) <> #MsgPack_Error_Success
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
Procedure BakaShrot_ReplicateAttachmentChunkPacket_Free(*Chunk.BakaShrot_ReplicateAttachmentChunk)
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
; Returns 0 on failure, the caller owns the returned struct - free it with BakaShrot_ReplicateAttachmentChunkPacket_Free().
Procedure.i BakaShrot_ReplicateAttachmentChunkPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Chunk.BakaShrot_ReplicateAttachmentChunk, Value.q

    *Chunk = AllocateStructure(BakaShrot_ReplicateAttachmentChunk)
    If Not *Chunk
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Chunk, *MsgPackData) Or *Chunk\PacketType <> #BakaShrot_PacketType_ReplicateAttachmentChunk
        Goto DecodeFailed
    EndIf

    ; Topic
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Chunk\Topic = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Not BakaShrot_IsValidName(*Chunk\Topic)
        Goto DecodeFailed
    EndIf

    ; Node
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Chunk\Node = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Not BakaShrot_IsValidName(*Chunk\Node)
        Goto DecodeFailed
    EndIf

    ; MessageId
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 1
        Goto DecodeFailed
    EndIf
    *Chunk\MessageId = Value

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
    BakaShrot_ReplicateAttachmentChunkPacket_Free(*Chunk)
    ProcedureReturn 0
EndProcedure
