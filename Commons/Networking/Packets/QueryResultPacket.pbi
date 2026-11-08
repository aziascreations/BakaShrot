; ============================================================================
; ...
; ============================================================================


XIncludeFile "../Packets.pbi"

; S2C, answers a QueryRequest with its rows, as JSON:
;   {"columns": ["name", ...], "rows": [["value", ...], ...]}
; Every value is a string, or null for NULL: PureBasic doesn't report SQLite's column types.
Structure BakaShrot_QueryResult Extends BakaShrot_PacketBase
    JsonResult.s
EndStructure


; Encodes *Result into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_QueryResultPacket_Encode(*Result.BakaShrot_QueryResult, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Result\Magic      = #BakaShrot_ProtocolMagic
    *Result\Version    = #BakaShrot_ProtocolVersion
    *Result\PacketType = #BakaShrot_PacketType_QueryResult

    *MsgPackData = MsgPackCreate(64)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Result, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Result\JsonResult) <> #MsgPack_Error_Success
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
Procedure.i BakaShrot_QueryResultPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Result.BakaShrot_QueryResult

    *Result = AllocateStructure(BakaShrot_QueryResult)
    If Not *Result
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Result, *MsgPackData) Or *Result\PacketType <> #BakaShrot_PacketType_QueryResult
        Goto DecodeFailed
    EndIf

    ; JsonResult
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Result\JsonResult = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ProcedureReturn *Result

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Result)
    ProcedureReturn 0
EndProcedure
