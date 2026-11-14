;{- Code Header
; ==- Basic Info -================================
;     Name: Attachments.pbi
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
; BakaShrot Storage Attachments
;
; A message has at most one attachment, of any size up to the server's
; MaxAttachmentSize, stored in parts (Design/Attachments.md):
;   blobs        the data of one attachment, being received or stored
;   blob_chunks  its parts, #BakaShrot_AttachmentChunkSize bytes each, the
;                last one what's left
;   attachments  a message's: its size and SHA-256, and its blob once any
;                of it is here
; See SetupStorageDatabase() in Storage.pbi for the columns and states.
;
; Pushed with a message:
;   CreateStorageBlob()      an upload starts (state 0), owned by the
;                            client's topic and node
;   StoreStorageBlobChunk()  each part, in order
;   HashStorageBlob()        once all of it is here, checked against the
;                            SHA-256 given at the start: complete (1), or
;                            dropped (3)
;   then InsertNextMessage() (Writer.pbi) with its blob id attaches it to
;   the message, in the same transaction (2).
; Replicated: the message comes first (ReplicateMessages), its attachments
; row in state 0, then once the messages are caught up:
;   GetMissingStorageAttachments()  what's missing, or started
;   StartReplicatedAttachment()     the first part makes its blob
;   StoreStorageBlobChunk()         each part, resuming where it stopped
;   FinishReplicatedAttachment()    ready (2), or back to missing if its
;                                   SHA-256 doesn't match
; Deleting a message (the retention) deletes its attachments row (trigger),
; which marks its blob (3); CleanUpStorageBlobs() deletes it a part at a
; time, along with uploads never completed or never attached.
;
; Writes go through the writer (Writer.pbi), under its mutex; reads take
; the caller's own connection.
; ============================================================================

; SHA-256 (BakaShrot_Sha256_*).
XIncludeFile "../../Commons/Cryptography/Libsodium.pbi"


Structure BakaShrot_StorageBlob
	BlobId.q
	TopicId.i
	NodeId.i
	Size.q
	Sha256.a[#BakaShrot_Sha256Size]
	Received.q
	State.i
EndStructure

Structure BakaShrot_StorageAttachment
	Size.q
	Sha256.a[#BakaShrot_Sha256Size]
	; 0 while none of it is here.
	BlobId.q
	; 0 missing, 1 receiving, 2 ready, 3 not kept here.
	State.i
	; Of its blob, 0 without one.
	Received.q
EndStructure

Structure BakaShrot_StorageMissingAttachment
	TopicId.i
	NodeId.i
	Topic.s
	Node.s
	MessageId.q
	Received.q
EndStructure

#BakaShrot_Blob_Receiving = 0
#BakaShrot_Blob_Complete  = 1
#BakaShrot_Blob_Attached  = 2
#BakaShrot_Blob_Deleted   = 3

#BakaShrot_Attachment_Missing   = 0
#BakaShrot_Attachment_Receiving = 1
#BakaShrot_Attachment_Ready     = 2
#BakaShrot_Attachment_NotKept   = 3


; --- Reads, on the caller's connection -----------------------------------------

; Fills *Blob with blob BlobId. Returns #False if there's none.
Procedure.i GetStorageBlob(DbId.i, BlobId.q, *Blob.BakaShrot_StorageBlob)
	Protected Found.i

	SetDatabaseQuad(DbId, 0, BlobId)
	If Not DatabaseQuery(DbId, "SELECT topic_id, node_id, size, sha256, received, state FROM blobs WHERE blob_id = ?")
		ProcedureReturn #False
	EndIf
	Found = NextDatabaseRow(DbId)
	If Found
		*Blob\BlobId   = BlobId
		*Blob\TopicId  = GetDatabaseLong(DbId, 0)
		*Blob\NodeId   = GetDatabaseLong(DbId, 1)
		*Blob\Size     = GetDatabaseQuad(DbId, 2)
		FillMemory(@*Blob\Sha256[0], #BakaShrot_Sha256Size, 0)
		If DatabaseColumnSize(DbId, 3) = #BakaShrot_Sha256Size
			GetDatabaseBlob(DbId, 3, @*Blob\Sha256[0], #BakaShrot_Sha256Size)
		EndIf
		*Blob\Received = GetDatabaseQuad(DbId, 4)
		*Blob\State    = GetDatabaseLong(DbId, 5)
	EndIf
	FinishDatabaseQuery(DbId)
	ProcedureReturn Found
EndProcedure


; Fills *Attachment with the attachment of TopicId:NodeId#MessageId.
; Returns #False if that message has none (or doesn't exist).
Procedure.i GetStorageAttachment(DbId.i, TopicId.i, NodeId.i, MessageId.q, *Attachment.BakaShrot_StorageAttachment)
	Protected Found.i

	SetDatabaseLong(DbId, 0, TopicId)
	SetDatabaseLong(DbId, 1, NodeId)
	SetDatabaseQuad(DbId, 2, MessageId)
	If Not DatabaseQuery(DbId, "SELECT a.size, a.sha256, COALESCE(a.blob_id, 0), a.state, COALESCE(b.received, 0) " +
	                           "FROM attachments a LEFT JOIN blobs b ON b.blob_id = a.blob_id " +
	                           "WHERE a.topic_id = ? AND a.node_id = ? AND a.message_id = ?")
		ProcedureReturn #False
	EndIf
	Found = NextDatabaseRow(DbId)
	If Found
		*Attachment\Size = GetDatabaseQuad(DbId, 0)
		FillMemory(@*Attachment\Sha256[0], #BakaShrot_Sha256Size, 0)
		If DatabaseColumnSize(DbId, 1) = #BakaShrot_Sha256Size
			GetDatabaseBlob(DbId, 1, @*Attachment\Sha256[0], #BakaShrot_Sha256Size)
		EndIf
		*Attachment\BlobId   = GetDatabaseQuad(DbId, 2)
		*Attachment\State    = GetDatabaseLong(DbId, 3)
		*Attachment\Received = GetDatabaseQuad(DbId, 4)
	EndIf
	FinishDatabaseQuery(DbId)
	ProcedureReturn Found
EndProcedure


; Part Index of blob BlobId, in a freshly allocated buffer, its size in
; *OutSize\i. Returns 0 if it isn't stored. The caller frees it.
Procedure.i ReadStorageBlobChunk(DbId.i, BlobId.q, Index.q, *OutSize.Integer)
	Protected *Data, Size.i

	SetDatabaseQuad(DbId, 0, BlobId)
	SetDatabaseQuad(DbId, 1, Index)
	If Not DatabaseQuery(DbId, "SELECT chunk_data FROM blob_chunks WHERE blob_id = ? AND chunk_index = ?")
		ProcedureReturn 0
	EndIf
	If NextDatabaseRow(DbId)
		Size = DatabaseColumnSize(DbId, 0)
		If Size > 0
			*Data = AllocateMemory(Size, #PB_Memory_NoClear)
			If *Data
				GetDatabaseBlob(DbId, 0, *Data, Size)
				*OutSize\i = Size
			EndIf
		EndIf
	EndIf
	FinishDatabaseQuery(DbId)
	ProcedureReturn *Data
EndProcedure


; Reads all of blob BlobId back (Size bytes, in parts) and checks its SHA-256
; is *Sha256. Returns #False if it isn't, or a part is missing or the wrong
; size. ~3 s per GB.
Procedure.i HashStorageBlob(DbId.i, BlobId.q, Size.q, *Sha256)
	Protected Hash.BakaShrot_Sha256, Index.q, Count.q, *Data, DataSize.Integer
	Protected Dim Result.a(#BakaShrot_Sha256Size - 1)

	If Not BakaShrot_Sha256_Start(@Hash)
		ProcedureReturn #False
	EndIf
	Count = BakaShrot_AttachmentChunkCount(Size)
	For Index = 0 To Count - 1
		*Data = ReadStorageBlobChunk(DbId, BlobId, Index, @DataSize)
		If Not *Data
			ProcedureReturn #False
		EndIf
		If DataSize\i <> BakaShrot_AttachmentChunkBytes(Size, Index)
			FreeMemory(*Data)
			ProcedureReturn #False
		EndIf
		BakaShrot_Sha256_Add(@Hash, *Data, DataSize\i)
		FreeMemory(*Data)
	Next
	BakaShrot_Sha256_Finish(@Hash, @Result(0))
	ProcedureReturn CompareMemory(@Result(0), *Sha256, #BakaShrot_Sha256Size)
EndProcedure


; Fills Missing() with attachments of messages here that aren't all here
; yet (missing or receiving), with their topic and node names, up to Limit.
; Unnamed topics or nodes are left out: replication goes by name.
; Returns #False if the query failed.
Procedure.i GetMissingStorageAttachments(DbId.i, Limit.i, List Missing.BakaShrot_StorageMissingAttachment())
	ClearList(Missing())
	SetDatabaseLong(DbId, 0, Limit)
	If Not DatabaseQuery(DbId, "SELECT a.topic_id, a.node_id, t.name, n.name, a.message_id, COALESCE(b.received, 0) " +
	                           "FROM attachments a JOIN topics t ON t.topic_id = a.topic_id JOIN nodes n ON n.node_id = a.node_id " +
	                           "LEFT JOIN blobs b ON b.blob_id = a.blob_id " +
	                           "WHERE a.state IN (0, 1) ORDER BY a.topic_id, a.node_id, a.message_id LIMIT ?")
		ProcedureReturn #False
	EndIf
	While NextDatabaseRow(DbId)
		AddElement(Missing())
		Missing()\TopicId   = GetDatabaseLong(DbId, 0)
		Missing()\NodeId    = GetDatabaseLong(DbId, 1)
		Missing()\Topic     = GetDatabaseString(DbId, 2)
		Missing()\Node      = GetDatabaseString(DbId, 3)
		Missing()\MessageId = GetDatabaseQuad(DbId, 4)
		Missing()\Received  = GetDatabaseQuad(DbId, 5)
	Wend
	FinishDatabaseQuery(DbId)
	ProcedureReturn #True
EndProcedure


; --- Writes, through the writer ------------------------------------------------

; Starts an upload for TopicId/NodeId: Size bytes whose SHA-256 is *Sha256.
; Returns its blob id, 0 with the reason in *Error\s.
Procedure.q CreateStorageBlob(TopicId.i, NodeId.i, Size.q, *Sha256, *Error.String)
	Protected DbId.i, BlobId.q

	LockMutex(BakaShrot_Storage_WriteMutex)
	DbId = BakaShrot_Storage_Writer\DbId
	If Not DbId
		UnlockMutex(BakaShrot_Storage_WriteMutex)
		*Error\s = "the storage writer isn't open"
		ProcedureReturn 0
	EndIf

	SetDatabaseLong(DbId, 0, TopicId)
	SetDatabaseLong(DbId, 1, NodeId)
	SetDatabaseQuad(DbId, 2, Size)
	SetDatabaseBlob(DbId, 3, *Sha256, #BakaShrot_Sha256Size)
	SetDatabaseQuad(DbId, 4, BakaShrot_NowUtcMs())
	If DatabaseUpdate(DbId, "INSERT INTO blobs (topic_id, node_id, size, sha256, received, state, created_at) VALUES (?, ?, ?, ?, 0, 0, ?)")
		If DatabaseQuery(DbId, "SELECT last_insert_rowid()")
			If NextDatabaseRow(DbId)
				BlobId = GetDatabaseQuad(DbId, 0)
			EndIf
			FinishDatabaseQuery(DbId)
		EndIf
	EndIf
	If Not BlobId
		*Error\s = DatabaseError()
	EndIf

	UnlockMutex(BakaShrot_Storage_WriteMutex)
	ProcedureReturn BlobId
EndProcedure


; Stores part Index (DataSize bytes at *Data) of blob BlobId, which must be
; the next one: Index * #BakaShrot_AttachmentChunkSize bytes received so far.
; Returns how many are received now, -1 with the reason in *Error\s (nothing
; stored then).
Procedure.q StoreStorageBlobChunk(BlobId.q, Index.q, *Data, DataSize.i, *Error.String)
	Protected DbId.i, Received.q = -1, Ok.i

	LockMutex(BakaShrot_Storage_WriteMutex)
	DbId = BakaShrot_Storage_Writer\DbId
	If Not DbId
		UnlockMutex(BakaShrot_Storage_WriteMutex)
		*Error\s = "the storage writer isn't open"
		ProcedureReturn -1
	EndIf

	If DatabaseUpdate(DbId, "BEGIN IMMEDIATE")
		; Only if it's the next one, and the blob is still being received.
		SetDatabaseQuad(DbId, 0, DataSize)
		SetDatabaseQuad(DbId, 1, BlobId)
		SetDatabaseQuad(DbId, 2, Index * #BakaShrot_AttachmentChunkSize)
		Ok = DatabaseUpdate(DbId, "UPDATE blobs SET received = received + ? WHERE blob_id = ? AND received = ? AND state = 0")
		If Ok And AffectedDatabaseRows(DbId) <> 1
			Ok = #False
			*Error\s = "not the next part, or not being received"
		ElseIf Not Ok
			*Error\s = DatabaseError()
		EndIf
		If Ok
			SetDatabaseQuad(DbId, 0, BlobId)
			SetDatabaseQuad(DbId, 1, Index)
			SetDatabaseBlob(DbId, 2, *Data, DataSize)
			Ok = DatabaseUpdate(DbId, "INSERT INTO blob_chunks (blob_id, chunk_index, chunk_data) VALUES (?, ?, ?)")
			If Not Ok
				*Error\s = DatabaseError()
			EndIf
		EndIf
		If Ok And DatabaseUpdate(DbId, "COMMIT")
			Received = Index * #BakaShrot_AttachmentChunkSize + DataSize
		Else
			If Ok
				*Error\s = DatabaseError()
			EndIf
			DatabaseUpdate(DbId, "ROLLBACK")
		EndIf
	Else
		*Error\s = DatabaseError()
	EndIf

	UnlockMutex(BakaShrot_Storage_WriteMutex)
	ProcedureReturn Received
EndProcedure


; Sets blob BlobId's state (#BakaShrot_Blob_*). Returns #False if it failed.
Procedure.i SetStorageBlobState(BlobId.q, State.i)
	Protected DbId.i, Ok.i

	LockMutex(BakaShrot_Storage_WriteMutex)
	DbId = BakaShrot_Storage_Writer\DbId
	If DbId
		SetDatabaseLong(DbId, 0, State)
		SetDatabaseQuad(DbId, 1, BlobId)
		Ok = DatabaseUpdate(DbId, "UPDATE blobs SET state = ? WHERE blob_id = ?")
	EndIf
	UnlockMutex(BakaShrot_Storage_WriteMutex)
	ProcedureReturn Ok
EndProcedure


; Makes the blob of a replicated attachment that's still missing (state 0),
; from its row's size and SHA-256, and links it: receiving (1).
; Returns its blob id, 0 with the reason in *Error\s.
Procedure.q StartReplicatedAttachment(TopicId.i, NodeId.i, MessageId.q, *Error.String)
	Protected DbId.i, BlobId.q, Ok.i

	LockMutex(BakaShrot_Storage_WriteMutex)
	DbId = BakaShrot_Storage_Writer\DbId
	If Not DbId
		UnlockMutex(BakaShrot_Storage_WriteMutex)
		*Error\s = "the storage writer isn't open"
		ProcedureReturn 0
	EndIf

	If DatabaseUpdate(DbId, "BEGIN IMMEDIATE")
		SetDatabaseLong(DbId, 0, TopicId)
		SetDatabaseLong(DbId, 1, NodeId)
		SetDatabaseQuad(DbId, 2, BakaShrot_NowUtcMs())
		SetDatabaseLong(DbId, 3, TopicId)
		SetDatabaseLong(DbId, 4, NodeId)
		SetDatabaseQuad(DbId, 5, MessageId)
		Ok = DatabaseUpdate(DbId, "INSERT INTO blobs (topic_id, node_id, size, sha256, received, state, created_at) " +
		                          "SELECT ?, ?, size, sha256, 0, 0, ? FROM attachments WHERE topic_id = ? AND node_id = ? AND message_id = ? AND state = 0 AND blob_id IS NULL")
		If Ok And AffectedDatabaseRows(DbId) = 1 And DatabaseQuery(DbId, "SELECT last_insert_rowid()")
			If NextDatabaseRow(DbId)
				BlobId = GetDatabaseQuad(DbId, 0)
			EndIf
			FinishDatabaseQuery(DbId)
		EndIf
		If BlobId
			SetDatabaseQuad(DbId, 0, BlobId)
			SetDatabaseLong(DbId, 1, TopicId)
			SetDatabaseLong(DbId, 2, NodeId)
			SetDatabaseQuad(DbId, 3, MessageId)
			Ok = DatabaseUpdate(DbId, "UPDATE attachments SET blob_id = ?, state = 1 WHERE topic_id = ? AND node_id = ? AND message_id = ?")
		EndIf
		If BlobId And Ok And DatabaseUpdate(DbId, "COMMIT")
			; Done.
		Else
			*Error\s = DatabaseError()
			If *Error\s = ""
				*Error\s = "the attachment isn't missing"
			EndIf
			DatabaseUpdate(DbId, "ROLLBACK")
			BlobId = 0
		EndIf
	Else
		*Error\s = DatabaseError()
	EndIf

	UnlockMutex(BakaShrot_Storage_WriteMutex)
	ProcedureReturn BlobId
EndProcedure


; A replicated attachment is all here: ready (2) if its SHA-256 checked out
; (IsValid), else its blob is dropped and it's missing again (0), to be sent
; again from the start. Returns #False if it failed.
Procedure.i FinishReplicatedAttachment(TopicId.i, NodeId.i, MessageId.q, BlobId.q, IsValid.i)
	Protected DbId.i, Ok.i

	LockMutex(BakaShrot_Storage_WriteMutex)
	DbId = BakaShrot_Storage_Writer\DbId
	If DbId And DatabaseUpdate(DbId, "BEGIN IMMEDIATE")
		SetDatabaseQuad(DbId, 0, BlobId)
		If IsValid
			Ok = DatabaseUpdate(DbId, "UPDATE blobs SET state = 2 WHERE blob_id = ?")
		Else
			Ok = DatabaseUpdate(DbId, "UPDATE blobs SET state = 3 WHERE blob_id = ?")
		EndIf
		If Ok
			SetDatabaseLong(DbId, 0, TopicId)
			SetDatabaseLong(DbId, 1, NodeId)
			SetDatabaseQuad(DbId, 2, MessageId)
			If IsValid
				Ok = DatabaseUpdate(DbId, "UPDATE attachments SET state = 2 WHERE topic_id = ? AND node_id = ? AND message_id = ?")
			Else
				Ok = DatabaseUpdate(DbId, "UPDATE attachments SET state = 0, blob_id = NULL WHERE topic_id = ? AND node_id = ? AND message_id = ?")
			EndIf
		EndIf
		If Ok
			Ok = DatabaseUpdate(DbId, "COMMIT")
		EndIf
		If Not Ok
			DatabaseUpdate(DbId, "ROLLBACK")
		EndIf
	EndIf
	UnlockMutex(BakaShrot_Storage_WriteMutex)
	ProcedureReturn Ok
EndProcedure


; Marks uploads never completed nor attached, started before BeforeMs (ms
; since 1970 UTC), to delete, then deletes up to Limit parts of what's to
; delete, and the blobs left with none. Call it again while it returns
; Limit. Returns how many parts were deleted, -1 with the reason in *Error\s.
Procedure.i CleanUpStorageBlobs(BeforeMs.q, Limit.i, *Error.String)
	Protected DbId.i, Deleted.i = -1

	LockMutex(BakaShrot_Storage_WriteMutex)
	DbId = BakaShrot_Storage_Writer\DbId
	If Not DbId
		UnlockMutex(BakaShrot_Storage_WriteMutex)
		*Error\s = "the storage writer isn't open"
		ProcedureReturn -1
	EndIf

	; Uploads (no attachments row points to them) left behind.
	SetDatabaseQuad(DbId, 0, BeforeMs)
	If DatabaseUpdate(DbId, "UPDATE blobs SET state = 3 WHERE state IN (0, 1) AND created_at < ? " +
	                        "AND NOT EXISTS (SELECT 1 FROM attachments a WHERE a.blob_id = blobs.blob_id)")
		SetDatabaseLong(DbId, 0, Limit)
		If DatabaseUpdate(DbId, "DELETE FROM blob_chunks WHERE rowid IN (SELECT c.rowid FROM blob_chunks c JOIN blobs b ON b.blob_id = c.blob_id WHERE b.state = 3 LIMIT ?)")
			Deleted = AffectedDatabaseRows(DbId)
			If Deleted < Limit
				DatabaseUpdate(DbId, "DELETE FROM blobs WHERE state = 3 AND NOT EXISTS (SELECT 1 FROM blob_chunks c WHERE c.blob_id = blobs.blob_id)")
			EndIf
		EndIf
	EndIf
	If Deleted < 0
		*Error\s = DatabaseError()
	EndIf

	UnlockMutex(BakaShrot_Storage_WriteMutex)
	ProcedureReturn Deleted
EndProcedure
