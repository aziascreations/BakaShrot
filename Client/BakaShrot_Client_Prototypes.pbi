; ============================================================================
; BakaShrot Client DLL - Prototypes
;
; Include this in an app to use BakaShrot_Client.dll:
;   XIncludeFile "BakaShrot_Client_Prototypes.pbi"
;   If BakaShrot_LoadClient("BakaShrot_Client.dll")
;       BakaShrot_SetPrivateKey("...")
;       BakaShrot_SetPublicKey("...")
;       BakaShrot_SetServerPublicKey("...")
;       ...
;       BakaShrot_UnloadClient()
;   EndIf
;
; See BakaShrot_Client.pbi for what each function does.
; The string functions are mapped to the DLL's W (UTF-16) variants.
; ============================================================================


PrototypeC.i BakaShrot_SetPrivateKey_Prototype(PrivateKey.p-unicode)
PrototypeC.i BakaShrot_SetPublicKey_Prototype(PublicKey.p-unicode)
PrototypeC.i BakaShrot_SetServerPublicKey_Prototype(PublicKey.p-unicode)
PrototypeC.i BakaShrot_SetTopicId_Prototype(TopicId.l)
PrototypeC.i BakaShrot_SetNodeId_Prototype(NodeId.l)
PrototypeC.i BakaShrot_SetTopic_Prototype(Topic.p-unicode)
PrototypeC.i BakaShrot_SetNode_Prototype(Node.p-unicode)
PrototypeC.i BakaShrot_Connect_Prototype(Host.p-unicode, Port.l)
PrototypeC.i BakaShrot_IsConnected_Prototype()
PrototypeC.i BakaShrot_Disconnect_Prototype()
PrototypeC.q BakaShrot_PushMessage_Prototype(JsonData.p-unicode)
PrototypeC.q BakaShrot_PushMessageTo_Prototype(Topic.p-unicode, JsonData.p-unicode)
PrototypeC.i BakaShrot_GetLatestMessage_Prototype(TopicId.l, NodeId.l)
PrototypeC.i BakaShrot_GetLatestMessageOf_Prototype(Topic.p-unicode, Node.p-unicode)
PrototypeC.q BakaShrot_GetMessageId_Prototype()
PrototypeC.q BakaShrot_GetMessagePushedAt_Prototype()
PrototypeC.i BakaShrot_GetMessageData_Prototype(*Buffer, BufferSize.i)
PrototypeC.l BakaShrot_GetMessageTopicId_Prototype()
PrototypeC.l BakaShrot_GetMessageNodeId_Prototype()
PrototypeC.i BakaShrot_GetMessageTopic_Prototype(*Buffer, BufferSize.i)
PrototypeC.i BakaShrot_GetMessageNode_Prototype(*Buffer, BufferSize.i)
PrototypeC.l BakaShrot_ResolveTopic_Prototype(Ref.p-unicode)
PrototypeC.l BakaShrot_ResolveNode_Prototype(Ref.p-unicode)
PrototypeC.i BakaShrot_GetResolvedName_Prototype(*Buffer, BufferSize.i)
PrototypeC.l BakaShrot_ListTopics_Prototype()
PrototypeC.l BakaShrot_ListNodes_Prototype()
PrototypeC.i BakaShrot_GetNamesList_Prototype(*Buffer, BufferSize.i)
PrototypeC.i BakaShrot_GetRefusalReason_Prototype(*Buffer, BufferSize.i)
PrototypeC.i BakaShrot_Query_Prototype(Sql.p-unicode)
PrototypeC.i BakaShrot_GetQueryResult_Prototype(*Buffer, BufferSize.i)
PrototypeC.l BakaShrot_GetMessages_Prototype(Topic.p-unicode, Node.p-unicode, AfterMessageId.q, Limit.l)
PrototypeC.l BakaShrot_GetMessageCount_Prototype()
PrototypeC.i BakaShrot_SelectMessage_Prototype(Index.l)
PrototypeC.i BakaShrot_HasMoreMessages_Prototype()
PrototypeC.q BakaShrot_PushMessageWithFile_Prototype(Topic.p-unicode, JsonData.p-unicode, FilePath.p-unicode)
PrototypeC.q BakaShrot_PushMessageWithData_Prototype(Topic.p-unicode, JsonData.p-unicode, *Data, Size.q)
PrototypeC.q BakaShrot_SaveAttachment_Prototype(Topic.p-unicode, Node.p-unicode, MessageId.q, FilePath.p-unicode)
PrototypeC.q BakaShrot_LoadAttachment_Prototype(Topic.p-unicode, Node.p-unicode, MessageId.q)
PrototypeC.q BakaShrot_GetAttachmentData_Prototype(*Buffer, BufferSize.q)
PrototypeC.i BakaShrot_FreeAttachmentData_Prototype()
PrototypeC.q BakaShrot_GetMessageAttachmentSize_Prototype()
PrototypeC.i BakaShrot_IsMessageAttachmentReady_Prototype()


