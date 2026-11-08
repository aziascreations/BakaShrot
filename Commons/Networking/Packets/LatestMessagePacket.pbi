; ============================================================================
; ...
; ============================================================================


XIncludeFile "../Packets.pbi"

; S2C, answers a GetLatestMessage with the latest message of that topic/node combination.
; TopicId, NodeId: the server's own ids for them.
; TopicName, NodeName: their names, or their ids in digits if they have none.
; PushedAt: when it was pushed, see Packets.pbi.
Structure BakaShrot_LatestMessage Extends BakaShrot_PacketBase
    TopicId.l
    NodeId.l
    TopicName.s
    NodeName.s
    MessageId.q
    PushedAt.q
    JsonData.s
EndStructure


; Encodes *Latest into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_LatestMessagePacket_Encode(*Latest.BakaShrot_LatestMessage, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Latest\Magic      = #BakaShrot_ProtocolMagic
    *Latest\Version    = #BakaShrot_ProtocolVersion
    *Latest\PacketType = #BakaShrot_PacketType_LatestMessage

    *MsgPackData = MsgPackCreate(64)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Latest, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Latest\TopicId) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Latest\NodeId) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Latest\TopicName) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Latest\NodeName) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Latest\MessageId) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf
    If MsgPackWriteInteger(*MsgPackData, *Latest\PushedAt) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Latest\JsonData) <> #MsgPack_Error_Success
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
Procedure.i BakaShrot_LatestMessagePacket_Decode(*MsgPackData.MsgPackData)
    Protected *Latest.BakaShrot_LatestMessage
    Protected Value.q

    *Latest = AllocateStructure(BakaShrot_LatestMessage)
    If Not *Latest
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Latest, *MsgPackData) Or *Latest\PacketType <> #BakaShrot_PacketType_LatestMessage
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
    *Latest\TopicId = Value

    ; NodeId
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 0 Or Value > 65535
        Goto DecodeFailed
    EndIf
    *Latest\NodeId = Value

    ; TopicName
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Latest\TopicName = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ; NodeName
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Latest\NodeName = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ; MessageId
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    *Latest\MessageId = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or *Latest\MessageId < 1
        Goto DecodeFailed
    EndIf

    ; PushedAt
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    *Latest\PushedAt = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Not BakaShrot_IsValidTimestamp(*Latest\PushedAt)
        Goto DecodeFailed
    EndIf

    ; JsonData
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Latest\JsonData = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ProcedureReturn *Latest

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Latest)
    ProcedureReturn 0
EndProcedure
