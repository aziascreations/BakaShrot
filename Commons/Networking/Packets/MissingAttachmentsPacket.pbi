;{- Code Header
; ==- Basic Info -================================
;     Name: MissingAttachmentsPacket.pbi
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

; Most attachments one MissingAttachments lists, the next check-in asks again.
#BakaShrot_MaxMissingAttachments = 256

; One attachment the server is missing: of Topic:Node#MessageId (names, never
; digits), from part NextChunk on (0 if it has none of it yet).
Structure BakaShrot_MissingAttachment
    Topic.s
    Node.s
    MessageId.q
    NextChunk.l
EndStructure

; S2P, answers a MissingAttachmentsRequest: attachments of messages the server
; has, that it takes from this peer, and doesn't have all of yet. Maybe none.
; On the wire: the count, then each one's topic, node, message id and next chunk.
Structure BakaShrot_MissingAttachments Extends BakaShrot_PacketBase
    List Attachments.BakaShrot_MissingAttachment()
EndStructure


; Encodes *Answer into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_MissingAttachmentsPacket_Encode(*Answer.BakaShrot_MissingAttachments, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Answer\Magic      = #BakaShrot_ProtocolMagic
    *Answer\Version    = #BakaShrot_ProtocolVersion
    *Answer\PacketType = #BakaShrot_PacketType_MissingAttachments

    If ListSize(*Answer\Attachments()) > #BakaShrot_MaxMissingAttachments
        ProcedureReturn 0
    EndIf

    *MsgPackData = MsgPackCreate(256)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Answer, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, ListSize(*Answer\Attachments())) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf
    ForEach *Answer\Attachments()
        If MsgPackWriteString(*MsgPackData, *Answer\Attachments()\Topic) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
        If MsgPackWriteString(*MsgPackData, *Answer\Attachments()\Node) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
        If MsgPackWriteInteger(*MsgPackData, *Answer\Attachments()\MessageId) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
        If MsgPackWriteInteger(*MsgPackData, *Answer\Attachments()\NextChunk) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
    Next

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
Procedure.i BakaShrot_MissingAttachmentsPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Answer.BakaShrot_MissingAttachments
    Protected Value.q, Count.q, i.q

    *Answer = AllocateStructure(BakaShrot_MissingAttachments)
    If Not *Answer
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Answer, *MsgPackData) Or *Answer\PacketType <> #BakaShrot_PacketType_MissingAttachments
        Goto DecodeFailed
    EndIf

    ; Count
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Count = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Count < 0 Or Count > #BakaShrot_MaxMissingAttachments
        Goto DecodeFailed
    EndIf

    For i = 1 To Count
        AddElement(*Answer\Attachments())

        ; Topic
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
            Goto DecodeFailed
        EndIf
        *Answer\Attachments()\Topic = MsgPackReadString(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Not BakaShrot_IsValidName(*Answer\Attachments()\Topic)
            Goto DecodeFailed
        EndIf

        ; Node
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
            Goto DecodeFailed
        EndIf
        *Answer\Attachments()\Node = MsgPackReadString(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Not BakaShrot_IsValidName(*Answer\Attachments()\Node)
            Goto DecodeFailed
        EndIf

        ; MessageId
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
            Goto DecodeFailed
        EndIf
        *Answer\Attachments()\MessageId = MsgPackReadInteger(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or *Answer\Attachments()\MessageId < 1
            Goto DecodeFailed
        EndIf

        ; NextChunk
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
            Goto DecodeFailed
        EndIf
        Value = MsgPackReadInteger(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 0 Or Value > #BakaShrot_MaxAttachmentChunks
            Goto DecodeFailed
        EndIf
        *Answer\Attachments()\NextChunk = Value
    Next

    ProcedureReturn *Answer

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Answer)
    ProcedureReturn 0
EndProcedure
