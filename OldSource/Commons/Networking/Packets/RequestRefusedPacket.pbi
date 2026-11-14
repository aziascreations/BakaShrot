;{- Code Header
; ==- Basic Info -================================
;     Name: RequestRefusedPacket.pbi
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

; S2C, answers a request the server won't fulfill, the connection stays open.
; Code: what kind of refusal, 1-#BakaShrot_Refused_Max, one of the
; #BakaShrot_Refused_* in Client/BakaShrot_ErrorCodes.pbi: what clients act
; on (protocol 6). Reason is only meant for logs and humans.
Structure BakaShrot_RequestRefused Extends BakaShrot_PacketBase
    Code.l
    Reason.s
EndStructure


; Encodes *Refused into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_RequestRefusedPacket_Encode(*Refused.BakaShrot_RequestRefused, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Refused\Magic      = #BakaShrot_ProtocolMagic
    *Refused\Version    = #BakaShrot_ProtocolVersion
    *Refused\PacketType = #BakaShrot_PacketType_RequestRefused

    If Not BakaShrot_IsRefusalCode(*Refused\Code)
        ProcedureReturn 0
    EndIf

    *MsgPackData = MsgPackCreate(64)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Refused, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Refused\Code) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Refused\Reason) <> #MsgPack_Error_Success
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
Procedure.i BakaShrot_RequestRefusedPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Refused.BakaShrot_RequestRefused, Value.q

    *Refused = AllocateStructure(BakaShrot_RequestRefused)
    If Not *Refused
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Refused, *MsgPackData) Or *Refused\PacketType <> #BakaShrot_PacketType_RequestRefused
        Goto DecodeFailed
    EndIf

    ; Code
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Not BakaShrot_IsRefusalCode(Value)
        Goto DecodeFailed
    EndIf
    *Refused\Code = Value

    ; Reason
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Refused\Reason = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ProcedureReturn *Refused

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Refused)
    ProcedureReturn 0
EndProcedure
