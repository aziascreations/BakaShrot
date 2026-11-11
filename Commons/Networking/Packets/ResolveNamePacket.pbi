;{- Code Header
; ==- Basic Info -================================
;     Name: ResolveNamePacket.pbi
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

; What a ResolveName / NameResolved is about.
#BakaShrot_NameKind_Topic = 1
#BakaShrot_NameKind_Node  = 2

; C2S, asks for the server's id and name of a topic or node.
; Kind: #BakaShrot_NameKind_Topic or #BakaShrot_NameKind_Node.
; Ref: a name or an id in digits (Commons/Networking/Names.pbi).
; Answered with a NameResolved, or a RequestRefused if the server doesn't
; know it, or if it's a topic the client may neither push to nor read
; (unless it may query, which reads everything anyway).
Structure BakaShrot_ResolveName Extends BakaShrot_PacketBase
    Kind.l
    Ref.s
EndStructure


; Encodes *Request into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_ResolveNamePacket_Encode(*Request.BakaShrot_ResolveName, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *Request\Magic      = #BakaShrot_ProtocolMagic
    *Request\Version    = #BakaShrot_ProtocolVersion
    *Request\PacketType = #BakaShrot_PacketType_ResolveName

    *MsgPackData = MsgPackCreate(64)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*Request, *MsgPackData)
        Goto EncodeFailed
    EndIf

    If MsgPackWriteInteger(*MsgPackData, *Request\Kind) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf

    If MsgPackWriteString(*MsgPackData, *Request\Ref) <> #MsgPack_Error_Success
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
Procedure.i BakaShrot_ResolveNamePacket_Decode(*MsgPackData.MsgPackData)
    Protected *Request.BakaShrot_ResolveName
    Protected Value.q

    *Request = AllocateStructure(BakaShrot_ResolveName)
    If Not *Request
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*Request, *MsgPackData) Or *Request\PacketType <> #BakaShrot_PacketType_ResolveName
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

    ; Ref
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
        Goto DecodeFailed
    EndIf
    *Request\Ref = MsgPackReadString(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success
        Goto DecodeFailed
    EndIf

    ProcedureReturn *Request

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*Request)
    ProcedureReturn 0
EndProcedure
