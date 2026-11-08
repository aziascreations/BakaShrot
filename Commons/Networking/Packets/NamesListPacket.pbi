; ============================================================================
; ...
; ============================================================================


XIncludeFile "ResolveNamePacket.pbi"

; One topic or node of a NamesList.
; Origin: where its name comes from, "config" (named in the config) or "id"
; (unnamed, Name is ""). See Server/Storage/Names.pbi.
Structure BakaShrot_NameEntry
    Id.l
    Name.s
    Origin.s
EndStructure

#BakaShrot_MaxNamesListEntries = 65536

; S2C, answers a ListNames, by id.
; Kind: the one asked about. Truncated: 1 if there were more than fit in one
; packet, the first ones by id are listed.
; On the wire: Kind, Truncated, entry count, then each entry's id, name and origin.
Structure BakaShrot_NamesList Extends BakaShrot_PacketBase
    Kind.l
    Truncated.l
    List Entries.BakaShrot_NameEntry()
EndStructure


; Encoded size of the packet's own fields, and of each entry on top of its
; name and origin, rounded up. Used to cut a list before it gets over
; #BakaShrot_MaxPacketSize.
#BakaShrot_NamesListOverhead      = 64
#BakaShrot_NamesListEntryOverhead = 16


; Encodes *List into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_NamesListPacket_Encode(*List.BakaShrot_NamesList, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *List\Magic      = #BakaShrot_ProtocolMagic
    *List\Version    = #BakaShrot_ProtocolVersion
    *List\PacketType = #BakaShrot_PacketType_NamesList

    If ListSize(*List\Entries()) > #BakaShrot_MaxNamesListEntries
        ProcedureReturn 0
    EndIf

    *MsgPackData = MsgPackCreate(256)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*List, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *List\Kind) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, Bool(*List\Truncated)) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, ListSize(*List\Entries())) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf
    ForEach *List\Entries()
        If MsgPackWriteInteger(*MsgPackData, *List\Entries()\Id) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
        If MsgPackWriteString(*MsgPackData, *List\Entries()\Name) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
        If MsgPackWriteString(*MsgPackData, *List\Entries()\Origin) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
    Next

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
Procedure.i BakaShrot_NamesListPacket_Decode(*MsgPackData.MsgPackData)
    Protected *List.BakaShrot_NamesList
    Protected Value.q, Count.q, i.q

    *List = AllocateStructure(BakaShrot_NamesList)
    If Not *List
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*List, *MsgPackData) Or *List\PacketType <> #BakaShrot_PacketType_NamesList
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
    *List\Kind = Value

    ; Truncated
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 0 Or Value > 1
        Goto DecodeFailed
    EndIf
    *List\Truncated = Value

    ; Entries
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Count = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Count < 0 Or Count > #BakaShrot_MaxNamesListEntries
        Goto DecodeFailed
    EndIf
    For i = 1 To Count
        AddElement(*List\Entries())

        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
            Goto DecodeFailed
        EndIf
        Value = MsgPackReadInteger(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 0 Or Value > #BakaShrot_MaxId
            Goto DecodeFailed
        EndIf
        *List\Entries()\Id = Value

        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
            Goto DecodeFailed
        EndIf
        *List\Entries()\Name = MsgPackReadString(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
            Goto DecodeFailed
        EndIf

        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
            Goto DecodeFailed
        EndIf
        *List\Entries()\Origin = MsgPackReadString(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
            Goto DecodeFailed
        EndIf
    Next

    ProcedureReturn *List

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*List)
    ProcedureReturn 0
EndProcedure
