;{- Code Header
; ==- Basic Info -================================
;     Name: NameResolvedPacket.pbi
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


XIncludeFile "ResolveNamePacket.pbi"

; S2C, answers a ResolveName.
; Kind: the one asked about, #BakaShrot_NameKind_Topic or #BakaShrot_NameKind_Node.
; Id: the server's own id for it, 0-65535.
; Name: its name, "" if it has none.
Structure BakaShrot_NameResolved Extends BakaShrot_PacketBase
    Kind.l
    Id.l
    Name.s
EndStructure


; Encodes *Answer into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_NameResolvedPacket_Encode(*Answer.BakaShrot_NameResolved, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Answer\Magic      = #BakaShrot_ProtocolMagic
    *Answer\Version    = #BakaShrot_ProtocolVersion
    *Answer\PacketType = #BakaShrot_PacketType_NameResolved

    *MsgPackData = MsgPackCreate(64)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Answer, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Answer\Kind) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Answer\Id) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Answer\Name) <> #MsgPack_Error_Success
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
Procedure.i BakaShrot_NameResolvedPacket_Decode(*MsgPackData.MsgPackData)
    Protected *Answer.BakaShrot_NameResolved
    Protected Value.q

    *Answer = AllocateStructure(BakaShrot_NameResolved)
    If Not *Answer
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Answer, *MsgPackData) Or *Answer\PacketType <> #BakaShrot_PacketType_NameResolved
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
    *Answer\Kind = Value

    ; Id
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        Goto DecodeFailed
    EndIf
    Value = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Value < 0 Or Value > #BakaShrot_MaxId
        Goto DecodeFailed
    EndIf
    *Answer\Id = Value

    ; Name
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Answer\Name = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ProcedureReturn *Answer

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Answer)
    ProcedureReturn 0
EndProcedure
