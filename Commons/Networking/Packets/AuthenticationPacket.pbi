

; ============================================================================
; BakaShrot Authentication Packets
;
; The three packets exchanged during the auth handshake:
;   C2S AuthRequest   - client introduces itself and its public key.
;   S2C AuthChallenge - server sends back something for the client to sign.
;   C2S AuthResult    - client replies with the signed challenge.
;
; Wire format: BakaShrot_PacketBase (Magic, Version, PacketType - see
; Packets.pbi) followed by each struct's own fields, in declaration order.
; Every string field is packed as {len}{str}: a 4-byte (Long) UTF-8 byte
; length, followed by exactly that many UTF-8 bytes - no null terminator.
; ============================================================================


XIncludeFile "../Packets.pbi"

; C2S auth request
Structure BakaShrot_AuthRequest Extends BakaShrot_PacketBase
    ClientGroupId.l
    ClientNodeId.l
    ClientPubKeyB64.s
EndStructure

; S2C Chalenge the client must sign it with their private key
Structure BakaShrot_AuthChallenge Extends BakaShrot_PacketBase
    ClientPubKeyB64.s
EndStructure

; C2S Response with the chalenge signed by their private key
Structure BakaShrot_AuthResult Extends BakaShrot_PacketBase
    ChallengeResponseB64.s
EndStructure


