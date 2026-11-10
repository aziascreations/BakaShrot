; ============================================================================
; ...
; ============================================================================


XIncludeFile "../Packets.pbi"

; One message of a ReplicateMessages batch.
; PushedAt: when it was pushed to its origin (Packets.pbi), stored as is.
; AttachmentSize, AttachmentSha256: its attachment's, 0 for none. The data
; itself follows on its own, once the messages are caught up
; (MissingAttachments, ReplicateAttachmentChunk).
Structure BakaShrot_ReplicatedMessage
    MessageId.q
    PushedAt.q
    JsonData.s
    AttachmentSize.q
    AttachmentSha256.a[#BakaShrot_Sha256Size]
EndStructure

; Most messages a batch may carry, whatever the sender's PeerBatchSize.
; #BakaShrot_ReplicateBatchBytes usually stops a batch well before that.
#BakaShrot_MaxReplicateBatch = 10000

; About how big a batch gets: messages are added while they fit in it, and
; a bigger one goes alone (up to #BakaShrot_MaxMessageSize). Small enough to
; keep each batch's transaction and memory short, like when 64 KB was the
; biggest packet.
#BakaShrot_ReplicateBatchBytes = 65536

; Encoded size of a batch's own fields, and of each message on top of its
; JSON, rounded up. Used to stop a batch before it gets over #BakaShrot_MaxPacketSize.
#BakaShrot_ReplicateBatchOverhead   = 64 + 2 * (#BakaShrot_MaxNameLength + 2)
#BakaShrot_ReplicateMessageOverhead = 70

; Peer -> Server, messages the server is missing for one topic/node, in
; message id order, with the message ids they were stored under on their
; origin. Topic and Node are names, never ids (Commons/Networking/Names.pbi):
; the server stores them under its own ids for those names, and refuses
; names it doesn't know.
; On the wire: topic, node, message count, then each message's id, PushedAt,
; JSON, attachment size and SHA-256.
; Answered with a MessagePushed carrying the last message's id, or a RequestRefused.
Structure BakaShrot_ReplicateMessages Extends BakaShrot_PacketBase
    Topic.s
    Node.s
    List Messages.BakaShrot_ReplicatedMessage()
EndStructure


; Encodes *Batch into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_ReplicateMessagesPacket_Encode(*Batch.BakaShrot_ReplicateMessages, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Batch\Magic      = #BakaShrot_ProtocolMagic
    *Batch\Version    = #BakaShrot_ProtocolVersion
    *Batch\PacketType = #BakaShrot_PacketType_ReplicateMessages

    If ListSize(*Batch\Messages()) < 1 Or ListSize(*Batch\Messages()) > #BakaShrot_MaxReplicateBatch
        ProcedureReturn 0
    EndIf

    *MsgPackData = MsgPackCreate(256)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Batch, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Batch\Topic) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Batch\Node) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    ; Messages
    If MsgPackWriteInteger(*MsgPackData, ListSize(*Batch\Messages())) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf
    ForEach *Batch\Messages()
        If MsgPackWriteInteger(*MsgPackData, *Batch\Messages()\MessageId) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
        If MsgPackWriteInteger(*MsgPackData, *Batch\Messages()\PushedAt) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
        If MsgPackWriteString(*MsgPackData, *Batch\Messages()\JsonData) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
        If MsgPackWriteInteger(*MsgPackData, *Batch\Messages()\AttachmentSize) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
        ; Empty without an attachment.
        If *Batch\Messages()\AttachmentSize > 0
            If MsgPackWriteBinary(*MsgPackData, @*Batch\Messages()\AttachmentSha256[0], #BakaShrot_Sha256Size) <> #MsgPack_Error_Success
                Goto EncodeFailed
            EndIf
        ElseIf MsgPackWriteBinary(*MsgPackData, @*Batch\Messages()\AttachmentSha256[0], 0) <> #MsgPack_Error_Success
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
; Message ids must be 1 or more, and strictly increasing.
; *MsgPackData stays owned by the caller, and should be discarded on failure.
; Returns 0 on failure, the caller owns the returned struct - free it with FreeStructure.
Procedure.i BakaShrot_ReplicateMessagesPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Batch.BakaShrot_ReplicateMessages
    Protected Value.q, Count.q, i.q, PreviousMessageId.q, ReadSize.q

    *Batch = AllocateStructure(BakaShrot_ReplicateMessages)
    If Not *Batch
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Batch, *MsgPackData) Or *Batch\PacketType <> #BakaShrot_PacketType_ReplicateMessages
        Goto DecodeFailed
    EndIf

    ; Topic
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Batch\Topic = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Not BakaShrot_IsValidName(*Batch\Topic)
        Goto DecodeFailed
    EndIf

    ; Node
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Batch\Node = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Not BakaShrot_IsValidName(*Batch\Node)
        Goto DecodeFailed
    EndIf

    ; Message count
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Count = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Count < 1 Or Count > #BakaShrot_MaxReplicateBatch
        Goto DecodeFailed
    EndIf

    ; Messages
    PreviousMessageId = 0
    For i = 1 To Count
        AddElement(*Batch\Messages())

        ; MessageId
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
            Goto DecodeFailed
        EndIf
        *Batch\Messages()\MessageId = MsgPackReadInteger(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or *Batch\Messages()\MessageId <= PreviousMessageId
            Goto DecodeFailed
        EndIf
        PreviousMessageId = *Batch\Messages()\MessageId

        ; PushedAt
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
            Goto DecodeFailed
        EndIf
        *Batch\Messages()\PushedAt = MsgPackReadInteger(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Not BakaShrot_IsValidTimestamp(*Batch\Messages()\PushedAt)
            Goto DecodeFailed
        EndIf

        ; JsonData
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
            Goto DecodeFailed
        EndIf
        *Batch\Messages()\JsonData = MsgPackReadString(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
            Goto DecodeFailed
        EndIf
        ; AttachmentSize
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
            Goto DecodeFailed
        EndIf
        *Batch\Messages()\AttachmentSize = MsgPackReadInteger(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or *Batch\Messages()\AttachmentSize < 0 Or *Batch\Messages()\AttachmentSize > #BakaShrot_MaxAttachmentSize
            Goto DecodeFailed
        EndIf

        ; AttachmentSha256: 32 bytes with an attachment, empty without.
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Binary
            Goto DecodeFailed
        EndIf
        ReadSize = MsgPackReadBinary(*MsgPackData, @*Batch\Messages()\AttachmentSha256[0], #BakaShrot_Sha256Size)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or (ReadSize <> #BakaShrot_Sha256Size And *Batch\Messages()\AttachmentSize > 0) Or (ReadSize <> 0 And *Batch\Messages()\AttachmentSize = 0)
            Goto DecodeFailed
        EndIf
    Next

    ProcedureReturn *Batch

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Batch)
    ProcedureReturn 0
EndProcedure
