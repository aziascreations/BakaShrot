;{- Code Header
; ==- Basic Info -================================
;     Name: ChunkStoredPacket.pbi
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

; S2C (and S2P), answers an UploadChunk (or a ReplicateAttachmentChunk): Received
; bytes are stored so far. Complete is 1 once they all are, and their SHA-256
; checked out.
Structure BakaShrot_ChunkStored Extends BakaShrot_PacketBase
    Received.q
    Complete.l
EndStructure


; Encodes *Stored into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_ChunkStoredPacket_Encode(*Stored.BakaShrot_ChunkStored, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Stored\Magic      = #BakaShrot_ProtocolMagic
    *Stored\Version    = #BakaShrot_ProtocolVersion
    *Stored\PacketType = #BakaShrot_PacketType_ChunkStored

    If *Stored\Received < 0 Or *Stored\Received > #BakaShrot_MaxAttachmentSize Or *Stored\Complete < 0 Or *Stored\Complete > 1
        ProcedureReturn 0
    EndIf

    *MsgPackData = MsgPackCreate(64)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Stored, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Stored\Received) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Stored\Complete) <> #MsgPack_Error_Success
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
Procedure.i BakaShrot_ChunkStoredPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Stored.BakaShrot_ChunkStored, Value.q

    *Stored = AllocateStructure(BakaShrot_ChunkStored)
    If Not *Stored
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Stored, *MsgPackData) Or *Stored\PacketType <> #BakaShrot_PacketType_ChunkStored
        Goto DecodeFailed
    EndIf

    ; Received
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 0 Or Value > #BakaShrot_MaxAttachmentSize
        Goto DecodeFailed
    EndIf
    *Stored\Received = Value

    ; Complete
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 0 Or Value > 1
        Goto DecodeFailed
    EndIf
    *Stored\Complete = Value

    ProcedureReturn *Stored

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Stored)
    ProcedureReturn 0
EndProcedure
