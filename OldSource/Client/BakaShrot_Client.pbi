;{- Code Header
; ==- Basic Info -================================
;     Name: BakaShrot_Client.pbi
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
; BakaShrot Client DLL
;
; Lets an app connect to a BakaShrot server, one step at a time:
;   1. BakaShrot_SetPrivateKey(), BakaShrot_SetPublicKey(),
;      BakaShrot_SetServerPublicKey() (the server's, from its log or its
;      BakaShrotGenerateKeyPairs output), and BakaShrot_SetNode() (a name
;      or an id) or BakaShrot_SetNodeId(): the node it writes as, which the
;      server must allow for its key. Its default topic is the server's to
;      say (DefaultTopic in its client section).
;   2. BakaShrot_Connect(Host, Port), connects and authenticates, see the
;      handshake in Commons/Networking/Connections.pbi: only to the server
;      holding the private key of BakaShrot_SetServerPublicKey()'s, and
;      everything is encrypted
;   3. Requests, once connected:
;        BakaShrot_PushMessage(JsonData), into the client's default topic, or
;        BakaShrot_PushMessageTo(Topic, JsonData), returns the new
;          message's id
;        BakaShrot_GetLatestMessageOf(Topic, Node), or
;        BakaShrot_GetLatestMessage(TopicId, NodeId), then
;          BakaShrot_GetMessageId(), BakaShrot_GetMessageData(),
;          BakaShrot_GetMessagePushedAt() (ms since 1970 UTC),
;          BakaShrot_GetMessageAttachmentSize() (0 for none) and
;          BakaShrot_IsMessageAttachmentReady(),
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
;        Attachments, one per message at most (Design/Attachments.md):
;        BakaShrot_PushMessageWithFile(Topic, JsonData, FilePath) or
;          BakaShrot_PushMessageWithData(Topic, JsonData, *Data, Size): the
;          attachment is uploaded first, the message stored once it all is
;        BakaShrot_SaveAttachment(Topic, Node, MessageId, FilePath), or
;          BakaShrot_LoadAttachment(Topic, Node, MessageId) then
;          BakaShrot_GetAttachmentData(*Buffer, Size): checked with its SHA-256
;      If the server refuses a request, the connection stays open and
;      BakaShrot_GetRefusalReason() tells why.
;   4. BakaShrot_IsConnected(), BakaShrot_Disconnect()
;
; After a failed call, BakaShrot_GetLastError() tells what failed: a
; refusal's code (1-99, the connection still open), or the client's own
; (100+: not connected, the connection lost, a bad argument...), see
; BakaShrot_ErrorCodes.pbi for each and what to do about it. 0 after a call
; that succeeded. Nothing reconnects by itself: on NotConnected,
; ConnectionLost or ProtocolError, call BakaShrot_Connect() again.
; A push whose answer was lost (ConnectionLost) may have been stored all
; the same: pushed again, it's stored twice. Delivery is at least once.
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
Global BakaShrot_Node.s          = ""

; The connection, see Commons/Networking/Outbound.pbi.
Global BakaShrot_Outbound.BakaShrot_Outbound

; Filled by the requests, see BakaShrot_GetLatestMessage() and BakaShrot_GetRefusalReasonA/W().
Global BakaShrot_MessageId.q      = 0
Global BakaShrot_MessagePushedAt.q = 0
Global BakaShrot_MessageAttachmentSize.q  = 0
Global BakaShrot_MessageAttachmentReady.i = #False
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

; Why the last call failed, a code of BakaShrot_ErrorCodes.pbi, 0 if it
; succeeded. See BakaShrot_GetLastError().
Global BakaShrot_LastError.l      = #BakaShrot_Error_None


; Sets BakaShrot_LastError to Code and returns Value, for the failures:
; ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False).
Procedure.q BakaShrot_Fail(Code.l, Value.q)
	BakaShrot_LastError = Code
	ProcedureReturn Value
EndProcedure

; At the start of every call that can fail: no error, no refusal yet.
Procedure BakaShrot_ResetError()
	BakaShrot_LastError     = #BakaShrot_Error_None
	BakaShrot_RefusalReason = ""
EndProcedure

; The code of what made the last call fail, 0 if it succeeded, see
; BakaShrot_ErrorCodes.pbi. Only the calls that can fail set it (not the
; getters of a message).
ProcedureCDLL.l BakaShrot_GetLastError()
	ProcedureReturn BakaShrot_LastError
EndProcedure


