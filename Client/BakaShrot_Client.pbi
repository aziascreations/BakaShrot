; ============================================================================
; BakaShrot Client DLL
;
; Lets an app connect to a BakaShrot server, one step at a time:
;   1. BakaShrot_SetPrivateKey(), BakaShrot_SetPublicKey(),
;      BakaShrot_SetServerPublicKey() (the server's, from its log or its
;      KeyGen output), BakaShrot_SetTopic() and BakaShrot_SetNode() (names
;      or ids), or BakaShrot_SetTopicId() and BakaShrot_SetNodeId()
;   2. BakaShrot_Connect(Host, Port), connects and authenticates, see the
;      handshake in Commons/Networking/Connections.pbi: only to the server
;      holding the private key of BakaShrot_SetServerPublicKey()'s, and
;      everything is encrypted
;   3. Requests, once connected:
;        BakaShrot_PushMessage(JsonData), into the client's own topic, or
;        BakaShrot_PushMessageTo(Topic, JsonData), returns the new
;          message's id
;        BakaShrot_GetLatestMessageOf(Topic, Node), or
;        BakaShrot_GetLatestMessage(TopicId, NodeId), then
;          BakaShrot_GetMessageId(), BakaShrot_GetMessageData(),
;          BakaShrot_GetMessageTopic() / BakaShrot_GetMessageNode() (names)
;          and BakaShrot_GetMessageTopicId() / BakaShrot_GetMessageNodeId()
;        BakaShrot_GetMessages(Topic, Node, AfterMessageId, Limit): the
;          messages after an id, returns how many came, then
;          BakaShrot_SelectMessage(Index) (0 is selected already) and the
;          same getters for each, BakaShrot_HasMoreMessages() if more
;          follow the last one
;        BakaShrot_ResolveTopic(Ref), BakaShrot_ResolveNode(Ref): the
;          server's id for a name (or the other way), then
;          BakaShrot_GetResolvedName()
;        BakaShrot_ListTopics(), BakaShrot_ListNodes(): every one with its
;          id and name, then BakaShrot_GetNamesList() as JSON
;        BakaShrot_Query(Sql), raw read-only SQL, then
;          BakaShrot_GetQueryResult()
;      If the server refuses a request, the connection stays open and
;      BakaShrot_GetRefusalReason() tells why.
;   4. BakaShrot_IsConnected(), BakaShrot_Disconnect()
;
; Topics and nodes are "refs": a name, or an id in digits, see
; Commons/Networking/Names.pbi. Ids are the server's own, each server can
; have different ones for the same names.
;
; The DLL holds a single connection.
; Every function returns #True (1) on success, #False (0) on failure, unless
; said otherwise.
;
; String getters copy into a caller-provided buffer of BufferSize bytes, and
; return the size in bytes needed for it, terminator included. Call them
; with a null *Buffer to get that size first. Nothing is copied if it
; doesn't fit.
;
; Functions taking strings come in two exported variants, like the Win32 API:
;   <Name>A  takes a null-terminated UTF-8 string (plain ASCII works too).
;   <Name>W  takes a null-terminated UTF-16 string (wchar_t* on Windows).
; Both only receive a pointer and read it with PeekS(), so apps built with
; any compiler or PureBasic version can call them.
;
; Apps should include BakaShrot_Client_Prototypes.pbi instead of this file.
; Compile as a shared DLL.
; ============================================================================

EnableExplicit

XIncludeFile "../Commons/Networking/Outbound.pbi"


