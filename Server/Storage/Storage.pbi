; ============================================================================
; BakaShrot Storage
;
; Opens the SQLite database file that backs the node's local storage, and
; provides the basic read/write operations on top of it.
; Schema: see db_schema_v7.dbml in this same folder. Attachments: see
; Attachments.pbi and Design/Attachments.md.
;
; Needs SQLite 3.38+ with its JSON functions (json_valid, ->>), which the one
; bundled with PureBasic 5.73 (3.33.0) doesn't have. On Windows, the official
; sqlite3.dll is used instead, it must be next to the program. Build.ps1
; extracts it from Libs/sqlite-dll-win-*.zip and copies it.
;
; Threads: ONE CONNECTION PER THREAD, never share a handle.
; The SetDatabase*() parameters and query results belong to a handle, so two
; threads using the same one overwrite each other's. Every thread that touches
; the database opens its own with OpenStorageDatabase() and closes it when it
; ends: each client thread, each peer link thread, each raw query, and the
; root's own one (setup and maintenance, see Server/Root.pbi).
; The one exception: every write goes through the writer (Writer.pbi), a
; single connection only used while holding BakaShrot_Storage_WriteMutex.
; SQLite still serializes writes from other processes
; (#BakaShrot_Storage_BusyTimeout). WAL mode lets reads run alongside them.
; See Design/StorageConcurrency.md.
; ============================================================================


; For BakaShrot_SyncPair and BakaShrot_ReplicatedMessage.
XIncludeFile "../../Commons/Networking/Packets/SyncStatePacket.pbi"
XIncludeFile "../../Commons/Networking/Packets/ReplicateMessagesPacket.pbi"


CompilerIf #PB_Compiler_OS = #PB_OS_Windows
	UseSQLiteDatabase("sqlite3.dll")
CompilerElse
	UseSQLiteDatabase()
CompilerEndIf


; One row of the "data" table (see db_schema_v7.dbml).
; PushedAt: when it was pushed, ms since 1970 UTC (Packets.pbi).
; AttachmentSize: its attachment's size, 0 for none (the "attachments"
; table), AttachmentReady #True once all of it is here, AttachmentSha256 its
; SHA-256.
Structure BakaShrot_Message
	MessageId.q
	PushedAt.q
	JsonData.s
	AttachmentSize.q
	AttachmentReady.i
	AttachmentSha256.a[#BakaShrot_Sha256Size]
EndStructure


CompilerIf #PB_Compiler_OS <> #PB_OS_Windows
	ImportC ""
		BakaShrot_GetTimeOfDay.l(*TimeVal, *TimeZone) As "gettimeofday"
	EndImport
CompilerEndIf

; Now, in milliseconds since 1970-01-01 00:00:00 UTC: what a pushed message
; is stamped with (pushed_at).
Procedure.q BakaShrot_NowUtcMs()
	CompilerIf #PB_Compiler_OS = #PB_OS_Windows
		; 100 ns intervals since 1601-01-01 UTC.
		Protected FileTime.q
		GetSystemTimeAsFileTime_(@FileTime)
		ProcedureReturn (FileTime - 116444736000000000) / 10000
	CompilerElse
		; Untested: Linux isn't built yet. struct timeval, 64-bit.
		Protected Dim TimeVal.q(1)
		BakaShrot_GetTimeOfDay(@TimeVal(0), 0)
		ProcedureReturn TimeVal(0) * 1000 + TimeVal(1) / 1000
	CompilerEndIf
EndProcedure


; How long a connection waits for another one's lock before a statement
; fails with "database is locked", in ms.
#BakaShrot_Storage_BusyTimeout = 5000

; The database runs in WAL mode (set up by SetupStorageDatabase(), stored in
; the file): readers and the writer don't block each other anymore, so a
; long raw query no longer stalls every push.
; With WAL, NORMAL only syncs to disk at checkpoints instead of on every
; commit, which is most of what a push used to cost. The database can't get
; corrupted, but the last commits before a power loss or an OS crash (not a
; crash of the server itself) can be lost. Those messages were acknowledged,
; and maybe replicated already, so their ids could then be handed out again
; for other messages: drift, see Design/ReplicationIssues.md #1.
; FULL syncs every commit, like before, but still lets reads and writes run
; side by side.
#BakaShrot_Storage_Synchronous = "NORMAL"


; Opens (and creates, if missing) the SQLite database at DatabasePath, as a
; new connection for the calling thread only.
; Returns the PureBasic database number, or 0 if the file could not be opened.
Procedure.i OpenStorageDatabase(DatabasePath.s)
	Protected FileId.i, DbId.i

	; PureBasic's SQLite driver refuses to open a file that doesn't exist,
	; so an empty one has to be created first.
	If FileSize(DatabasePath) = -1
		FileId = CreateFile(#PB_Any, DatabasePath)
		If Not FileId
			ProcedureReturn 0
		EndIf
		CloseFile(FileId)
	EndIf

	DbId = OpenDatabase(#PB_Any, DatabasePath, "", "")
	If Not DbId
		ProcedureReturn 0
	EndIf

	; Without it, a write fails right away while another connection writes.
	If Not DatabaseUpdate(DbId, "PRAGMA busy_timeout = " + Str(#BakaShrot_Storage_BusyTimeout))
		CloseDatabase(DbId)
		ProcedureReturn 0
	EndIf

	; Per connection, see #BakaShrot_Storage_Synchronous.
	If Not DatabaseUpdate(DbId, "PRAGMA synchronous = " + #BakaShrot_Storage_Synchronous)
		CloseDatabase(DbId)
		ProcedureReturn 0
	EndIf

	ProcedureReturn DbId
EndProcedure


; Rebuilds the database file, reclaiming the space of deleted rows.
; Only run it from the root while every worker is stopped: it needs every
; other connection to be idle. See BakaShrot_Root_Vacuum() in Server/Root.pbi.
Procedure.i VacuumStorageDatabase(DbId.i)
	ProcedureReturn DatabaseUpdate(DbId, "VACUUM")
EndProcedure


; #True if Table has a column named Column, #False if not (or no such table),
; -1 on failure.
Procedure.i StorageHasColumn(DbId.i, Table.s, Column.s)
	Protected Found.i = #False

	SetDatabaseString(DbId, 0, Table)
	SetDatabaseString(DbId, 1, Column)
	If Not DatabaseQuery(DbId, "SELECT COUNT(*) FROM pragma_table_info(?) WHERE name = ?")
		ProcedureReturn -1
	EndIf
	If NextDatabaseRow(DbId)
		Found = Bool(GetDatabaseLong(DbId, 0) > 0)
	EndIf
	FinishDatabaseQuery(DbId)

	ProcedureReturn Found
EndProcedure


; v3 -> v4: "group_id" became "topic_id" in every table. Renames the
; columns of a database made before, in one transaction. The trigger and the
; attachements index are dropped, SetupStorageDatabase() makes them again
; with the new names. The UNIQUE and PRIMARY KEY indexes follow the columns.
; Nothing to do on a new or already renamed database.
Procedure.i MigrateStorageTopicIds(DbId.i)
	Protected Table.s, Has.i, i.i

	Has = StorageHasColumn(DbId, "data", "group_id")
	If Has = -1
		ProcedureReturn #False
	ElseIf Not Has
		ProcedureReturn #True
	EndIf

	If Not DatabaseUpdate(DbId, "BEGIN IMMEDIATE")
		ProcedureReturn #False
	EndIf
	If Not DatabaseUpdate(DbId, "DROP TRIGGER IF EXISTS trg_data_node_heads") Or
	   Not DatabaseUpdate(DbId, "DROP INDEX IF EXISTS idx_attachements_group_node")
		DatabaseUpdate(DbId, "ROLLBACK")
		ProcedureReturn #False
	EndIf
	For i = 1 To 3
		Table = StringField("data,node_heads,attachements", i, ",")
		Has = StorageHasColumn(DbId, Table, "group_id")
		If Has = -1 Or (Has And Not DatabaseUpdate(DbId, "ALTER TABLE " + Table + " RENAME COLUMN group_id TO topic_id"))
			DatabaseUpdate(DbId, "ROLLBACK")
			ProcedureReturn #False
		EndIf
	Next
	If Not DatabaseUpdate(DbId, "COMMIT")
		DatabaseUpdate(DbId, "ROLLBACK")
		ProcedureReturn #False
	EndIf

	ProcedureReturn #True
EndProcedure


; v5 -> v6: "data" got pushed_at. Adds it to a database made before, every
; message stamped with the time of the upgrade (their real one is unknown),
; in one transaction. Nothing to do on a new or already upgraded database.
Procedure.i MigrateStoragePushedAt(DbId.i)
	Protected Has.i

	Has = StorageHasColumn(DbId, "data", "pushed_at")
	If Has = -1
		ProcedureReturn #False
	ElseIf Has
		ProcedureReturn #True
	EndIf

	If Not DatabaseUpdate(DbId, "BEGIN IMMEDIATE")
		ProcedureReturn #False
	EndIf
	If Not DatabaseUpdate(DbId, "ALTER TABLE data ADD COLUMN pushed_at INTEGER NOT NULL DEFAULT 0")
		DatabaseUpdate(DbId, "ROLLBACK")
		ProcedureReturn #False
	EndIf
	; Bound for the next statement run, so right before it.
	SetDatabaseQuad(DbId, 0, BakaShrot_NowUtcMs())
	If Not DatabaseUpdate(DbId, "UPDATE data SET pushed_at = ?")
		DatabaseUpdate(DbId, "ROLLBACK")
		ProcedureReturn #False
	EndIf
	If Not DatabaseUpdate(DbId, "COMMIT")
		DatabaseUpdate(DbId, "ROLLBACK")
		ProcedureReturn #False
	EndIf

	ProcedureReturn #True
EndProcedure


; Creates the tables and indexes described by db_schema_v7.dbml, if they
; don't exist yet. Plain "CREATE IF NOT EXISTS" for now - a real versioned
; upgrade mechanism (DbUpdater) will replace this later.
; Fails on a database made with an older schema, since it would be left as is.
Procedure.i SetupStorageDatabase(DbId.i)
	Protected JournalMode.s, HeadsExist.i

	; Stored in the file, every later connection uses it. Fails while another
	; connection has the database open, so only the root does it, at start.
	If Not DatabaseQuery(DbId, "PRAGMA journal_mode = WAL")
		ProcedureReturn #False
	EndIf
	If NextDatabaseRow(DbId)
		JournalMode = LCase(GetDatabaseString(DbId, 0))
	EndIf
	FinishDatabaseQuery(DbId)
	If JournalMode <> "wal"
		ProcedureReturn #False
	EndIf

	; Before anything below, which uses the new names.
	If Not MigrateStorageTopicIds(DbId)
		ProcedureReturn #False
	EndIf

	; A leftover of the first schemas, never used: the retention deletes
	; instead (Retention.pbi).
	If Not DatabaseUpdate(DbId, "DROP TABLE IF EXISTS archives")
		ProcedureReturn #False
	EndIf

	; is_json is set by SQLite on insert, and can't be written.
	; pushed_at: when it was pushed to its origin, ms since 1970 UTC, kept as
	; is when replicated. Last, like the ALTER TABLE below adds it.
	; The UNIQUE constraint's index also serves (topic_id, node_id) lookups.
	If Not DatabaseUpdate(DbId, "CREATE TABLE IF NOT EXISTS data (" +
	                             "topic_id INTEGER NOT NULL, " +
	                             "node_id INTEGER NOT NULL, " +
	                             "message_id INTEGER NOT NULL, " +
	                             "message_data TEXT NOT NULL, " +
	                             "is_json INTEGER NOT NULL GENERATED ALWAYS AS (json_valid(message_data)) STORED, " +
	                             "pushed_at INTEGER NOT NULL DEFAULT 0, " +
	                             "UNIQUE (topic_id, node_id, message_id))")
		ProcedureReturn #False
	EndIf

	; An older "data" table is kept by CREATE IF NOT EXISTS, its lack of
	; is_json gives it away. Fails with "no such column: is_json".
	If Not DatabaseQuery(DbId, "SELECT is_json FROM data LIMIT 0")
		ProcedureReturn #False
	EndIf
	FinishDatabaseQuery(DbId)
	If Not DatabaseUpdate(DbId, "CREATE INDEX IF NOT EXISTS idx_data_message_id ON data (message_id)")
		ProcedureReturn #False
	EndIf

	; A database from before pushed_at: its messages get the time of this
	; upgrade, so a topic's max age (Server/Storage/Retention.pbi) counts
	; from now for them instead of deleting them all at once.
	If Not MigrateStoragePushedAt(DbId)
		ProcedureReturn #False
	EndIf

	; What the retention deletes by: a topic's messages pushed before a time.
	If Not DatabaseUpdate(DbId, "CREATE INDEX IF NOT EXISTS idx_data_topic_pushed_at ON data (topic_id, pushed_at)")
		ProcedureReturn #False
	EndIf

	; The first schemas' placeholder, never used (and misspelled), replaced
	; by the three tables below. Its indexes go with it.
	If Not DatabaseUpdate(DbId, "DROP TABLE IF EXISTS attachements")
		ProcedureReturn #False
	EndIf

	; Attachments, see Attachments.pbi and Design/Attachments.md.
	; blobs: an attachment's data, being uploaded or replicated, or stored.
	;   topic_id, node_id: an upload's, who may attach it (or the message's).
	;   received: bytes stored so far, in blob_chunks.
	;   state: 0 receiving, 1 complete (an upload waiting for its message),
	;   2 attached to its message, 3 to delete (Retention.pbi deletes it).
	;   created_at: ms since 1970 UTC, uploads left incomplete expire.
	; blob_chunks: its parts, #BakaShrot_AttachmentChunkSize bytes each.
	; attachments: a message's (one at most), with its size and SHA-256
	;   from the start, its data in blob_id once any is here.
	;   state: 0 missing (a replicated message, none of it here yet),
	;   1 receiving, 2 ready, 3 not kept (bigger than this server takes).
	If Not DatabaseUpdate(DbId, "CREATE TABLE IF NOT EXISTS blobs (" +
	                             "blob_id INTEGER PRIMARY KEY, " +
	                             "topic_id INTEGER NOT NULL, " +
	                             "node_id INTEGER NOT NULL, " +
	                             "size INTEGER NOT NULL, " +
	                             "sha256 BLOB NOT NULL, " +
	                             "received INTEGER NOT NULL DEFAULT 0, " +
	                             "state INTEGER NOT NULL, " +
	                             "created_at INTEGER NOT NULL)") Or
	   Not DatabaseUpdate(DbId, "CREATE TABLE IF NOT EXISTS blob_chunks (" +
	                             "blob_id INTEGER NOT NULL, " +
	                             "chunk_index INTEGER NOT NULL, " +
	                             "chunk_data BLOB NOT NULL, " +
	                             "PRIMARY KEY (blob_id, chunk_index))") Or
	   Not DatabaseUpdate(DbId, "CREATE TABLE IF NOT EXISTS attachments (" +
	                             "topic_id INTEGER NOT NULL, " +
	                             "node_id INTEGER NOT NULL, " +
	                             "message_id INTEGER NOT NULL, " +
	                             "size INTEGER NOT NULL, " +
	                             "sha256 BLOB NOT NULL, " +
	                             "blob_id INTEGER, " +
	                             "state INTEGER NOT NULL, " +
	                             "PRIMARY KEY (topic_id, node_id, message_id)) WITHOUT ROWID") Or
	   Not DatabaseUpdate(DbId, "CREATE INDEX IF NOT EXISTS idx_blobs_state ON blobs (state)") Or
	   Not DatabaseUpdate(DbId, "CREATE INDEX IF NOT EXISTS idx_attachments_state ON attachments (state)")
		ProcedureReturn #False
	EndIf

	; A message deleted (the retention) takes its attachment with it, and an
	; attachment its data: marked, Retention.pbi deletes it a bit at a time.
	If Not DatabaseUpdate(DbId, "CREATE TRIGGER IF NOT EXISTS trg_data_attachments AFTER DELETE ON data BEGIN " +
	                             "DELETE FROM attachments WHERE topic_id = OLD.topic_id AND node_id = OLD.node_id AND message_id = OLD.message_id; " +
	                             "END") Or
	   Not DatabaseUpdate(DbId, "CREATE TRIGGER IF NOT EXISTS trg_attachments_blobs AFTER DELETE ON attachments WHEN OLD.blob_id IS NOT NULL BEGIN " +
	                             "UPDATE blobs SET state = 3 WHERE blob_id = OLD.blob_id; " +
	                             "END")
		ProcedureReturn #False
	EndIf

	; The highest message id of every topic/node id, kept by a trigger on
	; every insert, whoever does it. The sync state comes from it instead of
	; a GROUP BY over every message (131 ms at 1.9M rows, on every check-in).
	; Filled from "data" when it's created on an existing database.
	; Deleting from "data" (the retention) leaves it alone, on purpose: a
	; pair's head stays its highest id ever, so the next push still gets the
	; id after it, and peers aren't sent again what was deleted here.
	If Not DatabaseQuery(DbId, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'node_heads'")
		ProcedureReturn #False
	EndIf
	HeadsExist = #False
	If NextDatabaseRow(DbId)
		HeadsExist = Bool(GetDatabaseLong(DbId, 0) > 0)
	EndIf
	FinishDatabaseQuery(DbId)

	If Not HeadsExist
		If Not DatabaseUpdate(DbId, "BEGIN IMMEDIATE")
			ProcedureReturn #False
		EndIf
		If Not DatabaseUpdate(DbId, "CREATE TABLE node_heads (" +
		                             "topic_id INTEGER NOT NULL, " +
		                             "node_id INTEGER NOT NULL, " +
		                             "max_message_id INTEGER NOT NULL, " +
		                             "PRIMARY KEY (topic_id, node_id)) WITHOUT ROWID") Or
		   Not DatabaseUpdate(DbId, "INSERT INTO node_heads (topic_id, node_id, max_message_id) " +
		                             "SELECT topic_id, node_id, MAX(message_id) FROM data GROUP BY topic_id, node_id")
			DatabaseUpdate(DbId, "ROLLBACK")
			ProcedureReturn #False
		EndIf
		If Not DatabaseUpdate(DbId, "COMMIT")
			DatabaseUpdate(DbId, "ROLLBACK")
			ProcedureReturn #False
		EndIf
	EndIf

	; Only fires for rows actually inserted, not the ones INSERT OR IGNORE drops.
	If Not DatabaseUpdate(DbId, "CREATE TRIGGER IF NOT EXISTS trg_data_node_heads AFTER INSERT ON data BEGIN " +
	                             "INSERT INTO node_heads (topic_id, node_id, max_message_id) VALUES (NEW.topic_id, NEW.node_id, NEW.message_id) " +
	                             "ON CONFLICT (topic_id, node_id) DO UPDATE SET max_message_id = MAX(max_message_id, excluded.max_message_id); " +
	                             "END")
		ProcedureReturn #False
	EndIf

	; Every topic and node id in "data" has a row, with its name, or its id
	; in digits if it has none. origin: "config" (named in the config),
	; "peer" (a node a peer sent messages of, given an id here), "id"
	; (unnamed). Kept up to date by Server/Storage/Names.pbi.
	; No foreign keys from "data": see Notes.md, a replicated batch would
	; fail as a whole on an unknown id.
	If Not DatabaseUpdate(DbId, "CREATE TABLE IF NOT EXISTS topics (" +
	                             "topic_id INTEGER PRIMARY KEY, " +
	                             "name TEXT NOT NULL UNIQUE COLLATE NOCASE, " +
	                             "origin TEXT NOT NULL)") Or
	   Not DatabaseUpdate(DbId, "CREATE TABLE IF NOT EXISTS nodes (" +
	                             "node_id INTEGER PRIMARY KEY, " +
	                             "name TEXT NOT NULL UNIQUE COLLATE NOCASE, " +
	                             "origin TEXT NOT NULL)")
		ProcedureReturn #False
	EndIf

	; For queries by name: SELECT * FROM messages WHERE topic = 'logs' AND
	; node = 'kitchen' still goes through the indexes. pushed_utc is
	; pushed_at as text, "2026-11-08T14:03:59.123Z".
	; Made again on every start, so an older one gets the newer columns.
	If Not DatabaseUpdate(DbId, "DROP VIEW IF EXISTS messages") Or
	   Not DatabaseUpdate(DbId, "CREATE VIEW messages AS " +
	                             "SELECT t.name AS topic, n.name AS node, d.message_id, d.message_data, d.is_json, d.topic_id, d.node_id, " +
	                             "d.pushed_at, strftime('%Y-%m-%dT%H:%M:%fZ', d.pushed_at / 1000.0, 'unixepoch') AS pushed_utc " +
	                             "FROM data d JOIN topics t ON t.topic_id = d.topic_id JOIN nodes n ON n.node_id = d.node_id")
		ProcedureReturn #False
	EndIf

	ProcedureReturn #True
EndProcedure


; Inserts one JSON message into the "data" table, pushed now.
Procedure.i Insert(DbId.i, TopicId.i, NodeId.i, MessageId.i, JsonData.s)
	SetDatabaseLong(DbId, 0, TopicId)
	SetDatabaseLong(DbId, 1, NodeId)
	SetDatabaseLong(DbId, 2, MessageId)
	SetDatabaseString(DbId, 3, JsonData)
	SetDatabaseQuad(DbId, 4, BakaShrot_NowUtcMs())

	ProcedureReturn DatabaseUpdate(DbId, "INSERT INTO data (topic_id, node_id, message_id, message_data, pushed_at) VALUES (?, ?, ?, ?, ?)")
EndProcedure


; Gets every message stored for a given topic_id/node_id pair - the
; "(topic_id, node_id)" index - ordered by message_id.
Procedure.i GetMessagesByTopicAndNode(DbId.i, TopicId.i, NodeId.i, List Messages.BakaShrot_Message())
	ClearList(Messages())

	SetDatabaseLong(DbId, 0, TopicId)
	SetDatabaseLong(DbId, 1, NodeId)

	If Not DatabaseQuery(DbId, "SELECT message_id, message_data FROM data WHERE topic_id = ? AND node_id = ? ORDER BY message_id")
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
; topic/node it belongs to - the standalone "message_id" index.
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
; missing or null, and those that aren't JSON (is_json = 0: ->> fails the
; whole query on one). Kept basic on purpose - no paging, no topic/node filter.
Procedure.i GetValuesAtJsonPath(DbId.i, JsonPath.s, List Values.s())
	ClearList(Values())

	SetDatabaseString(DbId, 0, JsonPath)
	SetDatabaseString(DbId, 1, JsonPath)

	If Not DatabaseQuery(DbId, "SELECT message_data ->> ? FROM data WHERE is_json = 1 AND message_data ->> ? IS NOT NULL")
		ProcedureReturn #False
	EndIf

	While NextDatabaseRow(DbId)
		AddElement(Values())
		Values() = GetDatabaseString(DbId, 0)
	Wend
	FinishDatabaseQuery(DbId)

	ProcedureReturn #True
EndProcedure


; Returns the highest message_id stored for a given topic_id/node_id pair,
; or -1 if there's none yet. Will likely grow into a cached counter later.
Procedure.i GetLatestMessageId(DbId.i, TopicId.i, NodeId.i)
	Protected MessageId.i = -1

	SetDatabaseLong(DbId, 0, TopicId)
	SetDatabaseLong(DbId, 1, NodeId)

	If DatabaseQuery(DbId, "SELECT COALESCE(MAX(message_id), -1) FROM data WHERE topic_id = ? AND node_id = ?")
		If NextDatabaseRow(DbId)
			MessageId = GetDatabaseLong(DbId, 0)
		EndIf
		FinishDatabaseQuery(DbId)
	EndIf

	ProcedureReturn MessageId
EndProcedure



; Reads the attachment's size, state and SHA-256 (COALESCE(a.size, 0),
; COALESCE(a.state, 0), a.sha256) from Column on into *Message.
Procedure BakaShrot_ReadAttachmentColumns(DbId.i, Column.i, *Message.BakaShrot_Message)
	*Message\AttachmentSize  = GetDatabaseQuad(DbId, Column)
	*Message\AttachmentReady = Bool(*Message\AttachmentSize > 0 And GetDatabaseLong(DbId, Column + 1) = 2)
	FillMemory(@*Message\AttachmentSha256[0], #BakaShrot_Sha256Size, 0)
	If *Message\AttachmentSize > 0 And DatabaseColumnSize(DbId, Column + 2) = #BakaShrot_Sha256Size
		GetDatabaseBlob(DbId, Column + 2, @*Message\AttachmentSha256[0], #BakaShrot_Sha256Size)
	EndIf
EndProcedure


; Fills *Message with the message that has the highest message_id for a
; topic_id/node_id pair.
; Returns #False if there's none, or if the query failed.
Procedure.i GetLatestMessage(DbId.i, TopicId.i, NodeId.i, *Message.BakaShrot_Message)
	Protected Found.i

	SetDatabaseLong(DbId, 0, TopicId)
	SetDatabaseLong(DbId, 1, NodeId)
	If Not DatabaseQuery(DbId, "SELECT d.message_id, d.message_data, d.pushed_at, COALESCE(a.size, 0), COALESCE(a.state, 0), a.sha256 " +
	                           "FROM data d LEFT JOIN attachments a ON a.topic_id = d.topic_id AND a.node_id = d.node_id AND a.message_id = d.message_id " +
	                           "WHERE d.topic_id = ? AND d.node_id = ? ORDER BY d.message_id DESC LIMIT 1")
		ProcedureReturn #False
	EndIf

	Found = NextDatabaseRow(DbId)
	If Found
		*Message\MessageId = GetDatabaseQuad(DbId, 0)
		*Message\JsonData  = GetDatabaseString(DbId, 1)
		*Message\PushedAt  = GetDatabaseQuad(DbId, 2)
		BakaShrot_ReadAttachmentColumns(DbId, 3, *Message)
	EndIf
	FinishDatabaseQuery(DbId)

	ProcedureReturn Found
EndProcedure


; --- Raw queries -------------------------------------------------------------

; Most rows a raw query can return.
#BakaShrot_Query_MaxRows = 10000

; Telling the end of a query's rows from an error that cut them short.
; PureBasic's NextDatabaseRow() returns #False for both, and DatabaseError()
; stays empty after such an error: a JSON function (->>, json_extract())
; reaching a row that isn't JSON stops the query with "malformed JSON", and
; the query looked like it simply had no (more) rows. So once the rows end,
; SQLite itself is asked: sqlite3_errcode() on the connection is SQLITE_DONE
; (or SQLITE_ROW/SQLITE_OK) if they really ended, the error otherwise, with
; sqlite3_errmsg16() telling which. Same sqlite3.dll as PureBasic's
; (DatabaseID() is its sqlite3 handle), like Writer.pbi.
; Elsewhere than Windows, PureBasic's own SQLite is linked in and not
; reachable this way: DatabaseError() is checked instead, which misses it.
#BakaShrot_Query_SqliteOk   = 0
#BakaShrot_Query_SqliteRow  = 100
#BakaShrot_Query_SqliteDone = 101

CompilerIf #PB_Compiler_OS = #PB_OS_Windows
	PrototypeC.l BakaShrot_Query_SqliteErrCode(Db.i)
	PrototypeC.i BakaShrot_Query_SqliteErrMsg16(Db.i)

	Structure BakaShrot_Query_SqliteApi
		Library.i
		ErrCode.BakaShrot_Query_SqliteErrCode
		ErrMsg16.BakaShrot_Query_SqliteErrMsg16
	EndStructure

	Global BakaShrot_Query_Sqlite.BakaShrot_Query_SqliteApi
	; Queries run on every client's thread, the first one loads it.
	Global BakaShrot_Query_SqliteMutex.i = CreateMutex()

	; Returns #False if sqlite3.dll or its functions can't be found.
	Procedure.i BakaShrot_Query_LoadSqlite()
		Protected Loaded.i

		LockMutex(BakaShrot_Query_SqliteMutex)
		With BakaShrot_Query_Sqlite
			If Not \Library
				\Library = OpenLibrary(#PB_Any, "sqlite3.dll")
				If \Library
					\ErrCode  = GetFunction(\Library, "sqlite3_errcode")
					\ErrMsg16 = GetFunction(\Library, "sqlite3_errmsg16")
					If Not \ErrCode Or Not \ErrMsg16
						CloseLibrary(\Library)
						\Library = 0
					EndIf
				EndIf
			EndIf
			Loaded = Bool(\Library)
		EndWith
		UnlockMutex(BakaShrot_Query_SqliteMutex)

		ProcedureReturn Loaded
	EndProcedure
CompilerEndIf

; Runs a raw SQL query from a client, read-only, and fills *Result\s with its
; rows as JSON: {"columns": ["name", ...], "rows": [["value", ...], ...]}.
; Every value is a string, or null for NULL: PureBasic reports no column
; types for SQLite. Wrap a blob in hex() to read it.
;
; Read-only, enforced three ways:
;   1. It must start with SELECT or WITH.
;   2. It runs on its own connection to DatabasePath, opened just for it,
;      with PRAGMA query_only = ON. Writes fail, even WITH ... DELETE, and a
;      query that turns the pragma off only does so for its own connection.
;   3. Only the first statement runs, anything after a ";" is ignored.
;
; An error while reading the rows fails the whole query, with SQLite's
; message: a JSON function on a row that isn't JSON gives "malformed JSON",
; add "is_json = 1" to the WHERE. Never a partial or empty result instead.
;
; Thread-safe, since it never touches a shared handle.
; Returns #False with *Error\s set if it's refused, fails, or has more than
; #BakaShrot_Query_MaxRows rows.
Procedure.i RunReadOnlyQuery(DatabasePath.s, Sql.s, *Result.String, *Error.String)
	Protected DbId.i, JsonId.i, *Root, *Columns, *Rows, *Row
	Protected Column.i, RowCount.i, Start.s, ErrorCode.l

	Start = UCase(Trim(ReplaceString(ReplaceString(ReplaceString(Sql, #CR$, " "), #LF$, " "), #TAB$, " ")))
	If Left(Start, 6) <> "SELECT" And Left(Start, 4) <> "WITH"
		*Error\s = "Only SELECT and WITH queries are allowed"
		ProcedureReturn #False
	EndIf

	; Without it, errors in the rows would go unnoticed: refused instead.
	CompilerIf #PB_Compiler_OS = #PB_OS_Windows
		If Not BakaShrot_Query_LoadSqlite()
			*Error\s = "Queries can't be checked for errors: sqlite3_errcode() not found"
			ProcedureReturn #False
		EndIf
	CompilerEndIf

	DbId = OpenStorageDatabase(DatabasePath)
	If Not DbId
		*Error\s = "The database couldn't be opened"
		ProcedureReturn #False
	EndIf

	If Not DatabaseUpdate(DbId, "PRAGMA query_only = ON")
		*Error\s = "The database couldn't be made read-only"
		CloseDatabase(DbId)
		ProcedureReturn #False
	EndIf

	If Not DatabaseQuery(DbId, Sql)
		*Error\s = DatabaseError()
		CloseDatabase(DbId)
		ProcedureReturn #False
	EndIf

	; WITH ... DELETE and the likes have no columns. query_only stops them
	; anyway, but PureBasic doesn't report that, they'd look like no rows.
	If DatabaseColumns(DbId) = 0
		*Error\s = "The query doesn't return any column, only SELECT queries are allowed"
		FinishDatabaseQuery(DbId)
		CloseDatabase(DbId)
		ProcedureReturn #False
	EndIf

	JsonId = CreateJSON(#PB_Any)
	If Not JsonId
		*Error\s = "Out of memory"
		FinishDatabaseQuery(DbId)
		CloseDatabase(DbId)
		ProcedureReturn #False
	EndIf
	*Root = SetJSONObject(JSONValue(JsonId))

	*Columns = SetJSONArray(AddJSONMember(*Root, "columns"))
	For Column = 0 To DatabaseColumns(DbId) - 1
		SetJSONString(AddJSONElement(*Columns), DatabaseColumnName(DbId, Column))
	Next

	*Rows = SetJSONArray(AddJSONMember(*Root, "rows"))
	While NextDatabaseRow(DbId)
		RowCount + 1
		If RowCount > #BakaShrot_Query_MaxRows
			*Error\s = "More than " + Str(#BakaShrot_Query_MaxRows) + " rows, add a LIMIT"
			FreeJSON(JsonId)
			FinishDatabaseQuery(DbId)
			CloseDatabase(DbId)
			ProcedureReturn #False
		EndIf

		*Row = SetJSONArray(AddJSONElement(*Rows))
		For Column = 0 To DatabaseColumns(DbId) - 1
			If CheckDatabaseNull(DbId, Column)
				SetJSONNull(AddJSONElement(*Row))
			Else
				SetJSONString(AddJSONElement(*Row), GetDatabaseString(DbId, Column))
			EndIf
		Next
	Wend

	; Did the rows end, or did an error end them? (see above): "malformed
	; JSON", a write stopped by query_only (DELETE ... RETURNING), ...
	; Asked before FinishDatabaseQuery(), while the failed step is the last
	; thing done on this connection. A false alarm would refuse a good
	; query, it can't hide a bad one.
	CompilerIf #PB_Compiler_OS = #PB_OS_Windows
		ErrorCode = BakaShrot_Query_Sqlite\ErrCode(DatabaseID(DbId))
		If ErrorCode <> #BakaShrot_Query_SqliteOk And ErrorCode <> #BakaShrot_Query_SqliteRow And ErrorCode <> #BakaShrot_Query_SqliteDone
			*Error\s = PeekS(BakaShrot_Query_Sqlite\ErrMsg16(DatabaseID(DbId)), -1, #PB_Unicode)
			If *Error\s = ""
				*Error\s = "SQLite error " + Str(ErrorCode)
			EndIf
			If FindString(*Error\s, "JSON", 1, #PB_String_NoCase)
				*Error\s + " (a row isn't JSON: add is_json = 1 to the WHERE)"
			EndIf
			FreeJSON(JsonId)
			FinishDatabaseQuery(DbId)
			CloseDatabase(DbId)
			ProcedureReturn #False
		EndIf
	CompilerEndIf
	FinishDatabaseQuery(DbId)

	; Elsewhere than Windows, the only check there is. It misses errors in the
	; rows: PureBasic doesn't report them.
	; !!! DatabaseError() may be shared by every thread, see
	; !!! Design/StorageConcurrency.md, another thread's error could show up here.
	CompilerIf #PB_Compiler_OS <> #PB_OS_Windows
		If DatabaseError() <> ""
			*Error\s = DatabaseError()
			FreeJSON(JsonId)
			CloseDatabase(DbId)
			ProcedureReturn #False
		EndIf
	CompilerEndIf

	*Result\s = ComposeJSON(JsonId)
	FreeJSON(JsonId)
	CloseDatabase(DbId)

	ProcedureReturn #True
EndProcedure


; --- Replication -------------------------------------------------------------

; Fills Pairs() with where this node is at: the highest message id it has for
; every topic/node id combination, ordered by topic then node id. Read from
; node_heads, kept up to date by a trigger, see SetupStorageDatabase().
; Returns #False if the query failed.
Procedure.i GetSyncState(DbId.i, List Pairs.BakaShrot_SyncPair())
	ClearList(Pairs())

	If Not DatabaseQuery(DbId, "SELECT topic_id, node_id, max_message_id FROM node_heads ORDER BY topic_id, node_id")
		ProcedureReturn #False
	EndIf

	While NextDatabaseRow(DbId)
		AddElement(Pairs())
		Pairs()\TopicId   = GetDatabaseLong(DbId, 0)
		Pairs()\NodeId    = GetDatabaseLong(DbId, 1)
		Pairs()\MessageId = GetDatabaseQuad(DbId, 2)
	Wend
	FinishDatabaseQuery(DbId)

	ProcedureReturn #True
EndProcedure


; Fills Messages() with up to Limit messages of a topic/node id combination
; whose message_id is above AfterMessageId, in message_id order. Stops early
; once their JSON adds up to MaxChars characters or more (0: no such limit),
; the one that got there included, so big messages aren't all read at once.
; If *More is given, *More\i is set to #True if more messages follow the
; last one read.
; Returns #False if the query failed.
Procedure.i GetMessagesAfter(DbId.i, TopicId.i, NodeId.i, AfterMessageId.q, Limit.i, MaxChars.i, List Messages.BakaShrot_Message(), *More.Integer = 0)
	Protected Chars.i, More.i

	ClearList(Messages())

	; One more than asked for, to tell if more follow.
	SetDatabaseLong(DbId, 0, TopicId)
	SetDatabaseLong(DbId, 1, NodeId)
	SetDatabaseQuad(DbId, 2, AfterMessageId)
	SetDatabaseLong(DbId, 3, Limit + 1)
	If Not DatabaseQuery(DbId, "SELECT d.message_id, d.message_data, d.pushed_at, COALESCE(a.size, 0), COALESCE(a.state, 0), a.sha256 " +
	                           "FROM data d LEFT JOIN attachments a ON a.topic_id = d.topic_id AND a.node_id = d.node_id AND a.message_id = d.message_id " +
	                           "WHERE d.topic_id = ? AND d.node_id = ? AND d.message_id > ? ORDER BY d.message_id LIMIT ?")
		ProcedureReturn #False
	EndIf

	While NextDatabaseRow(DbId)
		If ListSize(Messages()) >= Limit Or (MaxChars > 0 And Chars >= MaxChars)
			More = #True
			Break
		EndIf
		AddElement(Messages())
		Messages()\MessageId = GetDatabaseQuad(DbId, 0)
		Messages()\JsonData  = GetDatabaseString(DbId, 1)
		Messages()\PushedAt  = GetDatabaseQuad(DbId, 2)
		BakaShrot_ReadAttachmentColumns(DbId, 3, @Messages())
		Chars + Len(Messages()\JsonData)
	Wend
	FinishDatabaseQuery(DbId)

	If *More
		*More\i = More
	EndIf
	ProcedureReturn #True
EndProcedure


; Stores a message replicated from a peer, under the ids it has on its origin.
; If that topic/node/message id is already stored, it's kept as is, and the
; new one is dropped, even if it differs. See Design/ReplicationIssues.md.
; On its own connection: for tools writing while the server is stopped
; (BenchSeed). The server itself writes through Writer.pbi.
; PushedAt: when it was pushed to its origin, ms since 1970 UTC.
; Returns #False if the insert failed.
Procedure.i InsertReplicatedMessage(DbId.i, TopicId.i, NodeId.i, MessageId.q, JsonData.s, PushedAt.q)
	SetDatabaseLong(DbId, 0, TopicId)
	SetDatabaseLong(DbId, 1, NodeId)
	SetDatabaseQuad(DbId, 2, MessageId)
	SetDatabaseString(DbId, 3, JsonData)
	SetDatabaseQuad(DbId, 4, PushedAt)
	ProcedureReturn DatabaseUpdate(DbId, "INSERT OR IGNORE INTO data (topic_id, node_id, message_id, message_data, pushed_at) VALUES (?, ?, ?, ?, ?)")
EndProcedure



; Every write: pushes (group commit), replicated batches, the WAL checkpoints.
XIncludeFile "Writer.pbi"

; Attachments: uploads, parts, reading them back, the replicated ones.
XIncludeFile "Attachments.pbi"


; Usage example. Only compiled when this file is run directly (F5 in the
; IDE), not when it's included as a module by the rest of the project.
CompilerIf #PB_Compiler_IsMainFile

	Define DbId = OpenStorageDatabase("storage.sqlite")

	If DbId
		If SetupStorageDatabase(DbId)
			Insert(DbId, 1, 1, 1, ~"{\"messageData\": {\"MsgType\": \"hello\"}}")
			Insert(DbId, 1, 1, 2, ~"{\"messageData\": {\"MsgType\": \"world\"}}")

			NewList Messages.BakaShrot_Message()
			GetMessagesByTopicAndNode(DbId, 1, 1, Messages())
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
