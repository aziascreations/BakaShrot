; ============================================================================
; ...
; ============================================================================


XIncludeFile "ResolveNamePacket.pbi"

; C2S, asks for every topic or node the server has, with their ids and names.
; Kind: #BakaShrot_NameKind_Topic or #BakaShrot_NameKind_Node.
; Topics: only those the client may push to or read, unless it may query.
; Answered with a NamesList.
Structure BakaShrot_ListNames Extends BakaShrot_PacketBase
    Kind.l
EndStructure


; Encodes *Request into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_ListNamesPacket_Encode(*Request.BakaShrot_ListNames, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Request\Magic      = #BakaShrot_ProtocolMagic
    *Request\Version    = #BakaShrot_ProtocolVersion
    *Request\PacketType = #BakaShrot_PacketType_ListNames

    *MsgPackData = MsgPackCreate(32)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Request, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Request\Kind) <> #MsgPack_Error_Success
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
Procedure.i BakaShrot_ListNamesPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Request.BakaShrot_ListNames
    Protected Value.q

    *Request = AllocateStructure(BakaShrot_ListNames)
    If Not *Request
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Request, *MsgPackData) Or *Request\PacketType <> #BakaShrot_PacketType_ListNames
        Goto DecodeFailed
    EndIf

    ; Kind
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or (Value <> #BakaShrot_NameKind_Topic And Value <> #BakaShrot_NameKind_Node)
        Goto DecodeFailed
    EndIf
    *Request\Kind = Value

    ProcedureReturn *Request

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Request)
    ProcedureReturn 0
EndProcedure