Structure BakaShrot_ClientPrivateKey
	Bytes.a[#BakaShrot_Ed25519_PrivateKeySize]
EndStructure


Structure BakaShrot_ClientServerKey
	Bytes.a[#BakaShrot_Ed25519_PublicKeySize]
EndStructure


Global BakaShrot_PrivateKey.BakaShrot_ClientPrivateKey
Global BakaShrot_HasPrivateKey.i = #False
Global BakaShrot_PublicKey.s     = ""
Global BakaShrot_ServerPublicKey.BakaShrot_ClientServerKey
Global BakaShrot_HasServerPublicKey.i = #False
Global BakaShrot_Topic.s         = ""
Global BakaShrot_Node.s          = ""

; The connection, see Commons/Networking/Outbound.pbi.
Global BakaShrot_Outbound.BakaShrot_Outbound

; Filled by the requests, see BakaShrot_GetLatestMessage() and BakaShrot_GetRefusalReasonA/W().
Global BakaShrot_MessageId.q      = 0
Global BakaShrot_MessageData.s    = ""
Global BakaShrot_MessageTopicId.l = -1
Global BakaShrot_MessageNodeId.l  = -1
Global BakaShrot_MessageTopic.s   = ""
Global BakaShrot_MessageNode.s    = ""
Global BakaShrot_RefusalReason.s  = ""
Global BakaShrot_QueryResult.s    = ""
Global BakaShrot_ResolvedName.s   = ""
Global BakaShrot_NamesList.s      = ""

; Every message of the last answer, BakaShrot_GetMessages() or
; BakaShrot_GetLatestMessage(). The BakaShrot_Message* globals above are the
; selected one, see BakaShrot_SelectMessage().
Global NewList BakaShrot_Messages.BakaShrot_MessagesEntry()
Global BakaShrot_MessagesMore.i   = #False


; Sets the Ed25519 private key (Base64) used to answer the server's challenge.
; Must be done before connecting.
Procedure.i BakaShrot_SetPrivateKeyString(PrivateKey.s)
	If BakaShrot_Outbound\ConnectionId
		ProcedureReturn #False
	EndIf

	If Not DecodeKeyFromString(PrivateKey, @BakaShrot_PrivateKey\Bytes[0], #BakaShrot_Ed25519_PrivateKeySize)
		ProcedureReturn #False
	EndIf

	BakaShrot_HasPrivateKey = #True
	ProcedureReturn #True
EndProcedure

ProcedureCDLL.i BakaShrot_SetPrivateKeyA(*PrivateKey)
	If Not *PrivateKey
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_SetPrivateKeyString(PeekS(*PrivateKey, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.i BakaShrot_SetPrivateKeyW(*PrivateKey)
	If Not *PrivateKey
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_SetPrivateKeyString(PeekS(*PrivateKey, -1, #PB_Unicode))
EndProcedure


; Sets the Ed25519 public key (Base64) sent to the server in the Hello.
; Must be done before connecting.
Procedure.i BakaShrot_SetPublicKeyString(PublicKey.s)
	If BakaShrot_Outbound\ConnectionId
		ProcedureReturn #False
	EndIf

	If PublicKey = ""
		ProcedureReturn #False
	EndIf

	BakaShrot_PublicKey = PublicKey
	ProcedureReturn #True
EndProcedure

ProcedureCDLL.i BakaShrot_SetPublicKeyA(*PublicKey)
	If Not *PublicKey
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_SetPublicKeyString(PeekS(*PublicKey, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.i BakaShrot_SetPublicKeyW(*PublicKey)
	If Not *PublicKey
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_SetPublicKeyString(PeekS(*PublicKey, -1, #PB_Unicode))
EndProcedure


; Sets the server's Ed25519 public key (Base64): the Hello is sealed for it,
; and the server must prove it holds the matching private key.
; Must be done before connecting.
Procedure.i BakaShrot_SetServerPublicKeyString(PublicKey.s)
	If BakaShrot_Outbound\ConnectionId
		ProcedureReturn #False
	EndIf

	If Not DecodeKeyFromString(PublicKey, @BakaShrot_ServerPublicKey\Bytes[0], #BakaShrot_Ed25519_PublicKeySize)
		ProcedureReturn #False
	EndIf

	BakaShrot_HasServerPublicKey = #True
	ProcedureReturn #True
EndProcedure

ProcedureCDLL.i BakaShrot_SetServerPublicKeyA(*PublicKey)
	If Not *PublicKey
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_SetServerPublicKeyString(PeekS(*PublicKey, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.i BakaShrot_SetServerPublicKeyW(*PublicKey)
	If Not *PublicKey
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_SetServerPublicKeyString(PeekS(*PublicKey, -1, #PB_Unicode))
EndProcedure


; Sets the topic the client identifies as, a name or an id in digits.
; Must be done before connecting.
Procedure.i BakaShrot_SetTopicString(Topic.s)
	If BakaShrot_Outbound\ConnectionId Or Not BakaShrot_IsValidRef(Topic)
		ProcedureReturn #False
	EndIf
	BakaShrot_Topic = Topic
	ProcedureReturn #True
EndProcedure

ProcedureCDLL.i BakaShrot_SetTopicA(*Topic)
	If Not *Topic
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_SetTopicString(PeekS(*Topic, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.i BakaShrot_SetTopicW(*Topic)
	If Not *Topic
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_SetTopicString(PeekS(*Topic, -1, #PB_Unicode))
EndProcedure

; Same, by id, 0-65535.
ProcedureCDLL.i BakaShrot_SetTopicId(TopicId.l)
	If TopicId < 0 Or TopicId > 65535
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_SetTopicString(Str(TopicId))
EndProcedure


; Sets the node the client identifies as, a name or an id in digits.
; Must be done before connecting.
Procedure.i BakaShrot_SetNodeString(Node.s)
	If BakaShrot_Outbound\ConnectionId Or Not BakaShrot_IsValidRef(Node)
		ProcedureReturn #False
	EndIf
	BakaShrot_Node = Node
	ProcedureReturn #True
EndProcedure

ProcedureCDLL.i BakaShrot_SetNodeA(*Node)
	If Not *Node
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_SetNodeString(PeekS(*Node, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.i BakaShrot_SetNodeW(*Node)
	If Not *Node
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_SetNodeString(PeekS(*Node, -1, #PB_Unicode))
EndProcedure

; Same, by id, 0-65535.
ProcedureCDLL.i BakaShrot_SetNodeId(NodeId.l)
	If NodeId < 0 Or NodeId > 65535
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_SetNodeString(Str(NodeId))
EndProcedure


; Connects to Host:Port and authenticates with the settings above, see
; BakaShrot_Outbound_Connect() in Commons/Networking/Outbound.pbi.
; Fails if already connected, if a setting is missing, or if anything in the
; handshake is out of order or unexpected, in which case the connection is
; closed.
Procedure.i BakaShrot_ConnectString(Host.s, Port.l)
	Protected Identity.BakaShrot_OutboundIdentity

	If BakaShrot_Outbound\ConnectionId
		ProcedureReturn #False
	EndIf

	If Not BakaShrot_HasPrivateKey Or BakaShrot_PublicKey = "" Or Not BakaShrot_HasServerPublicKey Or BakaShrot_Topic = "" Or BakaShrot_Node = ""
		ProcedureReturn #False
	EndIf

	Identity\Topic      = BakaShrot_Topic
	Identity\Node       = BakaShrot_Node
	Identity\PublicKey  = BakaShrot_PublicKey
	Identity\PrivateKey = @BakaShrot_PrivateKey\Bytes[0]

	ProcedureReturn BakaShrot_Outbound_Connect(@BakaShrot_Outbound, Host, Port, @Identity, @BakaShrot_ServerPublicKey\Bytes[0])
EndProcedure

ProcedureCDLL.i BakaShrot_ConnectA(*Host, Port.l)
	If Not *Host
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_ConnectString(PeekS(*Host, -1, #PB_UTF8), Port)
EndProcedure

ProcedureCDLL.i BakaShrot_ConnectW(*Host, Port.l)
	If Not *Host
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_ConnectString(PeekS(*Host, -1, #PB_Unicode), Port)
EndProcedure


; Returns #True while the connection is open and authenticated.
; Notices when the server closed it.
ProcedureCDLL.i BakaShrot_IsConnected()
	ProcedureReturn BakaShrot_Outbound_IsConnected(@BakaShrot_Outbound)
EndProcedure


; Closes the connection, if any. The settings are kept.
ProcedureCDLL.i BakaShrot_Disconnect()
	If Not BakaShrot_Outbound\ConnectionId
		ProcedureReturn #False
	EndIf

	BakaShrot_Outbound_Close(@BakaShrot_Outbound, #BakaShrot_ConnectionStatus_Disconnected)
	ProcedureReturn #True
EndProcedure


; --- Requests ----------------------------------------------------------------

; Closes the connection after something went wrong in a request.
Procedure BakaShrot_AbortConnection()
	BakaShrot_Outbound_Close(@BakaShrot_Outbound, #BakaShrot_ConnectionStatus_Aborted)
EndProcedure


; Sends a request and waits for its answer.
; Returns the answer (free it with FreeMemory) with its size in *OutSize\i,
; or 0 if the connection failed, in which case it's closed.
; A refusal is returned like any other answer.
Procedure.i BakaShrot_SendRequest(*Request, RequestSize.i, *OutSize.Integer)
	Protected *Answer

	If Not BakaShrot_Outbound_Send(@BakaShrot_Outbound, *Request, RequestSize)
		BakaShrot_AbortConnection()
		ProcedureReturn 0
	EndIf

	*Answer = BakaShrot_Outbound_WaitPacket(@BakaShrot_Outbound, *OutSize, #BakaShrot_Outbound_Timeout)
	If Not *Answer
		BakaShrot_AbortConnection()
		ProcedureReturn 0
	EndIf

	ProcedureReturn *Answer
EndProcedure


; Reads a RequestRefused answer into BakaShrot_RefusalReason.
; Returns #False if it's malformed, the connection must then be aborted.
Procedure.i BakaShrot_ReadRefusal(*Answer, AnswerSize.i)
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

	BakaShrot_RefusalReason = *Refused\Reason
	FreeStructure(*Refused)
	ProcedureReturn #True
EndProcedure


; Copies Text into *Buffer as a null-terminated string in Format
; (#PB_UTF8 or #PB_Unicode), if it fits in BufferSize bytes.
; Returns the size in bytes needed for it, terminator included.
Procedure.i BakaShrot_CopyString(Text.s, *Buffer, BufferSize.i, Format.i)
	Protected NeededSize.i

	If Format = #PB_UTF8
		NeededSize = StringByteLength(Text, #PB_UTF8) + 1
	Else
		NeededSize = StringByteLength(Text, #PB_Unicode) + 2
	EndIf

	If *Buffer And BufferSize >= NeededSize
		PokeS(*Buffer, Text, -1, Format)
	EndIf

	ProcedureReturn NeededSize
EndProcedure


; Pushes a message (JSON or anything else, the server flags which in its
; is_json column) into Topic (a name or an id, "" for the client's own
; topic), the server stores it under that topic and this client's node, with
; the next message id. The client's PushTopics on the server must allow it.
; Returns the new message's id (1 or more), or -1 on failure.
; On -1, BakaShrot_IsConnected() tells if the server refused it (still
; connected, see BakaShrot_GetRefusalReason()) or if the connection failed.
Procedure.q BakaShrot_PushMessageToString(Topic.s, JsonData.s)
	Protected Push.BakaShrot_PushMessage
	Protected *Pushed.BakaShrot_MessagePushed
	Protected *Request, RequestSize.Integer, *Answer, AnswerSize.Integer
	Protected *View.MsgPackData, IsRefusal.i, MessageId.q

	BakaShrot_RefusalReason = ""

	If Not BakaShrot_Outbound\ConnectionId Or BakaShrot_Outbound\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		ProcedureReturn -1
	EndIf

	If Topic <> "" And Not BakaShrot_IsValidRef(Topic)
		ProcedureReturn -1
	EndIf

	; Refused here rather than sent for nothing, same reason as the server's.
	If StringByteLength(JsonData, #PB_UTF8) > #BakaShrot_MaxMessageSize
		BakaShrot_RefusalReason = "The message is too big: " + Str(StringByteLength(JsonData, #PB_UTF8)) + " bytes, at most " + Str(#BakaShrot_MaxMessageSize)
		ProcedureReturn -1
	EndIf

	Push\Topic    = Topic
	Push\JsonData = JsonData
	*Request = BakaShrot_PushMessagePacket_Encode(@Push, @RequestSize)
	If Not *Request
		ProcedureReturn -1
	EndIf
	*Answer = BakaShrot_SendRequest(*Request, RequestSize\i, @AnswerSize)
	FreeMemory(*Request)
	If Not *Answer
		ProcedureReturn -1
	EndIf

	If BakaShrot_GetPacketType(*Answer, AnswerSize\i) = #BakaShrot_PacketType_RequestRefused
		IsRefusal = BakaShrot_ReadRefusal(*Answer, AnswerSize\i)
		FreeMemory(*Answer)
		If Not IsRefusal
			BakaShrot_AbortConnection()
		EndIf
		ProcedureReturn -1
	EndIf

	*Pushed = 0
	*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
	If *View
		*Pushed = BakaShrot_MessagePushedPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*Answer)
	If Not *Pushed
		BakaShrot_AbortConnection()
		ProcedureReturn -1
	EndIf

	MessageId = *Pushed\MessageId
	FreeStructure(*Pushed)
	ProcedureReturn MessageId
EndProcedure

; A null *JsonData is an empty message (stored, is_json = 0): PureBasic
; passes empty strings to a DLL as null pointers.
ProcedureCDLL.q BakaShrot_PushMessageA(*JsonData)
	If Not *JsonData
		ProcedureReturn BakaShrot_PushMessageToString("", "")
	EndIf
	ProcedureReturn BakaShrot_PushMessageToString("", PeekS(*JsonData, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.q BakaShrot_PushMessageW(*JsonData)
	If Not *JsonData
		ProcedureReturn BakaShrot_PushMessageToString("", "")
	EndIf
	ProcedureReturn BakaShrot_PushMessageToString("", PeekS(*JsonData, -1, #PB_Unicode))
EndProcedure

; A null *Topic is the client's own topic, like "", and a null *JsonData an
; empty message: PureBasic passes empty strings to a DLL as null pointers.
ProcedureCDLL.q BakaShrot_PushMessageToA(*Topic, *JsonData)
	Protected Topic.s, JsonData.s
	If *Topic
		Topic = PeekS(*Topic, -1, #PB_UTF8)
	EndIf
	If *JsonData
		JsonData = PeekS(*JsonData, -1, #PB_UTF8)
	EndIf
	ProcedureReturn BakaShrot_PushMessageToString(Topic, JsonData)
EndProcedure

ProcedureCDLL.q BakaShrot_PushMessageToW(*Topic, *JsonData)
	Protected Topic.s, JsonData.s
	If *Topic
		Topic = PeekS(*Topic, -1, #PB_Unicode)
	EndIf
	If *JsonData
		JsonData = PeekS(*JsonData, -1, #PB_Unicode)
	EndIf
	ProcedureReturn BakaShrot_PushMessageToString(Topic, JsonData)
EndProcedure


; Asks for the latest message of a topic/node, each a name or an id. The
; server refuses if the client's ReadTopics don't allow the topic, if
; either is unknown, or if there's no message.
; On success, read it with BakaShrot_GetMessageId(), BakaShrot_GetMessageData(),
; BakaShrot_GetMessageTopic/Node() and BakaShrot_GetMessageTopicId/NodeId().
; On failure, BakaShrot_IsConnected() tells if it was refused (see
; BakaShrot_GetRefusalReason()) or if the connection failed.
Procedure.i BakaShrot_GetLatestMessageOfString(Topic.s, Node.s)
	Protected Request.BakaShrot_GetLatestMessage
	Protected *Latest.BakaShrot_LatestMessage
	Protected *Packet, PacketSize.Integer, *Answer, AnswerSize.Integer
	Protected *View.MsgPackData, IsRefusal.i, IsExpected.i

	BakaShrot_RefusalReason = ""
	BakaShrot_MessageId     = 0
	BakaShrot_MessageData   = ""
	BakaShrot_MessageTopicId = -1
	BakaShrot_MessageNodeId  = -1
	BakaShrot_MessageTopic   = ""
	BakaShrot_MessageNode    = ""
	ClearList(BakaShrot_Messages())
	BakaShrot_MessagesMore   = #False

	If Not BakaShrot_Outbound\ConnectionId Or BakaShrot_Outbound\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		ProcedureReturn #False
	EndIf

	If Not BakaShrot_IsValidRef(Topic) Or Not BakaShrot_IsValidRef(Node)
		ProcedureReturn #False
	EndIf

	Request\Topic = Topic
	Request\Node  = Node
	*Packet = BakaShrot_GetLatestMessagePacket_Encode(@Request, @PacketSize)
	If Not *Packet
		ProcedureReturn #False
	EndIf
	*Answer = BakaShrot_SendRequest(*Packet, PacketSize\i, @AnswerSize)
	FreeMemory(*Packet)
	If Not *Answer
		ProcedureReturn #False
	EndIf

	If BakaShrot_GetPacketType(*Answer, AnswerSize\i) = #BakaShrot_PacketType_RequestRefused
		IsRefusal = BakaShrot_ReadRefusal(*Answer, AnswerSize\i)
		FreeMemory(*Answer)
		If Not IsRefusal
			BakaShrot_AbortConnection()
		EndIf
		ProcedureReturn #False
	EndIf

	*Latest = 0
	*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
	If *View
		*Latest = BakaShrot_LatestMessagePacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*Answer)
	If Not *Latest
		BakaShrot_AbortConnection()
		ProcedureReturn #False
	EndIf

	; An answer about another topic/node is out of order.
	IsExpected = Bool(BakaShrot_RefMatches(Topic, *Latest\TopicId, *Latest\TopicName) And BakaShrot_RefMatches(Node, *Latest\NodeId, *Latest\NodeName))
	If IsExpected
		BakaShrot_MessageId      = *Latest\MessageId
		BakaShrot_MessageData    = *Latest\JsonData
		BakaShrot_MessageTopicId = *Latest\TopicId
		BakaShrot_MessageNodeId  = *Latest\NodeId
		BakaShrot_MessageTopic   = *Latest\TopicName
		BakaShrot_MessageNode    = *Latest\NodeName
		AddElement(BakaShrot_Messages())
		BakaShrot_Messages()\MessageId = *Latest\MessageId
		BakaShrot_Messages()\JsonData  = *Latest\JsonData
	EndIf
	FreeStructure(*Latest)
	If Not IsExpected
		BakaShrot_AbortConnection()
		ProcedureReturn #False
	EndIf

	ProcedureReturn #True
EndProcedure


ProcedureCDLL.i BakaShrot_GetLatestMessageOfA(*Topic, *Node)
	If Not *Topic Or Not *Node
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_GetLatestMessageOfString(PeekS(*Topic, -1, #PB_UTF8), PeekS(*Node, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.i BakaShrot_GetLatestMessageOfW(*Topic, *Node)
	If Not *Topic Or Not *Node
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_GetLatestMessageOfString(PeekS(*Topic, -1, #PB_Unicode), PeekS(*Node, -1, #PB_Unicode))
EndProcedure

; Same, by ids, 0-65535.
ProcedureCDLL.i BakaShrot_GetLatestMessage(TopicId.l, NodeId.l)
	If TopicId < 0 Or TopicId > 65535 Or NodeId < 0 Or NodeId > 65535
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_GetLatestMessageOfString(Str(TopicId), Str(NodeId))
EndProcedure


; Asks for the messages of a topic/node (each a name or an id) stored after
; AfterMessageId (0 for the first ones), in message id order: at most Limit
; (1-10000), fewer if they didn't fit in about 1 MB, a bigger one alone. The
; server refuses if the client's ReadTopics don't allow the topic, or if
; either is unknown. No more messages isn't a refusal, it returns 0.
; Returns how many came (0 or more), or -1 on failure: BakaShrot_IsConnected()
; tells if it was refused (see BakaShrot_GetRefusalReason()) or if the
; connection failed.
; On success, the first one is selected: read it with BakaShrot_GetMessageId(),
; BakaShrot_GetMessageData() and the others, select the next ones with
; BakaShrot_SelectMessage(). BakaShrot_GetMessageTopic/Node/TopicId/NodeId()
; are set even if none came. BakaShrot_HasMoreMessages() tells if more
; follow the last one: ask again after its id.
Procedure.l BakaShrot_GetMessagesString(Topic.s, Node.s, AfterMessageId.q, Limit.l)
	Protected Request.BakaShrot_GetMessages
	Protected *Answer.BakaShrot_Messages
	Protected *Packet, PacketSize.Integer, *AnswerPacket, AnswerSize.Integer
	Protected *View.MsgPackData, IsRefusal.i, IsExpected.i, Count.l

	BakaShrot_RefusalReason  = ""
	BakaShrot_MessageId      = 0
	BakaShrot_MessageData    = ""
	BakaShrot_MessageTopicId = -1
	BakaShrot_MessageNodeId  = -1
	BakaShrot_MessageTopic   = ""
	BakaShrot_MessageNode    = ""
	ClearList(BakaShrot_Messages())
	BakaShrot_MessagesMore   = #False

	If Not BakaShrot_Outbound\ConnectionId Or BakaShrot_Outbound\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		ProcedureReturn -1
	EndIf

	If Not BakaShrot_IsValidRef(Topic) Or Not BakaShrot_IsValidRef(Node)
		ProcedureReturn -1
	EndIf
	If AfterMessageId < 0 Or Limit < 1 Or Limit > #BakaShrot_MaxGetMessages
		ProcedureReturn -1
	EndIf

	Request\Topic          = Topic
	Request\Node           = Node
	Request\AfterMessageId = AfterMessageId
	Request\Limit          = Limit
	*Packet = BakaShrot_GetMessagesPacket_Encode(@Request, @PacketSize)
	If Not *Packet
		ProcedureReturn -1
	EndIf
	*AnswerPacket = BakaShrot_SendRequest(*Packet, PacketSize\i, @AnswerSize)
	FreeMemory(*Packet)
	If Not *AnswerPacket
		ProcedureReturn -1
	EndIf

	If BakaShrot_GetPacketType(*AnswerPacket, AnswerSize\i) = #BakaShrot_PacketType_RequestRefused
		IsRefusal = BakaShrot_ReadRefusal(*AnswerPacket, AnswerSize\i)
		FreeMemory(*AnswerPacket)
		If Not IsRefusal
			BakaShrot_AbortConnection()
		EndIf
		ProcedureReturn -1
	EndIf

	*Answer = 0
	*View = MsgPackWrapMsgBuffer(*AnswerPacket, AnswerSize\i)
	If *View
		*Answer = BakaShrot_MessagesPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*AnswerPacket)
	If Not *Answer
		BakaShrot_AbortConnection()
		ProcedureReturn -1
	EndIf

	; An answer about another topic/node, with more messages than asked for,
	; or with ones that aren't after AfterMessageId, is out of order.
	IsExpected = Bool(BakaShrot_RefMatches(Topic, *Answer\TopicId, *Answer\TopicName) And BakaShrot_RefMatches(Node, *Answer\NodeId, *Answer\NodeName))
	If IsExpected And ListSize(*Answer\Messages()) > Limit
		IsExpected = #False
	EndIf
	If IsExpected And FirstElement(*Answer\Messages())
		If *Answer\Messages()\MessageId <= AfterMessageId
			IsExpected = #False
		EndIf
	EndIf
	If Not IsExpected
		FreeStructure(*Answer)
		BakaShrot_AbortConnection()
		ProcedureReturn -1
	EndIf

	BakaShrot_MessageTopicId = *Answer\TopicId
	BakaShrot_MessageNodeId  = *Answer\NodeId
	BakaShrot_MessageTopic   = *Answer\TopicName
	BakaShrot_MessageNode    = *Answer\NodeName
	BakaShrot_MessagesMore   = *Answer\More
	CopyList(*Answer\Messages(), BakaShrot_Messages())
	Count = ListSize(BakaShrot_Messages())
	FreeStructure(*Answer)

	If FirstElement(BakaShrot_Messages())
		BakaShrot_MessageId   = BakaShrot_Messages()\MessageId
		BakaShrot_MessageData = BakaShrot_Messages()\JsonData
	EndIf
	ProcedureReturn Count
EndProcedure

ProcedureCDLL.l BakaShrot_GetMessagesA(*Topic, *Node, AfterMessageId.q, Limit.l)
	If Not *Topic Or Not *Node
		ProcedureReturn -1
	EndIf
	ProcedureReturn BakaShrot_GetMessagesString(PeekS(*Topic, -1, #PB_UTF8), PeekS(*Node, -1, #PB_UTF8), AfterMessageId, Limit)
EndProcedure

ProcedureCDLL.l BakaShrot_GetMessagesW(*Topic, *Node, AfterMessageId.q, Limit.l)
	If Not *Topic Or Not *Node
		ProcedureReturn -1
	EndIf
	ProcedureReturn BakaShrot_GetMessagesString(PeekS(*Topic, -1, #PB_Unicode), PeekS(*Node, -1, #PB_Unicode), AfterMessageId, Limit)
EndProcedure

; How many messages the last BakaShrot_GetMessages() or
; BakaShrot_GetLatestMessage() got, 0 if it failed.
ProcedureCDLL.l BakaShrot_GetMessageCount()
	ProcedureReturn ListSize(BakaShrot_Messages())
EndProcedure

; Selects the message at Index (0 to BakaShrot_GetMessageCount() - 1) of the
; last answer, for BakaShrot_GetMessageId() and BakaShrot_GetMessageData().
; Returns #False if there's none at Index, the selection doesn't change then.
ProcedureCDLL.i BakaShrot_SelectMessage(Index.l)
	If Index < 0 Or Index >= ListSize(BakaShrot_Messages())
		ProcedureReturn #False
	EndIf
	SelectElement(BakaShrot_Messages(), Index)
	BakaShrot_MessageId   = BakaShrot_Messages()\MessageId
	BakaShrot_MessageData = BakaShrot_Messages()\JsonData
	ProcedureReturn #True
EndProcedure

; #True if more messages follow the last one the last BakaShrot_GetMessages() got.
ProcedureCDLL.i BakaShrot_HasMoreMessages()
	ProcedureReturn BakaShrot_MessagesMore
EndProcedure


; Id of the selected message of the last successful BakaShrot_GetLatestMessage()
; or BakaShrot_GetMessages(), 0 if none.
ProcedureCDLL.q BakaShrot_GetMessageId()
	ProcedureReturn BakaShrot_MessageId
EndProcedure

; The server's topic and node ids of that message, -1 if none.
ProcedureCDLL.l BakaShrot_GetMessageTopicId()
	ProcedureReturn BakaShrot_MessageTopicId
EndProcedure

ProcedureCDLL.l BakaShrot_GetMessageNodeId()
	ProcedureReturn BakaShrot_MessageNodeId
EndProcedure

; The names of its topic and node, or their ids in digits if they have none.
ProcedureCDLL.i BakaShrot_GetMessageTopicA(*Buffer, BufferSize.i)
	ProcedureReturn BakaShrot_CopyString(BakaShrot_MessageTopic, *Buffer, BufferSize, #PB_UTF8)
EndProcedure

ProcedureCDLL.i BakaShrot_GetMessageTopicW(*Buffer, BufferSize.i)
	ProcedureReturn BakaShrot_CopyString(BakaShrot_MessageTopic, *Buffer, BufferSize, #PB_Unicode)
EndProcedure

ProcedureCDLL.i BakaShrot_GetMessageNodeA(*Buffer, BufferSize.i)
	ProcedureReturn BakaShrot_CopyString(BakaShrot_MessageNode, *Buffer, BufferSize, #PB_UTF8)
EndProcedure

ProcedureCDLL.i BakaShrot_GetMessageNodeW(*Buffer, BufferSize.i)
	ProcedureReturn BakaShrot_CopyString(BakaShrot_MessageNode, *Buffer, BufferSize, #PB_Unicode)
EndProcedure


; Asks the server for its id and name of a topic or node (Kind, see
; ResolveNamePacket.pbi), Ref being a name or an id. The server only
; resolves the topics this client may push to or read, unless it may query.
; Returns the id (0-65535), or -1 on failure: refused (unknown) or the
; connection failed, see BakaShrot_IsConnected().
; On success, BakaShrot_GetResolvedName() has its name, "" if it has none.
Procedure.l BakaShrot_ResolveString(Kind.i, Ref.s)
	Protected Request.BakaShrot_ResolveName
	Protected *Resolved.BakaShrot_NameResolved
	Protected *Packet, PacketSize.Integer, *Answer, AnswerSize.Integer
	Protected *View.MsgPackData, IsRefusal.i, Id.l

	BakaShrot_RefusalReason = ""
	BakaShrot_ResolvedName  = ""

	If Not BakaShrot_Outbound\ConnectionId Or BakaShrot_Outbound\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		ProcedureReturn -1
	EndIf

	If Not BakaShrot_IsValidRef(Ref)
		ProcedureReturn -1
	EndIf

	Request\Kind = Kind
	Request\Ref  = Ref
	*Packet = BakaShrot_ResolveNamePacket_Encode(@Request, @PacketSize)
	If Not *Packet
		ProcedureReturn -1
	EndIf
	*Answer = BakaShrot_SendRequest(*Packet, PacketSize\i, @AnswerSize)
	FreeMemory(*Packet)
	If Not *Answer
		ProcedureReturn -1
	EndIf

	If BakaShrot_GetPacketType(*Answer, AnswerSize\i) = #BakaShrot_PacketType_RequestRefused
		IsRefusal = BakaShrot_ReadRefusal(*Answer, AnswerSize\i)
		FreeMemory(*Answer)
		If Not IsRefusal
			BakaShrot_AbortConnection()
		EndIf
		ProcedureReturn -1
	EndIf

	*Resolved = 0
	*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
	If *View
		*Resolved = BakaShrot_NameResolvedPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*Answer)
	If Not *Resolved
		BakaShrot_AbortConnection()
		ProcedureReturn -1
	EndIf

	; An answer about something else is out of order.
	If *Resolved\Kind <> Kind Or Not BakaShrot_RefMatches(Ref, *Resolved\Id, *Resolved\Name)
		FreeStructure(*Resolved)
		BakaShrot_AbortConnection()
		ProcedureReturn -1
	EndIf

	Id = *Resolved\Id
	BakaShrot_ResolvedName = *Resolved\Name
	FreeStructure(*Resolved)
	ProcedureReturn Id
EndProcedure

ProcedureCDLL.l BakaShrot_ResolveTopicA(*Ref)
	If Not *Ref
		ProcedureReturn -1
	EndIf
	ProcedureReturn BakaShrot_ResolveString(#BakaShrot_NameKind_Topic, PeekS(*Ref, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.l BakaShrot_ResolveTopicW(*Ref)
	If Not *Ref
		ProcedureReturn -1
	EndIf
	ProcedureReturn BakaShrot_ResolveString(#BakaShrot_NameKind_Topic, PeekS(*Ref, -1, #PB_Unicode))
EndProcedure

ProcedureCDLL.l BakaShrot_ResolveNodeA(*Ref)
	If Not *Ref
		ProcedureReturn -1
	EndIf
	ProcedureReturn BakaShrot_ResolveString(#BakaShrot_NameKind_Node, PeekS(*Ref, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.l BakaShrot_ResolveNodeW(*Ref)
	If Not *Ref
		ProcedureReturn -1
	EndIf
	ProcedureReturn BakaShrot_ResolveString(#BakaShrot_NameKind_Node, PeekS(*Ref, -1, #PB_Unicode))
EndProcedure

; Asks the server for every topic (Kind #BakaShrot_NameKind_Topic, only
; those this client may push to or read, unless it may query) or node, and
; keeps them as JSON for BakaShrot_GetNamesList():
;   {"kind": "topic", "truncated": false,
;    "items": [{"id": 1, "name": "logs", "origin": "config"}, ...]}
; by id, "name" "" if unnamed (those don't replicate), "origin" "config" or
; "id". "truncated" is true if they didn't all fit in one packet.
; Returns how many are listed, or -1 on failure (see BakaShrot_IsConnected()).
Procedure.l BakaShrot_ListNamesOf(Kind.i)
	Protected Request.BakaShrot_ListNames
	Protected *List.BakaShrot_NamesList
	Protected *Packet, PacketSize.Integer, *Answer, AnswerSize.Integer
	Protected *View.MsgPackData, IsRefusal.i, Count.l
	Protected Json.i, Root.i, Items.i, Item.i

	BakaShrot_RefusalReason = ""
	BakaShrot_NamesList     = ""

	If Not BakaShrot_Outbound\ConnectionId Or BakaShrot_Outbound\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		ProcedureReturn -1
	EndIf

	Request\Kind = Kind
	*Packet = BakaShrot_ListNamesPacket_Encode(@Request, @PacketSize)
	If Not *Packet
		ProcedureReturn -1
	EndIf
	*Answer = BakaShrot_SendRequest(*Packet, PacketSize\i, @AnswerSize)
	FreeMemory(*Packet)
	If Not *Answer
		ProcedureReturn -1
	EndIf

	If BakaShrot_GetPacketType(*Answer, AnswerSize\i) = #BakaShrot_PacketType_RequestRefused
		IsRefusal = BakaShrot_ReadRefusal(*Answer, AnswerSize\i)
		FreeMemory(*Answer)
		If Not IsRefusal
			BakaShrot_AbortConnection()
		EndIf
		ProcedureReturn -1
	EndIf

	*List = 0
	*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
	If *View
		*List = BakaShrot_NamesListPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*Answer)
	If Not *List Or *List\Kind <> Kind
		If *List
			FreeStructure(*List)
		EndIf
		BakaShrot_AbortConnection()
		ProcedureReturn -1
	EndIf

	Json = CreateJSON(#PB_Any)
	If Not Json
		FreeStructure(*List)
		ProcedureReturn -1
	EndIf
	Root = SetJSONObject(JSONValue(Json))
	If Kind = #BakaShrot_NameKind_Topic
		SetJSONString(AddJSONMember(Root, "kind"), "topic")
	Else
		SetJSONString(AddJSONMember(Root, "kind"), "node")
	EndIf
	SetJSONBoolean(AddJSONMember(Root, "truncated"), *List\Truncated)
	Items = SetJSONArray(AddJSONMember(Root, "items"))
	ForEach *List\Entries()
		Item = SetJSONObject(AddJSONElement(Items))
		SetJSONInteger(AddJSONMember(Item, "id"), *List\Entries()\Id)
		SetJSONString(AddJSONMember(Item, "name"), *List\Entries()\Name)
		SetJSONString(AddJSONMember(Item, "origin"), *List\Entries()\Origin)
	Next
	BakaShrot_NamesList = ComposeJSON(Json)
	FreeJSON(Json)

	Count = ListSize(*List\Entries())
	FreeStructure(*List)
	ProcedureReturn Count
EndProcedure

ProcedureCDLL.l BakaShrot_ListTopics()
	ProcedureReturn BakaShrot_ListNamesOf(#BakaShrot_NameKind_Topic)
EndProcedure

ProcedureCDLL.l BakaShrot_ListNodes()
	ProcedureReturn BakaShrot_ListNamesOf(#BakaShrot_NameKind_Node)
EndProcedure

; JSON of the last successful BakaShrot_ListTopics/Nodes().
ProcedureCDLL.i BakaShrot_GetNamesListA(*Buffer, BufferSize.i)
	ProcedureReturn BakaShrot_CopyString(BakaShrot_NamesList, *Buffer, BufferSize, #PB_UTF8)
EndProcedure

ProcedureCDLL.i BakaShrot_GetNamesListW(*Buffer, BufferSize.i)
	ProcedureReturn BakaShrot_CopyString(BakaShrot_NamesList, *Buffer, BufferSize, #PB_Unicode)
EndProcedure


; Name found by the last successful BakaShrot_ResolveTopic/Node(), "" if it has none.
ProcedureCDLL.i BakaShrot_GetResolvedNameA(*Buffer, BufferSize.i)
	ProcedureReturn BakaShrot_CopyString(BakaShrot_ResolvedName, *Buffer, BufferSize, #PB_UTF8)
EndProcedure

ProcedureCDLL.i BakaShrot_GetResolvedNameW(*Buffer, BufferSize.i)
	ProcedureReturn BakaShrot_CopyString(BakaShrot_ResolvedName, *Buffer, BufferSize, #PB_Unicode)
EndProcedure

; Data (JSON or not) of the selected message of the last successful
; BakaShrot_GetLatestMessage() or BakaShrot_GetMessages().
ProcedureCDLL.i BakaShrot_GetMessageDataA(*Buffer, BufferSize.i)
	ProcedureReturn BakaShrot_CopyString(BakaShrot_MessageData, *Buffer, BufferSize, #PB_UTF8)
EndProcedure

ProcedureCDLL.i BakaShrot_GetMessageDataW(*Buffer, BufferSize.i)
	ProcedureReturn BakaShrot_CopyString(BakaShrot_MessageData, *Buffer, BufferSize, #PB_Unicode)
EndProcedure


; Why the server refused the last request, empty if it didn't.
ProcedureCDLL.i BakaShrot_GetRefusalReasonA(*Buffer, BufferSize.i)
	ProcedureReturn BakaShrot_CopyString(BakaShrot_RefusalReason, *Buffer, BufferSize, #PB_UTF8)
EndProcedure

ProcedureCDLL.i BakaShrot_GetRefusalReasonW(*Buffer, BufferSize.i)
	ProcedureReturn BakaShrot_CopyString(BakaShrot_RefusalReason, *Buffer, BufferSize, #PB_Unicode)
EndProcedure


; Runs a raw SQL query on the server, read-only: a single SELECT (or WITH
; ... SELECT). The server refuses it if this client isn't allowed to query,
; if it fails, or if its result doesn't fit in one packet.
; On success, read the result with BakaShrot_GetQueryResult(), as JSON:
;   {"columns": ["name", ...], "rows": [["value", ...], ...]}
; Every value is a string, or null for NULL.
; On failure, BakaShrot_IsConnected() tells if it was refused (see
; BakaShrot_GetRefusalReason()) or if the connection failed.
Procedure.i BakaShrot_QueryString(Sql.s)
	Protected Request.BakaShrot_QueryRequest
	Protected *Result.BakaShrot_QueryResult
	Protected *Packet, PacketSize.Integer, *Answer, AnswerSize.Integer
	Protected *View.MsgPackData, IsRefusal.i

	BakaShrot_RefusalReason = ""
	BakaShrot_QueryResult   = ""

	If Not BakaShrot_Outbound\ConnectionId Or BakaShrot_Outbound\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		ProcedureReturn #False
	EndIf

	Request\Sql = Sql
	*Packet = BakaShrot_QueryRequestPacket_Encode(@Request, @PacketSize)
	If Not *Packet
		ProcedureReturn #False
	EndIf
	*Answer = BakaShrot_SendRequest(*Packet, PacketSize\i, @AnswerSize)
	FreeMemory(*Packet)
	If Not *Answer
		ProcedureReturn #False
	EndIf

	If BakaShrot_GetPacketType(*Answer, AnswerSize\i) = #BakaShrot_PacketType_RequestRefused
		IsRefusal = BakaShrot_ReadRefusal(*Answer, AnswerSize\i)
		FreeMemory(*Answer)
		If Not IsRefusal
			BakaShrot_AbortConnection()
		EndIf
		ProcedureReturn #False
	EndIf

	*Result = 0
	*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
	If *View
		*Result = BakaShrot_QueryResultPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*Answer)
	If Not *Result
		BakaShrot_AbortConnection()
		ProcedureReturn #False
	EndIf

	BakaShrot_QueryResult = *Result\JsonResult
	FreeStructure(*Result)
	ProcedureReturn #True
EndProcedure

ProcedureCDLL.i BakaShrot_QueryA(*Sql)
	If Not *Sql
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_QueryString(PeekS(*Sql, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.i BakaShrot_QueryW(*Sql)
	If Not *Sql
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_QueryString(PeekS(*Sql, -1, #PB_Unicode))
EndProcedure


; JSON result of the last successful BakaShrot_Query().
ProcedureCDLL.i BakaShrot_GetQueryResultA(*Buffer, BufferSize.i)
	ProcedureReturn BakaShrot_CopyString(BakaShrot_QueryResult, *Buffer, BufferSize, #PB_UTF8)
EndProcedure

ProcedureCDLL.i BakaShrot_GetQueryResultW(*Buffer, BufferSize.i)
	ProcedureReturn BakaShrot_CopyString(BakaShrot_QueryResult, *Buffer, BufferSize, #PB_Unicode)
EndProcedure
