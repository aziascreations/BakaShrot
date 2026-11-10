; ============================================================================
; BakaShrot Storage Writer
;
; Every write the server does to its database goes through here:
;   InsertNextMessage()         pushes, grouped (group commit), stamped
;                               with the time they arrived (pushed_at)
;   InsertReplicatedMessages()  batches from peers, with their pushed_at,
;                               skipping those already past their max age
;   DeleteStorageMessagesBefore()  the retention (Retention.pbi)
; on ONE connection, the writer, only ever used while holding
; BakaShrot_Storage_WriteMutex. Opened by OpenStorageWriter() when the
; workers start, closed by CloseStorageWriter() once they're stopped (see
; Server/Root.pbi). The exception to "one connection per thread" (see
; Storage.pbi): it's shared, but never by two threads at once.
;
; What makes it fast, see Design/StorageConcurrency.md:
;   - Group commit: each push queues itself, then takes the write mutex.
;     Whoever holds it writes every queued push in one transaction, the ones
;     that were waiting find theirs done. The busier, the bigger the groups.
;   - Prepared statements, kept for as long as the writer is open, through
;     SQLite's own API: PureBasic prepares a statement again on every call.
;     Same #BakaShrot_Storage_SqliteLibrary as PureBasic's (DatabaseID() is
;     its sqlite3 handle). Without #BakaShrot_Storage_ExternalSqlite (see
;     Storage.pbi), PureBasic's own SQLite is linked in, so its functions
;     are used instead (slower, same behaviour).
;   - The next message id of every topic/node id kept in memory, instead of
;     a MAX(message_id) on every push. Read from the database the first time
;     a pair is pushed to (node_heads, which deleting messages leaves as is:
;     ids never go back), raised by the replicated messages, forgotten on a
;     rollback. Only right as long as this writer is the only one writing,
;     which the write mutex ensures within the server.
;   - Checkpoints mostly off the write path: the writer only checkpoints by
;     itself past #BakaShrot_Storage_WalBackstopFrames, a background thread
;     checkpoints every
;     #BakaShrot_Storage_CheckpointInterval ms on its own connection, in
;     PASSIVE rounds that don't block anything, finishing with a short one
;     under the write mutex so the WAL can start over (see
;     BakaShrot_Writer_CheckpointThread()).
;
; Logs a [Storage] line every #BakaShrot_Storage_StatsInterval ms while
; pushes come in: pushes/s, per transaction, write time per push, how busy.
; ============================================================================


; Most pushes in one transaction.
#BakaShrot_Storage_MaxGroupSize = 1000

#BakaShrot_Storage_CheckpointInterval = 1000

; A checkpoint finishes under the write mutex once at most this many WAL
; frames (4 KB pages) are left to copy, see BakaShrot_Writer_CheckpointThread().
#BakaShrot_Storage_CheckpointFinishFrames = 2000
#BakaShrot_Storage_StatsInterval      = 10000

; The writer still checkpoints by itself (like SQLite does by default, at
; 1000) once the WAL reaches this many frames, when the checkpoint thread
; can't keep up: flat out, ~25,000 frames/s per server. Without it the WAL
; grew to 170,000 frames (700 MB) and Windows started throttling the writes,
; up to 5 s for a push.
#BakaShrot_Storage_WalBackstopFrames = 10000

; Once a checkpoint let the WAL start over, its file is truncated to this.
#BakaShrot_Storage_WalSizeLimit = 67108864


#BakaShrot_Storage_RawSqlite = #BakaShrot_Storage_ExternalSqlite

#BakaShrot_Sqlite_Done   = 101
#BakaShrot_Sqlite_Row    = 100
#BakaShrot_Sqlite_Static = 0

CompilerIf #BakaShrot_Storage_RawSqlite
	PrototypeC.l BakaShrot_Sqlite_Prepare16(Db.i, *Sql, Bytes.l, *Statement, *Tail)
	PrototypeC.l BakaShrot_Sqlite_BindInt64(Statement.i, Index.l, Value.q)
	PrototypeC.l BakaShrot_Sqlite_BindText16(Statement.i, Index.l, *Text, Bytes.l, Destructor.i)
	PrototypeC.l BakaShrot_Sqlite_Step(Statement.i)
	PrototypeC.l BakaShrot_Sqlite_Reset(Statement.i)
	PrototypeC.l BakaShrot_Sqlite_Finalize(Statement.i)
	PrototypeC.q BakaShrot_Sqlite_ColumnInt64(Statement.i, Column.l)
	PrototypeC.l BakaShrot_Sqlite_Changes(Db.i)
	PrototypeC.i BakaShrot_Sqlite_ErrMsg16(Db.i)
	PrototypeC.i BakaShrot_Sqlite_DbFilename(Db.i, *Name)

	Structure BakaShrot_SqliteApi
		Library.i
		Prepare16.BakaShrot_Sqlite_Prepare16
		BindInt64.BakaShrot_Sqlite_BindInt64
		BindText16.BakaShrot_Sqlite_BindText16
		Step_.BakaShrot_Sqlite_Step
		Reset.BakaShrot_Sqlite_Reset
		Finalize.BakaShrot_Sqlite_Finalize
		ColumnInt64.BakaShrot_Sqlite_ColumnInt64
		Changes.BakaShrot_Sqlite_Changes
		ErrMsg16.BakaShrot_Sqlite_ErrMsg16
		DbFilename.BakaShrot_Sqlite_DbFilename
	EndStructure

	Global BakaShrot_Sqlite.BakaShrot_SqliteApi
CompilerEndIf


; A queued push, on the stack of the thread that pushed it, which waits for
; it on the write mutex.
Structure BakaShrot_PushJob
	TopicId.i
	NodeId.i
	JsonData.s
	; When it arrived, ms since 1970 UTC.
	PushedAt.q
	; Its attachment, a complete upload (blobs), 0 for none.
	BlobId.q

	; Filled in by whoever writes it, under the write mutex.
	MessageId.q
	Error.s
	Done.i
EndStructure

Structure BakaShrot_StorageStats
	LastLog.i
	Groups.q
	Pushes.q
	Ticks.q
EndStructure