Global BakaShrot_SetPrivateKey.BakaShrot_SetPrivateKey_Prototype
Global BakaShrot_SetPublicKey.BakaShrot_SetPublicKey_Prototype
Global BakaShrot_SetServerPublicKey.BakaShrot_SetServerPublicKey_Prototype
Global BakaShrot_SetTopicId.BakaShrot_SetTopicId_Prototype
Global BakaShrot_SetNodeId.BakaShrot_SetNodeId_Prototype
Global BakaShrot_SetTopic.BakaShrot_SetTopic_Prototype
Global BakaShrot_SetNode.BakaShrot_SetNode_Prototype
Global BakaShrot_Connect.BakaShrot_Connect_Prototype
Global BakaShrot_IsConnected.BakaShrot_IsConnected_Prototype
Global BakaShrot_Disconnect.BakaShrot_Disconnect_Prototype
Global BakaShrot_PushMessage.BakaShrot_PushMessage_Prototype
Global BakaShrot_PushMessageTo.BakaShrot_PushMessageTo_Prototype
Global BakaShrot_GetLatestMessage.BakaShrot_GetLatestMessage_Prototype
Global BakaShrot_GetLatestMessageOf.BakaShrot_GetLatestMessageOf_Prototype
Global BakaShrot_GetMessageId.BakaShrot_GetMessageId_Prototype
Global BakaShrot_GetMessagePushedAt.BakaShrot_GetMessagePushedAt_Prototype
Global BakaShrot_GetMessageData.BakaShrot_GetMessageData_Prototype
Global BakaShrot_GetMessageTopicId.BakaShrot_GetMessageTopicId_Prototype
Global BakaShrot_GetMessageNodeId.BakaShrot_GetMessageNodeId_Prototype
Global BakaShrot_GetMessageTopic.BakaShrot_GetMessageTopic_Prototype
Global BakaShrot_GetMessageNode.BakaShrot_GetMessageNode_Prototype
Global BakaShrot_ResolveTopic.BakaShrot_ResolveTopic_Prototype
Global BakaShrot_ResolveNode.BakaShrot_ResolveNode_Prototype
Global BakaShrot_GetResolvedName.BakaShrot_GetResolvedName_Prototype
Global BakaShrot_ListTopics.BakaShrot_ListTopics_Prototype
Global BakaShrot_ListNodes.BakaShrot_ListNodes_Prototype
Global BakaShrot_GetNamesList.BakaShrot_GetNamesList_Prototype
Global BakaShrot_GetRefusalReason.BakaShrot_GetRefusalReason_Prototype
Global BakaShrot_Query.BakaShrot_Query_Prototype
Global BakaShrot_GetQueryResult.BakaShrot_GetQueryResult_Prototype
Global BakaShrot_GetMessages.BakaShrot_GetMessages_Prototype
Global BakaShrot_GetMessageCount.BakaShrot_GetMessageCount_Prototype
Global BakaShrot_SelectMessage.BakaShrot_SelectMessage_Prototype
Global BakaShrot_HasMoreMessages.BakaShrot_HasMoreMessages_Prototype
Global BakaShrot_PushMessageWithFile.BakaShrot_PushMessageWithFile_Prototype
Global BakaShrot_PushMessageWithData.BakaShrot_PushMessageWithData_Prototype
Global BakaShrot_SaveAttachment.BakaShrot_SaveAttachment_Prototype
Global BakaShrot_LoadAttachment.BakaShrot_LoadAttachment_Prototype
Global BakaShrot_GetAttachmentData.BakaShrot_GetAttachmentData_Prototype
Global BakaShrot_FreeAttachmentData.BakaShrot_FreeAttachmentData_Prototype
Global BakaShrot_GetMessageAttachmentSize.BakaShrot_GetMessageAttachmentSize_Prototype
Global BakaShrot_IsMessageAttachmentReady.BakaShrot_IsMessageAttachmentReady_Prototype

