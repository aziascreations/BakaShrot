; ============================================================================
; BakaShrot Storage Retention
;
; Deletes the messages past their topic's max age, so a server's database
; stops growing: [BakaShrot.Retention] in its config, see
; BakaShrot_RetentionRule in Server/Config/Config.pbi.
;
; A thread, started with the workers (StartStorageRetention(), see
; Server/Root.pbi), runs a pass right away then every [BakaShrot.Server]
; RetentionInterval seconds:
;   - every topic of the database (node_heads), with its name (topics);
;   - its max age from the rules; kept forever (0) is skipped;
;   - deletes its messages pushed (pushed_at) before now minus that age,
;     #BakaShrot_Retention_BatchSize at a time through the writer
;     (DeleteStorageMessagesBefore(), Writer.pbi), so pushes go on between
;     the batches.
;
; Messages "may be" deleted past their max age: up to RetentionInterval
; later. Those a peer replicates here already past it aren't stored at all
; (InsertReplicatedMessages() in Writer.pbi), only counted as received. pushed_at is the time the message was pushed to its origin, kept as
; is by replication, so a server deletes a replicated message by when it
; was first pushed, not when it got it.
;
; What deleting doesn't change:
;   - node_heads: a pair's head stays its highest id ever. The next push
;     still gets the next id, and the sync state still tells peers this
;     server had those messages: they aren't sent again.
;   - The file's size: SQLite reuses the freed pages for new messages, so
;     it stops growing once deletions keep up with pushes. VACUUM (the
;     "vacuum" console command) gives the space back to the disk.
; ============================================================================

; Most messages deleted in one statement, under the write mutex: a few ms.
#BakaShrot_Retention_BatchSize = 5000


Structure BakaShrot_RetentionTopic
	TopicId.i
	Name.s
EndStructure

Structure BakaShrot_RetentionState
	ThreadId.i
	StopRequested.i
	IntervalMs.i
	DatabasePath.s
	List Rules.BakaShrot_RetentionRule()
EndStructure

Global BakaShrot_Retention.BakaShrot_RetentionState


; Ms (since 1970 UTC) as "2026-11-08T14:03:59Z", for the logs.
Procedure.s BakaShrot_Retention_FormatUtc(Ms.q)
	ProcedureReturn FormatDate("%yyyy-%mm-%ddT%hh:%ii:%ssZ", Ms / 1000)
EndProcedure


; Deletes what's past its max age in every topic. DbId is the thread's own
; connection, only read from (the deletes go through the writer).
; Returns how many messages were deleted.
Procedure.q BakaShrot_Retention_Pass(DbId.i)
	Protected NewList Topics.BakaShrot_RetentionTopic()
	Protected MaxAge.q, Before.q, Deleted.i, TopicDeleted.q, Total.q, Error.String

	If Not DatabaseQuery(DbId, "SELECT DISTINCT h.topic_id, COALESCE(t.name, '') FROM node_heads h LEFT JOIN topics t ON t.topic_id = h.topic_id")
		PrintN("[Storage] Retention: can't list the topics: " + DatabaseError())
		ProcedureReturn 0
	EndIf
	While NextDatabaseRow(DbId)
		AddElement(Topics())
		Topics()\TopicId = GetDatabaseLong(DbId, 0)
		Topics()\Name    = GetDatabaseString(DbId, 1)
	Wend
	FinishDatabaseQuery(DbId)

	ForEach Topics()
		MaxAge = RetentionMaxAgeMs(BakaShrot_Retention\Rules(), Topics()\TopicId, Topics()\Name)
		If MaxAge <= 0
			Continue
		EndIf

		Before = BakaShrot_NowUtcMs() - MaxAge
		TopicDeleted = 0
		Repeat
			Deleted = DeleteStorageMessagesBefore(Topics()\TopicId, Before, #BakaShrot_Retention_BatchSize, @Error)
			If Deleted < 0
				PrintN("[Storage] Retention: failed to delete from topic " + Str(Topics()\TopicId) + ": " + Error\s)
				Break
			EndIf
			TopicDeleted + Deleted
		Until Deleted < #BakaShrot_Retention_BatchSize Or BakaShrot_Retention\StopRequested

		If TopicDeleted > 0
			If Topics()\Name <> ""
				PrintN("[Storage] Retention: deleted " + Str(TopicDeleted) + " messages of topic '" + Topics()\Name + "' pushed before " + BakaShrot_Retention_FormatUtc(Before))
			Else
				PrintN("[Storage] Retention: deleted " + Str(TopicDeleted) + " messages of topic " + Str(Topics()\TopicId) + " pushed before " + BakaShrot_Retention_FormatUtc(Before))
			EndIf
		EndIf
		Total + TopicDeleted

		If BakaShrot_Retention\StopRequested
			Break
		EndIf
	Next

	ProcedureReturn Total
EndProcedure


Procedure BakaShrot_Retention_Thread(Unused.i)
	Protected DbId.i, LastPass.i

	DbId = OpenStorageDatabase(BakaShrot_Retention\DatabasePath)
	If Not DbId
		PrintN("[Storage] Retention: can't open the database, nothing will be deleted: " + DatabaseError())
		ProcedureReturn
	EndIf

	BakaShrot_Retention_Pass(DbId)
	LastPass = ElapsedMilliseconds()
	While Not BakaShrot_Retention\StopRequested
		Delay(100)
		If ElapsedMilliseconds() - LastPass >= BakaShrot_Retention\IntervalMs
			BakaShrot_Retention_Pass(DbId)
			LastPass = ElapsedMilliseconds()
		EndIf
	Wend

	CloseDatabase(DbId)
EndProcedure


; Starts deleting what's past *Config's [BakaShrot.Retention] max ages, once
; the writer is open. Nothing to do (no thread) if every topic is kept
; forever. Returns #False if the thread can't start.
Procedure.i StartStorageRetention(*Config.BakaShrot_CoreConfig)
	Protected Deletes.i

	With BakaShrot_Retention
		ClearList(\Rules())
		CopyList(*Config\Retention(), \Rules())
		ForEach \Rules()
			If \Rules()\MaxAgeMs > 0
				Deletes = #True
				PrintN("[Storage] Retention: " + \Rules()\Ref + " = " + \Rules()\AgeText + ", checked every " + Str(*Config\Server\RetentionInterval) + " s")
			EndIf
		Next
		If Not Deletes
			ProcedureReturn #True
		EndIf

		\DatabasePath  = *Config\Server\DatabasePath
		\IntervalMs    = *Config\Server\RetentionInterval * 1000
		\StopRequested = #False
		\ThreadId      = CreateThread(@BakaShrot_Retention_Thread(), 0)
		ProcedureReturn Bool(\ThreadId)
	EndWith
EndProcedure


; Stops it, before the writer closes. Waits for a pass under way to end its
; current batch.
Procedure StopStorageRetention()
	With BakaShrot_Retention
		If \ThreadId
			\StopRequested = #True
			WaitThread(\ThreadId)
			\ThreadId = 0
		EndIf
	EndWith
EndProcedure
