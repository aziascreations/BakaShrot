; ============================================================================
; BakaShrot Storage Names
;
; Which name every topic and node id has on this server. Names are what's
; shared between servers (Commons/Networking/Names.pbi): replication sends
; them, and each server stores the messages under its own ids for them. Say
; topic "logs" is 1 here and 200 on a peer: the peer sends "logs", this
; server stores it under 1. Hand-written configs drift, the names keep them
; matching anyway.
;
; Only what's named on BOTH servers replicates: a topic or node without a
; name, or with a name the other server doesn't know, is dropped. Unless the
; receiver takes it by a wildcard: "*" or a pattern ("sensors.*") in that
; peer's AcceptTopics / AcceptNodes takes matching names it doesn't have,
; and adds them (BakaShrot_Names_Ingest(), origin "peer") under the highest
; free id counting down from 65535, out of the way of the ids picked in the
; config. To not be refused over and over, each check-in's sync state lists
; every name the receiver knows and takes, and its patterns, and the sender
; only sends those. Every drop goes through BakaShrot_Names_NoteDropped().
;
; Kept in the "topics" and "nodes" tables (Storage.pbi), so raw queries can
; join on them (the "messages" view), and in memory for the server, guarded
; by BakaShrot_Names_Mutex. Every id in "data" has a row:
;   origin "config"  named in [BakaShrot.Topics] / [BakaShrot.Nodes]
;   origin "id"      unnamed, its name is its id in digits
;   origin "peer"    sent by a peer, taken by a wildcard, named by the peer
;
; BakaShrot_Names_Load() reconciles the config with the tables at start (and
; on restart). The config wins, except when it would give a name to another
; id than the one the database has it under (or rename a "peer" one): that
; would relabel stored messages, so the server refuses to start and says
; which id to use.
;
; Lock order: BakaShrot_Names_Mutex, then the write mutex (Writer.pbi).
; ============================================================================

XIncludeFile "../Config/Config.pbi"
XIncludeFile "Storage.pbi"
XIncludeFile "../../Commons/Networking/Packets/NamesListPacket.pbi"


#BakaShrot_Names_OriginConfig = "config"
#BakaShrot_Names_OriginPeer   = "peer"
#BakaShrot_Names_OriginId     = "id"

; One of the two tables, in memory.
Structure BakaShrot_NameTable
	Table.s
	IdColumn.s
	Kind.s

	; LCase(name) -> id, named ones only.
	Map IdByName.i()

	; Str(id) -> name, "" if unnamed. Every id with a row.
	Map NameById.s()

	; Str(id) -> origin.
	Map OriginById.s()
EndStructure

Global BakaShrot_Names_Mutex.i = CreateMutex()
Global BakaShrot_Names_Topics.BakaShrot_NameTable
Global BakaShrot_Names_Nodes.BakaShrot_NameTable

BakaShrot_Names_Topics\Table    = "topics"
BakaShrot_Names_Topics\IdColumn = "topic_id"
BakaShrot_Names_Topics\Kind     = "topic"
BakaShrot_Names_Nodes\Table     = "nodes"
BakaShrot_Names_Nodes\IdColumn  = "node_id"
BakaShrot_Names_Nodes\Kind      = "node"


; --- Loading -----------------------------------------------------------------