Global BakaShrot_ClientLibrary.i = 0


; Unloads the DLL loaded by BakaShrot_LoadClient().
Procedure BakaShrot_UnloadClient()
	If BakaShrot_ClientLibrary
		CloseLibrary(BakaShrot_ClientLibrary)
		BakaShrot_ClientLibrary = 0
	EndIf
EndProcedure


; Loads the DLL at DllPath and fills the function pointers above.
; Returns #False if the DLL can't be loaded or a function is missing.
Procedure.i BakaShrot_LoadClient(DllPath.s)
	If BakaShrot_ClientLibrary
		ProcedureReturn #False
	EndIf

	BakaShrot_ClientLibrary = OpenLibrary(#PB_Any, DllPath)
	If Not BakaShrot_ClientLibrary
		ProcedureReturn #False
	EndIf

	; PureBasic strings are UTF-16, so the W variants are used.
	BakaShrot_SetPrivateKey = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_SetPrivateKeyW")
	BakaShrot_SetPublicKey  = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_SetPublicKeyW")
	BakaShrot_SetServerPublicKey = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_SetServerPublicKeyW")
	BakaShrot_SetTopicId    = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_SetTopicId")
	BakaShrot_SetNodeId     = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_SetNodeId")
	BakaShrot_SetTopic      = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_SetTopicW")
	BakaShrot_SetNode       = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_SetNodeW")
	BakaShrot_Connect       = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_ConnectW")
	BakaShrot_IsConnected   = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_IsConnected")
	BakaShrot_Disconnect    = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_Disconnect")
	BakaShrot_PushMessage      = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_PushMessageW")
	BakaShrot_GetLatestMessage = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetLatestMessage")
	BakaShrot_GetMessageId     = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetMessageId")
	BakaShrot_GetMessagePushedAt = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetMessagePushedAt")
	BakaShrot_GetMessageData   = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetMessageDataW")
	BakaShrot_GetRefusalReason = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetRefusalReasonW")
	BakaShrot_Query            = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_QueryW")
	BakaShrot_GetQueryResult   = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetQueryResultW")
	BakaShrot_PushMessageTo      = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_PushMessageToW")
	BakaShrot_GetLatestMessageOf = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetLatestMessageOfW")
	BakaShrot_GetMessageTopicId  = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetMessageTopicId")
	BakaShrot_GetMessageNodeId   = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetMessageNodeId")
	BakaShrot_GetMessageTopic    = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetMessageTopicW")
	BakaShrot_GetMessageNode     = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetMessageNodeW")
	BakaShrot_ResolveTopic       = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_ResolveTopicW")
	BakaShrot_ResolveNode        = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_ResolveNodeW")
	BakaShrot_GetResolvedName    = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetResolvedNameW")
	BakaShrot_ListTopics         = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_ListTopics")
	BakaShrot_ListNodes          = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_ListNodes")
	BakaShrot_GetNamesList       = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetNamesListW")
	BakaShrot_GetMessages        = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetMessagesW")
	BakaShrot_GetMessageCount    = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetMessageCount")
	BakaShrot_SelectMessage      = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_SelectMessage")
	BakaShrot_HasMoreMessages    = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_HasMoreMessages")
	BakaShrot_PushMessageWithFile = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_PushMessageWithFileW")
	BakaShrot_PushMessageWithData = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_PushMessageWithDataW")
	BakaShrot_SaveAttachment = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_SaveAttachmentW")
	BakaShrot_LoadAttachment = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_LoadAttachmentW")
	BakaShrot_GetAttachmentData = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetAttachmentData")
	BakaShrot_FreeAttachmentData = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_FreeAttachmentData")
	BakaShrot_GetMessageAttachmentSize = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_GetMessageAttachmentSize")
	BakaShrot_IsMessageAttachmentReady = GetFunction(BakaShrot_ClientLibrary, "BakaShrot_IsMessageAttachmentReady")

	If Not BakaShrot_SetPrivateKey Or Not BakaShrot_SetPublicKey Or Not BakaShrot_SetServerPublicKey Or Not BakaShrot_SetTopicId Or Not BakaShrot_SetNodeId Or Not BakaShrot_Connect Or Not BakaShrot_IsConnected Or Not BakaShrot_Disconnect
		BakaShrot_UnloadClient()
		ProcedureReturn #False
	EndIf

	If Not BakaShrot_PushMessage Or Not BakaShrot_GetLatestMessage Or Not BakaShrot_GetMessageId Or Not BakaShrot_GetMessagePushedAt Or Not BakaShrot_GetMessageData Or Not BakaShrot_GetRefusalReason
		BakaShrot_UnloadClient()
		ProcedureReturn #False
	EndIf

	If Not BakaShrot_Query Or Not BakaShrot_GetQueryResult
		BakaShrot_UnloadClient()
		ProcedureReturn #False
	EndIf

	If Not BakaShrot_SetTopic Or Not BakaShrot_SetNode Or Not BakaShrot_PushMessageTo Or Not BakaShrot_GetLatestMessageOf Or
	   Not BakaShrot_GetMessageTopicId Or Not BakaShrot_GetMessageNodeId Or Not BakaShrot_GetMessageTopic Or Not BakaShrot_GetMessageNode Or
	   Not BakaShrot_ResolveTopic Or Not BakaShrot_ResolveNode Or Not BakaShrot_GetResolvedName Or
	   Not BakaShrot_ListTopics Or Not BakaShrot_ListNodes Or Not BakaShrot_GetNamesList
		BakaShrot_UnloadClient()
		ProcedureReturn #False
	EndIf

	If Not BakaShrot_GetMessages Or Not BakaShrot_GetMessageCount Or Not BakaShrot_SelectMessage Or Not BakaShrot_HasMoreMessages
		BakaShrot_UnloadClient()
		ProcedureReturn #False
	EndIf

	If Not BakaShrot_PushMessageWithFile Or Not BakaShrot_PushMessageWithData Or Not BakaShrot_SaveAttachment Or Not BakaShrot_LoadAttachment Or Not BakaShrot_GetAttachmentData Or Not BakaShrot_FreeAttachmentData Or Not BakaShrot_GetMessageAttachmentSize Or Not BakaShrot_IsMessageAttachmentReady
		BakaShrot_UnloadClient()
		ProcedureReturn #False
	EndIf

	ProcedureReturn #True
EndProcedure


; BakaShrot_GetMessageData() as a string, asks for the size, then copies.
Procedure.s BakaShrot_GetMessageDataString()
	Protected *Buffer, BufferSize.i, Text.s

	BufferSize = BakaShrot_GetMessageData(0, 0)
	*Buffer = AllocateMemory(BufferSize)
	If Not *Buffer
		ProcedureReturn ""
	EndIf
	BakaShrot_GetMessageData(*Buffer, BufferSize)
	Text = PeekS(*Buffer, -1, #PB_Unicode)
	FreeMemory(*Buffer)

	ProcedureReturn Text
EndProcedure


; BakaShrot_GetQueryResult() as a string, asks for the size, then copies.
Procedure.s BakaShrot_GetQueryResultString()
	Protected *Buffer, BufferSize.i, Text.s

	BufferSize = BakaShrot_GetQueryResult(0, 0)
	*Buffer = AllocateMemory(BufferSize)
	If Not *Buffer
		ProcedureReturn ""
	EndIf
	BakaShrot_GetQueryResult(*Buffer, BufferSize)
	Text = PeekS(*Buffer, -1, #PB_Unicode)
	FreeMemory(*Buffer)

	ProcedureReturn Text
EndProcedure


; Calls a string getter of the DLL (*Getter(*Buffer, BufferSize)) and
; returns the string: asks for the size, then copies.
PrototypeC.i BakaShrot_StringGetter_Prototype(*Buffer, BufferSize.i)
Procedure.s BakaShrot_GetString(Getter.BakaShrot_StringGetter_Prototype)
	Protected *Buffer, BufferSize.i, Text.s

	BufferSize = Getter(0, 0)
	*Buffer = AllocateMemory(BufferSize)
	If Not *Buffer
		ProcedureReturn ""
	EndIf
	Getter(*Buffer, BufferSize)
	Text = PeekS(*Buffer, -1, #PB_Unicode)
	FreeMemory(*Buffer)

	ProcedureReturn Text
EndProcedure

; BakaShrot_GetMessageTopic/Node() and BakaShrot_GetResolvedName() as strings.
Procedure.s BakaShrot_GetMessageTopicString()
	ProcedureReturn BakaShrot_GetString(BakaShrot_GetMessageTopic)
EndProcedure

Procedure.s BakaShrot_GetMessageNodeString()
	ProcedureReturn BakaShrot_GetString(BakaShrot_GetMessageNode)
EndProcedure

Procedure.s BakaShrot_GetResolvedNameString()
	ProcedureReturn BakaShrot_GetString(BakaShrot_GetResolvedName)
EndProcedure

Procedure.s BakaShrot_GetNamesListString()
	ProcedureReturn BakaShrot_GetString(BakaShrot_GetNamesList)
EndProcedure


; BakaShrot_GetRefusalReason() as a string, asks for the size, then copies.
Procedure.s BakaShrot_GetRefusalReasonString()
	Protected *Buffer, BufferSize.i, Text.s

	BufferSize = BakaShrot_GetRefusalReason(0, 0)
	*Buffer = AllocateMemory(BufferSize)
	If Not *Buffer
		ProcedureReturn ""
	EndIf
	BakaShrot_GetRefusalReason(*Buffer, BufferSize)
	Text = PeekS(*Buffer, -1, #PB_Unicode)
	FreeMemory(*Buffer)

	ProcedureReturn Text
EndProcedure


; Usage example. Only compiled when this file is run directly (F5 in the
; IDE), not when it's included by an app.
; Connects with the identity from the client.ini that Build.ps1 generates,
; run it from the Build folder while BakaShrot_Server.exe is running.
CompilerIf #PB_Compiler_IsMainFile

	Define PrivateKey.s, PublicKey.s, ServerPublicKey.s, Topic.s, Node.s, ServerHost.s, ServerPort.l

	OpenConsole()

	If Not OpenPreferences("client.ini")
		PrintN("Failed to open client.ini")
		End 1
	EndIf
	PreferenceGroup("BakaShrot")
	PrivateKey = ReadPreferenceString("PrivateKey", "")
	PublicKey  = ReadPreferenceString("PublicKey", "")
	ServerPublicKey = ReadPreferenceString("ServerPublicKey", "")
	Topic      = ReadPreferenceString("Topic", ReadPreferenceString("TopicId", ""))
	Node       = ReadPreferenceString("Node", ReadPreferenceString("NodeId", ""))
	ServerHost = ReadPreferenceString("ServerHost", "")
	ServerPort = ReadPreferenceLong("ServerPort", 0)
	ClosePreferences()

	If Not BakaShrot_LoadClient("BakaShrot_Client.dll")
		PrintN("Failed to load BakaShrot_Client.dll")
		End 1
	EndIf

	If Not BakaShrot_SetPrivateKey(PrivateKey)
		PrintN("Failed to set the private key")
		End 1
	EndIf

	If Not BakaShrot_SetPublicKey(PublicKey)
		PrintN("Failed to set the public key")
		End 1
	EndIf

	If Not BakaShrot_SetServerPublicKey(ServerPublicKey)
		PrintN("Failed to set the server's public key")
		End 1
	EndIf

	If Not BakaShrot_SetTopic(Topic)
		PrintN("Failed to set the topic")
		End 1
	EndIf

	If Not BakaShrot_SetNode(Node)
		PrintN("Failed to set the node")
		End 1
	EndIf

	If Not BakaShrot_Connect(ServerHost, ServerPort)
		PrintN("Failed to connect and authenticate to " + ServerHost + ":" + Str(ServerPort))
		End 1
	EndIf
	PrintN("Connected and authenticated to " + ServerHost + ":" + Str(ServerPort))

	Delay(500)
	PrintN("IsConnected: " + Str(BakaShrot_IsConnected()))

	BakaShrot_Disconnect()
	PrintN("IsConnected after disconnecting: " + Str(BakaShrot_IsConnected()))

	BakaShrot_UnloadClient()
	End 0

CompilerEndIf
