;{- Code Header
; ==- Basic Info -================================
;     Name: MessagePushedPacket.pbi
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

; S2C, answers a PushMessage with the id the message was stored under.
Structure BakaShrot_MessagePushed Extends BakaShrot_PacketBase
    MessageId.q
EndStructure


; Encodes *Pushed into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_MessagePushedPacket_Encode(*Pushed.BakaShrot_MessagePushed, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Pushed\Magic      = #BakaShrot_ProtocolMagic
    *Pushed\Version    = #BakaShrot_ProtocolVersion
    *Pushed\PacketType = #BakaShrot_PacketType_MessagePushed

    *MsgPackData = MsgPackCreate(32)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Pushed, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Pushed\MessageId) <> #MsgPack_Error_Success
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
Procedure.i BakaShrot_MessagePushedPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Pushed.BakaShrot_MessagePushed

    *Pushed = AllocateStructure(BakaShrot_MessagePushed)
    If Not *Pushed
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Pushed, *MsgPackData) Or *Pushed\PacketType <> #BakaShrot_PacketType_MessagePushed
        Goto DecodeFailed
    EndIf

    ; MessageId
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    *Pushed\MessageId = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or *Pushed\MessageId < 1
        Goto DecodeFailed
    EndIf

    ProcedureReturn *Pushed

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Pushed)
    ProcedureReturn 0
EndProcedure
