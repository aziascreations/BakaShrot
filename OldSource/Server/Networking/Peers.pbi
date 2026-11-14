;{- Code Header
; ==- Basic Info -================================
;     Name: Peers.pbi
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
; BakaShrot Server Peers
;
; Links this server to the other servers in its config's
; [BakaShrot.Peer.<name>] sections, one thread per peer. Each thread:
;   1. Connects to the peer and authenticates with this server's own identity
;      ([BakaShrot] PrivateKey/TopicId/NodeId), like a client would. The peer
;      must have it registered in one of its [BakaShrot.Client.<name>].
;   2. Stays connected until the link drops.
;   3. Waits [BakaShrot.Server] PeerRetryDelay seconds, then starts over.
;      Same after a failed attempt.
;
; Once linked, it checks in with the peer every [BakaShrot.Server]
; PeerSyncInterval seconds, starting right away:
;   1. Asks the peer for its sync state: the topics it takes from this
;      server, and the highest message id it has for each of their
;      topic/node ids, in its own ids, with their names.
;   2. Compares it with this server's own (GetSyncState() in Storage.pbi),
;      matching topics and nodes by name: each server has its own ids, see
;      Server/Storage/Names.pbi. Only what's named on both sides replicates:
;      an unnamed one, or one whose name the peer doesn't list, is dropped
;      (BakaShrot_Names_NoteDropped()).
;   3. For every topic/node the peer takes, this server sends it
;      (the peer section's SendTopics), and the peer is behind on, sends it
;      the missing messages in order, in batches of up to
;      [BakaShrot.Server] PeerBatchSize messages, about 64 KB at most (a
;      bigger message goes alone, see ReplicateMessagesPacket.pbi), each
;      batch stored in one transaction and answered before the next. The
;      batches carry the names, the peer stores them under its own ids.
;      A message's attachment only has its size and SHA-256 in the batch.
;   4. Once the messages are caught up, asks the peer which attachments it's
;      missing (MissingAttachmentsRequest) and sends those it has, a part
;      (1 MB) per request, from where the peer stopped (Design/Attachments.md).
; The peer does the same over its own link to this server, which covers the
; other direction. Any packet from the peer outside of a check-in drops the
; link as unexpected.
; Known issues, like two servers drifting apart: Design/ReplicationIssues.md.
;
; Each link thread opens its own database connection when it starts, and
; closes it when it ends. See the top of Storage/Storage.pbi.
;
; The peer proves itself in the handshake: the Hello is sealed for the peer
; section's PublicKey and the peer must sign the handshake with the matching
; private key, so a link only reaches the real peer, and is encrypted
; (Commons/Networking/Connections.pbi).
;
; Logs with PrintN(), so the program must have a console open.
; Must be compiled with the thread-safe option enabled.
; ============================================================================

CompilerIf Not #PB_Compiler_Thread
	CompilerError "Peers.pbi needs the thread-safe option (Compiler Options > Create threadsafe executable)."
CompilerEndIf

XIncludeFile "../../Commons/Networking/Outbound.pbi"
XIncludeFile "../Config/Config.pbi"
XIncludeFile "../Storage/Storage.pbi"
XIncludeFile "../Storage/Names.pbi"


Structure BakaShrot_PeerLink
	*Links

	; [BakaShrot.Peer.<name>]
	Name.s
	Host.s
	Port.i

	; The peer section's PublicKey: who the peer must prove to be.
	ServerPublicKey.a[#BakaShrot_Ed25519_PublicKeySize]

	ThreadId.i

	; Only used by the link's thread.
	Outbound.BakaShrot_Outbound
	DbId.i

	; The peer section's SendTopics and SendNodes, copied for the link's thread.
	SendTopics.BakaShrot_NameSet
	SendNodes.BakaShrot_NameSet
EndStructure


Structure BakaShrot_PeerLinks
	; Set by BakaShrot_PeerLinks_Stop(), makes every link's thread return.
	StopRequested.i

	RetryDelayMs.i
	SyncIntervalMs.i

	; Most messages sent per ReplicateMessages packet.
	BatchSize.i

	; Every link's thread opens its own connection to it.
	DatabasePath.s

	; This server's identity, read by every link's thread.
	Identity.BakaShrot_OutboundIdentity
	PrivateKey.a[#BakaShrot_Ed25519_PrivateKeySize]
	PublicKey.a[#BakaShrot_Ed25519_PublicKeySize]

	List Links.BakaShrot_PeerLink()
EndStructure


; Waits the retry delay, returns early if stopping.
Procedure BakaShrot_PeerLink_WaitRetry(*Link.BakaShrot_PeerLink)
	Protected *Links.BakaShrot_PeerLinks = *Link\Links
	Protected StartTime.i

	StartTime = ElapsedMilliseconds()
	While Not *Links\StopRequested And ElapsedMilliseconds() - StartTime < *Links\RetryDelayMs
		Delay(100)
	Wend
EndProcedure


; Sends a request to the peer and waits for its answer.
; Returns the answer (free it with FreeMemory) with its size in *OutSize\i,
; or 0 if the link failed.
Procedure.i BakaShrot_PeerLink_Request(*Link.BakaShrot_PeerLink, *Request, RequestSize.i, *OutSize.Integer)
	If Not BakaShrot_Outbound_Send(@*Link\Outbound, *Request, RequestSize)
		ProcedureReturn 0
	EndIf
	ProcedureReturn BakaShrot_Outbound_WaitPacket(@*Link\Outbound, *OutSize, #BakaShrot_Outbound_Timeout)
EndProcedure


; Logs a RequestRefused answer from the peer.
; Returns #False if it's malformed, the link must then be dropped.
Procedure.i BakaShrot_PeerLink_LogRefusal(*Link.BakaShrot_PeerLink, *Answer, AnswerSize.i)
	Protected *View.MsgPackData, *Refused.BakaShrot_RequestRefused

	*Refused = 0
	*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize)
	If *View
		*Refused = BakaShrot_RequestRefusedPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	If Not *Refused
		ProcedureReturn #False
	EndIf

	PrintN("[Peer] '" + *Link\Name + "' refused (" + BakaShrot_ErrorName(*Refused\Code) + "): " + *Refused\Reason)
	FreeStructure(*Refused)
	ProcedureReturn #True
EndProcedure


; Sends the peer the attachment it's missing, *Missing, from the part it
; asked for on, if this server has all of it and sends that topic/node to it.
; Returns 1 once the peer has it, 0 if it's skipped (not here, not sent to
; that peer, refused: logged), -1 if the link must be dropped.
Procedure.i BakaShrot_PeerLink_SendAttachment(*Link.BakaShrot_PeerLink, *Missing.BakaShrot_MissingAttachment)
	Protected *Links.BakaShrot_PeerLinks = *Link\Links
	Protected Attachment.BakaShrot_StorageAttachment, Chunk.BakaShrot_ReplicateAttachmentChunk
	Protected *Stored.BakaShrot_ChunkStored
	Protected TopicId.i, NodeId.i, Index.q, Count.q, DataSize.Integer, Complete.i
	Protected *Packet, PacketSize.Integer, *Answer, AnswerSize.Integer, *View.MsgPackData, IsRefusal.i

	TopicId = BakaShrot_Names_TopicByName(*Missing\Topic)
	NodeId  = BakaShrot_Names_NodeByName(*Missing\Node)
	If TopicId < 0 Or NodeId < 0
		ProcedureReturn 0
	EndIf
	If Not NameSetHas(@*Link\SendTopics, TopicId, *Missing\Topic) Or Not NameSetHas(@*Link\SendNodes, NodeId, *Missing\Node)
		ProcedureReturn 0
	EndIf
	; Not here either (yet, or not kept): another server may have it.
	If Not GetStorageAttachment(*Link\DbId, TopicId, NodeId, *Missing\MessageId, @Attachment) Or Attachment\State <> #BakaShrot_Attachment_Ready
		ProcedureReturn 0
	EndIf

	Count = BakaShrot_AttachmentChunkCount(Attachment\Size)
	Chunk\Topic     = *Missing\Topic
	Chunk\Node      = *Missing\Node
	Chunk\MessageId = *Missing\MessageId
	For Index = *Missing\NextChunk To Count - 1
		If *Links\StopRequested
			ProcedureReturn -1
		EndIf

		Chunk\ChunkIndex = Index
		Chunk\Data = ReadStorageBlobChunk(*Link\DbId, Attachment\BlobId, Index, @DataSize)
		If Not Chunk\Data
			PrintN("[Peer] Can't read part " + Str(Index) + " of the attachment of " + *Missing\Topic + ":" + *Missing\Node + "#" + Str(*Missing\MessageId) + " for '" + *Link\Name + "'")
			ProcedureReturn 0
		EndIf
		Chunk\DataSize = DataSize\i
		*Packet = BakaShrot_ReplicateAttachmentChunkPacket_Encode(@Chunk, @PacketSize)
		FreeMemory(Chunk\Data)
		Chunk\Data = 0
		If Not *Packet
			ProcedureReturn -1
		EndIf
		*Answer = BakaShrot_PeerLink_Request(*Link, *Packet, PacketSize\i, @AnswerSize)
		FreeMemory(*Packet)
		If Not *Answer
			ProcedureReturn -1
		EndIf

		If BakaShrot_GetPacketType(*Answer, AnswerSize\i) = #BakaShrot_PacketType_RequestRefused
			IsRefusal = BakaShrot_PeerLink_LogRefusal(*Link, *Answer, AnswerSize\i)
			FreeMemory(*Answer)
			If Not IsRefusal
				ProcedureReturn -1
			EndIf
			ProcedureReturn 0
		EndIf

		*Stored = 0
		*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
		If *View
			*Stored = BakaShrot_ChunkStoredPacket_Decode(*View)
			MsgPackFree(*View, #False)
		EndIf
		FreeMemory(*Answer)
		If Not *Stored
			PrintN("[Peer] '" + *Link\Name + "' sent an invalid answer to an attachment's part")
			ProcedureReturn -1
		EndIf
		Complete = *Stored\Complete
		FreeStructure(*Stored)
		If Complete
			ProcedureReturn 1
		EndIf
	Next

	; All sent, and the peer didn't say it's complete: it'll ask again.
	ProcedureReturn 0
EndProcedure


; Once the messages are caught up: asks the peer which attachments it's
; missing, and sends those this server has, one after the other.
; Returns #False if the link must be dropped.
Procedure.i BakaShrot_PeerLink_SendAttachments(*Link.BakaShrot_PeerLink)
	Protected Request.BakaShrot_MissingAttachmentsRequest, *Missing.BakaShrot_MissingAttachments
	Protected *Packet, PacketSize.Integer, *Answer, AnswerSize.Integer, *View.MsgPackData, IsRefusal.i
	Protected Result.i, StartTime.i, Attachment.BakaShrot_StorageAttachment, Key.s

	*Packet = BakaShrot_MissingAttachmentsRequestPacket_Encode(@Request, @PacketSize)
	If Not *Packet
		ProcedureReturn #False
	EndIf
	*Answer = BakaShrot_PeerLink_Request(*Link, *Packet, PacketSize\i, @AnswerSize)
	FreeMemory(*Packet)
	If Not *Answer
		PrintN("[Peer] '" + *Link\Name + "' didn't answer which attachments it's missing")
		ProcedureReturn #False
	EndIf

	If BakaShrot_GetPacketType(*Answer, AnswerSize\i) = #BakaShrot_PacketType_RequestRefused
		IsRefusal = BakaShrot_PeerLink_LogRefusal(*Link, *Answer, AnswerSize\i)
		FreeMemory(*Answer)
		ProcedureReturn IsRefusal
	EndIf

	*Missing = 0
	*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
	If *View
		*Missing = BakaShrot_MissingAttachmentsPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*Answer)
	If Not *Missing
		PrintN("[Peer] '" + *Link\Name + "' sent an invalid list of missing attachments")
		ProcedureReturn #False
	EndIf

	ForEach *Missing\Attachments()
		StartTime = ElapsedMilliseconds()
		Result = BakaShrot_PeerLink_SendAttachment(*Link, @*Missing\Attachments())
		If Result < 0
			FreeStructure(*Missing)
			ProcedureReturn #False
		EndIf
		If Result > 0
			Key = *Missing\Attachments()\Topic + ":" + *Missing\Attachments()\Node + "#" + Str(*Missing\Attachments()\MessageId)
			PrintN("[Peer] Sent the attachment of " + Key + " to '" + *Link\Name + "' in " + Str(ElapsedMilliseconds() - StartTime) + " ms, from part " + Str(*Missing\Attachments()\NextChunk))
		EndIf
	Next
	FreeStructure(*Missing)
	ProcedureReturn #True
EndProcedure


; Sends a batch of messages the peer is missing and checks its answer.
; Returns 1 once stored, 0 if the peer refused it (logged), or -1 if the
; link must be dropped.
Procedure.i BakaShrot_PeerLink_SendBatch(*Link.BakaShrot_PeerLink, *Batch.BakaShrot_ReplicateMessages)
	Protected *Pushed.BakaShrot_MessagePushed
	Protected *Packet, PacketSize.Integer, *Answer, AnswerSize.Integer
	Protected *View.MsgPackData, IsRefusal.i, IsAcknowledged.i, LastMessageId.q

	LastElement(*Batch\Messages())
	LastMessageId = *Batch\Messages()\MessageId

	*Packet = BakaShrot_ReplicateMessagesPacket_Encode(*Batch, @PacketSize)
	If Not *Packet
		ProcedureReturn -1
	EndIf
	*Answer = BakaShrot_PeerLink_Request(*Link, *Packet, PacketSize\i, @AnswerSize)
	FreeMemory(*Packet)
	If Not *Answer
		ProcedureReturn -1
	EndIf

	If BakaShrot_GetPacketType(*Answer, AnswerSize\i) = #BakaShrot_PacketType_RequestRefused
		IsRefusal = BakaShrot_PeerLink_LogRefusal(*Link, *Answer, AnswerSize\i)
		FreeMemory(*Answer)
		If Not IsRefusal
			ProcedureReturn -1
		EndIf
		ProcedureReturn 0
	EndIf

	*Pushed = 0
	*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
	If *View
		*Pushed = BakaShrot_MessagePushedPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*Answer)
	If Not *Pushed
		ProcedureReturn -1
	EndIf

	; An acknowledgement for anything but the batch's last message is out of order.
	IsAcknowledged = Bool(*Pushed\MessageId = LastMessageId)
	FreeStructure(*Pushed)
	If Not IsAcknowledged
		ProcedureReturn -1
	EndIf

	ProcedureReturn 1
EndProcedure


; Sends every message of a topic/node id above AfterMessageId, in order, in
; batches of up to [BakaShrot.Server] PeerBatchSize messages, each one cut
; short at about #BakaShrot_ReplicateBatchBytes (a bigger message alone). TopicRef and NodeRef are what they
; go by on the wire: their names, or their ids in digits.
; Stops at the first refusal, or if the server is stopping.
; Returns how many were stored, or -1 if the link must be dropped.
Procedure.i BakaShrot_PeerLink_SendMissing(*Link.BakaShrot_PeerLink, TopicId.i, NodeId.i, TopicRef.s, NodeRef.s, AfterMessageId.q)
	Protected *Links.BakaShrot_PeerLinks = *Link\Links
	Protected NewList Messages.BakaShrot_Message()
	Protected Batch.BakaShrot_ReplicateMessages
	Protected SentCount.i, Result.i, BatchSize.i, MessageSize.i

	Batch\Topic = TopicRef
	Batch\Node  = NodeRef

	Repeat
		If *Links\StopRequested
			ProcedureReturn SentCount
		EndIf

		If Not GetMessagesAfter(*Link\DbId, TopicId, NodeId, AfterMessageId, *Links\BatchSize, #BakaShrot_ReplicateBatchBytes, Messages())
			PrintN("[Peer] Failed to read the messages to send to '" + *Link\Name + "': " + DatabaseError())
			ProcedureReturn SentCount
		EndIf
		If ListSize(Messages()) = 0
			ProcedureReturn SentCount
		EndIf

		; As many as fit in #BakaShrot_ReplicateBatchBytes, the rest goes in the
		; next batch. A bigger message goes alone, if it fits in a packet.
		ClearList(Batch\Messages())
		BatchSize = #BakaShrot_ReplicateBatchOverhead
		ForEach Messages()
			MessageSize = #BakaShrot_ReplicateMessageOverhead + StringByteLength(Messages()\JsonData, #PB_UTF8)
			If ListSize(Batch\Messages()) > 0 And BatchSize + MessageSize > #BakaShrot_ReplicateBatchBytes
				Break
			EndIf
			If BatchSize + MessageSize > #BakaShrot_MaxPacketSize
				Break
			EndIf
			BatchSize + MessageSize

			AddElement(Batch\Messages())
			Batch\Messages()\MessageId = Messages()\MessageId
			; As stored: when it was pushed to its origin, whichever server that was.
			Batch\Messages()\PushedAt  = Messages()\PushedAt
			Batch\Messages()\JsonData  = Messages()\JsonData
			; Its attachment's size and SHA-256 only: the data goes once the
			; messages are caught up (BakaShrot_PeerLink_SendAttachments()).
			Batch\Messages()\AttachmentSize = Messages()\AttachmentSize
			CopyMemory(@Messages()\AttachmentSha256[0], @Batch\Messages()\AttachmentSha256[0], #BakaShrot_Sha256Size)
		Next

		If ListSize(Batch\Messages()) = 0
			FirstElement(Messages())
			PrintN("[Peer] Message " + TopicRef + ":" + NodeRef + "#" + Str(Messages()\MessageId) + " is too big to replicate to '" + *Link\Name + "', skipping the rest of this pair")
			ProcedureReturn SentCount
		EndIf

		Result = BakaShrot_PeerLink_SendBatch(*Link, @Batch)
		If Result = -1
			ProcedureReturn -1
		EndIf
		If Result = 0
			ProcedureReturn SentCount
		EndIf

		SentCount + ListSize(Batch\Messages())
		LastElement(Batch\Messages())
		AfterMessageId = Batch\Messages()\MessageId
	ForEver
EndProcedure


; #True if Name matches one of Patterns() (Commons/Networking/Names.pbi).
Procedure.i BakaShrot_MatchesAny(List Patterns.s(), Name.s)
	ForEach Patterns()
		If BakaShrot_GlobMatch(Patterns(), Name)
			ProcedureReturn #True
		EndIf
	Next
	ProcedureReturn #False
EndProcedure


; Asks the peer where it's at, and sends it the messages it's missing.
; Returns #False if the link must be dropped.
Procedure.i BakaShrot_PeerLink_CheckIn(*Link.BakaShrot_PeerLink)
	Protected *Links.BakaShrot_PeerLinks = *Link\Links
	Protected Request.BakaShrot_SyncStateRequest
	Protected *State.BakaShrot_SyncState
	Protected NewList LocalPairs.BakaShrot_SyncPair()
	Protected NewMap RemoteTopics.i(), NewMap RemoteNodes.i()
	Protected NewList RemoteTopicPatterns.s(), NewList RemoteNodePatterns.s()
	Protected NewMap RemoteMessageIds.q()
	Protected *Packet, PacketSize.Integer, *Answer, AnswerSize.Integer
	Protected *View.MsgPackData, IsRefusal.i, Key.s, RemoteMessageId.q, SentCount.i, StartTime.i
	Protected TopicRef.s, NodeRef.s, RemoteTopicId.i, RemoteNodeId.i

	; 1. The peer's state
	*Packet = BakaShrot_SyncStateRequestPacket_Encode(@Request, @PacketSize)
	If Not *Packet
		ProcedureReturn #False
	EndIf
	*Answer = BakaShrot_PeerLink_Request(*Link, *Packet, PacketSize\i, @AnswerSize)
	FreeMemory(*Packet)
	If Not *Answer
		PrintN("[Peer] '" + *Link\Name + "' didn't answer the check-in")
		ProcedureReturn #False
	EndIf

	If BakaShrot_GetPacketType(*Answer, AnswerSize\i) = #BakaShrot_PacketType_RequestRefused
		IsRefusal = BakaShrot_PeerLink_LogRefusal(*Link, *Answer, AnswerSize\i)
		FreeMemory(*Answer)
		ProcedureReturn IsRefusal
	EndIf

	*State = 0
	*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
	If *View
		*State = BakaShrot_SyncStatePacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*Answer)
	If Not *State
		PrintN("[Peer] '" + *Link\Name + "' sent an invalid sync state")
		ProcedureReturn #False
	EndIf

	; The peer's ids, by LCase(name): every name it knows.
	ForEach *State\Topics()
		RemoteTopics(LCase(*State\Topics()\Name)) = *State\Topics()\Id
	Next
	ForEach *State\Nodes()
		RemoteNodes(LCase(*State\Nodes()\Name)) = *State\Nodes()\Id
	Next
	; And what it takes without having it yet.
	CopyList(*State\TopicPatterns(), RemoteTopicPatterns())
	CopyList(*State\NodePatterns(), RemoteNodePatterns())
	ForEach *State\Pairs()
		RemoteMessageIds(Str(*State\Pairs()\TopicId) + ":" + Str(*State\Pairs()\NodeId)) = *State\Pairs()\MessageId
	Next
	FreeStructure(*State)

	; 2. This server's state
	If Not GetSyncState(*Link\DbId, LocalPairs())
		PrintN("[Peer] Failed to read the sync state for '" + *Link\Name + "': " + DatabaseError())
		ProcedureReturn #True
	EndIf

	; 3. The delta, matching this server's topics and nodes to the peer's by
	; name. Anything not named on both sides is dropped, unless a wildcard
	; of the peer takes it.
	ForEach LocalPairs()
		TopicRef = BakaShrot_Names_TopicName(LocalPairs()\TopicId)
		NodeRef  = BakaShrot_Names_NodeName(LocalPairs()\NodeId)
		If Not NameSetHas(@*Link\SendTopics, LocalPairs()\TopicId, TopicRef) Or Not NameSetHas(@*Link\SendNodes, LocalPairs()\NodeId, NodeRef)
			Continue
		EndIf

		If TopicRef = ""
			BakaShrot_Names_NoteDropped(*Link\Name, "topic", Str(LocalPairs()\TopicId), "unnamed here")
			Continue
		EndIf
		If NodeRef = ""
			BakaShrot_Names_NoteDropped(*Link\Name, "node", Str(LocalPairs()\NodeId), "unnamed here")
			Continue
		EndIf

		; -1: the peer doesn't have it yet, but a wildcard of its takes it.
		RemoteTopicId = -1
		If FindMapElement(RemoteTopics(), LCase(TopicRef))
			RemoteTopicId = RemoteTopics()
		ElseIf Not BakaShrot_MatchesAny(RemoteTopicPatterns(), TopicRef)
			BakaShrot_Names_NoteDropped(*Link\Name, "topic", TopicRef, "not taken by the peer")
			Continue
		EndIf
		RemoteNodeId = -1
		If FindMapElement(RemoteNodes(), LCase(NodeRef))
			RemoteNodeId = RemoteNodes()
		ElseIf Not BakaShrot_MatchesAny(RemoteNodePatterns(), NodeRef)
			BakaShrot_Names_NoteDropped(*Link\Name, "node", NodeRef, "not taken by the peer")
			Continue
		EndIf

		RemoteMessageId = 0
		If RemoteTopicId >= 0 And RemoteNodeId >= 0 And FindMapElement(RemoteMessageIds(), Str(RemoteTopicId) + ":" + Str(RemoteNodeId))
			RemoteMessageId = RemoteMessageIds()
		EndIf

		Key = TopicRef + ":" + NodeRef
		If LocalPairs()\MessageId > RemoteMessageId
			StartTime = ElapsedMilliseconds()
			SentCount = BakaShrot_PeerLink_SendMissing(*Link, LocalPairs()\TopicId, LocalPairs()\NodeId, TopicRef, NodeRef, RemoteMessageId)
			If SentCount < 0
				ProcedureReturn #False
			EndIf
			If SentCount > 0
				PrintN("[Peer] Sent " + Str(SentCount) + " messages of " + Key + " to '" + *Link\Name + "' in " + Str(ElapsedMilliseconds() - StartTime) + " ms, it had up to #" + Str(RemoteMessageId))
			EndIf
		EndIf
	Next

	; 4. Then the attachments: only for messages the peer has now.
	ProcedureReturn BakaShrot_PeerLink_SendAttachments(*Link)
EndProcedure


; Keeps a linked peer's connection, checking in every sync interval, until it
; drops, a check-in fails, the peer sends something unasked, or the server is
; stopping. The connection is closed when it returns.
Procedure BakaShrot_PeerLink_StayLinked(*Link.BakaShrot_PeerLink)
	Protected *Links.BakaShrot_PeerLinks = *Link\Links
	Protected LastCheckIn.i

	; Checks in right away.
	LastCheckIn = ElapsedMilliseconds() - *Links\SyncIntervalMs

	While Not *Links\StopRequested
		If ElapsedMilliseconds() - LastCheckIn >= *Links\SyncIntervalMs
			If Not BakaShrot_PeerLink_CheckIn(*Link)
				PrintN("[Peer] Dropping the link to '" + *Link\Name + "', the check-in failed")
				BakaShrot_Outbound_Close(@*Link\Outbound, #BakaShrot_ConnectionStatus_Aborted)
				ProcedureReturn
			EndIf
			LastCheckIn = ElapsedMilliseconds()
		EndIf

		Select NetworkClientEvent(*Link\Outbound\ConnectionId)

			Case #PB_NetworkEvent_Data
				PrintN("[Peer] '" + *Link\Name + "' sent a packet it wasn't asked for")
				BakaShrot_Outbound_Close(@*Link\Outbound, #BakaShrot_ConnectionStatus_Aborted)
				ProcedureReturn

			Case #PB_NetworkEvent_Disconnect
				PrintN("[Peer] Lost the link to '" + *Link\Name + "'")
				BakaShrot_Outbound_Close(@*Link\Outbound, #BakaShrot_ConnectionStatus_Disconnected)
				ProcedureReturn

			Default
				Delay(50)

		EndSelect
	Wend

	BakaShrot_Outbound_Close(@*Link\Outbound, #BakaShrot_ConnectionStatus_Disconnected)
EndProcedure


Procedure BakaShrot_PeerLink_Thread(*Link.BakaShrot_PeerLink)
	Protected *Links.BakaShrot_PeerLinks = *Link\Links
	Protected Target.s = "'" + *Link\Name + "' (" + *Link\Host + ":" + Str(*Link\Port) + ")"

	*Link\DbId = OpenStorageDatabase(*Links\DatabasePath)
	If Not *Link\DbId
		PrintN("[Peer] Failed to open the database for " + Target + ", not linking to it: " + DatabaseError())
		ProcedureReturn
	EndIf

	; Waits for the peer's answers stop early when the server is stopping.
	*Link\Outbound\StopRequested = @*Links\StopRequested

	While Not *Links\StopRequested
		If BakaShrot_Outbound_Connect(@*Link\Outbound, *Link\Host, *Link\Port, @*Links\Identity, @*Link\ServerPublicKey[0])
			PrintN("[Peer] Linked to " + Target)
			BakaShrot_PeerLink_StayLinked(*Link)
		Else
			PrintN("[Peer] Failed to link to " + Target + ", unreachable, or the handshake failed (is its PublicKey right?)")
		EndIf

		If Not *Links\StopRequested
			PrintN("[Peer] Retrying " + Target + " in " + Str(*Links\RetryDelayMs / 1000) + "s")
			BakaShrot_PeerLink_WaitRetry(*Link)
		EndIf
	Wend

	CloseDatabase(*Link\DbId)
	*Link\DbId = 0
EndProcedure


; Stops every link's thread, closes their connections and frees *Links.
; Once it returns, no link thread is left, so none holds a database
; connection either.
; Waits for a peer's answer stop within a few ms, but a thread opening a
; connection is blocked in OpenNetworkConnection() until it succeeds or
; fails.
Procedure BakaShrot_PeerLinks_Stop(*Links.BakaShrot_PeerLinks)
	*Links\StopRequested = #True

	ForEach *Links\Links()
		If *Links\Links()\ThreadId
			WaitThread(*Links\Links()\ThreadId)
		EndIf
	Next

	; Don't leave the private key lying around in freed memory.
	FillMemory(@*Links\PrivateKey[0], #BakaShrot_Ed25519_PrivateKeySize, 0)
	FreeStructure(*Links)
EndProcedure


; Starts a link to every [BakaShrot.Peer.<name>] in *Config, replicating
; the messages in its [BakaShrot.Server] DatabasePath. *Config must outlive
; the links.
; Returns 0 if *Config's PrivateKey is invalid or a thread couldn't start,
; stop the returned links with BakaShrot_PeerLinks_Stop().
Procedure.i BakaShrot_PeerLinks_Start(*Config.BakaShrot_CoreConfig)
	Protected *Links.BakaShrot_PeerLinks

	If Not InitCryptography()
		ProcedureReturn 0
	EndIf

	*Links = AllocateStructure(BakaShrot_PeerLinks)
	If Not *Links
		ProcedureReturn 0
	EndIf

	; Identity
	If Not DecodeKeyFromString(*Config\PrivateKey, @*Links\PrivateKey[0], #BakaShrot_Ed25519_PrivateKeySize)
		FreeStructure(*Links)
		ProcedureReturn 0
	EndIf
	GetPublicKeyFromPrivateKey(@*Links\PrivateKey[0], @*Links\PublicKey[0])

	; By name: the peer has its own ids for them.
	*Links\Identity\Node       = BakaShrot_Names_NodeRef(*Config\NodeId)
	*Links\Identity\PublicKey  = EncodeKeyToString(@*Links\PublicKey[0], #BakaShrot_Ed25519_PublicKeySize)
	*Links\Identity\PrivateKey = @*Links\PrivateKey[0]

	*Links\DatabasePath = *Config\Server\DatabasePath

	*Links\RetryDelayMs = *Config\Server\PeerRetryDelay * 1000
	If *Links\RetryDelayMs < 1000
		*Links\RetryDelayMs = 1000
	EndIf

	*Links\SyncIntervalMs = *Config\Server\PeerSyncInterval * 1000
	If *Links\SyncIntervalMs < 1000
		*Links\SyncIntervalMs = 1000
	EndIf

	*Links\BatchSize = *Config\Server\PeerBatchSize
	If *Links\BatchSize < 1
		*Links\BatchSize = 1
	EndIf
	If *Links\BatchSize > #BakaShrot_MaxReplicateBatch
		*Links\BatchSize = #BakaShrot_MaxReplicateBatch
	EndIf

	; Links
	ForEach *Config\Peers()
		AddElement(*Links\Links())
		*Links\Links()\Links = *Links
		*Links\Links()\Name  = MapKey(*Config\Peers())
		*Links\Links()\Host  = *Config\Peers()\Host
		*Links\Links()\Port  = *Config\Peers()\Port
		If Not DecodeKeyFromString(*Config\Peers()\PublicKey, @*Links\Links()\ServerPublicKey[0], #BakaShrot_Ed25519_PublicKeySize)
			PrintN("[Peer] [BakaShrot.Peer." + MapKey(*Config\Peers()) + "] PublicKey is missing or invalid")
			BakaShrot_PeerLinks_Stop(*Links)
			ProcedureReturn 0
		EndIf
		CopyStructure(@*Config\Peers()\SendTopics, @*Links\Links()\SendTopics, BakaShrot_NameSet)
		CopyStructure(@*Config\Peers()\SendNodes, @*Links\Links()\SendNodes, BakaShrot_NameSet)

		; List elements never move, so the thread can keep this pointer.
		*Links\Links()\ThreadId = CreateThread(@BakaShrot_PeerLink_Thread(), @*Links\Links())
		If Not *Links\Links()\ThreadId
			BakaShrot_PeerLinks_Stop(*Links)
			ProcedureReturn 0
		EndIf
	Next

	ProcedureReturn *Links
EndProcedure