Structure BakaShrot_StorageWriter
	DatabasePath.s

	; PureBasic database, and its sqlite3 handle.
	DbId.i
	Handle.i

	; Prepared once (or the SQL, without the raw API).
	Begin.i
	Commit.i
	Rollback.i
	Insert.i
	InsertOrIgnore.i
	MaxId.i
	Delete.i
	RaiseHead.i

	; "TopicId:NodeId" -> the next message id to hand out.
	Map NextIds.q()

	; Set by the last failed statement.
	LastError.s

	CheckpointThread.i
	StopRequested.i
	CheckpointCount.i
	CheckpointTicks.q
	; The part of it holding the write mutex.
	CheckpointLockedTicks.q
	; Frames in the WAL at the last checkpoint, 4 KB each by default.
	WalFrames.i

	Stats.BakaShrot_StorageStats
EndStructure


; Taken around every write. SQLite already allows a single writer, but one
; that finds the database locked sleeps and retries (1, 2, 5, 10... ms):
; queued here instead, each one gets it the moment it's free. Only covers
; this process, the busy timeout still handles any other one.
Global BakaShrot_Storage_WriteMutex.i = CreateMutex()

; Guards BakaShrot_Storage_Queue(), *BakaShrot_PushJob in arrival order.
Global BakaShrot_Storage_QueueMutex.i = CreateMutex()
Global NewList BakaShrot_Storage_Queue.i()

Global BakaShrot_Storage_Writer.BakaShrot_StorageWriter

Global BakaShrot_Storage_TicksPerMs.d = 1

CompilerIf #PB_Compiler_OS = #PB_OS_Windows
	Define BakaShrot_Storage_Frequency.q
	QueryPerformanceFrequency_(@BakaShrot_Storage_Frequency)
	BakaShrot_Storage_TicksPerMs = BakaShrot_Storage_Frequency / 1000.0
CompilerEndIf


Procedure.q BakaShrot_Storage_Ticks()
	CompilerIf #PB_Compiler_OS = #PB_OS_Windows
		Protected Ticks.q
		QueryPerformanceCounter_(@Ticks)
		ProcedureReturn Ticks
	CompilerElse
		ProcedureReturn ElapsedMilliseconds()
	CompilerEndIf
EndProcedure


; --- Statements --------------------------------------------------------------
; Everything below the "Statements" line runs holding the write mutex.