DeclareModule BakaShrot_AuthenticationPacket

    ; Encodes *Request/*Challenge/*Result into a freshly allocated buffer.
    ; *OutSize receives its size in bytes. Returns 0 (and leaves *OutSize
    ; untouched) if the input is invalid (null) or the buffer could not be
    ; allocated. Caller owns the returned buffer - free it with FreeMemory.
    Declare.i EncodeRequest(*Request.BakaShrot_AuthRequest, *OutSize.l)
    Declare.i EncodeChallenge(*Challenge.BakaShrot_AuthChallenge, *OutSize.l)
    Declare.i EncodeResult(*Result.BakaShrot_AuthResult, *OutSize.l)

    ; Decodes *Buffer (BufferSize bytes) into a freshly allocated struct.
    ; Returns 0 if the packet is too small, malformed, truncated, or not of
    ; the expected kind. Caller owns the returned struct - free it with
    ; FreeStructure.
    Declare.i DecodeRequest(*Buffer, BufferSize.i)
    Declare.i DecodeChallenge(*Buffer, BufferSize.i)
    Declare.i DecodeResult(*Buffer, BufferSize.i)

EndDeclareModule


Module BakaShrot_AuthenticationPacket

    ; ------------------------------------------------------------------------
    ; Wire helpers. Every string on the wire is {len}{str}: a 4-byte UTF-8
    ; byte length followed by exactly that many UTF-8 bytes.
    ; ------------------------------------------------------------------------

    ; Size, in bytes, Str will take once written as {len}{str}.
    Procedure.i PackedStringSize(Str.s)
        ProcedureReturn 4 + StringByteLength(Str, #PB_UTF8)
    EndProcedure

    ; Writes Str at *Buffer + Offset as {len}{str}. *Buffer must have room
    ; for at least PackedStringSize(Str) bytes from Offset onward.
    Procedure WritePackedString(*Buffer, Offset.i, Str.s)
        PokeL(*Buffer + Offset, StringByteLength(Str, #PB_UTF8))
        PokeS(*Buffer + Offset + 4, Str, -1, #PB_UTF8)
    EndProcedure

    ; #True if a {len}{str} value starting at Offset is fully contained
    ; within the first BufferSize bytes of *Buffer. Always check this before
    ; calling ReadPackedString() - it does no bounds checking of its own.
    Procedure.i PackedStringFits(*Buffer, BufferSize.i, Offset.i)
        Protected ByteLen.l

        If Offset + 4 > BufferSize
            ProcedureReturn #False
        EndIf

        ByteLen = PeekL(*Buffer + Offset)
        If ByteLen < 0 Or Offset + 4 + ByteLen > BufferSize
            ProcedureReturn #False
        EndIf

        ProcedureReturn #True
    EndProcedure

    ; Reads the {len}{str} value at *Buffer + Offset. Caller MUST have
    ; checked PackedStringFits() first.
    Procedure.s ReadPackedString(*Buffer, Offset.i)
        ProcedureReturn PeekS(*Buffer + Offset + 4, PeekL(*Buffer + Offset), #PB_UTF8 | #PB_ByteLength)
    EndProcedure


    ; ------------------------------------------------------------------------
    ; Header. All three packets share the same BakaShrot_PacketBase layout:
    ; Magic.l, Version.l, PacketType.l.
    ; ------------------------------------------------------------------------

    ; Writes the packet header at the start of *Buffer. Returns the offset of
    ; the first byte after the header.
    Procedure.i WriteHeader(*Buffer, PacketType.l)
        PokeL(*Buffer, #BakaShrot_ProtocolMagic)
        PokeL(*Buffer + 4, #BakaShrot_ProtocolVersion)
        PokeL(*Buffer + 8, PacketType)

        ProcedureReturn SizeOf(BakaShrot_PacketBase)
    EndProcedure

    ; Validates the header at the start of *Buffer: big enough to hold one,
    ; correct Magic/Version, and PacketType matching ExpectedPacketType.
    ; Returns the offset of the first byte after the header on success, or
    ; -1 if the packet must be thrown out.
    Procedure.i ReadHeader(*Buffer, BufferSize.i, ExpectedPacketType.l)
        If BufferSize < SizeOf(BakaShrot_PacketBase)
            ProcedureReturn -1
        EndIf

        If PeekL(*Buffer) <> #BakaShrot_ProtocolMagic
            ProcedureReturn -1
        EndIf

        If PeekL(*Buffer + 4) <> #BakaShrot_ProtocolVersion
            ProcedureReturn -1
        EndIf

        If PeekL(*Buffer + 8) <> ExpectedPacketType
            ProcedureReturn -1
        EndIf

        ProcedureReturn SizeOf(BakaShrot_PacketBase)
    EndProcedure


    ; ------------------------------------------------------------------------
    ; AuthRequest (C2S)
    ; ------------------------------------------------------------------------

    Procedure.i EncodeRequest(*Request.BakaShrot_AuthRequest, *OutSize.l)
        Protected Size.i, *Buffer, Offset.i

        If Not *Request
            ProcedureReturn 0
        EndIf

        Size = SizeOf(BakaShrot_PacketBase) + 4 + 4 + PackedStringSize(*Request\ClientPubKeyB64)

        *Buffer = AllocateMemory(Size)
        If Not *Buffer
            ProcedureReturn 0
        EndIf

        Offset = WriteHeader(*Buffer, #BakaShrot_PacketType_AuthenticationRequest)

        PokeL(*Buffer + Offset, *Request\ClientGroupId)
        Offset = Offset + 4
        PokeL(*Buffer + Offset, *Request\ClientNodeId)
        Offset = Offset + 4

        WritePackedString(*Buffer, Offset, *Request\ClientPubKeyB64)

        *OutSize\l = Size
        ProcedureReturn *Buffer
    EndProcedure

    Procedure.i DecodeRequest(*Buffer, BufferSize.i)
        Protected Offset.i, *Request.BakaShrot_AuthRequest

        Offset = ReadHeader(*Buffer, BufferSize, #BakaShrot_PacketType_AuthenticationRequest)
        If Offset = -1
            ProcedureReturn 0
        EndIf

        If Offset + 4 + 4 > BufferSize
            ProcedureReturn 0
        EndIf

        *Request = AllocateStructure(BakaShrot_AuthRequest)

        *Request\Magic      = #BakaShrot_ProtocolMagic
        *Request\Version    = #BakaShrot_ProtocolVersion
        *Request\PacketType = #BakaShrot_PacketType_AuthenticationRequest

        *Request\ClientGroupId = PeekL(*Buffer + Offset)
        Offset = Offset + 4
        *Request\ClientNodeId = PeekL(*Buffer + Offset)
        Offset = Offset + 4

        If Not PackedStringFits(*Buffer, BufferSize, Offset)
            FreeStructure(*Request)
            ProcedureReturn 0
        EndIf
        *Request\ClientPubKeyB64 = ReadPackedString(*Buffer, Offset)

        ProcedureReturn *Request
    EndProcedure


    ; ------------------------------------------------------------------------
    ; AuthChallenge (S2C)
    ; ------------------------------------------------------------------------

    Procedure.i EncodeChallenge(*Challenge.BakaShrot_AuthChallenge, *OutSize.l)
        Protected Size.i, *Buffer, Offset.i

        If Not *Challenge
            ProcedureReturn 0
        EndIf

        Size = SizeOf(BakaShrot_PacketBase) + PackedStringSize(*Challenge\ClientPubKeyB64)

        *Buffer = AllocateMemory(Size)
        If Not *Buffer
            ProcedureReturn 0
        EndIf

        Offset = WriteHeader(*Buffer, #BakaShrot_PacketType_AuthenticationChallenge)
        WritePackedString(*Buffer, Offset, *Challenge\ClientPubKeyB64)

        *OutSize\l = Size
        ProcedureReturn *Buffer
    EndProcedure

    Procedure.i DecodeChallenge(*Buffer, BufferSize.i)
        Protected Offset.i, *Challenge.BakaShrot_AuthChallenge

        Offset = ReadHeader(*Buffer, BufferSize, #BakaShrot_PacketType_AuthenticationChallenge)
        If Offset = -1
            ProcedureReturn 0
        EndIf

        If Not PackedStringFits(*Buffer, BufferSize, Offset)
            ProcedureReturn 0
        EndIf

        *Challenge = AllocateStructure(BakaShrot_AuthChallenge)

        *Challenge\Magic      = #BakaShrot_ProtocolMagic
        *Challenge\Version    = #BakaShrot_ProtocolVersion
        *Challenge\PacketType = #BakaShrot_PacketType_AuthenticationChallenge
        *Challenge\ClientPubKeyB64 = ReadPackedString(*Buffer, Offset)

        ProcedureReturn *Challenge
    EndProcedure


    ; ------------------------------------------------------------------------
    ; AuthResult (C2S)
    ; ------------------------------------------------------------------------

    Procedure.i EncodeResult(*Result.BakaShrot_AuthResult, *OutSize.l)
        Protected Size.i, *Buffer, Offset.i

        If Not *Result
            ProcedureReturn 0
        EndIf

        Size = SizeOf(BakaShrot_PacketBase) + PackedStringSize(*Result\ChallengeResponseB64)

        *Buffer = AllocateMemory(Size)
        If Not *Buffer
            ProcedureReturn 0
        EndIf

        Offset = WriteHeader(*Buffer, #BakaShrot_PacketType_AuthenticationResult)
        WritePackedString(*Buffer, Offset, *Result\ChallengeResponseB64)

        *OutSize\l = Size
        ProcedureReturn *Buffer
    EndProcedure

    Procedure.i DecodeResult(*Buffer, BufferSize.i)
        Protected Offset.i, *Result.BakaShrot_AuthResult

        Offset = ReadHeader(*Buffer, BufferSize, #BakaShrot_PacketType_AuthenticationResult)
        If Offset = -1
            ProcedureReturn 0
        EndIf

        If Not PackedStringFits(*Buffer, BufferSize, Offset)
            ProcedureReturn 0
        EndIf

        *Result = AllocateStructure(BakaShrot_AuthResult)

        *Result\Magic      = #BakaShrot_ProtocolMagic
        *Result\Version    = #BakaShrot_ProtocolVersion
        *Result\PacketType = #BakaShrot_PacketType_AuthenticationResult
        *Result\ChallengeResponseB64 = ReadPackedString(*Buffer, Offset)

        ProcedureReturn *Result
    EndProcedure

EndModule

