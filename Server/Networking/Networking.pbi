; ============================================================================
; BakaShrot Server Networking
;
; Threaded TCP server, one thread per client:
;   - The listener thread is the only one calling NetworkServerEvent().
;     On connect it starts a thread for the client, on data it adds what it
;     received to that client's inbox, on disconnect it flags the client.
;     Either way it then sets the client's Signal to wake its thread up.
;     With nothing to do, it sleeps in select() on every socket (see
;     Commons/Networking/SocketWait.pbi).
;   - Each client thread runs the handshake (see Connections.pbi) by taking
;     packets out of its inbox, sleeping on its Signal while it's empty.
;     Anything out of order or unexpected aborts the connection.
;     It opens the client's sealed Hello with this server's key, proves it
;     holds it, and sets up the connection's cipher: every packet after the
;     ChallengeRequest is encrypted, and decrypted by the client's thread.
;
; Once authenticated, a client's thread answers its requests one at a time
; until it disconnects: PushMessage, GetLatestMessage, GetMessages,
; QueryRequest, ResolveName and ListNames, each one only if its
; [BakaShrot.Client.<name>] allows it (AllowWrite and PushTopics, AllowRead
; and ReadTopics, AllowQuery), and for
; peers, SyncStateRequest and ReplicateMessages, refused for regular clients,
; within the peer's AcceptTopics and AcceptNodes. Any other packet aborts it.
;
; Topics and nodes come by name or id (Commons/Networking/Names.pbi), and
; are resolved to this server's ids by Storage/Names.pbi.
;
; Each client thread opens its own database connection once its client is
; authenticated, and closes it when it ends. See the top of Storage/Storage.pbi.
;
; Logs with PrintN(), so the program must have a console open.
; Must be compiled with the thread-safe option enabled.
; ============================================================================

CompilerIf Not #PB_Compiler_Thread
	CompilerError "Networking.pbi needs the thread-safe option (Compiler Options > Create threadsafe executable)."
CompilerEndIf

XIncludeFile "../../Commons/Networking/Connections.pbi"
XIncludeFile "../../Commons/Networking/SocketWait.pbi"
XIncludeFile "../../Commons/Threading/Signal.pbi"
XIncludeFile "../Config/Config.pbi"
XIncludeFile "../Storage/Storage.pbi"
XIncludeFile "../Storage/Names.pbi"


#BakaShrot_Net_ReceiveBufferSize = 65536

; How long a client gets to send each handshake packet.
#BakaShrot_Net_HandshakeTimeout = 10000

; Logs every push, read and query. Off: PrintN() costs ~0.4 ms per line and
; serializes every thread behind it, which capped a server at ~2400 pushes/s
; (12000/s without it, see Design/StorageConcurrency.md). The storage logs a
; summary every 10 s instead.
#BakaShrot_Net_LogRequests = #False