Procedure.s BakaShrot_Writer_Error()
	CompilerIf #BakaShrot_Storage_RawSqlite
		If BakaShrot_Storage_Writer\Handle
			ProcedureReturn PeekS(BakaShrot_Sqlite\ErrMsg16(BakaShrot_Storage_Writer\Handle), -1, #PB_Unicode)
		EndIf
	CompilerEndIf
	ProcedureReturn DatabaseError()
EndProcedure


CompilerIf Not #BakaShrot_Storage_RawSqlite
	Procedure.i BakaShrot_Writer_AllocateString(Text.s)
		Protected *Buffer = AllocateMemory(StringByteLength(Text) + 2)
		If *Buffer
			PokeS(*Buffer, Text)
		EndIf
		ProcedureReturn *Buffer
	EndProcedure
CompilerEndIf

; Returns the prepared statement (the SQL itself without the raw API), or 0.
Procedure.i BakaShrot_Writer_Prepare(Sql.s)
	CompilerIf #BakaShrot_Storage_RawSqlite
		Protected Statement.i
		If BakaShrot_Sqlite\Prepare16(BakaShrot_Storage_Writer\Handle, @Sql, -1, @Statement, 0) <> 0
			BakaShrot_Storage_Writer\LastError = BakaShrot_Writer_Error()
			ProcedureReturn 0
		EndIf
		ProcedureReturn Statement
	CompilerElse
		ProcedureReturn BakaShrot_Writer_AllocateString(Sql)
	CompilerEndIf
EndProcedure

Procedure BakaShrot_Writer_Finalize(*Statement.Integer)
	If *Statement\i
		CompilerIf #BakaShrot_Storage_RawSqlite
			BakaShrot_Sqlite\Finalize(*Statement\i)
		CompilerElse
			FreeMemory(*Statement\i)
		CompilerEndIf
		*Statement\i = 0
	EndIf
EndProcedure

; Runs a statement without parameters (BEGIN, COMMIT, ROLLBACK).
Procedure.i BakaShrot_Writer_Run(Statement.i)
	CompilerIf #BakaShrot_Storage_RawSqlite
		Protected Result.l = BakaShrot_Sqlite\Step_(Statement)
		If Result <> #BakaShrot_Sqlite_Done And Result <> #BakaShrot_Sqlite_Row
			BakaShrot_Storage_Writer\LastError = BakaShrot_Writer_Error()
			BakaShrot_Sqlite\Reset(Statement)
			ProcedureReturn #False
		EndIf
		BakaShrot_Sqlite\Reset(Statement)
		ProcedureReturn #True
	CompilerElse
		If Not DatabaseUpdate(BakaShrot_Storage_Writer\DbId, PeekS(Statement))
			BakaShrot_Storage_Writer\LastError = DatabaseError()
			ProcedureReturn #False
		EndIf
		ProcedureReturn #True
	CompilerEndIf
EndProcedure


; Inserts one row with Statement (Insert or InsertOrIgnore).
; Returns 1 if inserted, 0 if ignored, -1 if it failed.
Procedure.i BakaShrot_Writer_InsertRow(Statement.i, TopicId.i, NodeId.i, MessageId.q, JsonData.s, PushedAt.q)
	CompilerIf #BakaShrot_Storage_RawSqlite
		Protected Result.l

		BakaShrot_Sqlite\BindInt64(Statement, 1, TopicId)
		BakaShrot_Sqlite\BindInt64(Statement, 2, NodeId)
		BakaShrot_Sqlite\BindInt64(Statement, 3, MessageId)
		; Static: JsonData outlives the step, the next insert binds it again.
		BakaShrot_Sqlite\BindText16(Statement, 4, @JsonData, -1, #BakaShrot_Sqlite_Static)
		BakaShrot_Sqlite\BindInt64(Statement, 5, PushedAt)
		Result = BakaShrot_Sqlite\Step_(Statement)
		If Result <> #BakaShrot_Sqlite_Done
			BakaShrot_Storage_Writer\LastError = BakaShrot_Writer_Error()
			BakaShrot_Sqlite\Reset(Statement)
			ProcedureReturn -1
		EndIf
		BakaShrot_Sqlite\Reset(Statement)
		ProcedureReturn BakaShrot_Sqlite\Changes(BakaShrot_Storage_Writer\Handle)
	CompilerElse
		Protected DbId.i = BakaShrot_Storage_Writer\DbId
		SetDatabaseLong(DbId, 0, TopicId)
		SetDatabaseLong(DbId, 1, NodeId)
		SetDatabaseQuad(DbId, 2, MessageId)
		SetDatabaseString(DbId, 3, JsonData)
		SetDatabaseQuad(DbId, 4, PushedAt)
		If Not DatabaseUpdate(DbId, PeekS(Statement))
			BakaShrot_Storage_Writer\LastError = DatabaseError()
			ProcedureReturn -1
		EndIf
		ProcedureReturn AffectedDatabaseRows(DbId)
	CompilerEndIf
EndProcedure


; The highest message id ever stored for a topic/node id, 0 if none, -1 on
; failure. Still there once deleted: node_heads keeps it.
Procedure.q BakaShrot_Writer_ReadMaxId(TopicId.i, NodeId.i)
	Protected MaxId.q = -1

	CompilerIf #BakaShrot_Storage_RawSqlite
		Protected Statement.i = BakaShrot_Storage_Writer\MaxId
		BakaShrot_Sqlite\BindInt64(Statement, 1, TopicId)
		BakaShrot_Sqlite\BindInt64(Statement, 2, NodeId)
		If BakaShrot_Sqlite\Step_(Statement) = #BakaShrot_Sqlite_Row
			MaxId = BakaShrot_Sqlite\ColumnInt64(Statement, 0)
		Else
			BakaShrot_Storage_Writer\LastError = BakaShrot_Writer_Error()
		EndIf
		BakaShrot_Sqlite\Reset(Statement)
	CompilerElse
		Protected DbId.i = BakaShrot_Storage_Writer\DbId
		SetDatabaseLong(DbId, 0, TopicId)
		SetDatabaseLong(DbId, 1, NodeId)
		If DatabaseQuery(DbId, PeekS(BakaShrot_Storage_Writer\MaxId))
			If NextDatabaseRow(DbId)
				MaxId = GetDatabaseQuad(DbId, 0)
			EndIf
			FinishDatabaseQuery(DbId)
		Else
			BakaShrot_Storage_Writer\LastError = DatabaseError()
		EndIf
	CompilerEndIf

	ProcedureReturn MaxId
EndProcedure


; Raises a topic/node id's head (node_heads) to MessageId, if it's lower,
; like inserting that message would. Returns #False if it failed.
Procedure.i BakaShrot_Writer_RaiseHead(TopicId.i, NodeId.i, MessageId.q)
	CompilerIf #BakaShrot_Storage_RawSqlite
		Protected Statement.i = BakaShrot_Storage_Writer\RaiseHead
		BakaShrot_Sqlite\BindInt64(Statement, 1, TopicId)
		BakaShrot_Sqlite\BindInt64(Statement, 2, NodeId)
		BakaShrot_Sqlite\BindInt64(Statement, 3, MessageId)
		If BakaShrot_Sqlite\Step_(Statement) <> #BakaShrot_Sqlite_Done
			BakaShrot_Storage_Writer\LastError = BakaShrot_Writer_Error()
			BakaShrot_Sqlite\Reset(Statement)
			ProcedureReturn #False
		EndIf
		BakaShrot_Sqlite\Reset(Statement)
		ProcedureReturn #True
	CompilerElse
		Protected DbId.i = BakaShrot_Storage_Writer\DbId
		SetDatabaseLong(DbId, 0, TopicId)
		SetDatabaseLong(DbId, 1, NodeId)
		SetDatabaseQuad(DbId, 2, MessageId)
		If Not DatabaseUpdate(DbId, PeekS(BakaShrot_Storage_Writer\RaiseHead))
			BakaShrot_Storage_Writer\LastError = DatabaseError()
			ProcedureReturn #False
		EndIf
		ProcedureReturn #True
	CompilerEndIf
EndProcedure


; The next message id to hand out for a topic/node id, -1 on failure.
Procedure.q BakaShrot_Writer_NextId(Key.s, TopicId.i, NodeId.i)
	Protected MaxId.q

	If FindMapElement(BakaShrot_Storage_Writer\NextIds(), Key)
		ProcedureReturn BakaShrot_Storage_Writer\NextIds()
	EndIf

	MaxId = BakaShrot_Writer_ReadMaxId(TopicId, NodeId)
	If MaxId < 0
		ProcedureReturn -1
	EndIf
	BakaShrot_Storage_Writer\NextIds(Key) = MaxId + 1
	ProcedureReturn MaxId + 1
EndProcedure


; --- Opening and closing -----------------------------------------------------

CompilerIf #BakaShrot_Storage_RawSqlite
	Procedure.i BakaShrot_Writer_LoadSqlite()
		With BakaShrot_Sqlite
			If \Library
				ProcedureReturn #True
			EndIf
			; The one PureBasic's SQLite driver already loaded.
			\Library = OpenLibrary(#PB_Any, #BakaShrot_Storage_SqliteLibrary)
			If Not \Library
				ProcedureReturn #False
			EndIf
			\Prepare16   = GetFunction(\Library, "sqlite3_prepare16_v2")
			\BindInt64   = GetFunction(\Library, "sqlite3_bind_int64")
			\BindText16  = GetFunction(\Library, "sqlite3_bind_text16")
			\Step_       = GetFunction(\Library, "sqlite3_step")
			\Reset       = GetFunction(\Library, "sqlite3_reset")
			\Finalize    = GetFunction(\Library, "sqlite3_finalize")
			\ColumnInt64 = GetFunction(\Library, "sqlite3_column_int64")
			\Changes     = GetFunction(\Library, "sqlite3_changes")
			\ErrMsg16    = GetFunction(\Library, "sqlite3_errmsg16")
			\DbFilename  = GetFunction(\Library, "sqlite3_db_filename")
			If Not \Prepare16 Or Not \BindInt64 Or Not \BindText16 Or Not \Step_ Or Not \Reset Or Not \Finalize Or Not \ColumnInt64 Or Not \Changes Or Not \ErrMsg16 Or Not \DbFilename
				CloseLibrary(\Library)
				\Library = 0
				ProcedureReturn #False
			EndIf
		EndWith
		ProcedureReturn #True
	EndProcedure
CompilerEndIf


; One PASSIVE checkpoint: copies what it can of the WAL into the database,
; without waiting for the writer nor the readers. Fills *Frames\i with how
; many frames the WAL has, *Left\i with how many it couldn't copy yet.
Procedure BakaShrot_Writer_CheckpointOnce(DbId.i, *Frames.Integer, *Left.Integer)
	*Frames\i = 0
	*Left\i   = 0
	; It only runs on the first NextDatabaseRow(). Its row: busy, frames in
	; the WAL, frames checkpointed.
	If DatabaseQuery(DbId, "PRAGMA wal_checkpoint(PASSIVE)")
		If NextDatabaseRow(DbId)
			*Frames\i = GetDatabaseLong(DbId, 1)
			*Left\i   = *Frames\i - GetDatabaseLong(DbId, 2)
		EndIf
		FinishDatabaseQuery(DbId)
	EndIf
EndProcedure


; Every #BakaShrot_Storage_CheckpointInterval ms, copies the WAL into the
; database in PASSIVE rounds, without the write mutex: they copy far faster
; than the pushes write, so each round leaves less behind. Once few enough
; frames are left, finishes under the write mutex, which takes a few ms: a
; checkpoint that's complete when the next transaction starts is what makes
; SQLite start the WAL over, otherwise it grows forever under steady writes.
; A long read can keep it from completing, it's tried again next time.
Procedure BakaShrot_Writer_CheckpointThread(Unused.i)
	Protected DbId.i, LastCheckpoint.i, StartTicks.q, LockedTicks.q, Round.i
	Protected Frames.Integer, Left.Integer

	DbId = OpenStorageDatabase(BakaShrot_Storage_Writer\DatabasePath)
	If Not DbId
		PrintN("[Storage] Can't open the database for the checkpoints, the WAL file will keep growing: " + DatabaseError())
		ProcedureReturn
	EndIf

	LastCheckpoint = ElapsedMilliseconds()
	While Not BakaShrot_Storage_Writer\StopRequested
		Delay(50)
		If ElapsedMilliseconds() - LastCheckpoint < #BakaShrot_Storage_CheckpointInterval
			Continue
		EndIf

		StartTicks = BakaShrot_Storage_Ticks()
		Round = 0
		Repeat
			BakaShrot_Writer_CheckpointOnce(DbId, @Frames, @Left)
			Round + 1
		Until Left\i <= #BakaShrot_Storage_CheckpointFinishFrames Or Round >= 4 Or BakaShrot_Storage_Writer\StopRequested

		If Frames\i > 0 And Left\i <= #BakaShrot_Storage_CheckpointFinishFrames
			LockMutex(BakaShrot_Storage_WriteMutex)
			LockedTicks = BakaShrot_Storage_Ticks()
			BakaShrot_Writer_CheckpointOnce(DbId, @Frames, @Left)
			BakaShrot_Storage_Writer\CheckpointLockedTicks + BakaShrot_Storage_Ticks() - LockedTicks
			UnlockMutex(BakaShrot_Storage_WriteMutex)
		EndIf

		BakaShrot_Storage_Writer\WalFrames = Frames\i
		BakaShrot_Storage_Writer\CheckpointTicks + BakaShrot_Storage_Ticks() - StartTicks
		BakaShrot_Storage_Writer\CheckpointCount + 1
		LastCheckpoint = ElapsedMilliseconds()
	Wend

	CloseDatabase(DbId)
EndProcedure


; Holding the write mutex.
Procedure BakaShrot_Writer_Release()
	With BakaShrot_Storage_Writer
		BakaShrot_Writer_Finalize(@\Begin)
		BakaShrot_Writer_Finalize(@\Commit)
		BakaShrot_Writer_Finalize(@\Rollback)
		BakaShrot_Writer_Finalize(@\Insert)
		BakaShrot_Writer_Finalize(@\InsertOrIgnore)
		BakaShrot_Writer_Finalize(@\MaxId)
		BakaShrot_Writer_Finalize(@\Delete)
		BakaShrot_Writer_Finalize(@\RaiseHead)
		If \DbId
			CloseDatabase(\DbId)
		EndIf
		\DbId   = 0
		\Handle = 0
		ClearMap(\NextIds())
	EndWith
EndProcedure


; Opens the writer on DatabasePath, already set up by SetupStorageDatabase(),
; and starts the checkpoints. Returns #False with the reason in *Error\s.
Procedure.i OpenStorageWriter(DatabasePath.s, *Error.String)
	Protected *Main

	LockMutex(BakaShrot_Storage_WriteMutex)
	With BakaShrot_Storage_Writer
		\DatabasePath = DatabasePath
		\DbId = OpenStorageDatabase(DatabasePath)
		If Not \DbId
			*Error\s = "can't open it: " + DatabaseError()
			UnlockMutex(BakaShrot_Storage_WriteMutex)
			ProcedureReturn #False
		EndIf

		; The checkpoint thread does them, see the top of this file. This is
		; only the backstop for when it can't keep up.
		If Not DatabaseUpdate(\DbId, "PRAGMA wal_autocheckpoint = " + Str(#BakaShrot_Storage_WalBackstopFrames)) Or
		   Not DatabaseUpdate(\DbId, "PRAGMA journal_size_limit = " + Str(#BakaShrot_Storage_WalSizeLimit))
			*Error\s = "can't set it up: " + DatabaseError()
			BakaShrot_Writer_Release()
			UnlockMutex(BakaShrot_Storage_WriteMutex)
			ProcedureReturn #False
		EndIf

		CompilerIf #BakaShrot_Storage_RawSqlite
			If Not BakaShrot_Writer_LoadSqlite()
				*Error\s = #BakaShrot_Storage_SqliteLibrary + " doesn't have the functions needed"
				BakaShrot_Writer_Release()
				UnlockMutex(BakaShrot_Storage_WriteMutex)
				ProcedureReturn #False
			EndIf
			\Handle = DatabaseID(\DbId)
			*Main = UTF8("main")
			If Not \Handle Or Not BakaShrot_Sqlite\DbFilename(\Handle, *Main)
				FreeMemory(*Main)
				*Error\s = "DatabaseID() didn't give a sqlite3 handle"
				BakaShrot_Writer_Release()
				UnlockMutex(BakaShrot_Storage_WriteMutex)
				ProcedureReturn #False
			EndIf
			FreeMemory(*Main)
		CompilerEndIf

		\Begin          = BakaShrot_Writer_Prepare("BEGIN IMMEDIATE")
		\Commit         = BakaShrot_Writer_Prepare("COMMIT")
		\Rollback       = BakaShrot_Writer_Prepare("ROLLBACK")
		\Insert         = BakaShrot_Writer_Prepare("INSERT INTO data (topic_id, node_id, message_id, message_data, pushed_at) VALUES (?1, ?2, ?3, ?4, ?5)")
		\InsertOrIgnore = BakaShrot_Writer_Prepare("INSERT OR IGNORE INTO data (topic_id, node_id, message_id, message_data, pushed_at) VALUES (?1, ?2, ?3, ?4, ?5)")
		; node_heads first: it outlives the deleted messages. data too, in
		; case a database was written to by something without the trigger.
		\MaxId          = BakaShrot_Writer_Prepare("SELECT COALESCE(MAX(m), 0) FROM (SELECT max_message_id AS m FROM node_heads WHERE topic_id = ?1 AND node_id = ?2 " +
		                                           "UNION ALL SELECT MAX(message_id) FROM data WHERE topic_id = ?1 AND node_id = ?2)")
		; Some at a time (?3), so pushes get the write mutex in between.
		\Delete         = BakaShrot_Writer_Prepare("DELETE FROM data WHERE rowid IN (SELECT rowid FROM data WHERE topic_id = ?1 AND pushed_at < ?2 LIMIT ?3)")
		; What the trigger does on an insert, for the messages skipped instead.
		\RaiseHead      = BakaShrot_Writer_Prepare("INSERT INTO node_heads (topic_id, node_id, max_message_id) VALUES (?1, ?2, ?3) " +
		                                           "ON CONFLICT (topic_id, node_id) DO UPDATE SET max_message_id = MAX(max_message_id, excluded.max_message_id)")
		If Not \Begin Or Not \Commit Or Not \Rollback Or Not \Insert Or Not \InsertOrIgnore Or Not \MaxId Or Not \Delete Or Not \RaiseHead
			*Error\s = "can't prepare its statements: " + \LastError
			BakaShrot_Writer_Release()
			UnlockMutex(BakaShrot_Storage_WriteMutex)
			ProcedureReturn #False
		EndIf

		\StopRequested    = #False
		\CheckpointThread = CreateThread(@BakaShrot_Writer_CheckpointThread(), 0)
		If Not \CheckpointThread
			*Error\s = "can't start the checkpoint thread"
			BakaShrot_Writer_Release()
			UnlockMutex(BakaShrot_Storage_WriteMutex)
			ProcedureReturn #False
		EndIf
	EndWith
	UnlockMutex(BakaShrot_Storage_WriteMutex)

	ProcedureReturn #True
EndProcedure


; Stops the checkpoints, checkpoints everything (emptying the WAL file) and
; closes the writer. Once nothing writes anymore: the workers are stopped.
Procedure CloseStorageWriter()
	With BakaShrot_Storage_Writer
		If \CheckpointThread
			\StopRequested = #True
			WaitThread(\CheckpointThread)
			\CheckpointThread = 0
		EndIf

		LockMutex(BakaShrot_Storage_WriteMutex)
		If \DbId
			If DatabaseQuery(\DbId, "PRAGMA wal_checkpoint(TRUNCATE)")
				NextDatabaseRow(\DbId)
				FinishDatabaseQuery(\DbId)
			EndIf
		EndIf
		BakaShrot_Writer_Release()
		UnlockMutex(BakaShrot_Storage_WriteMutex)
	EndWith
EndProcedure


; --- Writes ------------------------------------------------------------------

; Holding the write mutex.
Procedure BakaShrot_Writer_LogStats()
	Protected Now.i = ElapsedMilliseconds(), Seconds.d, Checkpoints.s

	With BakaShrot_Storage_Writer\Stats
		If \LastLog = 0
			\LastLog = Now
			ProcedureReturn
		EndIf
		If Now - \LastLog < #BakaShrot_Storage_StatsInterval
			ProcedureReturn
		EndIf

		Seconds = (Now - \LastLog) / 1000.0
		If \Groups > 0
			If BakaShrot_Storage_Writer\CheckpointCount > 0
				Checkpoints = ", " + Str(BakaShrot_Storage_Writer\CheckpointCount) + " checkpoints of " +
				              StrD(BakaShrot_Storage_Writer\CheckpointTicks / BakaShrot_Storage_TicksPerMs / BakaShrot_Storage_Writer\CheckpointCount, 1) + " ms (" +
				              StrD(BakaShrot_Storage_Writer\CheckpointLockedTicks / BakaShrot_Storage_TicksPerMs / BakaShrot_Storage_Writer\CheckpointCount, 1) + " ms of it holding the writes), " +
				              Str(BakaShrot_Storage_Writer\WalFrames) + " frames in the WAL"
			EndIf
			PrintN("[Storage] " + Str(\Pushes) + " pushes in " + StrD(Seconds, 1) + " s (" + StrD(\Pushes / Seconds, 0) + "/s), " +
			       Str(\Groups) + " transactions of " + StrD(\Pushes / \Groups, 1) + " on average, " +
			       StrD(\Ticks / BakaShrot_Storage_TicksPerMs / \Groups, 3) + " ms each, " +
			       StrD(\Ticks / BakaShrot_Storage_TicksPerMs / \Pushes, 3) + " ms per push, writing " +
			       StrD(100.0 * \Ticks / BakaShrot_Storage_TicksPerMs / (Seconds * 1000.0), 0) + " % of the time" + Checkpoints)
		EndIf
		\LastLog = Now
		\Groups  = 0
		\Pushes  = 0
		\Ticks   = 0
		BakaShrot_Storage_Writer\CheckpointCount       = 0
		BakaShrot_Storage_Writer\CheckpointTicks       = 0
		BakaShrot_Storage_Writer\CheckpointLockedTicks = 0
	EndWith
EndProcedure


; Claims a complete upload (blobs state 1) of TopicId/NodeId for a message:
; state 2. Returns #False if it isn't one, someone else's, or attached already.
Procedure.i BakaShrot_Writer_ClaimBlob(BlobId.q, TopicId.i, NodeId.i)
	Protected DbId.i = BakaShrot_Storage_Writer\DbId
	SetDatabaseQuad(DbId, 0, BlobId)
	SetDatabaseLong(DbId, 1, TopicId)
	SetDatabaseLong(DbId, 2, NodeId)
	If Not DatabaseUpdate(DbId, "UPDATE blobs SET state = 2 WHERE blob_id = ? AND topic_id = ? AND node_id = ? AND state = 1")
		BakaShrot_Storage_Writer\LastError = DatabaseError()
		ProcedureReturn #False
	EndIf
	If AffectedDatabaseRows(DbId) <> 1
		BakaShrot_Storage_Writer\LastError = "the upload isn't complete, or isn't this client's for that topic"
		ProcedureReturn #False
	EndIf
	ProcedureReturn #True
EndProcedure

; Gives a claimed upload back (state 1), its message couldn't be stored.
Procedure BakaShrot_Writer_UnclaimBlob(BlobId.q)
	Protected DbId.i = BakaShrot_Storage_Writer\DbId
	SetDatabaseQuad(DbId, 0, BlobId)
	DatabaseUpdate(DbId, "UPDATE blobs SET state = 1 WHERE blob_id = ?")
EndProcedure

; The attachments row of a pushed message, from its claimed upload.
Procedure.i BakaShrot_Writer_LinkBlob(TopicId.i, NodeId.i, MessageId.q, BlobId.q)
	Protected DbId.i = BakaShrot_Storage_Writer\DbId
	SetDatabaseLong(DbId, 0, TopicId)
	SetDatabaseLong(DbId, 1, NodeId)
	SetDatabaseQuad(DbId, 2, MessageId)
	SetDatabaseQuad(DbId, 3, BlobId)
	If Not DatabaseUpdate(DbId, "INSERT INTO attachments (topic_id, node_id, message_id, size, sha256, blob_id, state) " +
	                            "SELECT ?, ?, ?, size, sha256, blob_id, 2 FROM blobs WHERE blob_id = ?") Or AffectedDatabaseRows(DbId) <> 1
		BakaShrot_Storage_Writer\LastError = "can't attach the upload: " + DatabaseError()
		ProcedureReturn #False
	EndIf
	ProcedureReturn #True
EndProcedure

; Deletes a message just inserted in this transaction, its attachment failed.
Procedure BakaShrot_Writer_DropMessage(TopicId.i, NodeId.i, MessageId.q)
	Protected DbId.i = BakaShrot_Storage_Writer\DbId
	SetDatabaseLong(DbId, 0, TopicId)
	SetDatabaseLong(DbId, 1, NodeId)
	SetDatabaseQuad(DbId, 2, MessageId)
	DatabaseUpdate(DbId, "DELETE FROM data WHERE topic_id = ? AND node_id = ? AND message_id = ?")
EndProcedure

; The attachments row of a replicated message: its data comes later
; (Attachments.pbi), state 0 (missing), or 3 (not kept here) past MaxSize.
Procedure.i BakaShrot_Writer_AddReplicatedAttachment(TopicId.i, NodeId.i, *Message.BakaShrot_ReplicatedMessage, MaxSize.q)
	Protected DbId.i = BakaShrot_Storage_Writer\DbId
	SetDatabaseLong(DbId, 0, TopicId)
	SetDatabaseLong(DbId, 1, NodeId)
	SetDatabaseQuad(DbId, 2, *Message\MessageId)
	SetDatabaseQuad(DbId, 3, *Message\AttachmentSize)
	SetDatabaseBlob(DbId, 4, @*Message\AttachmentSha256[0], #BakaShrot_Sha256Size)
	If *Message\AttachmentSize > MaxSize
		SetDatabaseLong(DbId, 5, 3)
	Else
		SetDatabaseLong(DbId, 5, 0)
	EndIf
	If Not DatabaseUpdate(DbId, "INSERT OR IGNORE INTO attachments (topic_id, node_id, message_id, size, sha256, blob_id, state) VALUES (?, ?, ?, ?, ?, NULL, ?)")
		BakaShrot_Storage_Writer\LastError = DatabaseError()
		ProcedureReturn #False
	EndIf
	ProcedureReturn #True
EndProcedure


; Writes queued pushes in one transaction, filling in their MessageId (-1 and
; Error if that one failed) and setting Done. Holding the write mutex.
Procedure BakaShrot_Writer_WriteJobs(List Jobs.i())
	Protected *Job.BakaShrot_PushJob, InTransaction.i, Key.s, MessageId.q, JsonData.s

	; If it can't start (another process writing past the busy timeout),
	; every insert still runs, each in its own transaction.
	InTransaction = BakaShrot_Writer_Run(BakaShrot_Storage_Writer\Begin)

	; One failed insert is only that statement's, SQLite keeps the others.
	ForEach Jobs()
		*Job = Jobs()
		Key = Str(*Job\TopicId) + ":" + Str(*Job\NodeId)
		MessageId = BakaShrot_Writer_NextId(Key, *Job\TopicId, *Job\NodeId)
		JsonData  = *Job\JsonData
		*Job\MessageId = -1

		; Its upload first: nothing is stored if it can't be claimed.
		If MessageId > 0 And *Job\BlobId And Not BakaShrot_Writer_ClaimBlob(*Job\BlobId, *Job\TopicId, *Job\NodeId)
			MessageId = -1
		EndIf

		If MessageId > 0 And BakaShrot_Writer_InsertRow(BakaShrot_Storage_Writer\Insert, *Job\TopicId, *Job\NodeId, MessageId, JsonData, *Job\PushedAt) = 1
			If *Job\BlobId And Not BakaShrot_Writer_LinkBlob(*Job\TopicId, *Job\NodeId, MessageId, *Job\BlobId)
				BakaShrot_Writer_DropMessage(*Job\TopicId, *Job\NodeId, MessageId)
				BakaShrot_Writer_UnclaimBlob(*Job\BlobId)
			Else
				*Job\MessageId = MessageId
			EndIf
			; Taken either way: node_heads went up.
			BakaShrot_Storage_Writer\NextIds(Key) = MessageId + 1
		ElseIf MessageId > 0 And *Job\BlobId
			BakaShrot_Writer_UnclaimBlob(*Job\BlobId)
		EndIf

		If *Job\MessageId < 1
			*Job\Error = BakaShrot_Storage_Writer\LastError
		EndIf
	Next

	If InTransaction And Not BakaShrot_Writer_Run(BakaShrot_Storage_Writer\Commit)
		ForEach Jobs()
			*Job = Jobs()
			*Job\MessageId = -1
			*Job\Error     = BakaShrot_Storage_Writer\LastError
		Next
		BakaShrot_Writer_Run(BakaShrot_Storage_Writer\Rollback)
		; Some ids were handed out and rolled back.
		ClearMap(BakaShrot_Storage_Writer\NextIds())
	EndIf

	ForEach Jobs()
		*Job = Jobs()
		*Job\Done = #True
	Next
EndProcedure


; Inserts one JSON message for a topic_id/node_id pair, with the next
; message_id for that pair, starting at 1, grouped with the other pushes
; arriving meanwhile. Stamped with the time it got here (pushed_at).
; BlobId: its attachment, a complete upload of this topic and node
; (Attachments.pbi), 0 for none: attached in the same transaction.
; Returns the new message's id once committed, or -1 with
; the reason in *Error\s.
Procedure.q InsertNextMessage(TopicId.i, NodeId.i, JsonData.s, *Error.String, BlobId.q = 0)
	Protected Job.BakaShrot_PushJob
	Protected NewList Jobs.i()
	Protected StartTicks.q

	Job\TopicId   = TopicId
	Job\NodeId    = NodeId
	Job\JsonData  = JsonData
	Job\PushedAt  = BakaShrot_NowUtcMs()
	Job\BlobId    = BlobId
	Job\MessageId = -1

	LockMutex(BakaShrot_Storage_QueueMutex)
	AddElement(BakaShrot_Storage_Queue())
	BakaShrot_Storage_Queue() = @Job
	UnlockMutex(BakaShrot_Storage_QueueMutex)

	; Whoever gets the mutex writes everything queued so far, this one's
	; included unless an earlier holder already did. The queue is first in,
	; first out, so a capped group still gets to it eventually.
	LockMutex(BakaShrot_Storage_WriteMutex)
	If Not BakaShrot_Storage_Writer\DbId
		; Closed: the workers are stopping.
		LockMutex(BakaShrot_Storage_QueueMutex)
		ForEach BakaShrot_Storage_Queue()
			If BakaShrot_Storage_Queue() = @Job
				DeleteElement(BakaShrot_Storage_Queue())
				Break
			EndIf
		Next
		UnlockMutex(BakaShrot_Storage_QueueMutex)
		UnlockMutex(BakaShrot_Storage_WriteMutex)
		*Error\s = "the storage writer isn't open"
		ProcedureReturn -1
	EndIf

	While Not Job\Done
		ClearList(Jobs())
		LockMutex(BakaShrot_Storage_QueueMutex)
		ForEach BakaShrot_Storage_Queue()
			If ListSize(Jobs()) >= #BakaShrot_Storage_MaxGroupSize
				Break
			EndIf
			AddElement(Jobs())
			Jobs() = BakaShrot_Storage_Queue()
			DeleteElement(BakaShrot_Storage_Queue())
		Next
		UnlockMutex(BakaShrot_Storage_QueueMutex)

		StartTicks = BakaShrot_Storage_Ticks()
		BakaShrot_Writer_WriteJobs(Jobs())
		With BakaShrot_Storage_Writer\Stats
			\Ticks  + BakaShrot_Storage_Ticks() - StartTicks
			\Groups + 1
			\Pushes + ListSize(Jobs())
		EndWith
	Wend
	BakaShrot_Writer_LogStats()
	UnlockMutex(BakaShrot_Storage_WriteMutex)

	If Job\MessageId < 1
		*Error\s = Job\Error
	EndIf
	ProcedureReturn Job\MessageId
EndProcedure


; Stores a batch of messages replicated from a peer, all of one topic/node
; id, under the ids and pushed_at they have on their origin, in a single transaction:
; either all of them are stored, or none. An id that's already stored is kept
; as is, the new one is dropped, even if it differs (Design/ReplicationIssues.md).
; Messages pushed before SkipBeforeMs (ms since 1970 UTC, 0 for none) are
; past this server's max age for the topic already: not stored, but the
; pair's head still goes up to them, so the peer doesn't send them again.
; *Skipped\i, if given, gets how many.
; A message's attachment gets its row, its data comes later (Attachments.pbi),
; unless it's bigger than MaxAttachmentSize: not kept here then.
; Returns #False with the reason in *Error\s, the transaction is rolled back.
Procedure.i InsertReplicatedMessages(TopicId.i, NodeId.i, List Messages.BakaShrot_ReplicatedMessage(), *Error.String, SkipBeforeMs.q = 0, *Skipped.Integer = 0, MaxAttachmentSize.q = #BakaShrot_MaxAttachmentSize)
	Protected Stored.i, Inserted.i, Key.s, JsonData.s, Skipped.i, LastMessageId.q

	Key = Str(TopicId) + ":" + Str(NodeId)

	LockMutex(BakaShrot_Storage_WriteMutex)
	If Not BakaShrot_Storage_Writer\DbId
		UnlockMutex(BakaShrot_Storage_WriteMutex)
		*Error\s = "the storage writer isn't open"
		ProcedureReturn #False
	EndIf

	; IMMEDIATE takes the write lock up front, instead of failing midway if
	; another process started writing first.
	Stored = BakaShrot_Writer_Run(BakaShrot_Storage_Writer\Begin)
	If Stored
		ForEach Messages()
			LastMessageId = Messages()\MessageId
			If SkipBeforeMs > 0 And Messages()\PushedAt < SkipBeforeMs
				Skipped + 1
				Continue
			EndIf
			JsonData = Messages()\JsonData
			Inserted = BakaShrot_Writer_InsertRow(BakaShrot_Storage_Writer\InsertOrIgnore, TopicId, NodeId, Messages()\MessageId, JsonData, Messages()\PushedAt)
			If Inserted < 0
				Stored = #False
				Break
			EndIf
			If Inserted = 1 And Messages()\AttachmentSize > 0 And Not BakaShrot_Writer_AddReplicatedAttachment(TopicId, NodeId, @Messages(), MaxAttachmentSize)
				Stored = #False
				Break
			EndIf
			; A pair pushed to here too (drift): the next push goes after it.
			If Inserted = 1 And FindMapElement(BakaShrot_Storage_Writer\NextIds(), Key)
				If Messages()\MessageId + 1 > BakaShrot_Storage_Writer\NextIds()
					BakaShrot_Storage_Writer\NextIds() = Messages()\MessageId + 1
				EndIf
			EndIf
		Next

		; The skipped ones count as received: the head covers the whole batch,
		; and the next push goes after it.
		If Stored And Skipped > 0
			If BakaShrot_Writer_RaiseHead(TopicId, NodeId, LastMessageId)
				If FindMapElement(BakaShrot_Storage_Writer\NextIds(), Key)
					If LastMessageId + 1 > BakaShrot_Storage_Writer\NextIds()
						BakaShrot_Storage_Writer\NextIds() = LastMessageId + 1
					EndIf
				EndIf
			Else
				Stored = #False
			EndIf
		EndIf

		If Stored And Not BakaShrot_Writer_Run(BakaShrot_Storage_Writer\Commit)
			Stored = #False
		EndIf
		If Not Stored
			*Error\s = BakaShrot_Storage_Writer\LastError
			BakaShrot_Writer_Run(BakaShrot_Storage_Writer\Rollback)
			ClearMap(BakaShrot_Storage_Writer\NextIds())
		EndIf
	Else
		*Error\s = BakaShrot_Storage_Writer\LastError
	EndIf

	UnlockMutex(BakaShrot_Storage_WriteMutex)
	If *Skipped
		*Skipped\i = Skipped
	EndIf
	ProcedureReturn Stored
EndProcedure


; Deletes up to Limit messages of TopicId pushed before BeforeMs (ms since
; 1970 UTC), in one statement under the write mutex: call it again while it
; deletes Limit, pushes get their turn in between. node_heads is left as is
; (see SetupStorageDatabase()).
; Returns how many were deleted, -1 with the reason in *Error\s.
Procedure.i DeleteStorageMessagesBefore(TopicId.i, BeforeMs.q, Limit.i, *Error.String)
	Protected Deleted.i = -1

	LockMutex(BakaShrot_Storage_WriteMutex)
	If Not BakaShrot_Storage_Writer\DbId
		UnlockMutex(BakaShrot_Storage_WriteMutex)
		*Error\s = "the storage writer isn't open"
		ProcedureReturn -1
	EndIf

	CompilerIf #BakaShrot_Storage_RawSqlite
		Protected Statement.i = BakaShrot_Storage_Writer\Delete
		BakaShrot_Sqlite\BindInt64(Statement, 1, TopicId)
		BakaShrot_Sqlite\BindInt64(Statement, 2, BeforeMs)
		BakaShrot_Sqlite\BindInt64(Statement, 3, Limit)
		If BakaShrot_Sqlite\Step_(Statement) = #BakaShrot_Sqlite_Done
			Deleted = BakaShrot_Sqlite\Changes(BakaShrot_Storage_Writer\Handle)
		Else
			*Error\s = BakaShrot_Writer_Error()
		EndIf
		BakaShrot_Sqlite\Reset(Statement)
	CompilerElse
		Protected DbId.i = BakaShrot_Storage_Writer\DbId
		SetDatabaseLong(DbId, 0, TopicId)
		SetDatabaseQuad(DbId, 1, BeforeMs)
		SetDatabaseLong(DbId, 2, Limit)
		If DatabaseUpdate(DbId, PeekS(BakaShrot_Storage_Writer\Delete))
			Deleted = AffectedDatabaseRows(DbId)
		Else
			*Error\s = DatabaseError()
		EndIf
	CompilerEndIf

	UnlockMutex(BakaShrot_Storage_WriteMutex)
	ProcedureReturn Deleted
EndProcedure


; Adds a row to the "topics" or "nodes" table (Table), for Id, named Name
; (its id in digits if it has none), Origin "peer" or "id", see
; Server/Storage/Names.pbi. A row already there for that id is kept.
; Returns #False with the reason in *Error\s.
Procedure.i RegisterStorageName(Table.s, Id.i, Name.s, Origin.s, *Error.String)
	Protected DbId.i, Stored.i

	LockMutex(BakaShrot_Storage_WriteMutex)
	DbId = BakaShrot_Storage_Writer\DbId
	If Not DbId
		UnlockMutex(BakaShrot_Storage_WriteMutex)
		*Error\s = "the storage writer isn't open"
		ProcedureReturn #False
	EndIf

	SetDatabaseLong(DbId, 0, Id)
	SetDatabaseString(DbId, 1, Name)
	SetDatabaseString(DbId, 2, Origin)
	Stored = DatabaseUpdate(DbId, "INSERT OR IGNORE INTO " + Table + " VALUES (?, ?, ?)")
	If Not Stored
		*Error\s = DatabaseError()
	EndIf

	UnlockMutex(BakaShrot_Storage_WriteMutex)
	ProcedureReturn Stored
EndProcedure
