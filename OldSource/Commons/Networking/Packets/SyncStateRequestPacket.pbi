;{- Code Header
; ==- Basic Info -================================
;     Name: SyncStateRequestPacket.pbi
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

; Peer -> Server, asks for the server's sync state, to know which messages it's missing.
; Answered with a SyncState or a RequestRefused. Only carries the base fields.
Structure BakaShrot_SyncStateRequest Extends BakaShrot_PacketBase
EndStructure


; Encodes *Request into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_SyncStateRequestPacket_Encode(*Request.BakaShrot_SyncStateRequest, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Request\Magic      = #BakaShrot_ProtocolMagic
    *Request\Version    = #BakaShrot_ProtocolVersion
    *Request\PacketType = #BakaShrot_PacketType_SyncStateRequest

    *MsgPackData = MsgPackCreate(16)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Request, *MsgPackData)
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
Procedure.i BakaShrot_SyncStateRequestPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Request.BakaShrot_SyncStateRequest

    *Request = AllocateStructure(BakaShrot_SyncStateRequest)
    If Not *Request
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Request, *MsgPackData) Or *Request\PacketType <> #BakaShrot_PacketType_SyncStateRequest
        FreeStructure(*Request)
        ProcedureReturn 0
    EndIf

    ProcedureReturn *Request
EndProcedure
