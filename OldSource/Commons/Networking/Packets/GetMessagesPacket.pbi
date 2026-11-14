;{- Code Header
; ==- Basic Info -================================
;     Name: GetMessagesPacket.pbi
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

; Most messages a GetMessages may ask for.
#BakaShrot_MaxGetMessages = 10000

; C2S, asks for the messages of a topic/node combination stored after
; AfterMessageId (0 for the first ones), in message id order, at most Limit
; (1-#BakaShrot_MaxGetMessages) of them.
; Topic, Node: each a name or an id in digits (Commons/Networking/Names.pbi).
; The client's [BakaShrot.Client.<name>] ReadTopics must allow the topic.
; Answered with a Messages (maybe with none) or a RequestRefused.
Structure BakaShrot_GetMessages Extends BakaShrot_PacketBase
    Topic.s
    Node.s
    AfterMessageId.q
    Limit.l
EndStructure


; Encodes *Request into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_GetMessagesPacket_Encode(*Request.BakaShrot_GetMessages, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Request\Magic      = #BakaShrot_ProtocolMagic
    *Request\Version    = #BakaShrot_ProtocolVersion
    *Request\PacketType = #BakaShrot_PacketType_GetMessages

    If *Request\AfterMessageId < 0 Or *Request\Limit < 1 Or *Request\Limit > #BakaShrot_MaxGetMessages
        ProcedureReturn 0
    EndIf

    *MsgPackData = MsgPackCreate(64)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Request, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Request\Topic) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Request\Node) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Request\AfterMessageId) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Request\Limit) <> #MsgPack_Error_Success
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
Procedure.i BakaShrot_GetMessagesPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Request.BakaShrot_GetMessages
    Protected Value.q

    *Request = AllocateStructure(BakaShrot_GetMessages)
    If Not *Request
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Request, *MsgPackData) Or *Request\PacketType <> #BakaShrot_PacketType_GetMessages
        Goto DecodeFailed
    EndIf

    ; Topic
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Request\Topic = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ; Node
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Request\Node = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ; AfterMessageId
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    *Request\AfterMessageId = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or *Request\AfterMessageId < 0
        Goto DecodeFailed
    EndIf

    ; Limit
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 1 Or Value > #BakaShrot_MaxGetMessages
        Goto DecodeFailed
    EndIf
    *Request\Limit = Value

    ProcedureReturn *Request

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Request)
    ProcedureReturn 0
EndProcedure