; Sets the Ed25519 private key (Base64) used to answer the server's challenge.
; Must be done before connecting.
Procedure.i BakaShrot_SetPrivateKeyString(PrivateKey.s)
	BakaShrot_ResetError()
	If BakaShrot_Outbound\ConnectionId
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_AlreadyConnected, #False)
	EndIf

	If Not DecodeKeyFromString(PrivateKey, @BakaShrot_PrivateKey\Bytes[0], #BakaShrot_Ed25519_PrivateKeySize)
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf

	BakaShrot_HasPrivateKey = #True
	ProcedureReturn #True
EndProcedure

ProcedureCDLL.i BakaShrot_SetPrivateKeyA(*PrivateKey)
	If Not *PrivateKey
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf
	ProcedureReturn BakaShrot_SetPrivateKeyString(PeekS(*PrivateKey, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.i BakaShrot_SetPrivateKeyW(*PrivateKey)
	If Not *PrivateKey
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf
	ProcedureReturn BakaShrot_SetPrivateKeyString(PeekS(*PrivateKey, -1, #PB_Unicode))
EndProcedure


; Sets the Ed25519 public key (Base64) sent to the server in the Hello.
; Must be done before connecting.
Procedure.i BakaShrot_SetPublicKeyString(PublicKey.s)
	BakaShrot_ResetError()
	If BakaShrot_Outbound\ConnectionId
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_AlreadyConnected, #False)
	EndIf

	If PublicKey = ""
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf

	BakaShrot_PublicKey = PublicKey
	ProcedureReturn #True
EndProcedure

ProcedureCDLL.i BakaShrot_SetPublicKeyA(*PublicKey)
	If Not *PublicKey
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf
	ProcedureReturn BakaShrot_SetPublicKeyString(PeekS(*PublicKey, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.i BakaShrot_SetPublicKeyW(*PublicKey)
	If Not *PublicKey
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf
	ProcedureReturn BakaShrot_SetPublicKeyString(PeekS(*PublicKey, -1, #PB_Unicode))
EndProcedure


; Sets the server's Ed25519 public key (Base64): the Hello is sealed for it,
; and the server must prove it holds the matching private key.
; Must be done before connecting.
Procedure.i BakaShrot_SetServerPublicKeyString(PublicKey.s)
	BakaShrot_ResetError()
	If BakaShrot_Outbound\ConnectionId
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_AlreadyConnected, #False)
	EndIf

	If Not DecodeKeyFromString(PublicKey, @BakaShrot_ServerPublicKey\Bytes[0], #BakaShrot_Ed25519_PublicKeySize)
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf

	BakaShrot_HasServerPublicKey = #True
	ProcedureReturn #True
EndProcedure

ProcedureCDLL.i BakaShrot_SetServerPublicKeyA(*PublicKey)
	If Not *PublicKey
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf
	ProcedureReturn BakaShrot_SetServerPublicKeyString(PeekS(*PublicKey, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.i BakaShrot_SetServerPublicKeyW(*PublicKey)
	If Not *PublicKey
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf
	ProcedureReturn BakaShrot_SetServerPublicKeyString(PeekS(*PublicKey, -1, #PB_Unicode))
EndProcedure


; Sets the node the client identifies as, a name or an id in digits.
; Must be done before connecting.
Procedure.i BakaShrot_SetNodeString(Node.s)
	BakaShrot_ResetError()
	If BakaShrot_Outbound\ConnectionId
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_AlreadyConnected, #False)
	EndIf
	If Not BakaShrot_IsValidRef(Node)
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf
	BakaShrot_Node = Node
	ProcedureReturn #True
EndProcedure

ProcedureCDLL.i BakaShrot_SetNodeA(*Node)
	If Not *Node
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf
	ProcedureReturn BakaShrot_SetNodeString(PeekS(*Node, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.i BakaShrot_SetNodeW(*Node)
	If Not *Node
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf
	ProcedureReturn BakaShrot_SetNodeString(PeekS(*Node, -1, #PB_Unicode))
EndProcedure

; Same, by id, 0-65535.
ProcedureCDLL.i BakaShrot_SetNodeId(NodeId.l)
	If NodeId < 0 Or NodeId > 65535
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf
	ProcedureReturn BakaShrot_SetNodeString(Str(NodeId))
EndProcedure


; Connects to Host:Port and authenticates with the settings above, see
; BakaShrot_Outbound_Connect() in Commons/Networking/Outbound.pbi.
; Fails if already connected, if a setting is missing, or if anything in the
; handshake is out of order or unexpected, in which case the connection is
; closed.
Procedure.i BakaShrot_ConnectString(Host.s, Port.l)
	Protected Identity.BakaShrot_OutboundIdentity, Connected.i

	BakaShrot_ResetError()
	If BakaShrot_Outbound\ConnectionId
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_AlreadyConnected, #False)
	EndIf

	If Not BakaShrot_HasPrivateKey Or BakaShrot_PublicKey = "" Or Not BakaShrot_HasServerPublicKey Or BakaShrot_Node = ""
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf

	Identity\Node       = BakaShrot_Node
	Identity\PublicKey  = BakaShrot_PublicKey
	Identity\PrivateKey = @BakaShrot_PrivateKey\Bytes[0]

	Connected = BakaShrot_Outbound_Connect(@BakaShrot_Outbound, Host, Port, @Identity, @BakaShrot_ServerPublicKey\Bytes[0])
	BakaShrot_LastError = BakaShrot_Outbound\LastError
	ProcedureReturn Connected
EndProcedure

ProcedureCDLL.i BakaShrot_ConnectA(*Host, Port.l)
	If Not *Host
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf
	ProcedureReturn BakaShrot_ConnectString(PeekS(*Host, -1, #PB_UTF8), Port)
EndProcedure

ProcedureCDLL.i BakaShrot_ConnectW(*Host, Port.l)
	If Not *Host
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
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

; Closes the connection after something went wrong in a request: an
; unexpected or malformed answer, unless the caller said otherwise first.
Procedure BakaShrot_AbortConnection()
	If BakaShrot_LastError = #BakaShrot_Error_None
		BakaShrot_LastError = #BakaShrot_Error_ProtocolError
	EndIf
	BakaShrot_Outbound_Close(@BakaShrot_Outbound, #BakaShrot_ConnectionStatus_Aborted)
EndProcedure


; Sends a request and waits for its answer.
; Returns the answer (free it with FreeMemory) with its size in *OutSize\i,
; or 0 if the connection failed, in which case it's closed.
; A refusal is returned like any other answer.
Procedure.i BakaShrot_SendRequest(*Request, RequestSize.i, *OutSize.Integer)
	Protected *Answer

	If Not BakaShrot_Outbound_Send(@BakaShrot_Outbound, *Request, RequestSize)
		BakaShrot_LastError = #BakaShrot_Error_ConnectionLost
		BakaShrot_AbortConnection()
		ProcedureReturn 0
	EndIf

	*Answer = BakaShrot_Outbound_WaitPacket(@BakaShrot_Outbound, *OutSize, #BakaShrot_Outbound_Timeout)
	If Not *Answer
		BakaShrot_LastError = #BakaShrot_Error_ConnectionLost
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
	BakaShrot_LastError     = *Refused\Code
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
; is_json column) into Topic (a name or an id, "" for the client's default
; topic, its server config's DefaultTopic), the server stores it under that topic and this client's node, with
; the next message id. The client's PushTopics on the server must allow it.
; UploadId: its attachment, uploaded with BakaShrot_Upload(), 0 for none.
; Returns the new message's id (1 or more), or -1 on failure.
; On -1, BakaShrot_IsConnected() tells if the server refused it (still
; connected, see BakaShrot_GetRefusalReason()) or if the connection failed.
Procedure.q BakaShrot_PushMessageToString(Topic.s, JsonData.s, UploadId.q = 0)
	Protected Push.BakaShrot_PushMessage
	Protected *Pushed.BakaShrot_MessagePushed
	Protected *Request, RequestSize.Integer, *Answer, AnswerSize.Integer
	Protected *View.MsgPackData, IsRefusal.i, MessageId.q

	BakaShrot_ResetError()

	If Not BakaShrot_Outbound\ConnectionId Or BakaShrot_Outbound\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_NotConnected, -1)
	EndIf

	If Topic <> "" And Not BakaShrot_IsValidRef(Topic)
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf

	; Refused here rather than sent for nothing, same reason as the server's.
	If StringByteLength(JsonData, #PB_UTF8) > #BakaShrot_MaxMessageSize
		BakaShrot_RefusalReason = "The message is too big: " + Str(StringByteLength(JsonData, #PB_UTF8)) + " bytes, at most " + Str(#BakaShrot_MaxMessageSize)
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf

	Push\Topic    = Topic
	Push\JsonData = JsonData
	Push\UploadId = UploadId
	*Request = BakaShrot_PushMessagePacket_Encode(@Push, @RequestSize)
	If Not *Request
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_Internal, -1)
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

; A null *Topic is the client's default topic, like "", and a null *JsonData an
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

	BakaShrot_ResetError()
	BakaShrot_MessageId     = 0
	BakaShrot_MessagePushedAt = 0
	BakaShrot_MessageAttachmentSize  = 0
	BakaShrot_MessageAttachmentReady = #False
	BakaShrot_MessageData   = ""
	BakaShrot_MessageTopicId = -1
	BakaShrot_MessageNodeId  = -1
	BakaShrot_MessageTopic   = ""
	BakaShrot_MessageNode    = ""
	ClearList(BakaShrot_Messages())
	BakaShrot_MessagesMore   = #False

	If Not BakaShrot_Outbound\ConnectionId Or BakaShrot_Outbound\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_NotConnected, #False)
	EndIf

	If Not BakaShrot_IsValidRef(Topic) Or Not BakaShrot_IsValidRef(Node)
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf

	Request\Topic = Topic
	Request\Node  = Node
	*Packet = BakaShrot_GetLatestMessagePacket_Encode(@Request, @PacketSize)
	If Not *Packet
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_Internal, #False)
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
		BakaShrot_MessagePushedAt = *Latest\PushedAt
		BakaShrot_MessageAttachmentSize  = *Latest\AttachmentSize
		BakaShrot_MessageAttachmentReady = *Latest\AttachmentReady
		BakaShrot_MessageData    = *Latest\JsonData
		BakaShrot_MessageTopicId = *Latest\TopicId
		BakaShrot_MessageNodeId  = *Latest\NodeId
		BakaShrot_MessageTopic   = *Latest\TopicName
		BakaShrot_MessageNode    = *Latest\NodeName
		AddElement(BakaShrot_Messages())
		BakaShrot_Messages()\MessageId = *Latest\MessageId
		BakaShrot_Messages()\PushedAt  = *Latest\PushedAt
		BakaShrot_Messages()\AttachmentSize  = *Latest\AttachmentSize
		BakaShrot_Messages()\AttachmentReady = *Latest\AttachmentReady
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
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf
	ProcedureReturn BakaShrot_GetLatestMessageOfString(PeekS(*Topic, -1, #PB_UTF8), PeekS(*Node, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.i BakaShrot_GetLatestMessageOfW(*Topic, *Node)
	If Not *Topic Or Not *Node
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf
	ProcedureReturn BakaShrot_GetLatestMessageOfString(PeekS(*Topic, -1, #PB_Unicode), PeekS(*Node, -1, #PB_Unicode))
EndProcedure

; Same, by ids, 0-65535.
ProcedureCDLL.i BakaShrot_GetLatestMessage(TopicId.l, NodeId.l)
	If TopicId < 0 Or TopicId > 65535 Or NodeId < 0 Or NodeId > 65535
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
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

	BakaShrot_ResetError()
	BakaShrot_MessageId      = 0
	BakaShrot_MessagePushedAt = 0
	BakaShrot_MessageAttachmentSize  = 0
	BakaShrot_MessageAttachmentReady = #False
	BakaShrot_MessageData    = ""
	BakaShrot_MessageTopicId = -1
	BakaShrot_MessageNodeId  = -1
	BakaShrot_MessageTopic   = ""
	BakaShrot_MessageNode    = ""
	ClearList(BakaShrot_Messages())
	BakaShrot_MessagesMore   = #False

	If Not BakaShrot_Outbound\ConnectionId Or BakaShrot_Outbound\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_NotConnected, -1)
	EndIf

	If Not BakaShrot_IsValidRef(Topic) Or Not BakaShrot_IsValidRef(Node)
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf
	If AfterMessageId < 0 Or Limit < 1 Or Limit > #BakaShrot_MaxGetMessages
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf

	Request\Topic          = Topic
	Request\Node           = Node
	Request\AfterMessageId = AfterMessageId
	Request\Limit          = Limit
	*Packet = BakaShrot_GetMessagesPacket_Encode(@Request, @PacketSize)
	If Not *Packet
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_Internal, -1)
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
		BakaShrot_MessagePushedAt = BakaShrot_Messages()\PushedAt
		BakaShrot_MessageAttachmentSize  = BakaShrot_Messages()\AttachmentSize
		BakaShrot_MessageAttachmentReady = BakaShrot_Messages()\AttachmentReady
		BakaShrot_MessageData = BakaShrot_Messages()\JsonData
	EndIf
	ProcedureReturn Count
EndProcedure

ProcedureCDLL.l BakaShrot_GetMessagesA(*Topic, *Node, AfterMessageId.q, Limit.l)
	If Not *Topic Or Not *Node
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf
	ProcedureReturn BakaShrot_GetMessagesString(PeekS(*Topic, -1, #PB_UTF8), PeekS(*Node, -1, #PB_UTF8), AfterMessageId, Limit)
EndProcedure

ProcedureCDLL.l BakaShrot_GetMessagesW(*Topic, *Node, AfterMessageId.q, Limit.l)
	If Not *Topic Or Not *Node
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
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
	BakaShrot_LastError = #BakaShrot_Error_None
	If Index < 0 Or Index >= ListSize(BakaShrot_Messages())
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf
	SelectElement(BakaShrot_Messages(), Index)
	BakaShrot_MessageId   = BakaShrot_Messages()\MessageId
	BakaShrot_MessagePushedAt = BakaShrot_Messages()\PushedAt
	BakaShrot_MessageAttachmentSize  = BakaShrot_Messages()\AttachmentSize
	BakaShrot_MessageAttachmentReady = BakaShrot_Messages()\AttachmentReady
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

; When that message was pushed, to whichever server it was pushed to: in
; milliseconds since 1970-01-01 00:00:00 UTC. 0 if none.
ProcedureCDLL.q BakaShrot_GetMessagePushedAt()
	ProcedureReturn BakaShrot_MessagePushedAt
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

	BakaShrot_ResetError()
	BakaShrot_ResolvedName  = ""

	If Not BakaShrot_Outbound\ConnectionId Or BakaShrot_Outbound\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_NotConnected, -1)
	EndIf

	If Not BakaShrot_IsValidRef(Ref)
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf

	Request\Kind = Kind
	Request\Ref  = Ref
	*Packet = BakaShrot_ResolveNamePacket_Encode(@Request, @PacketSize)
	If Not *Packet
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_Internal, -1)
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
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf
	ProcedureReturn BakaShrot_ResolveString(#BakaShrot_NameKind_Topic, PeekS(*Ref, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.l BakaShrot_ResolveTopicW(*Ref)
	If Not *Ref
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf
	ProcedureReturn BakaShrot_ResolveString(#BakaShrot_NameKind_Topic, PeekS(*Ref, -1, #PB_Unicode))
EndProcedure

ProcedureCDLL.l BakaShrot_ResolveNodeA(*Ref)
	If Not *Ref
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf
	ProcedureReturn BakaShrot_ResolveString(#BakaShrot_NameKind_Node, PeekS(*Ref, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.l BakaShrot_ResolveNodeW(*Ref)
	If Not *Ref
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
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

	BakaShrot_ResetError()
	BakaShrot_NamesList     = ""

	If Not BakaShrot_Outbound\ConnectionId Or BakaShrot_Outbound\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_NotConnected, -1)
	EndIf

	Request\Kind = Kind
	*Packet = BakaShrot_ListNamesPacket_Encode(@Request, @PacketSize)
	If Not *Packet
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_Internal, -1)
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
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_Internal, -1)
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

	BakaShrot_ResetError()
	BakaShrot_QueryResult   = ""

	If Not BakaShrot_Outbound\ConnectionId Or BakaShrot_Outbound\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_NotConnected, #False)
	EndIf

	Request\Sql = Sql
	*Packet = BakaShrot_QueryRequestPacket_Encode(@Request, @PacketSize)
	If Not *Packet
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_Internal, #False)
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
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
	EndIf
	ProcedureReturn BakaShrot_QueryString(PeekS(*Sql, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.i BakaShrot_QueryW(*Sql)
	If Not *Sql
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, #False)
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


; --- Attachments -----------------------------------------------------------------
; At most one per message, of any size the server takes (its
; MaxAttachmentSize), sent and read in parts of 1 MB, checked with their
; SHA-256 (Design/Attachments.md). The message is only stored once all of its
; attachment is: readers never see it without.

; What BakaShrot_LoadAttachment() read, for BakaShrot_GetAttachmentData().
Global *BakaShrot_AttachmentData = 0
Global BakaShrot_AttachmentDataSize.q = 0


; Sends *Request and returns the answer if it's a packet of AnswerType, its
; size in *AnswerSize\i. Returns 0 if the server refused it (the reason in
; BakaShrot_RefusalReason, still connected), or anything else went wrong
; (the connection is closed then).
Procedure.i BakaShrot_RequestExpecting(*Request, RequestSize.i, AnswerType.i, *AnswerSize.Integer)
	Protected *Answer, Type.i, IsRefusal.i

	*Answer = BakaShrot_SendRequest(*Request, RequestSize, *AnswerSize)
	If Not *Answer
		ProcedureReturn 0
	EndIf

	Type = BakaShrot_GetPacketType(*Answer, *AnswerSize\i)
	If Type = #BakaShrot_PacketType_RequestRefused
		IsRefusal = BakaShrot_ReadRefusal(*Answer, *AnswerSize\i)
		FreeMemory(*Answer)
		If Not IsRefusal
			BakaShrot_AbortConnection()
		EndIf
		ProcedureReturn 0
	EndIf
	If Type <> AnswerType
		FreeMemory(*Answer)
		BakaShrot_AbortConnection()
		ProcedureReturn 0
	EndIf
	ProcedureReturn *Answer
EndProcedure


; Uploads Size bytes, read from FileId (from its start) or else from *Memory,
; as the attachment of a message about to be pushed to Topic ("" for the
; client's default one). Its SHA-256 is computed first, so the file is read twice.
; Returns the upload id for BakaShrot_PushMessageToString(), 0 on failure.
Procedure.q BakaShrot_Upload(Topic.s, FileId.i, *Memory, Size.q)
	Protected Start.BakaShrot_UploadStart, *Started.BakaShrot_UploadStarted
	Protected Chunk.BakaShrot_UploadChunk, *Stored.BakaShrot_ChunkStored
	Protected Hash.BakaShrot_Sha256, *Buffer, Index.q, Count.q, Bytes.i, UploadId.q, Received.q, Complete.i
	Protected *Request, RequestSize.Integer, *Answer, AnswerSize.Integer, *View.MsgPackData

	BakaShrot_ResetError()
	If Not BakaShrot_Outbound\ConnectionId Or BakaShrot_Outbound\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_NotConnected, 0)
	EndIf
	If Topic <> "" And Not BakaShrot_IsValidRef(Topic)
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, 0)
	EndIf
	If Size < 1
		BakaShrot_RefusalReason = "The attachment is empty"
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, 0)
	EndIf
	If Size > #BakaShrot_MaxAttachmentSize
		BakaShrot_RefusalReason = "The attachment is too big: " + Str(Size) + " bytes, at most " + Str(#BakaShrot_MaxAttachmentSize)
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, 0)
	EndIf

	*Buffer = AllocateMemory(#BakaShrot_AttachmentChunkSize, #PB_Memory_NoClear)
	If Not *Buffer Or Not BakaShrot_Sha256_Start(@Hash)
		If *Buffer : FreeMemory(*Buffer) : EndIf
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_Internal, 0)
	EndIf
	Count = BakaShrot_AttachmentChunkCount(Size)

	; 1. Its SHA-256.
	If FileId
		FileSeek(FileId, 0)
		For Index = 0 To Count - 1
			Bytes = BakaShrot_AttachmentChunkBytes(Size, Index)
			If ReadData(FileId, *Buffer, Bytes) <> Bytes
				BakaShrot_RefusalReason = "The file couldn't be read"
				FreeMemory(*Buffer)
				ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_FileError, 0)
			EndIf
			BakaShrot_Sha256_Add(@Hash, *Buffer, Bytes)
		Next
		FileSeek(FileId, 0)
	Else
		BakaShrot_Sha256_Add(@Hash, *Memory, Size)
	EndIf
	BakaShrot_Sha256_Finish(@Hash, @Start\Sha256[0])

	; 2. The server makes room for it.
	Start\Topic = Topic
	Start\Size  = Size
	*Request = BakaShrot_UploadStartPacket_Encode(@Start, @RequestSize)
	If Not *Request
		FreeMemory(*Buffer)
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_Internal, 0)
	EndIf
	*Answer = BakaShrot_RequestExpecting(*Request, RequestSize\i, #BakaShrot_PacketType_UploadStarted, @AnswerSize)
	FreeMemory(*Request)
	If Not *Answer
		FreeMemory(*Buffer)
		ProcedureReturn 0
	EndIf
	*Started = 0
	*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
	If *View
		*Started = BakaShrot_UploadStartedPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*Answer)
	If Not *Started Or *Started\ChunkSize <> #BakaShrot_AttachmentChunkSize
		If *Started : FreeStructure(*Started) : EndIf
		FreeMemory(*Buffer)
		BakaShrot_AbortConnection()
		ProcedureReturn 0
	EndIf
	UploadId = *Started\UploadId
	FreeStructure(*Started)

	; 3. Its parts, in order.
	Chunk\UploadId = UploadId
	For Index = 0 To Count - 1
		Bytes = BakaShrot_AttachmentChunkBytes(Size, Index)
		If FileId
			If ReadData(FileId, *Buffer, Bytes) <> Bytes
				BakaShrot_RefusalReason = "The file couldn't be read"
				FreeMemory(*Buffer)
				ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_FileError, 0)
			EndIf
			Chunk\Data = *Buffer
		Else
			Chunk\Data = *Memory + Index * #BakaShrot_AttachmentChunkSize
		EndIf
		Chunk\ChunkIndex = Index
		Chunk\DataSize   = Bytes
		*Request = BakaShrot_UploadChunkPacket_Encode(@Chunk, @RequestSize)
		If Not *Request
			FreeMemory(*Buffer)
			ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_Internal, 0)
		EndIf
		*Answer = BakaShrot_RequestExpecting(*Request, RequestSize\i, #BakaShrot_PacketType_ChunkStored, @AnswerSize)
		FreeMemory(*Request)
		If Not *Answer
			FreeMemory(*Buffer)
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
			FreeMemory(*Buffer)
			BakaShrot_AbortConnection()
			ProcedureReturn 0
		EndIf
		Received = *Stored\Received
		Complete = *Stored\Complete
		FreeStructure(*Stored)
		; Complete exactly with the last part.
		If Received <> Index * #BakaShrot_AttachmentChunkSize + Bytes Or Bool(Complete) <> Bool(Index = Count - 1)
			FreeMemory(*Buffer)
			BakaShrot_AbortConnection()
			ProcedureReturn 0
		EndIf
	Next

	FreeMemory(*Buffer)
	ProcedureReturn UploadId
EndProcedure


; Pushes a message with the file at FilePath as its attachment, see
; BakaShrot_PushMessageToString(): the file is uploaded first, the message
; only stored once all of it is on the server.
; Returns the new message's id, or -1 on failure (refused, see
; BakaShrot_GetRefusalReason(), or the connection failed).
Procedure.q BakaShrot_PushMessageWithFileString(Topic.s, JsonData.s, FilePath.s)
	Protected FileId.i, UploadId.q

	BakaShrot_ResetError()
	If StringByteLength(JsonData, #PB_UTF8) > #BakaShrot_MaxMessageSize
		BakaShrot_RefusalReason = "The message is too big: " + Str(StringByteLength(JsonData, #PB_UTF8)) + " bytes, at most " + Str(#BakaShrot_MaxMessageSize)
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf
	FileId = ReadFile(#PB_Any, FilePath, #PB_File_SharedRead)
	If Not FileId
		BakaShrot_RefusalReason = "Can't open '" + FilePath + "'"
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_FileError, -1)
	EndIf
	UploadId = BakaShrot_Upload(Topic, FileId, 0, Lof(FileId))
	CloseFile(FileId)
	If Not UploadId
		ProcedureReturn -1
	EndIf
	ProcedureReturn BakaShrot_PushMessageToString(Topic, JsonData, UploadId)
EndProcedure

; A null *Topic is the client's default topic, a null *JsonData an empty message.
ProcedureCDLL.q BakaShrot_PushMessageWithFileA(*Topic, *JsonData, *FilePath)
	Protected Topic.s, JsonData.s
	If Not *FilePath
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf
	If *Topic : Topic = PeekS(*Topic, -1, #PB_UTF8) : EndIf
	If *JsonData : JsonData = PeekS(*JsonData, -1, #PB_UTF8) : EndIf
	ProcedureReturn BakaShrot_PushMessageWithFileString(Topic, JsonData, PeekS(*FilePath, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.q BakaShrot_PushMessageWithFileW(*Topic, *JsonData, *FilePath)
	Protected Topic.s, JsonData.s
	If Not *FilePath
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf
	If *Topic : Topic = PeekS(*Topic, -1, #PB_Unicode) : EndIf
	If *JsonData : JsonData = PeekS(*JsonData, -1, #PB_Unicode) : EndIf
	ProcedureReturn BakaShrot_PushMessageWithFileString(Topic, JsonData, PeekS(*FilePath, -1, #PB_Unicode))
EndProcedure


; Same, the attachment being Size bytes at *Data.
Procedure.q BakaShrot_PushMessageWithDataString(Topic.s, JsonData.s, *Data, Size.q)
	Protected UploadId.q

	BakaShrot_ResetError()
	If StringByteLength(JsonData, #PB_UTF8) > #BakaShrot_MaxMessageSize
		BakaShrot_RefusalReason = "The message is too big: " + Str(StringByteLength(JsonData, #PB_UTF8)) + " bytes, at most " + Str(#BakaShrot_MaxMessageSize)
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf
	If Not *Data
		BakaShrot_RefusalReason = "The attachment is empty"
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf
	UploadId = BakaShrot_Upload(Topic, 0, *Data, Size)
	If Not UploadId
		ProcedureReturn -1
	EndIf
	ProcedureReturn BakaShrot_PushMessageToString(Topic, JsonData, UploadId)
EndProcedure

ProcedureCDLL.q BakaShrot_PushMessageWithDataA(*Topic, *JsonData, *Data, Size.q)
	Protected Topic.s, JsonData.s
	If *Topic : Topic = PeekS(*Topic, -1, #PB_UTF8) : EndIf
	If *JsonData : JsonData = PeekS(*JsonData, -1, #PB_UTF8) : EndIf
	ProcedureReturn BakaShrot_PushMessageWithDataString(Topic, JsonData, *Data, Size)
EndProcedure

ProcedureCDLL.q BakaShrot_PushMessageWithDataW(*Topic, *JsonData, *Data, Size.q)
	Protected Topic.s, JsonData.s
	If *Topic : Topic = PeekS(*Topic, -1, #PB_Unicode) : EndIf
	If *JsonData : JsonData = PeekS(*JsonData, -1, #PB_Unicode) : EndIf
	ProcedureReturn BakaShrot_PushMessageWithDataString(Topic, JsonData, *Data, Size)
EndProcedure


; Reads the attachment of Topic:Node#MessageId, a part at a time, into FileId
; (from its start) or else into memory (*BakaShrot_AttachmentData), and
; checks its SHA-256.
; Returns its size, -1 on failure: refused (no attachment, not on this server
; yet...), a SHA-256 mismatch (refusal reason set), or the connection failed.
Procedure.q BakaShrot_Download(Topic.s, Node.s, MessageId.q, FileId.i)
	Protected Request.BakaShrot_GetAttachment, *Chunk.BakaShrot_AttachmentChunk
	Protected Hash.BakaShrot_Sha256, Index.q, Count.q, Size.q, *Memory, IsValid.i
	Protected Dim Expected.a(#BakaShrot_Sha256Size - 1), Dim Result.a(#BakaShrot_Sha256Size - 1)
	Protected *Request, RequestSize.Integer, *Answer, AnswerSize.Integer, *View.MsgPackData

	BakaShrot_ResetError()
	If Not BakaShrot_Outbound\ConnectionId Or BakaShrot_Outbound\Metadata\Status <> #BakaShrot_ConnectionStatus_Authenticated
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_NotConnected, -1)
	EndIf
	If Not BakaShrot_IsValidRef(Topic) Or Not BakaShrot_IsValidRef(Node) Or MessageId < 1 Or Not BakaShrot_Sha256_Start(@Hash)
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf

	Request\Topic     = Topic
	Request\Node      = Node
	Request\MessageId = MessageId
	Index = 0
	Count = 1
	While Index < Count
		Request\ChunkIndex = Index
		*Request = BakaShrot_GetAttachmentPacket_Encode(@Request, @RequestSize)
		If Not *Request
			BakaShrot_LastError = #BakaShrot_Error_Internal
			Goto DownloadFailed
		EndIf
		*Answer = BakaShrot_RequestExpecting(*Request, RequestSize\i, #BakaShrot_PacketType_AttachmentChunk, @AnswerSize)
		FreeMemory(*Request)
		If Not *Answer
			Goto DownloadFailed
		EndIf
		*Chunk = 0
		*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
		If *View
			*Chunk = BakaShrot_AttachmentChunkPacket_Decode(*View)
			MsgPackFree(*View, #False)
		EndIf
		FreeMemory(*Answer)
		If Not *Chunk
			BakaShrot_AbortConnection()
			Goto DownloadFailed
		EndIf

		; The first part tells the size and SHA-256, every other must agree.
		If Index = 0
			Size  = *Chunk\Size
			Count = BakaShrot_AttachmentChunkCount(Size)
			CopyMemory(@*Chunk\Sha256[0], @Expected(0), #BakaShrot_Sha256Size)
			If Not FileId
				*Memory = AllocateMemory(Size, #PB_Memory_NoClear)
				If Not *Memory
					BakaShrot_AttachmentChunkPacket_Free(*Chunk)
					BakaShrot_RefusalReason = "Out of memory for " + Str(Size) + " bytes"
					BakaShrot_LastError = #BakaShrot_Error_Internal
					Goto DownloadFailed
				EndIf
			EndIf
		EndIf
		If *Chunk\MessageId <> MessageId Or *Chunk\ChunkIndex <> Index Or *Chunk\Size <> Size Or Not CompareMemory(@*Chunk\Sha256[0], @Expected(0), #BakaShrot_Sha256Size) Or *Chunk\DataSize <> BakaShrot_AttachmentChunkBytes(Size, Index)
			BakaShrot_AttachmentChunkPacket_Free(*Chunk)
			BakaShrot_AbortConnection()
			Goto DownloadFailed
		EndIf

		BakaShrot_Sha256_Add(@Hash, *Chunk\Data, *Chunk\DataSize)
		If FileId
			If WriteData(FileId, *Chunk\Data, *Chunk\DataSize) <> *Chunk\DataSize
				BakaShrot_AttachmentChunkPacket_Free(*Chunk)
				BakaShrot_RefusalReason = "The file couldn't be written"
				BakaShrot_LastError = #BakaShrot_Error_FileError
				Goto DownloadFailed
			EndIf
		Else
			CopyMemory(*Chunk\Data, *Memory + Index * #BakaShrot_AttachmentChunkSize, *Chunk\DataSize)
		EndIf
		BakaShrot_AttachmentChunkPacket_Free(*Chunk)
		Index + 1
	Wend

	BakaShrot_Sha256_Finish(@Hash, @Result(0))
	If Not CompareMemory(@Result(0), @Expected(0), #BakaShrot_Sha256Size)
		BakaShrot_RefusalReason = "The attachment doesn't match its SHA-256"
		BakaShrot_LastError = #BakaShrot_Error_AttachmentMismatch
		Goto DownloadFailed
	EndIf

	If Not FileId
		If *BakaShrot_AttachmentData
			FreeMemory(*BakaShrot_AttachmentData)
		EndIf
		*BakaShrot_AttachmentData     = *Memory
		BakaShrot_AttachmentDataSize = Size
	EndIf
	ProcedureReturn Size

	DownloadFailed:
	If *Memory
		FreeMemory(*Memory)
	EndIf
	ProcedureReturn -1
EndProcedure


; Saves the attachment of Topic:Node#MessageId to FilePath (replaced),
; checked with its SHA-256. A failed one leaves no file.
; Returns its size, -1 on failure, see BakaShrot_Download().
Procedure.q BakaShrot_SaveAttachmentString(Topic.s, Node.s, MessageId.q, FilePath.s)
	Protected FileId.i, Size.q

	BakaShrot_ResetError()
	FileId = CreateFile(#PB_Any, FilePath)
	If Not FileId
		BakaShrot_RefusalReason = "Can't create '" + FilePath + "'"
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_FileError, -1)
	EndIf
	Size = BakaShrot_Download(Topic, Node, MessageId, FileId)
	CloseFile(FileId)
	If Size < 0
		DeleteFile(FilePath)
	EndIf
	ProcedureReturn Size
EndProcedure

ProcedureCDLL.q BakaShrot_SaveAttachmentA(*Topic, *Node, MessageId.q, *FilePath)
	If Not *Topic Or Not *Node Or Not *FilePath
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf
	ProcedureReturn BakaShrot_SaveAttachmentString(PeekS(*Topic, -1, #PB_UTF8), PeekS(*Node, -1, #PB_UTF8), MessageId, PeekS(*FilePath, -1, #PB_UTF8))
EndProcedure

ProcedureCDLL.q BakaShrot_SaveAttachmentW(*Topic, *Node, MessageId.q, *FilePath)
	If Not *Topic Or Not *Node Or Not *FilePath
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf
	ProcedureReturn BakaShrot_SaveAttachmentString(PeekS(*Topic, -1, #PB_Unicode), PeekS(*Node, -1, #PB_Unicode), MessageId, PeekS(*FilePath, -1, #PB_Unicode))
EndProcedure


; Reads the attachment of Topic:Node#MessageId into memory, checked with its
; SHA-256, for BakaShrot_GetAttachmentData(). All of it is held at once:
; BakaShrot_SaveAttachment() for big ones.
; Returns its size, -1 on failure, see BakaShrot_Download().
ProcedureCDLL.q BakaShrot_LoadAttachmentA(*Topic, *Node, MessageId.q)
	If Not *Topic Or Not *Node
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf
	ProcedureReturn BakaShrot_Download(PeekS(*Topic, -1, #PB_UTF8), PeekS(*Node, -1, #PB_UTF8), MessageId, 0)
EndProcedure

ProcedureCDLL.q BakaShrot_LoadAttachmentW(*Topic, *Node, MessageId.q)
	If Not *Topic Or Not *Node
		ProcedureReturn BakaShrot_Fail(#BakaShrot_Error_InvalidArgument, -1)
	EndIf
	ProcedureReturn BakaShrot_Download(PeekS(*Topic, -1, #PB_Unicode), PeekS(*Node, -1, #PB_Unicode), MessageId, 0)
EndProcedure

; Copies what the last successful BakaShrot_LoadAttachment() read into
; *Buffer, if BufferSize is enough. Returns its size (0 if none): call it
; with a null *Buffer first.
ProcedureCDLL.q BakaShrot_GetAttachmentData(*Buffer, BufferSize.q)
	If *Buffer And *BakaShrot_AttachmentData And BufferSize >= BakaShrot_AttachmentDataSize
		CopyMemory(*BakaShrot_AttachmentData, *Buffer, BakaShrot_AttachmentDataSize)
	EndIf
	ProcedureReturn BakaShrot_AttachmentDataSize
EndProcedure

; Frees what BakaShrot_LoadAttachment() read.
ProcedureCDLL.i BakaShrot_FreeAttachmentData()
	If *BakaShrot_AttachmentData
		FreeMemory(*BakaShrot_AttachmentData)
	EndIf
	*BakaShrot_AttachmentData     = 0
	BakaShrot_AttachmentDataSize = 0
	ProcedureReturn #True
EndProcedure


; Size in bytes of the selected message's attachment, 0 if it has none.
ProcedureCDLL.q BakaShrot_GetMessageAttachmentSize()
	ProcedureReturn BakaShrot_MessageAttachmentSize
EndProcedure

; #True if all of the selected message's attachment is on this server: a
; replicated one comes after its message.
ProcedureCDLL.i BakaShrot_IsMessageAttachmentReady()
	ProcedureReturn BakaShrot_MessageAttachmentReady
EndProcedure
