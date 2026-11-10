; ============================================================================
; BakaShrot Bench Seed
;
; Usage: BenchSeed <TopicId> <Nodes> <RowsPerNode> <MessageSize> <Db> [Db...]
;   Nodes        Node ids, "101-110,201-210".
;
; Adds RowsPerNode messages to every node, identical in every database, so
; servers that were in sync stay in sync without replicating anything: a
; quick way to get millions of rows for the query and check-in benchmarks.
; Each node continues from the highest message id any database has for it,
; and INSERT OR IGNORE keeps what's already there.
; Nodes go by name ("n" + id, like Bench-Replication.ps1 names them): each
; database stores a node under its own id for that name, and gets the name
; (origin "peer", as if a peer had sent it) if it doesn't have it yet, so
; servers that take nodes by wildcard (-Names Wildcard) see them as known.
; The servers must be stopped. Same JSON as BenchClient's pushes.
;
; Used by Tests/Bench/Bench-Replication.ps1, compile as a console program.
; ============================================================================

EnableExplicit

XIncludeFile "../../Server/Storage/Storage.pbi"


#Seed_BatchSize = 50000


; The id DbId has for node "n<Node>", given that name if it has none yet.
; Returns -1 on failure.
Procedure.i Seed_LocalNode(DbId.i, Node.i)
	Protected Name.s = "n" + Str(Node), Id.i = -1

	SetDatabaseString(DbId, 0, Name)
	If DatabaseQuery(DbId, "SELECT node_id FROM nodes WHERE name = ?")
		If NextDatabaseRow(DbId)
			Id = GetDatabaseLong(DbId, 0)
		EndIf
		FinishDatabaseQuery(DbId)
	EndIf
	If Id >= 0
		ProcedureReturn Id
	EndIf

	; Its own id, unless something else is named there.
	SetDatabaseLong(DbId, 0, Node)
	SetDatabaseString(DbId, 1, Name)
	If Not DatabaseUpdate(DbId, "INSERT INTO nodes (node_id, name, origin) VALUES (?, ?, 'peer') " +
	                            "ON CONFLICT (node_id) DO UPDATE SET name = excluded.name, origin = 'peer' WHERE origin = 'id'")
		ProcedureReturn -1
	EndIf
	SetDatabaseString(DbId, 0, Name)
	If DatabaseQuery(DbId, "SELECT node_id FROM nodes WHERE name = ?")
		If NextDatabaseRow(DbId)
			Id = GetDatabaseLong(DbId, 0)
		EndIf
		FinishDatabaseQuery(DbId)
	EndIf
	ProcedureReturn Id
EndProcedure


Procedure.s Seed_Json(NodeId.i, Seq.q, Pad.s)
	Protected Kind.s, Value.i

	If Seq % 50 = 0
		Kind = "alert"
	Else
		Select Seq % 4
			Case 0 : Kind = "temp"
			Case 1 : Kind = "humidity"
			Case 2 : Kind = "pressure"
			Default : Kind = "status"
		EndSelect
	EndIf
	Value = (Seq * 7919 + NodeId) % 10000
	ProcedureReturn ~"{\"kind\":\"" + Kind + ~"\",\"node\":" + Str(NodeId) + ~",\"seq\":" + Str(Seq) +
	                ~",\"value\":" + StrD(Value / 100.0, 2) + ~",\"ts\":" + Str(1700000000 + Seq) +
	                ~",\"pad\":\"" + Pad + ~"\"}"
EndProcedure


Define TopicId.i, NodesSpec.s, RowsPerNode.i, MessageSize.i, Pad.s
Define NewList Nodes.i(), NewList Dbs.i()
Define i.i, Part.s, First.i, Last.i, Node.i, StartId.q, Id.q, MaxId.q, Count.q, StartMs.i, Total.q, d.i
Define Dim LocalIds.i(0)

OpenConsole()

If CountProgramParameters() < 5
	PrintN("Usage: BenchSeed <TopicId> <Nodes> <RowsPerNode> <MessageSize> <Db> [Db...]")
	End 1
EndIf

TopicId     = Val(ProgramParameter(0))
NodesSpec   = ProgramParameter(1)
RowsPerNode = Val(ProgramParameter(2))
MessageSize = Val(ProgramParameter(3))
If MessageSize > 90
	Pad = LSet("", MessageSize - 90, "x")
EndIf

For i = 1 To CountString(NodesSpec, ",") + 1
	Part = Trim(StringField(NodesSpec, i, ","))
	If Part = ""
		Continue
	EndIf
	If FindString(Part, "-")
		First = Val(StringField(Part, 1, "-"))
		Last  = Val(StringField(Part, 2, "-"))
	Else
		First = Val(Part)
		Last  = First
	EndIf
	For Node = First To Last
		AddElement(Nodes())
		Nodes() = Node
	Next
Next

For i = 4 To CountProgramParameters() - 1
	AddElement(Dbs())
	Dbs() = OpenStorageDatabase(ProgramParameter(i))
	If Not Dbs() Or Not SetupStorageDatabase(Dbs())
		PrintN("Can't open '" + ProgramParameter(i) + "': " + DatabaseError())
		End 1
	EndIf
Next

StartMs = ElapsedMilliseconds()
ReDim LocalIds(ListSize(Dbs()) - 1)
ForEach Nodes()
	; Where every database is at for this node, continue after the furthest.
	StartId = 0
	d = 0
	ForEach Dbs()
		LocalIds(d) = Seed_LocalNode(Dbs(), Nodes())
		If LocalIds(d) < 0
			PrintN("Can't name node " + Str(Nodes()) + ": " + DatabaseError())
			End 1
		EndIf
		MaxId = GetLatestMessageId(Dbs(), TopicId, LocalIds(d))
		If MaxId > StartId
			StartId = MaxId
		EndIf
		d + 1
	Next

	d = -1
	ForEach Dbs()
		d + 1
		Id = StartId
		While Id < StartId + RowsPerNode
			If Not DatabaseUpdate(Dbs(), "BEGIN IMMEDIATE")
				PrintN("BEGIN failed: " + DatabaseError())
				End 1
			EndIf
			Count = 0
			While Count < #Seed_BatchSize And Id < StartId + RowsPerNode
				Id + 1
				Count + 1
				If Not InsertReplicatedMessage(Dbs(), TopicId, LocalIds(d), Id, Seed_Json(Nodes(), Id, Pad), BakaShrot_NowUtcMs())
					PrintN("Insert failed: " + DatabaseError())
					End 1
				EndIf
			Wend
			If Not DatabaseUpdate(Dbs(), "COMMIT")
				PrintN("COMMIT failed: " + DatabaseError())
				End 1
			EndIf
			Total + Count
		Wend
	Next
Next

ForEach Dbs()
	CloseDatabase(Dbs())
Next

PrintN("Seeded " + Str(Total) + " rows (" + Str(RowsPerNode) + " per node, " + Str(ListSize(Nodes())) + " nodes, " + Str(ListSize(Dbs())) + " databases) in " + StrD((ElapsedMilliseconds() - StartMs) / 1000.0, 1) + " s")
End 0
