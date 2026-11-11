;{- Code Header
; ==- Basic Info -================================
;     Name: SyncStatePacket.pbi
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

; Highest message id a node has for a topic/node id combination.
Structure BakaShrot_SyncPair
    TopicId.l
    NodeId.l
    MessageId.q
EndStructure

; One of the sender's ids, and what it's called: its name, or its id in
; digits if it has none (Commons/Networking/Names.pbi).
Structure BakaShrot_SyncName
    Id.l
    Name.s
EndStructure

; Biggest lists accepted, the packet size limit keeps the real ones well under it.
#BakaShrot_MaxSyncTopics   = 65536
#BakaShrot_MaxSyncNodes    = 65536
#BakaShrot_MaxSyncPairs    = 65536
#BakaShrot_MaxSyncPatterns = 4096

; Server -> Peer, answers a SyncStateRequest, at every check-in. Ids are the
; sender's own, names are what the peer matches them by: each server has its
; own ids. Only named topics and nodes replicate, and only those named on
; both servers: this is how the peer learns which names this server knows,
; so it never sends anything this server would refuse.
; Topics: the named topics it takes from this peer (its AcceptTopics).
; Nodes: the named nodes it takes from this peer (its AcceptNodes).
; TopicPatterns, NodePatterns: the wildcards ("*", "sensors.*") of its
;  AcceptTopics / AcceptNodes: it also takes names it doesn't have yet if
;  they match one (Commons/Networking/Names.pbi).
; Pairs: the highest message id it has for each topic/node of those.
;  A combination that isn't listed has no message yet.
; Names are names, never ids in digits.
; On the wire: topic count, each topic's id and name, node count, each
; node's id and name, topic pattern count, each pattern, node pattern
; count, each pattern, pair count, then each pair's topic id, node id and
; message id.
Structure BakaShrot_SyncState Extends BakaShrot_PacketBase
    List Topics.BakaShrot_SyncName()
    List Nodes.BakaShrot_SyncName()
    List TopicPatterns.s()
    List NodePatterns.s()
    List Pairs.BakaShrot_SyncPair()
EndStructure


; Writes a list of ids and names, with its count first.
Procedure.i BakaShrot_SyncStatePacket_WriteNames(*MsgPackData.MsgPackData, List Names.BakaShrot_SyncName())
    If MsgPackWriteInteger(*MsgPackData, ListSize(Names())) <> #MsgPack_Error_Success
        ProcedureReturn #False
    EndIf
    ForEach Names()
        If MsgPackWriteInteger(*MsgPackData, Names()\Id) <> #MsgPack_Error_Success
            ProcedureReturn #False
        EndIf
        If MsgPackWriteString(*MsgPackData, Names()\Name) <> #MsgPack_Error_Success
            ProcedureReturn #False
        EndIf
    Next
    ProcedureReturn #True
EndProcedure


; Writes a list of patterns, with its count first.
Procedure.i BakaShrot_SyncStatePacket_WritePatterns(*MsgPackData.MsgPackData, List Patterns.s())
    If MsgPackWriteInteger(*MsgPackData, ListSize(Patterns())) <> #MsgPack_Error_Success
        ProcedureReturn #False
    EndIf
    ForEach Patterns()
        If MsgPackWriteString(*MsgPackData, Patterns()) <> #MsgPack_Error_Success
            ProcedureReturn #False
        EndIf
    Next
    ProcedureReturn #True
EndProcedure


; Encodes *State into a freshly allocated buffer, its base fields are set by this procedure.
; *OutSize receives its size in bytes.
; Returns 0 on failure, the caller owns the returned buffer - free it with FreeMemory.
Procedure.i BakaShrot_SyncStatePacket_Encode(*State.BakaShrot_SyncState, *OutSize.Integer)
    Protected *MsgPackData.MsgPackData, *Buffer

    *State\Magic      = #BakaShrot_ProtocolMagic
    *State\Version    = #BakaShrot_ProtocolVersion
    *State\PacketType = #BakaShrot_PacketType_SyncState

    If ListSize(*State\Topics()) > #BakaShrot_MaxSyncTopics Or ListSize(*State\Nodes()) > #BakaShrot_MaxSyncNodes Or ListSize(*State\Pairs()) > #BakaShrot_MaxSyncPairs
        ProcedureReturn 0
    EndIf
    If ListSize(*State\TopicPatterns()) > #BakaShrot_MaxSyncPatterns Or ListSize(*State\NodePatterns()) > #BakaShrot_MaxSyncPatterns
        ProcedureReturn 0
    EndIf

    *MsgPackData = MsgPackCreate(64)
    If Not *MsgPackData
        ProcedureReturn 0
    EndIf

    If Not BakaShrot_WritePacketBase(*State, *MsgPackData)
        Goto EncodeFailed
    EndIf


    If Not BakaShrot_SyncStatePacket_WriteNames(*MsgPackData, *State\Topics())
        Goto EncodeFailed
    EndIf

    If Not BakaShrot_SyncStatePacket_WriteNames(*MsgPackData, *State\Nodes())
        Goto EncodeFailed
    EndIf

    If Not BakaShrot_SyncStatePacket_WritePatterns(*MsgPackData, *State\TopicPatterns())
        Goto EncodeFailed
    EndIf

    If Not BakaShrot_SyncStatePacket_WritePatterns(*MsgPackData, *State\NodePatterns())
        Goto EncodeFailed
    EndIf

    ; Pairs
    If MsgPackWriteInteger(*MsgPackData, ListSize(*State\Pairs())) <> #MsgPack_Error_Success
        Goto EncodeFailed
    EndIf
    ForEach *State\Pairs()
        If MsgPackWriteInteger(*MsgPackData, *State\Pairs()\TopicId) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
        If MsgPackWriteInteger(*MsgPackData, *State\Pairs()\NodeId) <> #MsgPack_Error_Success
            Goto EncodeFailed
        EndIf
        If MsgPackWriteInteger(*MsgPackData, *State\Pairs()\MessageId) <> #MsgPack_Error_Success
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

; Reads one integer within Minimum-Maximum into *Value\q.
; Returns #False if it's not an integer, couldn't be read, or is out of range.
Procedure.i BakaShrot_SyncStatePacket_ReadInteger(*MsgPackData.MsgPackData, *Value.Quad, Minimum.q, Maximum.q)
    If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_Integer
        ProcedureReturn #False
    EndIf
    *Value\q = MsgPackReadInteger(*MsgPackData)
    If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or *Value\q < Minimum Or *Value\q > Maximum
        ProcedureReturn #False
    EndIf
    ProcedureReturn #True
EndProcedure

; Reads a list of ids and names, with its count first. Every name must be a
; valid name, not an id in digits.
; Returns #False if anything is invalid.
Procedure.i BakaShrot_SyncStatePacket_ReadNames(*MsgPackData.MsgPackData, List Names.BakaShrot_SyncName(), MaxCount.i)
    Protected Count.q, Value.q, i.q

    If Not BakaShrot_SyncStatePacket_ReadInteger(*MsgPackData, @Count, 0, MaxCount)
        ProcedureReturn #False
    EndIf
    For i = 1 To Count
        AddElement(Names())
        If Not BakaShrot_SyncStatePacket_ReadInteger(*MsgPackData, @Value, 0, #BakaShrot_MaxId)
            ProcedureReturn #False
        EndIf
        Names()\Id = Value
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
            ProcedureReturn #False
        EndIf
        Names()\Name = MsgPackReadString(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Not BakaShrot_IsValidName(Names()\Name)
            ProcedureReturn #False
        EndIf
    Next
    ProcedureReturn #True
EndProcedure

; Reads a list of patterns, with its count first. Each one must be a valid
; pattern, see Commons/Networking/Names.pbi.
; Returns #False if anything is invalid.
Procedure.i BakaShrot_SyncStatePacket_ReadPatterns(*MsgPackData.MsgPackData, List Patterns.s())
    Protected Count.q, i.q

    If Not BakaShrot_SyncStatePacket_ReadInteger(*MsgPackData, @Count, 0, #BakaShrot_MaxSyncPatterns)
        ProcedureReturn #False
    EndIf
    For i = 1 To Count
        AddElement(Patterns())
        If MsgPackFormatCodeToDataType(MsgPackGetFormatCode(*MsgPackData)) <> #MsgPack_DataTypes_String
            ProcedureReturn #False
        EndIf
        Patterns() = MsgPackReadString(*MsgPackData)
        If MsgPackLastError(*MsgPackData) <> #MsgPack_Error_Success Or Not BakaShrot_IsValidPattern(Patterns())
            ProcedureReturn #False
        EndIf
    Next
    ProcedureReturn #True
EndProcedure

; Decodes the packet at *MsgPackData's current offset into a freshly allocated struct.
; *MsgPackData stays owned by the caller, and should be discarded on failure.
; Returns 0 on failure, the caller owns the returned struct - free it with FreeStructure.
Procedure.i BakaShrot_SyncStatePacket_Decode(*MsgPackData.MsgPackData)
    Protected *State.BakaShrot_SyncState
    Protected Count.q, Value.q, i.q

    *State = AllocateStructure(BakaShrot_SyncState)
    If Not *State
        ProcedureReturn 0
    EndIf

    ; The base parser doesn't check which packet it is, that's on us.
    If Not BakaShrot_ReadPacketBase(*State, *MsgPackData) Or *State\PacketType <> #BakaShrot_PacketType_SyncState
        Goto DecodeFailed
    EndIf


    If Not BakaShrot_SyncStatePacket_ReadNames(*MsgPackData, *State\Topics(), #BakaShrot_MaxSyncTopics)
        Goto DecodeFailed
    EndIf

    If Not BakaShrot_SyncStatePacket_ReadNames(*MsgPackData, *State\Nodes(), #BakaShrot_MaxSyncNodes)
        Goto DecodeFailed
    EndIf

    If Not BakaShrot_SyncStatePacket_ReadPatterns(*MsgPackData, *State\TopicPatterns())
        Goto DecodeFailed
    EndIf

    If Not BakaShrot_SyncStatePacket_ReadPatterns(*MsgPackData, *State\NodePatterns())
        Goto DecodeFailed
    EndIf

    ; Pairs
    If Not BakaShrot_SyncStatePacket_ReadInteger(*MsgPackData, @Count, 0, #BakaShrot_MaxSyncPairs)
        Goto DecodeFailed
    EndIf
    For i = 1 To Count
        AddElement(*State\Pairs())
        If Not BakaShrot_SyncStatePacket_ReadInteger(*MsgPackData, @Value, 0, #BakaShrot_MaxId)
            Goto DecodeFailed
        EndIf
        *State\Pairs()\TopicId = Value
        If Not BakaShrot_SyncStatePacket_ReadInteger(*MsgPackData, @Value, 0, #BakaShrot_MaxId)
            Goto DecodeFailed
        EndIf
        *State\Pairs()\NodeId = Value
        If Not BakaShrot_SyncStatePacket_ReadInteger(*MsgPackData, @Value, 1, 9223372036854775807)
            Goto DecodeFailed
        EndIf
        *State\Pairs()\MessageId = Value
    Next

    ProcedureReturn *State

    ; Everything read so far is tainted, drop it.
    DecodeFailed:
    FreeStructure(*State)
    ProcedureReturn 0
EndProcedure
