; ============================================================================
; ...
; ============================================================================


XIncludeFile "../Packets.pbi"

; S2C, tells the client its challenge response was accepted and it is now authenticated.
; Only carries the base fields.
Structure BakaShrot_AuthAccepted Extends BakaShrot_PacketBase
EndStructure


; Encodes *Accepted into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_AuthAcceptedPacket_Encode(*Accepted.BakaShrot_AuthAccepted, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Accepted\Magic      = #BakaShrot_ProtocolMagic
    *Accepted\Version    = #BakaShrot_ProtocolVersion
    *Accepted\PacketType = #BakaShrot_PacketType_AuthAccepted

    *MsgPackData = MsgPackCreate(16)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Accepted, *MsgPackData)
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
Procedure.i BakaShrot_AuthAcceptedPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Accepted.BakaShrot_AuthAccepted

    *Accepted = AllocateStructure(BakaShrot_AuthAccepted)
    If Not *Accepted
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Accepted, *MsgPackData) Or *Accepted\PacketType <> #BakaShrot_PacketType_AuthAccepted
        FreeStructure(*Accepted)
        ProcedureReturn 0
    EndIf

    ProcedureReturn *Accepted
EndProcedure