Structure BakaShrot_NetServer
	ServerId.i
	ThreadId.i
	*Config.BakaShrot_CoreConfig

	; Every client thread opens its own connection to it, and so does every
	; raw query, read-only.
	DatabasePath.s

	; This server's identity, from [BakaShrot] PrivateKey: signs the
	; handshake, and opens the Hellos sealed for it. Read-only once started,
	; every client thread uses them. Wiped when it stops.
	PrivateKey.a[#BakaShrot_Ed25519_PrivateKeySize]
	PublicKey.a[#BakaShrot_Ed25519_PublicKeySize]
	HelloKeys.BakaShrot_HelloKeys

	; Set by BakaShrot_NetServer_Stop(), makes every thread return.
	StopRequested.i

	; Guards Clients(), every client's Inbox, Disconnected and Overflowed,
	; ActiveClientThreads and the use of *Config\Clients().
	Mutex.i

	; Client threads that haven't finished yet.
	ActiveClientThreads.i

	; *BakaShrot_NetClient by Str(ClientId), for the listener to find them.
	; A client is removed when it disconnects or its thread closes it.
	Map Clients.i()
EndStructure


Structure BakaShrot_NetClient
	*Server.BakaShrot_NetServer
	ClientId.i

	; Filled by the listener thread, read by the client's thread.
	Inbox.BakaShrot_Inbox

	; Set by the listener thread.
	Disconnected.i
	Overflowed.i

	; Set by the listener thread whenever it changed the above, or the
	; inbox. The client's thread sleeps on it while waiting for a packet.
	; Freed by the client's thread, once it's out of Clients().
	Signal.i

	; Only used by the client's thread.
	Metadata.BakaShrot_ConnectionMetadata

	; Name of the [BakaShrot.Peer.<name>] the client authenticated as, ""
	; for a regular client. Only peers may replicate.
	PeerName.s

	; From the [BakaShrot.Client.<name>] the client authenticated as, copied
	; so this thread can look them up without the server's mutex.
	Permissions.BakaShrot_ClientPermissions
	PushTopics.BakaShrot_NameSet
	ReadTopics.BakaShrot_NameSet

	; From the [BakaShrot.Peer.<name>], for peers only.
	AcceptTopics.BakaShrot_NameSet
	AcceptNodes.BakaShrot_NameSet

	; [BakaShrot.Retention], for peers only: what they send that's already
	; past its max age isn't stored. A copy, lists aren't safe to walk from
	; several threads.
	List Retention.BakaShrot_RetentionRule()

	; This thread's own database connection, opened once authenticated.
	DbId.i
EndStructure


; Waits for the next packet from *Client, for up to TimeoutMs, 0 waits forever.
; Decrypted once the connection's cipher is set up, outside the server's
; mutex.
; Returns the packet (free it with FreeMemory) with its size in *OutSize\i,
; or 0 if the client disconnected, sent an invalid frame, one that doesn't
; decrypt or too much data, timed out, or the server is stopping. The
; reason is logged.
Procedure.i BakaShrot_NetClient_WaitPacket(*Client.BakaShrot_NetClient, *OutSize.Integer, TimeoutMs.i)
	Protected *Packet = 0, Result.i, Disconnected.i, Overflowed.i, StartTime.i

	StartTime = ElapsedMilliseconds()

	Repeat
		LockMutex(*Client\Server\Mutex)
		Disconnected = *Client\Disconnected
		Overflowed   = *Client\Overflowed
		Result = BakaShrot_Inbox_TakePacket(@*Client\Inbox, @*Packet, *OutSize)
		UnlockMutex(*Client\Server\Mutex)

		If Result = #BakaShrot_Inbox_Packet
			*Packet = BakaShrot_OpenFrame(@*Client\Metadata\Cipher, *Packet, *OutSize\i, *OutSize)
			If Not *Packet
				PrintN("[Net] Client " + Str(*Client\ClientId) + " sent a packet that doesn't decrypt")
			EndIf
			ProcedureReturn *Packet
		EndIf

		If Result = #BakaShrot_Inbox_Invalid
			PrintN("[Net] Client " + Str(*Client\ClientId) + " sent an invalid frame")
			ProcedureReturn 0
		EndIf

		If Overflowed
			PrintN("[Net] Client " + Str(*Client\ClientId) + " sent too much data")
			ProcedureReturn 0
		EndIf

		If Disconnected
			PrintN("[Net] Client " + Str(*Client\ClientId) + " disconnected")
			ProcedureReturn 0
		EndIf

		If *Client\Server\StopRequested
			PrintN("[Net] Client " + Str(*Client\ClientId) + " dropped, the server is stopping")
			ProcedureReturn 0
		EndIf

		If TimeoutMs > 0 And ElapsedMilliseconds() - StartTime > TimeoutMs
			PrintN("[Net] Client " + Str(*Client\ClientId) + " timed out")
			ProcedureReturn 0
		EndIf

		; Sleeps until the listener got something for it, waking up at least
		; every 50 ms to check the timeout and StopRequested.
		BakaShrot_Signal_Wait(*Client\Signal, 50)
	ForEver
EndProcedure


; Runs the server's side of the handshake, see Connections.pbi.
; Returns #True once the client is authenticated, #False if it must be aborted.
Procedure.i BakaShrot_NetClient_Authenticate(*Client.BakaShrot_NetClient)
	Protected *Server.BakaShrot_NetServer = *Client\Server
	Protected *Packet, PacketSize.Integer, *View.MsgPackData, *Sealed
	Protected *Hello.BakaShrot_AuthHello
	Protected Request.BakaShrot_ChallengeRequest
	Protected *Response.BakaShrot_ChallengeResponse
	Protected Accepted.BakaShrot_AuthAccepted
	Protected Proof.BakaShrot_ChallengeProof
	Protected KeyPair.BakaShrot_SessionKeyPair
	Protected TopicId.i, NodeId.i, PublicKey.s, ClientName.s, TopicRef.s, NodeRef.s
	Protected NonceMatches.i, SignatureDecoded.i, Sent.i, CipherReady.i

	*Client\Metadata\Status = #BakaShrot_ConnectionStatus_New
	CopyMemory(@*Server\PublicKey[0], @*Client\Metadata\ServerPublicKey[0], #BakaShrot_Ed25519_PublicKeySize)


	; 1. Hello, sealed for this server
	*Sealed = BakaShrot_NetClient_WaitPacket(*Client, @PacketSize, #BakaShrot_Net_HandshakeTimeout)
	If Not *Sealed
		ProcedureReturn #False
	EndIf
	*Packet = BakaShrot_Session_OpenHello(@*Server\HelloKeys, *Sealed, PacketSize\i, @PacketSize)
	FreeMemory(*Sealed)
	If Not *Packet
		PrintN("[Net] Client " + Str(*Client\ClientId) + " sent a hello that isn't sealed for this server (wrong ServerPublicKey?)")
		ProcedureReturn #False
	EndIf

	*Hello = 0
	*View = MsgPackWrapMsgBuffer(*Packet, PacketSize\i)
	If *View
		*Hello = BakaShrot_HelloPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*Packet)
	If Not *Hello
		PrintN("[Net] Client " + Str(*Client\ClientId) + " didn't send a valid hello")
		ProcedureReturn #False
	EndIf

	TopicRef  = *Hello\ClientTopic
	NodeRef   = *Hello\ClientNode
	PublicKey = *Hello\ClientPubKeyB64
	CopyMemory(@*Hello\ClientSessionKey[0], @*Client\Metadata\ClientSessionKey[0], #BakaShrot_SessionKeySize)
	FreeStructure(*Hello)

	TopicId = BakaShrot_Names_ResolveTopic(TopicRef)
	NodeId  = BakaShrot_Names_ResolveNode(NodeRef)
	If TopicId < 0 Or NodeId < 0
		PrintN("[Net] Client " + Str(*Client\ClientId) + " sent an unknown identity '" + Left(TopicRef, 80) + "':'" + Left(NodeRef, 80) + "'")
		ProcedureReturn #False
	EndIf

	If Not DecodeKeyFromString(PublicKey, @*Client\Metadata\PublicKey[0], #BakaShrot_Ed25519_PublicKeySize)
		PrintN("[Net] Client " + Str(*Client\ClientId) + " sent an invalid public key")
		ProcedureReturn #False
	EndIf

	LockMutex(*Server\Mutex)
	ClientName = FindClientName(*Server\Config, PublicKey, TopicId, NodeId)
	*Client\PeerName = FindPeerName(*Server\Config, PublicKey, TopicId, NodeId)
	If ClientName <> "" And FindMapElement(*Server\Config\Clients(), ClientName)
		*Client\Permissions\Read  = *Server\Config\Clients()\Permissions\Read
		*Client\Permissions\Write = *Server\Config\Clients()\Permissions\Write
		*Client\Permissions\Query = *Server\Config\Clients()\Permissions\Query
		CopyStructure(@*Server\Config\Clients()\PushTopics, @*Client\PushTopics, BakaShrot_NameSet)
		CopyStructure(@*Server\Config\Clients()\ReadTopics, @*Client\ReadTopics, BakaShrot_NameSet)
	EndIf
	If *Client\PeerName <> "" And FindMapElement(*Server\Config\Peers(), *Client\PeerName)
		CopyStructure(@*Server\Config\Peers()\AcceptTopics, @*Client\AcceptTopics, BakaShrot_NameSet)
		CopyStructure(@*Server\Config\Peers()\AcceptNodes, @*Client\AcceptNodes, BakaShrot_NameSet)
		CopyList(*Server\Config\Retention(), *Client\Retention())
	EndIf
	UnlockMutex(*Server\Mutex)
	If ClientName = ""
		PrintN("[Net] Client " + Str(*Client\ClientId) + " isn't allowed to use " + BakaShrot_Names_TopicRef(TopicId) + ":" + BakaShrot_Names_NodeRef(NodeId) + " with its public key")
		ProcedureReturn #False
	EndIf

	*Client\Metadata\TopicId = TopicId
	*Client\Metadata\NodeId  = NodeId


	; 2. Challenge request, in plain text, signed by this server
	If Not CryptRandomData(@*Client\Metadata\Challenge[0], #BakaShrot_ChallengeSize)
		PrintN("[Net] Failed to generate a challenge for client " + Str(*Client\ClientId))
		ProcedureReturn #False
	EndIf
	If Not CryptRandomData(@*Client\Metadata\Nonce[0], #BakaShrot_NonceSize)
		PrintN("[Net] Failed to generate a nonce for client " + Str(*Client\ClientId))
		ProcedureReturn #False
	EndIf

	BakaShrot_Session_NewKeyPair(@KeyPair)
	CopyMemory(@KeyPair\PublicKey[0], @*Client\Metadata\ServerSessionKey[0], #BakaShrot_SessionKeySize)

	BakaShrot_MakeHandshakeTranscript(@*Client\Metadata, #BakaShrot_TranscriptServerLabel, @Proof)
	If Not BakaShrot_SignHandshake(@Proof, @*Server\PrivateKey[0])
		BakaShrot_Session_ClearKeyPair(@KeyPair)
		PrintN("[Net] Failed to sign the handshake for client " + Str(*Client\ClientId))
		ProcedureReturn #False
	EndIf

	; This connection's keys, before anything else arrives: the client
	; encrypts everything after this.
	CipherReady = BakaShrot_Session_StartServer(@*Client\Metadata\Cipher, @KeyPair, @*Client\Metadata\ClientSessionKey[0])
	If Not CipherReady
		PrintN("[Net] Client " + Str(*Client\ClientId) + " sent an unusable session key")
		ProcedureReturn #False
	EndIf

	Request\ChallengeB64 = EncodeKeyToString(@*Client\Metadata\Challenge[0], #BakaShrot_ChallengeSize)
	CopyMemory(@*Client\Metadata\Nonce[0], @Request\Nonce[0], #BakaShrot_NonceSize)
	CopyMemory(@*Client\Metadata\ServerSessionKey[0], @Request\ServerSessionKey[0], #BakaShrot_SessionKeySize)
	CopyMemory(@Proof\Signature[0], @Request\ServerSignature[0], #BakaShrot_HandshakeSignatureSize)

	*Packet = BakaShrot_ChallengeRequestPacket_Encode(@Request, @PacketSize)
	If Not *Packet
		PrintN("[Net] Failed to encode the challenge request for client " + Str(*Client\ClientId))
		ProcedureReturn #False
	EndIf
	Sent = BakaShrot_SendPacket(*Client\ClientId, *Packet, PacketSize\i, 0)
	FreeMemory(*Packet)
	If Not Sent
		PrintN("[Net] Failed to send the challenge request to client " + Str(*Client\ClientId))
		ProcedureReturn #False
	EndIf

	*Client\Metadata\Status = #BakaShrot_ConnectionStatus_Challenged


	; 3. Challenge response, encrypted as everything from now on
	*Packet = BakaShrot_NetClient_WaitPacket(*Client, @PacketSize, #BakaShrot_Net_HandshakeTimeout)
	If Not *Packet
		ProcedureReturn #False
	EndIf

	*Response = 0
	*View = MsgPackWrapMsgBuffer(*Packet, PacketSize\i)
	If *View
		*Response = BakaShrot_ChallengeResponsePacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*Packet)
	If Not *Response
		PrintN("[Net] Client " + Str(*Client\ClientId) + " didn't send a valid challenge response")
		ProcedureReturn #False
	EndIf

	NonceMatches     = CompareMemory(@*Response\Nonce[0], @*Client\Metadata\Nonce[0], #BakaShrot_NonceSize)
	SignatureDecoded = DecodeKeyFromString(*Response\ChallengeResponseB64, @Proof\Signature[0], #BakaShrot_Ed25519_SignatureSize)
	FreeStructure(*Response)

	If Not NonceMatches
		PrintN("[Net] Client " + Str(*Client\ClientId) + " answered with the wrong nonce")
		ProcedureReturn #False
	EndIf

	If Not SignatureDecoded
		PrintN("[Net] Client " + Str(*Client\ClientId) + " sent an invalid signature")
		ProcedureReturn #False
	EndIf

	BakaShrot_MakeHandshakeTranscript(@*Client\Metadata, #BakaShrot_TranscriptClientLabel, @Proof)
	If Not BakaShrot_VerifyHandshake(@Proof, @*Client\Metadata\PublicKey[0])
		PrintN("[Net] Client " + Str(*Client\ClientId) + " failed the challenge")
		ProcedureReturn #False
	EndIf


	; 4. Accepted
	; Big packets from now on, set before it hears it's accepted: the listener
	; may get its first request right after.
	LockMutex(*Server\Mutex)
	BakaShrot_Inbox_Lift(@*Client\Inbox)
	UnlockMutex(*Server\Mutex)

	*Packet = BakaShrot_AuthAcceptedPacket_Encode(@Accepted, @PacketSize)
	If Not *Packet
		PrintN("[Net] Failed to encode the acceptance for client " + Str(*Client\ClientId))
		ProcedureReturn #False
	EndIf
	Sent = BakaShrot_SendPacket(*Client\ClientId, *Packet, PacketSize\i, @*Client\Metadata\Cipher)
	FreeMemory(*Packet)
	If Not Sent
		PrintN("[Net] Failed to send the acceptance to client " + Str(*Client\ClientId))
		ProcedureReturn #False
	EndIf

	*Client\Metadata\Status = #BakaShrot_ConnectionStatus_Authenticated
	If *Client\PeerName = ""
		PrintN("[Net] Client " + Str(*Client\ClientId) + " authenticated as '" + ClientName + "' " + BakaShrot_Names_TopicRef(TopicId) + ":" + BakaShrot_Names_NodeRef(NodeId))
	Else
		PrintN("[Net] Client " + Str(*Client\ClientId) + " authenticated as '" + ClientName + "' " + BakaShrot_Names_TopicRef(TopicId) + ":" + BakaShrot_Names_NodeRef(NodeId) + ", peer '" + *Client\PeerName + "'")
	EndIf

	ProcedureReturn #True
EndProcedure


; Encodes and sends a RequestRefused.
; Returns #False if it couldn't be sent, the client must then be aborted.
Procedure.i BakaShrot_NetClient_Refuse(*Client.BakaShrot_NetClient, Reason.s)
	Protected Refused.BakaShrot_RequestRefused
	Protected *Packet, PacketSize.Integer, Sent.i

	PrintN("[Net] Refused a request from client " + Str(*Client\ClientId) + ": " + Reason)

	Refused\Reason = Reason
	*Packet = BakaShrot_RequestRefusedPacket_Encode(@Refused, @PacketSize)
	If Not *Packet
		ProcedureReturn #False
	EndIf
	Sent = BakaShrot_SendPacket(*Client\ClientId, *Packet, PacketSize\i, @*Client\Metadata\Cipher)
	FreeMemory(*Packet)

	ProcedureReturn Sent
EndProcedure


; Stores the pushed message in the asked topic (its authenticated one if
; none) under the client's authenticated node, with the next message id for
; them, and answers with that id. JSON or not: SQLite flags it in is_json,
; nothing here looks inside it.
; Returns #False if the client must be aborted.
Procedure.i BakaShrot_NetClient_HandlePushMessage(*Client.BakaShrot_NetClient, *Packet, PacketSize.i)
	Protected *View.MsgPackData, *Push.BakaShrot_PushMessage
	Protected Pushed.BakaShrot_MessagePushed
	Protected JsonData.s, TopicRef.s, TopicId.i, JsonSize.i, MessageId.q, StoreError.String
	Protected *Answer, AnswerSize.Integer, Sent.i

	*Push = 0
	*View = MsgPackWrapMsgBuffer(*Packet, PacketSize)
	If *View
		*Push = BakaShrot_PushMessagePacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	If Not *Push
		PrintN("[Net] Client " + Str(*Client\ClientId) + " sent an invalid push")
		ProcedureReturn #False
	EndIf
	JsonData = *Push\JsonData
	TopicRef = *Push\Topic
	FreeStructure(*Push)

	; The node is the authenticated one, the client never sends it here.
	If *Client\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		PrintN("[Net] Client " + Str(*Client\ClientId) + " pushed without being authenticated")
		ProcedureReturn #False
	EndIf

	If Not *Client\Permissions\Write
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Not allowed to write")
	EndIf

	If TopicRef = ""
		TopicId = *Client\Metadata\TopicId
	Else
		TopicId = BakaShrot_Names_ResolveTopic(TopicRef)
		If TopicId < 0
			ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Unknown topic '" + Left(TopicRef, 80) + "'")
		EndIf
	EndIf
	If Not NameSetHas(@*Client\PushTopics, TopicId, BakaShrot_Names_TopicName(TopicId))
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Not allowed to push to topic '" + BakaShrot_Names_TopicRef(TopicId) + "'")
	EndIf

	; So it fits in every packet that carries it later, see Packets.pbi.
	JsonSize = StringByteLength(JsonData, #PB_UTF8)
	If JsonSize > #BakaShrot_MaxMessageSize
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "The message is too big: " + Str(JsonSize) + " bytes, at most " + Str(#BakaShrot_MaxMessageSize))
	EndIf

	; A topic allowed by "*" may be new here, it needs its row for the
	; "messages" view.
	If Not BakaShrot_Names_EnsureTopicId(TopicId, @StoreError)
		PrintN("[Net] Failed to register topic " + Str(TopicId) + ": " + StoreError\s)
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "The message couldn't be stored")
	EndIf

	MessageId = InsertNextMessage(TopicId, *Client\Metadata\NodeId, JsonData, @StoreError)
	If MessageId < 1
		PrintN("[Net] Failed to store a message from client " + Str(*Client\ClientId) + ": " + StoreError\s)
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "The message couldn't be stored")
	EndIf

	Pushed\MessageId = MessageId
	*Answer = BakaShrot_MessagePushedPacket_Encode(@Pushed, @AnswerSize)
	If Not *Answer
		ProcedureReturn #False
	EndIf
	Sent = BakaShrot_SendPacket(*Client\ClientId, *Answer, AnswerSize\i, @*Client\Metadata\Cipher)
	FreeMemory(*Answer)

	CompilerIf #BakaShrot_Net_LogRequests
		PrintN("[Net] Client " + Str(*Client\ClientId) + " pushed message " + Str(TopicId) + ":" + Str(*Client\Metadata\NodeId) + "#" + Str(MessageId))
	CompilerEndIf
	ProcedureReturn Sent
EndProcedure


; Answers with the latest message of the asked topic/node.
; Refuses if the client may not read that topic, if either is unknown, or if
; there's no message.
; Returns #False if the client must be aborted.
Procedure.i BakaShrot_NetClient_HandleGetLatestMessage(*Client.BakaShrot_NetClient, *Packet, PacketSize.i)
	Protected *View.MsgPackData, *Request.BakaShrot_GetLatestMessage
	Protected Latest.BakaShrot_LatestMessage
	Protected Message.BakaShrot_Message
	Protected TopicId.i, NodeId.i, TopicRef.s, NodeRef.s
	Protected *Answer, AnswerSize.Integer, Sent.i

	*Request = 0
	*View = MsgPackWrapMsgBuffer(*Packet, PacketSize)
	If *View
		*Request = BakaShrot_GetLatestMessagePacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	If Not *Request
		PrintN("[Net] Client " + Str(*Client\ClientId) + " sent an invalid latest message request")
		ProcedureReturn #False
	EndIf
	TopicRef = *Request\Topic
	NodeRef  = *Request\Node
	FreeStructure(*Request)

	If *Client\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		PrintN("[Net] Client " + Str(*Client\ClientId) + " asked for a message without being authenticated")
		ProcedureReturn #False
	EndIf

	If Not *Client\Permissions\Read
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Not allowed to read")
	EndIf

	TopicId = BakaShrot_Names_ResolveTopic(TopicRef)
	If TopicId < 0
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Unknown topic '" + Left(TopicRef, 80) + "'")
	EndIf
	If Not NameSetHas(@*Client\ReadTopics, TopicId, BakaShrot_Names_TopicName(TopicId))
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Not allowed to read topic '" + BakaShrot_Names_TopicRef(TopicId) + "'")
	EndIf
	NodeId = BakaShrot_Names_ResolveNode(NodeRef)
	If NodeId < 0
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Unknown node '" + Left(NodeRef, 80) + "'")
	EndIf

	If Not GetLatestMessage(*Client\DbId, TopicId, NodeId, @Message)
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "No message for " + BakaShrot_Names_TopicRef(TopicId) + ":" + BakaShrot_Names_NodeRef(NodeId))
	EndIf

	Latest\TopicId   = TopicId
	Latest\NodeId    = NodeId
	Latest\TopicName = BakaShrot_Names_TopicRef(TopicId)
	Latest\NodeName  = BakaShrot_Names_NodeRef(NodeId)
	Latest\MessageId = Message\MessageId
	Latest\PushedAt  = Message\PushedAt
	Latest\JsonData  = Message\JsonData
	*Answer = BakaShrot_LatestMessagePacket_Encode(@Latest, @AnswerSize)
	If Not *Answer
		ProcedureReturn #False
	EndIf
	Sent = BakaShrot_SendPacket(*Client\ClientId, *Answer, AnswerSize\i, @*Client\Metadata\Cipher)
	FreeMemory(*Answer)

	CompilerIf #BakaShrot_Net_LogRequests
		PrintN("[Net] Client " + Str(*Client\ClientId) + " got message " + Str(TopicId) + ":" + Str(NodeId) + "#" + Str(Message\MessageId))
	CompilerEndIf
	ProcedureReturn Sent
EndProcedure


; Answers with the messages of the asked topic/node after the asked id: as
; many as asked for that fit in about #BakaShrot_MessagesBatchBytes, a
; bigger one alone. None if there are no more, that isn't refused.
; Refuses if the client may not read that topic, or if either is unknown.
; Returns #False if the client must be aborted.
Procedure.i BakaShrot_NetClient_HandleGetMessages(*Client.BakaShrot_NetClient, *Packet, PacketSize.i)
	Protected *View.MsgPackData, *Request.BakaShrot_GetMessages
	Protected Answer.BakaShrot_Messages
	Protected NewList Messages.BakaShrot_Message()
	Protected TopicId.i, NodeId.i, TopicRef.s, NodeRef.s, AfterMessageId.q, Limit.i
	Protected More.Integer, BatchSize.i, MessageSize.i
	Protected *Answer, AnswerSize.Integer, Sent.i

	*Request = 0
	*View = MsgPackWrapMsgBuffer(*Packet, PacketSize)
	If *View
		*Request = BakaShrot_GetMessagesPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	If Not *Request
		PrintN("[Net] Client " + Str(*Client\ClientId) + " sent an invalid messages request")
		ProcedureReturn #False
	EndIf
	TopicRef       = *Request\Topic
	NodeRef        = *Request\Node
	AfterMessageId = *Request\AfterMessageId
	Limit          = *Request\Limit
	FreeStructure(*Request)

	If *Client\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		PrintN("[Net] Client " + Str(*Client\ClientId) + " asked for messages without being authenticated")
		ProcedureReturn #False
	EndIf

	If Not *Client\Permissions\Read
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Not allowed to read")
	EndIf

	TopicId = BakaShrot_Names_ResolveTopic(TopicRef)
	If TopicId < 0
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Unknown topic '" + Left(TopicRef, 80) + "'")
	EndIf
	If Not NameSetHas(@*Client\ReadTopics, TopicId, BakaShrot_Names_TopicName(TopicId))
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Not allowed to read topic '" + BakaShrot_Names_TopicRef(TopicId) + "'")
	EndIf
	NodeId = BakaShrot_Names_ResolveNode(NodeRef)
	If NodeId < 0
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Unknown node '" + Left(NodeRef, 80) + "'")
	EndIf

	; In characters, the bytes are counted below: never less than that.
	If Not GetMessagesAfter(*Client\DbId, TopicId, NodeId, AfterMessageId, Limit, #BakaShrot_MessagesBatchBytes, Messages(), @More)
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "The messages couldn't be read")
	EndIf

	; As many as fit in #BakaShrot_MessagesBatchBytes, the rest is for the
	; next request. A bigger message goes alone, it always fits in a packet.
	Answer\More = More\i
	BatchSize = #BakaShrot_MessagesOverhead
	ForEach Messages()
		MessageSize = #BakaShrot_MessagesMessageOverhead + StringByteLength(Messages()\JsonData, #PB_UTF8)
		If ListSize(Answer\Messages()) > 0 And (BatchSize + MessageSize > #BakaShrot_MessagesBatchBytes Or BatchSize + MessageSize > #BakaShrot_MaxPacketSize)
			Answer\More = #True
			Break
		EndIf
		BatchSize + MessageSize

		AddElement(Answer\Messages())
		Answer\Messages()\MessageId = Messages()\MessageId
		Answer\Messages()\PushedAt  = Messages()\PushedAt
		Answer\Messages()\JsonData  = Messages()\JsonData
	Next
	ClearList(Messages())

	Answer\TopicId   = TopicId
	Answer\NodeId    = NodeId
	Answer\TopicName = BakaShrot_Names_TopicRef(TopicId)
	Answer\NodeName  = BakaShrot_Names_NodeRef(NodeId)
	*Answer = BakaShrot_MessagesPacket_Encode(@Answer, @AnswerSize)
	If Not *Answer
		ProcedureReturn #False
	EndIf
	Sent = BakaShrot_SendPacket(*Client\ClientId, *Answer, AnswerSize\i, @*Client\Metadata\Cipher)
	FreeMemory(*Answer)

	CompilerIf #BakaShrot_Net_LogRequests
		PrintN("[Net] Client " + Str(*Client\ClientId) + " got " + Str(ListSize(Answer\Messages())) + " messages of " + Str(TopicId) + ":" + Str(NodeId) + " after #" + Str(AfterMessageId))
	CompilerEndIf
	ProcedureReturn Sent
EndProcedure


; Runs a raw read-only SQL query and answers with its rows as JSON, see
; RunReadOnlyQuery() in Storage/Storage.pbi.
; Refuses clients not allowed to query, and results too big for one packet.
; Returns #False if the client must be aborted.
Procedure.i BakaShrot_NetClient_HandleQuery(*Client.BakaShrot_NetClient, *Packet, PacketSize.i)
	Protected *View.MsgPackData, *Request.BakaShrot_QueryRequest
	Protected Result.BakaShrot_QueryResult
	Protected Sql.s, JsonResult.String, QueryError.String
	Protected *Answer, AnswerSize.Integer, Sent.i

	*Request = 0
	*View = MsgPackWrapMsgBuffer(*Packet, PacketSize)
	If *View
		*Request = BakaShrot_QueryRequestPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	If Not *Request
		PrintN("[Net] Client " + Str(*Client\ClientId) + " sent an invalid query")
		ProcedureReturn #False
	EndIf
	Sql = *Request\Sql
	FreeStructure(*Request)

	If Not *Client\Permissions\Query
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Not allowed to query")
	EndIf

	If Not RunReadOnlyQuery(*Client\Server\DatabasePath, Sql, @JsonResult, @QueryError)
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Query failed: " + QueryError\s)
	EndIf

	; Leaves room for the packet's own fields.
	If StringByteLength(JsonResult\s, #PB_UTF8) > #BakaShrot_MaxPacketSize - 64
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "The result is too big for one packet, add a LIMIT")
	EndIf

	Result\JsonResult = JsonResult\s
	*Answer = BakaShrot_QueryResultPacket_Encode(@Result, @AnswerSize)
	If Not *Answer
		ProcedureReturn #False
	EndIf
	Sent = BakaShrot_SendPacket(*Client\ClientId, *Answer, AnswerSize\i, @*Client\Metadata\Cipher)
	FreeMemory(*Answer)

	CompilerIf #BakaShrot_Net_LogRequests
		PrintN("[Net] Client " + Str(*Client\ClientId) + " ran a query, " + Str(AnswerSize\i) + " bytes of results")
	CompilerEndIf
	ProcedureReturn Sent
EndProcedure


; Answers with this server's id and name of a topic or node.
; Topics: only those the client may push to or read, unless it may query.
; Returns #False if the client must be aborted.
Procedure.i BakaShrot_NetClient_HandleResolveName(*Client.BakaShrot_NetClient, *Packet, PacketSize.i)
	Protected *View.MsgPackData, *Request.BakaShrot_ResolveName
	Protected Resolved.BakaShrot_NameResolved
	Protected Kind.i, Ref.s, Id.i
	Protected *Answer, AnswerSize.Integer, Sent.i

	*Request = 0
	*View = MsgPackWrapMsgBuffer(*Packet, PacketSize)
	If *View
		*Request = BakaShrot_ResolveNamePacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	If Not *Request
		PrintN("[Net] Client " + Str(*Client\ClientId) + " sent an invalid name request")
		ProcedureReturn #False
	EndIf
	Kind = *Request\Kind
	Ref  = *Request\Ref
	FreeStructure(*Request)

	If Kind = #BakaShrot_NameKind_Topic
		Id = BakaShrot_Names_ResolveTopic(Ref)
		If Id < 0
			ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Unknown topic '" + Left(Ref, 80) + "'")
		EndIf
		If Not *Client\Permissions\Query And Not NameSetHas(@*Client\PushTopics, Id, BakaShrot_Names_TopicName(Id)) And Not NameSetHas(@*Client\ReadTopics, Id, BakaShrot_Names_TopicName(Id))
			ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Unknown topic '" + Left(Ref, 80) + "'")
		EndIf
		Resolved\Name = BakaShrot_Names_TopicName(Id)
	Else
		Id = BakaShrot_Names_ResolveNode(Ref)
		If Id < 0
			ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Unknown node '" + Left(Ref, 80) + "'")
		EndIf
		Resolved\Name = BakaShrot_Names_NodeName(Id)
	EndIf

	Resolved\Kind = Kind
	Resolved\Id   = Id
	*Answer = BakaShrot_NameResolvedPacket_Encode(@Resolved, @AnswerSize)
	If Not *Answer
		ProcedureReturn #False
	EndIf
	Sent = BakaShrot_SendPacket(*Client\ClientId, *Answer, AnswerSize\i, @*Client\Metadata\Cipher)
	FreeMemory(*Answer)

	ProcedureReturn Sent
EndProcedure


; Lists every topic (those the client may push to or read, unless it may
; query) or node, with its id, name and origin, as many as fit in one packet.
; Returns #False if the client must be aborted.
Procedure.i BakaShrot_NetClient_HandleListNames(*Client.BakaShrot_NetClient, *Packet, PacketSize.i)
	Protected *View.MsgPackData, *Request.BakaShrot_ListNames
	Protected Answer.BakaShrot_NamesList, Visible.BakaShrot_NameSet
	Protected NewList All.BakaShrot_NameEntry()
	Protected Kind.i, Size.i, EntrySize.i
	Protected *Answer, AnswerSize.Integer, Sent.i

	*Request = 0
	*View = MsgPackWrapMsgBuffer(*Packet, PacketSize)
	If *View
		*Request = BakaShrot_ListNamesPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	If Not *Request
		PrintN("[Net] Client " + Str(*Client\ClientId) + " sent an invalid names list request")
		ProcedureReturn #False
	EndIf
	Kind = *Request\Kind
	FreeStructure(*Request)

	If Kind = #BakaShrot_NameKind_Topic And Not *Client\Permissions\Query
		; The topics it may push to or read.
		Visible\All   = Bool(*Client\PushTopics\All Or *Client\ReadTopics\All)
		Visible\Known = Bool(*Client\PushTopics\Known Or *Client\ReadTopics\Known)
		ForEach *Client\PushTopics\Ids()
			Visible\Ids(MapKey(*Client\PushTopics\Ids())) = #True
		Next
		ForEach *Client\ReadTopics\Ids()
			Visible\Ids(MapKey(*Client\ReadTopics\Ids())) = #True
		Next
		ForEach *Client\PushTopics\Patterns()
			AddElement(Visible\Patterns()) : Visible\Patterns() = *Client\PushTopics\Patterns()
		Next
		ForEach *Client\ReadTopics\Patterns()
			AddElement(Visible\Patterns()) : Visible\Patterns() = *Client\ReadTopics\Patterns()
		Next
		BakaShrot_Names_GetAll(Kind, All(), @Visible)
	Else
		BakaShrot_Names_GetAll(Kind, All())
	EndIf

	Answer\Kind = Kind
	Size = #BakaShrot_NamesListOverhead
	ForEach All()
		EntrySize = #BakaShrot_NamesListEntryOverhead + StringByteLength(All()\Name, #PB_UTF8) + StringByteLength(All()\Origin, #PB_UTF8)
		If Size + EntrySize > #BakaShrot_MaxPacketSize
			Answer\Truncated = #True
			Break
		EndIf
		Size + EntrySize
		AddElement(Answer\Entries())
		Answer\Entries()\Id     = All()\Id
		Answer\Entries()\Name   = All()\Name
		Answer\Entries()\Origin = All()\Origin
	Next

	*Answer = BakaShrot_NamesListPacket_Encode(@Answer, @AnswerSize)
	If Not *Answer
		ProcedureReturn #False
	EndIf
	Sent = BakaShrot_SendPacket(*Client\ClientId, *Answer, AnswerSize\i, @*Client\Metadata\Cipher)
	FreeMemory(*Answer)

	ProcedureReturn Sent
EndProcedure


; Answers a peer with this server's sync state, see SyncStatePacket.pbi:
; every name it knows and takes from that peer (its AcceptTopics and
; AcceptNodes), their wildcards, and the highest message id it has for each
; topic/node of those. Unnamed ones don't replicate.
; Refuses regular clients.
; Returns #False if the client must be aborted.
Procedure.i BakaShrot_NetClient_HandleSyncStateRequest(*Client.BakaShrot_NetClient, *Packet, PacketSize.i)
	Protected *View.MsgPackData, *Request.BakaShrot_SyncStateRequest
	Protected State.BakaShrot_SyncState
	Protected NewList AllPairs.BakaShrot_SyncPair()
	Protected NewMap Topics.i(), NewMap Nodes.i()
	Protected *Answer, AnswerSize.Integer, Sent.i

	*Request = 0
	*View = MsgPackWrapMsgBuffer(*Packet, PacketSize)
	If *View
		*Request = BakaShrot_SyncStateRequestPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	If Not *Request
		PrintN("[Net] Client " + Str(*Client\ClientId) + " sent an invalid sync state request")
		ProcedureReturn #False
	EndIf
	FreeStructure(*Request)

	If *Client\PeerName = ""
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Only peers can replicate")
	EndIf

	If Not GetSyncState(*Client\DbId, AllPairs())
		PrintN("[Net] Failed to read the sync state for peer '" + *Client\PeerName + "': " + DatabaseError())
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "The sync state couldn't be read")
	EndIf

	; Every name this server knows, the peer only sends those.
	BakaShrot_Names_GetNamed(#BakaShrot_NameKind_Topic, State\Topics(), @*Client\AcceptTopics)
	BakaShrot_Names_GetNamed(#BakaShrot_NameKind_Node, State\Nodes(), @*Client\AcceptNodes)
	If *Client\AcceptTopics\All
		AddElement(State\TopicPatterns()) : State\TopicPatterns() = "*"
	EndIf
	ForEach *Client\AcceptTopics\Patterns()
		AddElement(State\TopicPatterns()) : State\TopicPatterns() = *Client\AcceptTopics\Patterns()
	Next
	If *Client\AcceptNodes\All
		AddElement(State\NodePatterns()) : State\NodePatterns() = "*"
	EndIf
	ForEach *Client\AcceptNodes\Patterns()
		AddElement(State\NodePatterns()) : State\NodePatterns() = *Client\AcceptNodes\Patterns()
	Next
	ForEach State\Topics()
		Topics(Str(State\Topics()\Id)) = #True
	Next
	ForEach State\Nodes()
		Nodes(Str(State\Nodes()\Id)) = #True
	Next
	ForEach AllPairs()
		If FindMapElement(Topics(), Str(AllPairs()\TopicId)) And FindMapElement(Nodes(), Str(AllPairs()\NodeId))
			AddElement(State\Pairs())
			State\Pairs()\TopicId   = AllPairs()\TopicId
			State\Pairs()\NodeId    = AllPairs()\NodeId
			State\Pairs()\MessageId = AllPairs()\MessageId
		EndIf
	Next

	*Answer = BakaShrot_SyncStatePacket_Encode(@State, @AnswerSize)
	If Not *Answer
		PrintN("[Net] Failed to encode the sync state for peer '" + *Client\PeerName + "', is it too big?")
		ProcedureReturn #False
	EndIf
	Sent = BakaShrot_SendPacket(*Client\ClientId, *Answer, AnswerSize\i, @*Client\Metadata\Cipher)
	FreeMemory(*Answer)

	ProcedureReturn Sent
EndProcedure


; Stores a batch of messages a peer replicated, under this server's ids for
; their topic and node names and their original message ids, in one
; transaction, and answers with the last one's message id.
; Refuses regular clients, and topics or nodes this server doesn't take from
; that peer (AcceptTopics, AcceptNodes): only what's named on both servers
; replicates, unless a wildcard there takes a name this server doesn't have,
; which is then added, see Storage/Names.pbi. The sync state tells the peer
; what's taken here, so it doesn't send the rest in the first place.
; Messages already past the topic's max age here ([BakaShrot.Retention]) are
; skipped, but acknowledged like the others.
; Returns #False if the client must be aborted.
Procedure.i BakaShrot_NetClient_HandleReplicateMessages(*Client.BakaShrot_NetClient, *Packet, PacketSize.i)
	Protected *View.MsgPackData, *Batch.BakaShrot_ReplicateMessages
	Protected Pushed.BakaShrot_MessagePushed
	Protected TopicId.i, NodeId.i, TopicRef.s, NodeRef.s, LastMessageId.q, IsStored.i, StoreError.String
	Protected MaxAge.q, SkipBefore.q, Skipped.Integer
	Protected *Answer, AnswerSize.Integer, Sent.i

	*Batch = 0
	*View = MsgPackWrapMsgBuffer(*Packet, PacketSize)
	If *View
		*Batch = BakaShrot_ReplicateMessagesPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	If Not *Batch
		PrintN("[Net] Client " + Str(*Client\ClientId) + " sent an invalid batch of replicated messages")
		ProcedureReturn #False
	EndIf
	TopicRef = *Batch\Topic
	NodeRef  = *Batch\Node
	LastElement(*Batch\Messages())
	LastMessageId = *Batch\Messages()\MessageId

	If *Client\PeerName = ""
		FreeStructure(*Batch)
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Only peers can replicate")
	EndIf

	TopicId = BakaShrot_Names_TopicByName(TopicRef)
	If Not NameSetHas(@*Client\AcceptTopics, TopicId, TopicRef)
		FreeStructure(*Batch)
		BakaShrot_Names_NoteDropped(*Client\PeerName, "topic", TopicRef, "not taken here")
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Topic '" + TopicRef + "' isn't replicated here")
	EndIf
	NodeId = BakaShrot_Names_NodeByName(NodeRef)
	If Not NameSetHas(@*Client\AcceptNodes, NodeId, NodeRef)
		FreeStructure(*Batch)
		BakaShrot_Names_NoteDropped(*Client\PeerName, "node", NodeRef, "not taken here")
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "Node '" + NodeRef + "' isn't replicated here")
	EndIf

	; Taken by a wildcard, new here.
	If TopicId < 0
		TopicId = BakaShrot_Names_Ingest(#BakaShrot_NameKind_Topic, TopicRef, @StoreError)
	EndIf
	If TopicId >= 0 And NodeId < 0
		NodeId = BakaShrot_Names_Ingest(#BakaShrot_NameKind_Node, NodeRef, @StoreError)
	EndIf
	If TopicId < 0 Or NodeId < 0
		FreeStructure(*Batch)
		PrintN("[Net] Failed to add '" + TopicRef + "':'" + NodeRef + "' from peer '" + *Client\PeerName + "': " + StoreError\s)
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "The messages couldn't be stored")
	EndIf

	MaxAge = RetentionMaxAgeMs(*Client\Retention(), TopicId, TopicRef)
	If MaxAge > 0
		SkipBefore = BakaShrot_NowUtcMs() - MaxAge
	EndIf
	IsStored = InsertReplicatedMessages(TopicId, NodeId, *Batch\Messages(), @StoreError, SkipBefore, @Skipped)
	FreeStructure(*Batch)
	If #BakaShrot_Net_LogRequests And Skipped\i > 0
		PrintN("[Net] Skipped " + Str(Skipped\i) + " messages of " + TopicRef + ":" + NodeRef + " from peer '" + *Client\PeerName + "', past their max age here")
	EndIf
	If Not IsStored
		PrintN("[Net] Failed to store messages from peer '" + *Client\PeerName + "': " + StoreError\s)
		ProcedureReturn BakaShrot_NetClient_Refuse(*Client, "The messages couldn't be stored")
	EndIf

	Pushed\MessageId = LastMessageId
	*Answer = BakaShrot_MessagePushedPacket_Encode(@Pushed, @AnswerSize)
	If Not *Answer
		ProcedureReturn #False
	EndIf
	Sent = BakaShrot_SendPacket(*Client\ClientId, *Answer, AnswerSize\i, @*Client\Metadata\Cipher)
	FreeMemory(*Answer)

	ProcedureReturn Sent
EndProcedure


; Handles one request from an authenticated client.
; Returns #False if the client must be aborted.
Procedure.i BakaShrot_NetClient_HandleRequest(*Client.BakaShrot_NetClient, *Packet, PacketSize.i)
	Select BakaShrot_GetPacketType(*Packet, PacketSize)
		Case #BakaShrot_PacketType_PushMessage
			ProcedureReturn BakaShrot_NetClient_HandlePushMessage(*Client, *Packet, PacketSize)

		Case #BakaShrot_PacketType_GetLatestMessage
			ProcedureReturn BakaShrot_NetClient_HandleGetLatestMessage(*Client, *Packet, PacketSize)

		Case #BakaShrot_PacketType_GetMessages
			ProcedureReturn BakaShrot_NetClient_HandleGetMessages(*Client, *Packet, PacketSize)

		Case #BakaShrot_PacketType_QueryRequest
			ProcedureReturn BakaShrot_NetClient_HandleQuery(*Client, *Packet, PacketSize)

		Case #BakaShrot_PacketType_ResolveName
			ProcedureReturn BakaShrot_NetClient_HandleResolveName(*Client, *Packet, PacketSize)

		Case #BakaShrot_PacketType_ListNames
			ProcedureReturn BakaShrot_NetClient_HandleListNames(*Client, *Packet, PacketSize)

		Case #BakaShrot_PacketType_SyncStateRequest
			ProcedureReturn BakaShrot_NetClient_HandleSyncStateRequest(*Client, *Packet, PacketSize)

		Case #BakaShrot_PacketType_ReplicateMessages
			ProcedureReturn BakaShrot_NetClient_HandleReplicateMessages(*Client, *Packet, PacketSize)
	EndSelect

	PrintN("[Net] Client " + Str(*Client\ClientId) + " sent an unexpected packet")
	ProcedureReturn #False
EndProcedure


Procedure BakaShrot_NetClient_Thread(*Client.BakaShrot_NetClient)
	Protected *Server.BakaShrot_NetServer = *Client\Server
	Protected *Packet, PacketSize.Integer, Disconnected.i, Handled.i

	If BakaShrot_NetClient_Authenticate(*Client)
		*Client\DbId = OpenStorageDatabase(*Server\DatabasePath)
		If Not *Client\DbId
			PrintN("[Net] Failed to open the database for client " + Str(*Client\ClientId) + ": " + DatabaseError())
		EndIf
	EndIf

	If *Client\DbId
		Repeat
			*Packet = BakaShrot_NetClient_WaitPacket(*Client, @PacketSize, 0)
			If Not *Packet
				Break
			EndIf

			Handled = BakaShrot_NetClient_HandleRequest(*Client, *Packet, PacketSize\i)
			FreeMemory(*Packet)
			If Not Handled
				Break
			EndIf
		ForEver
	EndIf

	; Removes the client so the listener stops using it, unless it already did
	; because the client disconnected.
	LockMutex(*Server\Mutex)
	Disconnected = *Client\Disconnected
	If FindMapElement(*Server\Clients(), Str(*Client\ClientId))
		If *Server\Clients() = *Client
			DeleteMapElement(*Server\Clients())
		EndIf
	EndIf
	UnlockMutex(*Server\Mutex)

	If Disconnected
		*Client\Metadata\Status = #BakaShrot_ConnectionStatus_Disconnected
	Else
		*Client\Metadata\Status = #BakaShrot_ConnectionStatus_Aborted
		CloseNetworkConnection(*Client\ClientId)
		PrintN("[Net] Client " + Str(*Client\ClientId) + " aborted")
	EndIf

	If *Client\DbId
		CloseDatabase(*Client\DbId)
	EndIf
	BakaShrot_Inbox_Clear(@*Client\Inbox)
	BakaShrot_ClearConnectionMetadata(@*Client\Metadata)
	; Out of Clients(), the listener can't set it anymore.
	BakaShrot_Signal_Free(*Client\Signal)
	FreeStructure(*Client)

	LockMutex(*Server\Mutex)
	*Server\ActiveClientThreads - 1
	UnlockMutex(*Server\Mutex)
EndProcedure


; Called by the listener thread when a client connects.
Procedure BakaShrot_NetServer_AcceptClient(*Server.BakaShrot_NetServer, ClientId.i)
	Protected *Client.BakaShrot_NetClient

	*Client = AllocateStructure(BakaShrot_NetClient)
	If Not *Client
		PrintN("[Net] Out of memory, refusing client " + Str(ClientId))
		CloseNetworkConnection(ClientId)
		ProcedureReturn
	EndIf
	*Client\Server   = *Server
	*Client\ClientId = ClientId
	*Client\Signal   = BakaShrot_Signal_Create()
	If Not *Client\Signal
		PrintN("[Net] Failed to create a signal, refusing client " + Str(ClientId))
		FreeStructure(*Client)
		CloseNetworkConnection(ClientId)
		ProcedureReturn
	EndIf

	LockMutex(*Server\Mutex)
	*Server\Clients(Str(ClientId)) = *Client
	*Server\ActiveClientThreads + 1
	UnlockMutex(*Server\Mutex)

	If Not CreateThread(@BakaShrot_NetClient_Thread(), *Client)
		LockMutex(*Server\Mutex)
		DeleteMapElement(*Server\Clients(), Str(ClientId))
		*Server\ActiveClientThreads - 1
		UnlockMutex(*Server\Mutex)

		BakaShrot_Signal_Free(*Client\Signal)
		FreeStructure(*Client)
		CloseNetworkConnection(ClientId)
		PrintN("[Net] Failed to start a thread, refusing client " + Str(ClientId))
		ProcedureReturn
	EndIf

	PrintN("[Net] Client " + Str(ClientId) + " connected")
EndProcedure


; Called by the listener thread when a client sent data.
Procedure BakaShrot_NetServer_ReceiveClientData(*Server.BakaShrot_NetServer, ClientId.i, *Buffer)
	Protected *Client.BakaShrot_NetClient, Received.i

	; Done while holding the mutex, so the client's thread can't close the
	; connection in the middle of it.
	LockMutex(*Server\Mutex)
	If FindMapElement(*Server\Clients(), Str(ClientId))
		*Client = *Server\Clients()
		Received = ReceiveNetworkData(ClientId, *Buffer, #BakaShrot_Net_ReceiveBufferSize)
		If Received > 0
			If Not BakaShrot_Inbox_Append(@*Client\Inbox, *Buffer, Received)
				*Client\Overflowed = #True
			EndIf
			BakaShrot_Signal_Set(*Client\Signal)
		EndIf
	EndIf
	UnlockMutex(*Server\Mutex)
EndProcedure


; Called by the listener thread when a client disconnected.
Procedure BakaShrot_NetServer_DropClient(*Server.BakaShrot_NetServer, ClientId.i)
	Protected *Client.BakaShrot_NetClient

	LockMutex(*Server\Mutex)
	If FindMapElement(*Server\Clients(), Str(ClientId))
		*Client = *Server\Clients()
		*Client\Disconnected = #True
		BakaShrot_Signal_Set(*Client\Signal)
		DeleteMapElement(*Server\Clients())
	EndIf
	UnlockMutex(*Server\Mutex)
EndProcedure


; Sleeps until a client sends something, connects or disconnects, for up to
; TimeoutMs. *Set is just a buffer, reused to save allocating it every time.
Procedure BakaShrot_NetServer_WaitEvent(*Server.BakaShrot_NetServer, *Set.BakaShrot_SocketSet, TimeoutMs.i)
	Protected *Client.BakaShrot_NetClient

	BakaShrot_SocketSet_Clear(*Set)
	BakaShrot_SocketSet_Add(*Set, ServerID(*Server\ServerId))
	LockMutex(*Server\Mutex)
	ForEach *Server\Clients()
		*Client = *Server\Clients()
		BakaShrot_SocketSet_Add(*Set, ConnectionID(*Client\ClientId))
	Next
	UnlockMutex(*Server\Mutex)

	BakaShrot_SocketSet_Wait(*Set, TimeoutMs)
EndProcedure


Procedure BakaShrot_NetServer_Thread(*Server.BakaShrot_NetServer)
	Protected *Buffer, *Set.BakaShrot_SocketSet

	*Buffer = AllocateMemory(#BakaShrot_Net_ReceiveBufferSize)
	*Set    = AllocateStructure(BakaShrot_SocketSet)
	If Not *Buffer Or Not *Set
		PrintN("[Net] Failed to allocate the receive buffer")
		ProcedureReturn
	EndIf

	While Not *Server\StopRequested
		Select NetworkServerEvent(*Server\ServerId)

			Case #PB_NetworkEvent_Connect
				BakaShrot_NetServer_AcceptClient(*Server, EventClient())

			Case #PB_NetworkEvent_Data
				BakaShrot_NetServer_ReceiveClientData(*Server, EventClient(), *Buffer)

			Case #PB_NetworkEvent_Disconnect
				BakaShrot_NetServer_DropClient(*Server, EventClient())

			Default
				; Nothing left, sleeps until there's something, waking up at
				; least every 20 ms to check StopRequested.
				BakaShrot_NetServer_WaitEvent(*Server, *Set, 20)

		EndSelect
	Wend

	FreeStructure(*Set)
	FreeMemory(*Buffer)
EndProcedure


; Starts listening on Host:Port, an empty Host binds to every interface.
; Clients are authenticated against *Config's [BakaShrot.Client.<name>]
; sections, and their messages are stored in its [BakaShrot.Server]
; DatabasePath. *Config must outlive the server.
; Returns 0 on failure, stop the returned server with BakaShrot_NetServer_Stop().
Procedure.i BakaShrot_NetServer_Start(Host.s, Port.u, *Config.BakaShrot_CoreConfig)
	Protected *Server.BakaShrot_NetServer

	; Only needed before PureBasic 6.00.
	CompilerIf #PB_Compiler_Version < 600
		If Not InitNetwork()
			ProcedureReturn 0
		EndIf
	CompilerEndIf

	; Verifies the challenge responses.
	If Not InitCryptography()
		ProcedureReturn 0
	EndIf

	; Challenges and nonces come from it.
	If Not OpenCryptRandom()
		ProcedureReturn 0
	EndIf

	*Server = AllocateStructure(BakaShrot_NetServer)
	If Not *Server
		CloseCryptRandom()
		ProcedureReturn 0
	EndIf
	*Server\Config       = *Config
	*Server\DatabasePath = *Config\Server\DatabasePath

	; Its identity: clients seal their Hello for it, and check it signed the
	; handshake.
	If Not DecodeKeyFromString(*Config\PrivateKey, @*Server\PrivateKey[0], #BakaShrot_Ed25519_PrivateKeySize)
		PrintN("[Net] [BakaShrot] PrivateKey is missing or invalid")
		FreeStructure(*Server)
		CloseCryptRandom()
		ProcedureReturn 0
	EndIf
	GetPublicKeyFromPrivateKey(@*Server\PrivateKey[0], @*Server\PublicKey[0])
	If Not BakaShrot_Session_LoadHelloKeys(@*Server\HelloKeys, @*Server\PrivateKey[0])
		PrintN("[Net] [BakaShrot] PrivateKey can't be used to open hellos")
		sodium_memzero(@*Server\PrivateKey[0], #BakaShrot_Ed25519_PrivateKeySize)
		FreeStructure(*Server)
		CloseCryptRandom()
		ProcedureReturn 0
	EndIf
	; Clients need it as their ServerPublicKey.
	PrintN("[Net] Server public key: " + EncodeKeyToString(@*Server\PublicKey[0], #BakaShrot_Ed25519_PublicKeySize))

	*Server\Mutex = CreateMutex()
	If Not *Server\Mutex
		FreeStructure(*Server)
		CloseCryptRandom()
		ProcedureReturn 0
	EndIf

	If Host = ""
		*Server\ServerId = CreateNetworkServer(#PB_Any, Port, #PB_Network_TCP | #PB_Network_IPv4)
	Else
		*Server\ServerId = CreateNetworkServer(#PB_Any, Port, #PB_Network_TCP | #PB_Network_IPv4, Host)
	EndIf
	If Not *Server\ServerId
		FreeMutex(*Server\Mutex)
		FreeStructure(*Server)
		CloseCryptRandom()
		ProcedureReturn 0
	EndIf

	*Server\ThreadId = CreateThread(@BakaShrot_NetServer_Thread(), *Server)
	If Not *Server\ThreadId
		CloseNetworkServer(*Server\ServerId)
		FreeMutex(*Server\Mutex)
		FreeStructure(*Server)
		CloseCryptRandom()
		ProcedureReturn 0
	EndIf

	ProcedureReturn *Server
EndProcedure


; Stops every thread, closes the server and frees *Server.
; Connected clients are dropped. Once it returns, no client thread is left,
; so none holds a database connection either.
Procedure BakaShrot_NetServer_Stop(*Server.BakaShrot_NetServer)
	Protected ActiveClientThreads.i

	*Server\StopRequested = #True
	WaitThread(*Server\ThreadId)

	; Client threads notice StopRequested within a few ms and close their connection.
	Repeat
		LockMutex(*Server\Mutex)
		ActiveClientThreads = *Server\ActiveClientThreads
		UnlockMutex(*Server\Mutex)
		If ActiveClientThreads = 0
			Break
		EndIf
		Delay(5)
	ForEver

	CloseNetworkServer(*Server\ServerId)
	FreeMutex(*Server\Mutex)
	; Don't leave the private key lying around in freed memory.
	sodium_memzero(@*Server\PrivateKey[0], #BakaShrot_Ed25519_PrivateKeySize)
	BakaShrot_Session_ClearHelloKeys(@*Server\HelloKeys)
	FreeStructure(*Server)
	CloseCryptRandom()
EndProcedure
