; ============================================================================
; ...
; ============================================================================


XIncludeFile "../Packets.pbi"
XIncludeFile "GetMessagesPacket.pbi"

; One message of a Messages answer.
Structure BakaShrot_MessagesEntry
    MessageId.q
    ; When it was pushed, see Packets.pbi.
    PushedAt.q
    ; Its attachment's size in bytes, 0 for none, and whether this server has
    ; all of it yet (a replicated one comes after its message).
    AttachmentSize.q
    AttachmentReady.l
    JsonData.s
EndStructure

; About how big a Messages answer gets: messages are added while they fit
; in it, and a bigger one goes alone (up to #BakaShrot_MaxMessageSize).
#BakaShrot_MessagesBatchBytes = 1024 * 1024

; Encoded size of the answer's own fields, and of each message on top of its
; JSON, rounded up. Used to stop an answer before it gets over #BakaShrot_MaxPacketSize.
#BakaShrot_MessagesOverhead        = 64 + 2 * (#BakaShrot_MaxNameLength + 2)
#BakaShrot_MessagesMessageOverhead = 40

; S2C, answers a GetMessages with the messages of that topic/node combination
; stored after the asked id, in message id order: as many as were asked for,
; or fewer if they didn't fit in about #BakaShrot_MessagesBatchBytes. None
; if there are no more.
; TopicId, NodeId: the server's own ids for them.
; TopicName, NodeName: their names, or their ids in digits if they have none.
; More: 1 if more messages follow the last one, ask again after it.
; On the wire: topic id, node id, topic name, node name, more, message
; count, then each message's id and JSON.
Structure BakaShrot_Messages Extends BakaShrot_PacketBase
    TopicId.l
    NodeId.l
    TopicName.s
    NodeName.s
    More.l
    List Messages.BakaShrot_MessagesEntry()
EndStructure


; Encodes *Answer into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_MessagesPacket_Encode(*Answer.BakaShrot_Messages, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Answer\Magic      = #BakaShrot_ProtocolMagic
    *Answer\Version    = #BakaShrot_ProtocolVersion
    *Answer\PacketType = #BakaShrot_PacketType_Messages

    If ListSize(*Answer\Messages()) > #BakaShrot_MaxGetMessages
        ProcedureReturn 0
    EndIf

    *MsgPackData = MsgPackCreate(256)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Answer, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Answer\TopicId) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Answer\NodeId) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Answer\TopicName) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Answer\NodeName) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, Bool(*Answer\More)) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    ; Messages
    If MsgPackWriteInteger(*MsgPackData, ListSize(*Answer\Messages())) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf
    ForEach *Answer\Messages()
        If MsgPackWriteInteger(*MsgPackData, *Answer\Messages()\MessageId) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
        If MsgPackWriteInteger(*MsgPackData, *Answer\Messages()\PushedAt) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
        If MsgPackWriteString(*MsgPackData, *Answer\Messages()\JsonData) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
        If MsgPackWriteInteger(*MsgPackData, *Answer\Messages()\AttachmentSize) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
        If MsgPackWriteInteger(*MsgPackData, *Answer\Messages()\AttachmentReady) <> #MsgPack_Error_Success
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
Procedure.i BakaShrot_MessagesPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Answer.BakaShrot_Messages
    Protected Value.q, Count.q, i.q, PreviousMessageId.q

    *Answer = AllocateStructure(BakaShrot_Messages)
    If Not *Answer
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Answer, *MsgPackData) Or *Answer\PacketType <> #BakaShrot_PacketType_Messages
        Goto DecodeFailed
    EndIf

    ; TopicId
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 0 Or Value > 65535
        Goto DecodeFailed
    EndIf
    *Answer\TopicId = Value

    ; NodeId
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 0 Or Value > 65535
        Goto DecodeFailed
    EndIf
    *Answer\NodeId = Value

    ; TopicName
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Answer\TopicName = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ; NodeName
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Answer\NodeName = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ; More
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 0 Or Value > 1
        Goto DecodeFailed
    EndIf
    *Answer\More = Value

    ; Message count
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Count = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Count < 0 Or Count > #BakaShrot_MaxGetMessages
        Goto DecodeFailed
    EndIf

    ; Messages
    PreviousMessageId = 0
    For i = 1 To Count
        AddElement(*Answer\Messages())

        ; MessageId
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
            Goto DecodeFailed
        EndIf
        *Answer\Messages()\MessageId = MsgPackReadInteger(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or *Answer\Messages()\MessageId <= PreviousMessageId
            Goto DecodeFailed
        EndIf
        PreviousMessageId = *Answer\Messages()\MessageId

        ; PushedAt
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
            Goto DecodeFailed
        EndIf
        *Answer\Messages()\PushedAt = MsgPackReadInteger(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Not BakaShrot_IsValidTimestamp(*Answer\Messages()\PushedAt)
            Goto DecodeFailed
        EndIf

        ; JsonData
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
            Goto DecodeFailed
        EndIf
        *Answer\Messages()\JsonData = MsgPackReadString(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
            Goto DecodeFailed
        EndIf
        ; AttachmentSize
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
            Goto DecodeFailed
        EndIf
        *Answer\Messages()\AttachmentSize = MsgPackReadInteger(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or *Answer\Messages()\AttachmentSize < 0 Or *Answer\Messages()\AttachmentSize > #BakaShrot_MaxAttachmentSize
            Goto DecodeFailed
        EndIf

        ; AttachmentReady
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
            Goto DecodeFailed
        EndIf
        *Answer\Messages()\AttachmentReady = MsgPackReadInteger(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or *Answer\Messages()\AttachmentReady < 0 Or *Answer\Messages()\AttachmentReady > 1
            Goto DecodeFailed
        EndIf
    Next

    ProcedureReturn *Answer

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Answer)
    ProcedureReturn 0
EndProcedure
