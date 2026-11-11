;{- Code Header
; ==- Basic Info -================================
;     Name: PushMessagePacket.pbi
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

; C2S, asks the server to store a JSON message.
; Topic: where to push it, a name or an id in digits (Commons/Networking/Names.pbi),
;  "" for the topic of the client's authenticated identity. The client's
;  [BakaShrot.Client.<name>] PushTopics must allow it.
; The node is always the client's authenticated one, the client can't pick it.
; UploadId: the attachment uploaded for it (UploadStart, all of it stored), 0 for none.
; Answered with a MessagePushed or a RequestRefused.
Structure BakaShrot_PushMessage Extends BakaShrot_PacketBase
    Topic.s
    JsonData.s
    UploadId.q
EndStructure


; Encodes *Push into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_PushMessagePacket_Encode(*Push.BakaShrot_PushMessage, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Push\Magic      = #BakaShrot_ProtocolMagic
    *Push\Version    = #BakaShrot_ProtocolVersion
    *Push\PacketType = #BakaShrot_PacketType_PushMessage

    *MsgPackData = MsgPackCreate(64)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Push, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Push\Topic) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Push\JsonData) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If *Push\UploadId < 0 Or MsgPackWriteInteger(*MsgPackData, *Push\UploadId) <> #MsgPack_Error_Success
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
Procedure.i BakaShrot_PushMessagePacket_Decode(*MsgPackData.MsgPackData)
    Protected *Push.BakaShrot_PushMessage

    *Push = AllocateStructure(BakaShrot_PushMessage)
    If Not *Push
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Push, *MsgPackData) Or *Push\PacketType <> #BakaShrot_PacketType_PushMessage
        Goto DecodeFailed
    EndIf

    ; Topic
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Push\Topic = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ; JsonData
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Push\JsonData = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ; UploadId
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    *Push\UploadId = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or *Push\UploadId < 0
        Goto DecodeFailed
    EndIf

    ProcedureReturn *Push

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Push)
    ProcedureReturn 0
EndProcedure