; Reconciles one table with the config's names (ConfigNames: Str(id) ->
; name) and the ids it uses (UsedIds), plus every id already in "data"
; (node_heads), then fills *Names from it.
; Runs inside the transaction of BakaShrot_Names_Load().
Procedure.i BakaShrot_Names_LoadTable(DbId.i, *Names.BakaShrot_NameTable, Map ConfigNames.s(), Map UsedIds.i(), *Error.String)
	Protected NewMap DbName.s(), NewMap DbOrigin.s(), NewMap DbIdByName.i(), NewMap AllIds.i()
	Protected Id.i, Name.s, Key.s, Section.s

	If *Names = @BakaShrot_Names_Topics
		Section = "[BakaShrot.Topics]"
	Else
		Section = "[BakaShrot.Nodes]"
	EndIf

	; What the database has.
	If Not DatabaseQuery(DbId, "SELECT " + *Names\IdColumn + ", name, origin FROM " + *Names\Table)
		*Error\s = "can't read the " + *Names\Table + " table: " + DatabaseError()
		ProcedureReturn #False
	EndIf
	While NextDatabaseRow(DbId)
		Key = Str(GetDatabaseLong(DbId, 0))
		DbName(Key)   = GetDatabaseString(DbId, 1)
		DbOrigin(Key) = GetDatabaseString(DbId, 2)
		If Not BakaShrot_IsDigits(DbName(Key))
			DbIdByName(LCase(DbName(Key))) = Val(Key)
		EndIf
	Wend
	FinishDatabaseQuery(DbId)

	; The config's names.
	ForEach ConfigNames()
		Key  = MapKey(ConfigNames())
		Name = ConfigNames()
		Id   = Val(Key)

		If FindMapElement(DbIdByName(), LCase(Name)) And DbIdByName() <> Id
			*Error\s = *Names\Kind + " '" + Name + "' is id " + Str(Id) + " in " + Section + ", but its messages are stored under id " +
			           Str(DbIdByName()) + ": give it id " + Str(DbIdByName()) + " in the config"
			ProcedureReturn #False
		EndIf

		If FindMapElement(DbName(), Key)
			If DbName(Key) = Name And DbOrigin(Key) = #BakaShrot_Names_OriginConfig
				Continue
			EndIf
			If DbOrigin(Key) = #BakaShrot_Names_OriginPeer And LCase(DbName(Key)) <> LCase(Name)
				*Error\s = *Names\Kind + " id " + Str(Id) + " is '" + DbName(Key) + "', added by a peer, " + Section + " can't rename it to '" + Name +
				           "': give '" + Name + "' another id, or name id " + Str(Id) + " '" + DbName(Key) + "'"
				ProcedureReturn #False
			EndIf
			If LCase(DbName(Key)) <> LCase(Name) And DbOrigin(Key) = #BakaShrot_Names_OriginConfig
				PrintN("[Names] Renaming " + *Names\Kind + " " + Key + " from '" + DbName(Key) + "' to '" + Name + "'")
			EndIf
		EndIf

		SetDatabaseLong(DbId, 0, Id)
		SetDatabaseString(DbId, 1, Name)
		SetDatabaseString(DbId, 2, #BakaShrot_Names_OriginConfig)
		If Not DatabaseUpdate(DbId, "INSERT INTO " + *Names\Table + " (" + *Names\IdColumn + ", name, origin) VALUES (?, ?, ?) " +
		                            "ON CONFLICT (" + *Names\IdColumn + ") DO UPDATE SET name = excluded.name, origin = excluded.origin")
			*Error\s = "can't store " + *Names\Kind + " '" + Name + "': " + DatabaseError()
			ProcedureReturn #False
		EndIf
	Next

	; Every id the config uses, and every one already in "data", gets a row.
	ForEach UsedIds()
		AllIds(MapKey(UsedIds())) = #True
	Next
	If Not DatabaseQuery(DbId, "SELECT DISTINCT " + *Names\IdColumn + " FROM node_heads")
		*Error\s = "can't read node_heads: " + DatabaseError()
		ProcedureReturn #False
	EndIf
	While NextDatabaseRow(DbId)
		AllIds(Str(GetDatabaseLong(DbId, 0))) = #True
	Wend
	FinishDatabaseQuery(DbId)

	ForEach AllIds()
		Key = MapKey(AllIds())
		If FindMapElement(ConfigNames(), Key) Or FindMapElement(DbName(), Key)
			Continue
		EndIf
		SetDatabaseLong(DbId, 0, Val(Key))
		SetDatabaseString(DbId, 1, Key)
		SetDatabaseString(DbId, 2, #BakaShrot_Names_OriginId)
		If Not DatabaseUpdate(DbId, "INSERT OR IGNORE INTO " + *Names\Table + " (" + *Names\IdColumn + ", name, origin) VALUES (?, ?, ?)")
			*Error\s = "can't store " + *Names\Kind + " id " + Key + ": " + DatabaseError()
			ProcedureReturn #False
		EndIf
	Next

	; In memory, from what the table now holds.
	ClearMap(*Names\IdByName())
	ClearMap(*Names\NameById())
	ClearMap(*Names\OriginById())
	If Not DatabaseQuery(DbId, "SELECT " + *Names\IdColumn + ", name, origin FROM " + *Names\Table)
		*Error\s = "can't read the " + *Names\Table + " table: " + DatabaseError()
		ProcedureReturn #False
	EndIf
	While NextDatabaseRow(DbId)
		Id   = GetDatabaseLong(DbId, 0)
		Name = GetDatabaseString(DbId, 1)
		*Names\OriginById(Str(Id)) = GetDatabaseString(DbId, 2)
		If BakaShrot_IsDigits(Name)
			*Names\NameById(Str(Id)) = ""
		Else
			*Names\NameById(Str(Id))     = Name
			*Names\IdByName(LCase(Name)) = Id
		EndIf
	Wend
	FinishDatabaseQuery(DbId)

	ProcedureReturn #True
EndProcedure


; Reconciles the config's names with the database, see the top of this
; file. Only from the root, with the workers stopped, on its own connection.
; Returns #False with the reason in *Error\s, nothing is changed then.
Procedure.i BakaShrot_Names_Load(DbId.i, *Config.BakaShrot_CoreConfig, *Error.String)
	Protected Loaded.i

	LockMutex(BakaShrot_Names_Mutex)
	If Not DatabaseUpdate(DbId, "BEGIN IMMEDIATE")
		*Error\s = DatabaseError()
		UnlockMutex(BakaShrot_Names_Mutex)
		ProcedureReturn #False
	EndIf

	Loaded = Bool(BakaShrot_Names_LoadTable(DbId, @BakaShrot_Names_Topics, *Config\TopicNames(), *Config\UsedTopicIds(), *Error) And
	              BakaShrot_Names_LoadTable(DbId, @BakaShrot_Names_Nodes, *Config\NodeNames(), *Config\UsedNodeIds(), *Error))

	If Loaded And Not DatabaseUpdate(DbId, "COMMIT")
		*Error\s = DatabaseError()
		Loaded = #False
	EndIf
	If Not Loaded
		DatabaseUpdate(DbId, "ROLLBACK")
	EndIf

	UnlockMutex(BakaShrot_Names_Mutex)
	ProcedureReturn Loaded
EndProcedure


; --- Lookups -----------------------------------------------------------------

; The id Ref stands for: an id in digits is that id, a name must be known.
; -1 if it's neither. Holding the names mutex.
Procedure.i BakaShrot_Names_ResolveIn(*Names.BakaShrot_NameTable, Ref.s)
	Protected Id.i = BakaShrot_RefToId(Ref)

	If Id >= 0
		ProcedureReturn Id
	EndIf
	If BakaShrot_IsValidName(Ref) And FindMapElement(*Names\IdByName(), LCase(Ref))
		ProcedureReturn *Names\IdByName()
	EndIf
	ProcedureReturn -1
EndProcedure

; Its name, "" if it has none. Holding the names mutex.
Procedure.s BakaShrot_Names_NameIn(*Names.BakaShrot_NameTable, Id.i)
	If FindMapElement(*Names\NameById(), Str(Id))
		ProcedureReturn *Names\NameById()
	EndIf
	ProcedureReturn ""
EndProcedure


; The topic id Ref stands for here, -1 if none.
Procedure.i BakaShrot_Names_ResolveTopic(Ref.s)
	Protected Id.i
	LockMutex(BakaShrot_Names_Mutex)
	Id = BakaShrot_Names_ResolveIn(@BakaShrot_Names_Topics, Ref)
	UnlockMutex(BakaShrot_Names_Mutex)
	ProcedureReturn Id
EndProcedure

; The node id Ref stands for here, -1 if none.
Procedure.i BakaShrot_Names_ResolveNode(Ref.s)
	Protected Id.i
	LockMutex(BakaShrot_Names_Mutex)
	Id = BakaShrot_Names_ResolveIn(@BakaShrot_Names_Nodes, Ref)
	UnlockMutex(BakaShrot_Names_Mutex)
	ProcedureReturn Id
EndProcedure

; The topic id of a known name (never an id in digits), -1 if none: what
; replication goes by.
Procedure.i BakaShrot_Names_TopicByName(Name.s)
	If Not BakaShrot_IsValidName(Name)
		ProcedureReturn -1
	EndIf
	ProcedureReturn BakaShrot_Names_ResolveTopic(Name)
EndProcedure

; Same for a node.
Procedure.i BakaShrot_Names_NodeByName(Name.s)
	If Not BakaShrot_IsValidName(Name)
		ProcedureReturn -1
	EndIf
	ProcedureReturn BakaShrot_Names_ResolveNode(Name)
EndProcedure

; A topic's name, "" if it has none.
Procedure.s BakaShrot_Names_TopicName(Id.i)
	Protected Name.s
	LockMutex(BakaShrot_Names_Mutex)
	Name = BakaShrot_Names_NameIn(@BakaShrot_Names_Topics, Id)
	UnlockMutex(BakaShrot_Names_Mutex)
	ProcedureReturn Name
EndProcedure

; A node's name, "" if it has none.
Procedure.s BakaShrot_Names_NodeName(Id.i)
	Protected Name.s
	LockMutex(BakaShrot_Names_Mutex)
	Name = BakaShrot_Names_NameIn(@BakaShrot_Names_Nodes, Id)
	UnlockMutex(BakaShrot_Names_Mutex)
	ProcedureReturn Name
EndProcedure

; What a topic goes by in answers and logs: its name, or its id in digits.
Procedure.s BakaShrot_Names_TopicRef(Id.i)
	Protected Name.s = BakaShrot_Names_TopicName(Id)
	If Name = ""
		ProcedureReturn Str(Id)
	EndIf
	ProcedureReturn Name
EndProcedure

; Same for a node.
Procedure.s BakaShrot_Names_NodeRef(Id.i)
	Protected Name.s = BakaShrot_Names_NodeName(Id)
	If Name = ""
		ProcedureReturn Str(Id)
	EndIf
	ProcedureReturn Name
EndProcedure


; Fills Names() with every named topic (Kind #BakaShrot_NameKind_Topic) or
; node, by id, for the sync state. *Filter: only the ones it holds, 0 for
; all of them.
Procedure BakaShrot_Names_GetNamed(Kind.i, List Names.BakaShrot_SyncName(), *Filter.BakaShrot_NameSet = 0)
	Protected *Names.BakaShrot_NameTable, Id.i

	*Names = @BakaShrot_Names_Topics
	If Kind = #BakaShrot_NameKind_Node
		*Names = @BakaShrot_Names_Nodes
	EndIf

	ClearList(Names())
	LockMutex(BakaShrot_Names_Mutex)
	ForEach *Names\IdByName()
		Id = *Names\IdByName()
		If *Filter And Not NameSetHas(*Filter, Id, BakaShrot_Names_NameIn(*Names, Id))
			Continue
		EndIf
		AddElement(Names())
		Names()\Id   = Id
		Names()\Name = BakaShrot_Names_NameIn(*Names, Id)
	Next
	UnlockMutex(BakaShrot_Names_Mutex)

	SortStructuredList(Names(), #PB_Sort_Ascending, OffsetOf(BakaShrot_SyncName\Id), #PB_Long)
EndProcedure


; Fills Entries() with every topic or node (Kind), named or not, by id, with
; where its name comes from. *Filter: only the topics it holds, 0 for all.
Procedure BakaShrot_Names_GetAll(Kind.i, List Entries.BakaShrot_NameEntry(), *Filter.BakaShrot_NameSet = 0)
	Protected *Names.BakaShrot_NameTable, Id.i

	*Names = @BakaShrot_Names_Topics
	If Kind = #BakaShrot_NameKind_Node
		*Names = @BakaShrot_Names_Nodes
	EndIf

	ClearList(Entries())
	LockMutex(BakaShrot_Names_Mutex)
	ForEach *Names\NameById()
		Id = Val(MapKey(*Names\NameById()))
		If *Filter And Not NameSetHas(*Filter, Id, *Names\NameById())
			Continue
		EndIf
		AddElement(Entries())
		Entries()\Id     = Id
		Entries()\Name   = *Names\NameById()
		Entries()\Origin = *Names\OriginById(Str(Id))
	Next
	UnlockMutex(BakaShrot_Names_Mutex)

	SortStructuredList(Entries(), #PB_Sort_Ascending, OffsetOf(BakaShrot_NameEntry\Id), #PB_Long)
EndProcedure


; Prints every topic and node with its id, for the server's "names" command.
Procedure BakaShrot_Names_Print()
	Protected NewList Entries.BakaShrot_NameEntry()
	Protected Kind.i, Label.s, Name.s

	For Kind = #BakaShrot_NameKind_Topic To #BakaShrot_NameKind_Node
		BakaShrot_Names_GetAll(Kind, Entries())
		If Kind = #BakaShrot_NameKind_Topic
			Label = "Topics"
		Else
			Label = "Nodes"
		EndIf
		PrintN(Label + " (" + Str(ListSize(Entries())) + "):")
		ForEach Entries()
			Name = Entries()\Name
			If Name = ""
				Name = "(unnamed, not replicated)"
			EndIf
			PrintN("  " + RSet(Str(Entries()\Id), 5) + "  " + LSet(Name, 30) + "  " + Entries()\Origin)
		Next
	Next
EndProcedure


; --- Adding ------------------------------------------------------------------

; Makes sure Id has a row, as unnamed if it's new: for messages stored under
; an id the database didn't know yet (a push to a topic allowed by "*").
; Holding the names mutex. Returns #False with the reason in *Error\s.
Procedure.i BakaShrot_Names_EnsureIdIn(*Names.BakaShrot_NameTable, Id.i, *Error.String)
	If FindMapElement(*Names\NameById(), Str(Id))
		ProcedureReturn #True
	EndIf
	If Not RegisterStorageName(*Names\Table, Id, Str(Id), #BakaShrot_Names_OriginId, *Error)
		ProcedureReturn #False
	EndIf
	*Names\NameById(Str(Id))   = ""
	*Names\OriginById(Str(Id)) = #BakaShrot_Names_OriginId
	ProcedureReturn #True
EndProcedure

Procedure.i BakaShrot_Names_EnsureTopicId(Id.i, *Error.String)
	Protected Done.i
	LockMutex(BakaShrot_Names_Mutex)
	Done = BakaShrot_Names_EnsureIdIn(@BakaShrot_Names_Topics, Id, *Error)
	UnlockMutex(BakaShrot_Names_Mutex)
	ProcedureReturn Done
EndProcedure


; The id of a topic (Kind #BakaShrot_NameKind_Topic) or node a peer sent,
; by its name, which a wildcard in that peer's AcceptTopics / AcceptNodes
; took (the caller checks): a name this server doesn't have yet is added,
; under the highest free id counting down from 65535 (origin "peer").
; Returns -1 with the reason in *Error\s.
Procedure.i BakaShrot_Names_Ingest(Kind.i, Name.s, *Error.String)
	Protected *Names.BakaShrot_NameTable, Id.i

	*Names = @BakaShrot_Names_Topics
	If Kind = #BakaShrot_NameKind_Node
		*Names = @BakaShrot_Names_Nodes
	EndIf

	If Not BakaShrot_IsValidName(Name)
		*Error\s = "'" + Name + "' isn't a valid " + *Names\Kind + " name"
		ProcedureReturn -1
	EndIf

	LockMutex(BakaShrot_Names_Mutex)
	If FindMapElement(*Names\IdByName(), LCase(Name))
		Id = *Names\IdByName()
		UnlockMutex(BakaShrot_Names_Mutex)
		ProcedureReturn Id
	EndIf

	For Id = #BakaShrot_MaxId To 0 Step -1
		If Not FindMapElement(*Names\NameById(), Str(Id))
			Break
		EndIf
	Next
	If Id < 0
		UnlockMutex(BakaShrot_Names_Mutex)
		*Error\s = "no " + *Names\Kind + " id left for '" + Name + "'"
		ProcedureReturn -1
	EndIf

	If Not RegisterStorageName(*Names\Table, Id, Name, #BakaShrot_Names_OriginPeer, *Error)
		UnlockMutex(BakaShrot_Names_Mutex)
		ProcedureReturn -1
	EndIf
	*Names\NameById(Str(Id))    = Name
	*Names\OriginById(Str(Id))  = #BakaShrot_Names_OriginPeer
	*Names\IdByName(LCase(Name)) = Id
	UnlockMutex(BakaShrot_Names_Mutex)

	PrintN("[Names] New " + *Names\Kind + " '" + Name + "' from a peer, id " + Str(Id) + " here")
	ProcedureReturn Id
EndProcedure


; --- Drops -------------------------------------------------------------------

; Called whenever a topic or node isn't replicated because one side doesn't
; know it: Peer is the peer section's name, Kind "topic" or "node", Ref what
; it goes by on the side that has it, Reason why it was dropped.
; !!! Does nothing for now, on purpose: it's called at every check-in for
; !!! every such pair, so logging each one would spam. Later: warn once per
; !!! peer and name (and again only if it changes), see Notes.md.
Procedure BakaShrot_Names_NoteDropped(Peer.s, Kind.s, Ref.s, Reason.s)
EndProcedure
