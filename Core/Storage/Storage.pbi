; ============================================================================
; BakaShrot Storage
;
; Opens the SQLite database file that backs the node's local storage, and
; provides the basic read/write operations on top of it.
; Schema: see db_schema_v1.dbml in this same folder.
; ============================================================================


UseSQLiteDatabase()


; One row of the "data" table (see db_schema_v1.dbml).
Structure BakaShrot_Message
	MessageId.i
	JsonData.s
EndStructure


; Opens (and creates, if missing) the SQLite database at DatabasePath.
; Returns the PureBasic database number, or 0 if the file could not be opened.
Procedure.i OpenStorageDatabase(DatabasePath.s)
	ProcedureReturn OpenDatabase(#PB_Any, DatabasePath, "", "")
EndProcedure


; Creates the tables and indexes described by db_schema_v1.dbml, if they
; don't exist yet. Plain "CREATE IF NOT EXISTS" for now - a real versioned
; upgrade mechanism (DbUpdater) will replace this later.
Procedure.i SetupStorageDatabase(DbId.i)

	If Not DatabaseUpdate(DbId, "CREATE TABLE IF NOT EXISTS archives (" +
	                             "delete_by INTEGER NOT NULL, " +
	                             "message_data TEXT NOT NULL)")
		ProcedureReturn #False
	EndIf

	If Not DatabaseUpdate(DbId, "CREATE TABLE IF NOT EXISTS data (" +
	                             "group_id INTEGER NOT NULL, " +
	                             "node_id INTEGER NOT NULL, " +
	                             "message_id INTEGER NOT NULL, " +
	                             "message_data TEXT NOT NULL)")
		ProcedureReturn #False
	EndIf
	If Not DatabaseUpdate(DbId, "CREATE INDEX IF NOT EXISTS idx_data_group_node ON data (group_id, node_id)")
		ProcedureReturn #False
	EndIf
	If Not DatabaseUpdate(DbId, "CREATE INDEX IF NOT EXISTS idx_data_message_id ON data (message_id)")
		ProcedureReturn #False
	EndIf

	; Not used yet, but created now so the on-disk schema already matches
	; db_schema_v1.dbml.
	If Not DatabaseUpdate(DbId, "CREATE TABLE IF NOT EXISTS attachements (" +
	                             "group_id INTEGER NOT NULL, " +
	                             "node_id INTEGER NOT NULL, " +
	                             "message_id INTEGER NOT NULL, " +
	                             "attachement_data BLOB NOT NULL)")
		ProcedureReturn #False
	EndIf
	If Not DatabaseUpdate(DbId, "CREATE INDEX IF NOT EXISTS idx_attachements_group_node ON attachements (group_id, node_id)")
		ProcedureReturn #False
	EndIf
	If Not DatabaseUpdate(DbId, "CREATE INDEX IF NOT EXISTS idx_attachements_message_id ON attachements (message_id)")
		ProcedureReturn #False
	EndIf

	ProcedureReturn #True
EndProcedure


; Inserts one JSON message into the "data" table.
Procedure.i Insert(DbId.i, GroupId.i, NodeId.i, MessageId.i, JsonData.s)
	SetDatabaseLong(DbId, 0, GroupId)
	SetDatabaseLong(DbId, 1, NodeId)
	SetDatabaseLong(DbId, 2, MessageId)
	SetDatabaseString(DbId, 3, JsonData)

	ProcedureReturn DatabaseUpdate(DbId, "INSERT INTO data (group_id, node_id, message_id, message_data) VALUES (?, ?, ?, ?)")
EndProcedure


; Gets every message stored for a given group_id/node_id pair - the
; "(group_id, node_id)" index - ordered by message_id.
Procedure.i GetMessagesByGroupAndNode(DbId.i, GroupId.i, NodeId.i, List Messages.BakaShrot_Message())
	ClearList(Messages())

	SetDatabaseLong(DbId, 0, GroupId)
	SetDatabaseLong(DbId, 1, NodeId)

	If Not DatabaseQuery(DbId, "SELECT message_id, message_data FROM data WHERE group_id = ? AND node_id = ? ORDER BY message_id")
		ProcedureReturn #False
	EndIf

	While NextDatabaseRow(DbId)
		AddElement(Messages())
		Messages()\MessageId = GetDatabaseLong(DbId, 0)
		Messages()\JsonData  = GetDatabaseString(DbId, 1)
	Wend
	FinishDatabaseQuery(DbId)

	ProcedureReturn #True
EndProcedure


; Gets every message stored under a given message_id, regardless of which
; group/node it belongs to - the standalone "message_id" index.
Procedure.i GetMessagesByMessageId(DbId.i, MessageId.i, List Messages.BakaShrot_Message())
	ClearList(Messages())

	SetDatabaseLong(DbId, 0, MessageId)

	If Not DatabaseQuery(DbId, "SELECT message_id, message_data FROM data WHERE message_id = ?")
		ProcedureReturn #False
	EndIf

	While NextDatabaseRow(DbId)
		AddElement(Messages())
		Messages()\MessageId = GetDatabaseLong(DbId, 0)
		Messages()\JsonData  = GetDatabaseString(DbId, 1)
	Wend
	FinishDatabaseQuery(DbId)

	ProcedureReturn #True
EndProcedure


; Test helper: scans every stored message and collects the value found at
; JsonPath (e.g. "$.messageData.MsgType"), skipping messages where it's
; missing or null. Kept basic on purpose - no paging, no group/node filter.
Procedure.i GetValuesAtJsonPath(DbId.i, JsonPath.s, List Values.s())
	ClearList(Values())

	SetDatabaseString(DbId, 0, JsonPath)
	SetDatabaseString(DbId, 1, JsonPath)

	If Not DatabaseQuery(DbId, "SELECT message_data ->> ? FROM data WHERE message_data ->> ? IS NOT NULL")
		ProcedureReturn #False
	EndIf

	While NextDatabaseRow(DbId)
		AddElement(Values())
		Values() = GetDatabaseString(DbId, 0)
	Wend
	FinishDatabaseQuery(DbId)

	ProcedureReturn #True
EndProcedure


; Returns the highest message_id stored for a given group_id/node_id pair,
; or -1 if there's none yet. Will likely grow into a cached counter later.
Procedure.i GetLatestMessageId(DbId.i, GroupId.i, NodeId.i)
	Protected MessageId.i = -1

	SetDatabaseLong(DbId, 0, GroupId)
	SetDatabaseLong(DbId, 1, NodeId)

	If DatabaseQuery(DbId, "SELECT COALESCE(MAX(message_id), -1) FROM data WHERE group_id = ? AND node_id = ?")
		If NextDatabaseRow(DbId)
			MessageId = GetDatabaseLong(DbId, 0)
		EndIf
		FinishDatabaseQuery(DbId)
	EndIf

	ProcedureReturn MessageId
EndProcedure


; Usage example. Only compiled when this file is run directly (F5 in the
; IDE), not when it's included as a module by the rest of the project.
CompilerIf #PB_Compiler_IsMainFile

	Define DbId = OpenStorageDatabase("storage.sqlite")

	If DbId
		If SetupStorageDatabase(DbId)
			Insert(DbId, 1, 1, 1, ~"{\"messageData\": {\"MsgType\": \"hello\"}}")
			Insert(DbId, 1, 1, 2, ~"{\"messageData\": {\"MsgType\": \"world\"}}")

			NewList Messages.BakaShrot_Message()
			GetMessagesByGroupAndNode(DbId, 1, 1, Messages())
			ForEach Messages()
				Debug "Message #" + Str(Messages()\MessageId) + ": " + Messages()\JsonData
			Next

			NewList MsgTypes.s()
			GetValuesAtJsonPath(DbId, "$.messageData.MsgType", MsgTypes())
			ForEach MsgTypes()
				Debug "MsgType: " + MsgTypes()
			Next

			Debug "Latest message id: " + Str(GetLatestMessageId(DbId, 1, 1))
		Else
			Debug "Failed to set up database: " + DatabaseError()
		EndIf

		CloseDatabase(DbId)
	Else
		Debug "Failed to open database: " + DatabaseError()
	EndIf

CompilerEndIf
