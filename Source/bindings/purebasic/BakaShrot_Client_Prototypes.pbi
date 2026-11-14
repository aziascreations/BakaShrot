;{- Code Header
; ==- Basic Info -================================
;     Name: BakaShrot_Client_Prototypes.pbi
;  Version: 0.0.1
;   Author: Herwin Bozet (NibblePoker)
;
; ==- Compatibility -=============================
;  Tested compiler versions:
;    * PureBasic 5.73 LTS (Windows x64)
;
; ==- Links -=====================================
;  GitHub: https://github.com/aziascreations/BakaShrot
;}

; ============================================================================
; BakaShrot client DLL - Prototypes
;
; Include this in an app to use bakashrot.dll (libbakashrot.so on Linux):
;   XIncludeFile "BakaShrot_Client_Prototypes.pbi"
;   If BakaShrot_LoadClient("bakashrot.dll")
;       BakaShrot_SetCaCertificate("ca.crt")        ; a file, or PEM text
;       BakaShrot_SetCertificate("kitchen.crt")
;       BakaShrot_SetPrivateKey("kitchen.key")
;       If BakaShrot_Connect("10.0.0.2", 7000)
;           BakaShrot_PushMessageTo("logs", ~"{\"temp\": 21}")
;           ...
;       EndIf
;       BakaShrot_UnloadClient()
;   EndIf
;
; Source/docs/client.md has what each function does (and
; Source/bindings/c/bakashrot.h, generated from the DLL). The string
; functions are mapped to the DLL's W (UTF-16) variants. After a failed
; call, BakaShrot_GetLastError() tells why: the codes and what to do about
; each are in BakaShrot_ErrorCodes.pbi, next to this file (included below),
; BakaShrot_ErrorName() names them; BakaShrot_GetRefusalReasonString() says
; why in words.
;
; Changed from the PureBasic DLL (protocol 6): certificates instead of keys
; and a node (BakaShrot_SetCaCertificate(), _SetCertificate(),
; _SetPrivateKey() now a PEM key, _SetCrl()); a push always names its topic
; (BakaShrot_PushMessage() is gone); no ids (_GetLatestMessage(TopicId,
; NodeId), _SetNodeId(), _GetMessageTopicId/NodeId(), _ResolveTopic/Node(),
; _GetResolvedName() are gone); _GetNamesList() is
; {"kind":"topic","names":[...],"truncated":false}. New: _GetNode().
; Attachments: the same six as before, by names.
; ============================================================================

XIncludeFile "BakaShrot_ErrorCodes.pbi"


PrototypeC.l BakaShrot_GetLastError_Prototype()
PrototypeC.i BakaShrot_GetRefusalReason_Prototype(*Buffer, BufferSize.i)
PrototypeC.i BakaShrot_SetCaCertificate_Prototype(Certificate.p-unicode)
PrototypeC.i BakaShrot_SetCertificate_Prototype(Certificate.p-unicode)
PrototypeC.i BakaShrot_SetPrivateKey_Prototype(PrivateKey.p-unicode)
PrototypeC.i BakaShrot_SetCrl_Prototype(Crl.p-unicode)
PrototypeC.i BakaShrot_Connect_Prototype(Host.p-unicode, Port.l)
PrototypeC.i BakaShrot_IsConnected_Prototype()
PrototypeC.i BakaShrot_Disconnect_Prototype()
PrototypeC.i BakaShrot_GetNode_Prototype(*Buffer, BufferSize.i)
PrototypeC.q BakaShrot_PushMessageTo_Prototype(Topic.p-unicode, JsonData.p-unicode)
PrototypeC.i BakaShrot_GetLatestMessageOf_Prototype(Topic.p-unicode, Node.p-unicode)
PrototypeC.l BakaShrot_GetMessages_Prototype(Topic.p-unicode, Node.p-unicode, AfterMessageId.q, Limit.l)
PrototypeC.l BakaShrot_GetMessageCount_Prototype()
PrototypeC.i BakaShrot_SelectMessage_Prototype(Index.l)
PrototypeC.i BakaShrot_HasMoreMessages_Prototype()
PrototypeC.q BakaShrot_GetMessageId_Prototype()
PrototypeC.q BakaShrot_GetMessagePushedAt_Prototype()
PrototypeC.q BakaShrot_GetMessageAttachmentSize_Prototype()
PrototypeC.i BakaShrot_IsMessageAttachmentReady_Prototype()
PrototypeC.i BakaShrot_GetMessageData_Prototype(*Buffer, BufferSize.i)
PrototypeC.i BakaShrot_GetMessageTopic_Prototype(*Buffer, BufferSize.i)
PrototypeC.i BakaShrot_GetMessageNode_Prototype(*Buffer, BufferSize.i)
PrototypeC.l BakaShrot_ListTopics_Prototype()
PrototypeC.l BakaShrot_ListNodes_Prototype()
PrototypeC.i BakaShrot_GetNamesList_Prototype(*Buffer, BufferSize.i)
PrototypeC.i BakaShrot_Query_Prototype(Sql.p-unicode)
PrototypeC.i BakaShrot_GetQueryResult_Prototype(*Buffer, BufferSize.i)
PrototypeC.q BakaShrot_PushMessageWithFile_Prototype(Topic.p-unicode, JsonData.p-unicode, FilePath.p-unicode)
PrototypeC.q BakaShrot_PushMessageWithData_Prototype(Topic.p-unicode, JsonData.p-unicode, *Data, Size.q)
PrototypeC.q BakaShrot_SaveAttachment_Prototype(Topic.p-unicode, Node.p-unicode, MessageId.q, FilePath.p-unicode)
PrototypeC.q BakaShrot_LoadAttachment_Prototype(Topic.p-unicode, Node.p-unicode, MessageId.q)
PrototypeC.q BakaShrot_GetAttachmentData_Prototype(*Buffer, BufferSize.q)
PrototypeC.i BakaShrot_FreeAttachmentData_Prototype()


Global BakaShrot_GetLastError.BakaShrot_GetLastError_Prototype
Global BakaShrot_GetRefusalReason.BakaShrot_GetRefusalReason_Prototype
Global BakaShrot_SetCaCertificate.BakaShrot_SetCaCertificate_Prototype
Global BakaShrot_SetCertificate.BakaShrot_SetCertificate_Prototype
Global BakaShrot_SetPrivateKey.BakaShrot_SetPrivateKey_Prototype
Global BakaShrot_SetCrl.BakaShrot_SetCrl_Prototype
Global BakaShrot_Connect.BakaShrot_Connect_Prototype
Global BakaShrot_IsConnected.BakaShrot_IsConnected_Prototype
Global BakaShrot_Disconnect.BakaShrot_Disconnect_Prototype
Global BakaShrot_GetNode.BakaShrot_GetNode_Prototype
Global BakaShrot_PushMessageTo.BakaShrot_PushMessageTo_Prototype
Global BakaShrot_GetLatestMessageOf.BakaShrot_GetLatestMessageOf_Prototype
Global BakaShrot_GetMessages.BakaShrot_GetMessages_Prototype
Global BakaShrot_GetMessageCount.BakaShrot_GetMessageCount_Prototype
Global BakaShrot_SelectMessage.BakaShrot_SelectMessage_Prototype
Global BakaShrot_HasMoreMessages.BakaShrot_HasMoreMessages_Prototype
Global BakaShrot_GetMessageId.BakaShrot_GetMessageId_Prototype
Global BakaShrot_GetMessagePushedAt.BakaShrot_GetMessagePushedAt_Prototype
Global BakaShrot_GetMessageAttachmentSize.BakaShrot_GetMessageAttachmentSize_Prototype
Global BakaShrot_IsMessageAttachmentReady.BakaShrot_IsMessageAttachmentReady_Prototype
Global BakaShrot_GetMessageData.BakaShrot_GetMessageData_Prototype
Global BakaShrot_GetMessageTopic.BakaShrot_GetMessageTopic_Prototype
Global BakaShrot_GetMessageNode.BakaShrot_GetMessageNode_Prototype
Global BakaShrot_ListTopics.BakaShrot_ListTopics_Prototype
Global BakaShrot_ListNodes.BakaShrot_ListNodes_Prototype
Global BakaShrot_GetNamesList.BakaShrot_GetNamesList_Prototype
Global BakaShrot_Query.BakaShrot_Query_Prototype
Global BakaShrot_GetQueryResult.BakaShrot_GetQueryResult_Prototype
Global BakaShrot_PushMessageWithFile.BakaShrot_PushMessageWithFile_Prototype
Global BakaShrot_PushMessageWithData.BakaShrot_PushMessageWithData_Prototype
Global BakaShrot_SaveAttachment.BakaShrot_SaveAttachment_Prototype
Global BakaShrot_LoadAttachment.BakaShrot_LoadAttachment_Prototype
Global BakaShrot_GetAttachmentData.BakaShrot_GetAttachmentData_Prototype
Global BakaShrot_FreeAttachmentData.BakaShrot_FreeAttachmentData_Prototype

Global BakaShrot_ClientLibrary.i = 0
; The first export BakaShrot_LoadClient() didn't find, "" if none.
Global BakaShrot_ClientMissing.s = ""


; Unloads the DLL loaded by BakaShrot_LoadClient().
Procedure BakaShrot_UnloadClient()
	If BakaShrot_ClientLibrary
		CloseLibrary(BakaShrot_ClientLibrary)
		BakaShrot_ClientLibrary = 0
	EndIf
EndProcedure


; An export of the DLL, noted in BakaShrot_ClientMissing if it has none.
Procedure.i BakaShrot_ClientFunction(Name.s)
	Protected *Function = GetFunction(BakaShrot_ClientLibrary, Name)
	If Not *Function And BakaShrot_ClientMissing = ""
		BakaShrot_ClientMissing = Name
	EndIf
	ProcedureReturn *Function
EndProcedure


; Loads the DLL at DllPath and fills the function pointers above.
; Returns #False if the DLL can't be loaded or an export is missing (an
; older DLL: BakaShrot_ClientMissing says which).
Procedure.i BakaShrot_LoadClient(DllPath.s)
	If BakaShrot_ClientLibrary
		ProcedureReturn #False
	EndIf

	BakaShrot_ClientLibrary = OpenLibrary(#PB_Any, DllPath)
	If Not BakaShrot_ClientLibrary
		ProcedureReturn #False
	EndIf
	BakaShrot_ClientMissing = ""

	; PureBasic strings are UTF-16, so the W variants are used.
	BakaShrot_GetLastError        = BakaShrot_ClientFunction("BakaShrot_GetLastError")
	BakaShrot_GetRefusalReason    = BakaShrot_ClientFunction("BakaShrot_GetRefusalReasonW")
	BakaShrot_SetCaCertificate    = BakaShrot_ClientFunction("BakaShrot_SetCaCertificateW")
	BakaShrot_SetCertificate      = BakaShrot_ClientFunction("BakaShrot_SetCertificateW")
	BakaShrot_SetPrivateKey       = BakaShrot_ClientFunction("BakaShrot_SetPrivateKeyW")
	BakaShrot_SetCrl              = BakaShrot_ClientFunction("BakaShrot_SetCrlW")
	BakaShrot_Connect             = BakaShrot_ClientFunction("BakaShrot_ConnectW")
	BakaShrot_IsConnected         = BakaShrot_ClientFunction("BakaShrot_IsConnected")
	BakaShrot_Disconnect          = BakaShrot_ClientFunction("BakaShrot_Disconnect")
	BakaShrot_GetNode             = BakaShrot_ClientFunction("BakaShrot_GetNodeW")
	BakaShrot_PushMessageTo       = BakaShrot_ClientFunction("BakaShrot_PushMessageToW")
	BakaShrot_GetLatestMessageOf  = BakaShrot_ClientFunction("BakaShrot_GetLatestMessageOfW")
	BakaShrot_GetMessages         = BakaShrot_ClientFunction("BakaShrot_GetMessagesW")
	BakaShrot_GetMessageCount     = BakaShrot_ClientFunction("BakaShrot_GetMessageCount")
	BakaShrot_SelectMessage       = BakaShrot_ClientFunction("BakaShrot_SelectMessage")
	BakaShrot_HasMoreMessages     = BakaShrot_ClientFunction("BakaShrot_HasMoreMessages")
	BakaShrot_GetMessageId        = BakaShrot_ClientFunction("BakaShrot_GetMessageId")
	BakaShrot_GetMessagePushedAt  = BakaShrot_ClientFunction("BakaShrot_GetMessagePushedAt")
	BakaShrot_GetMessageAttachmentSize = BakaShrot_ClientFunction("BakaShrot_GetMessageAttachmentSize")
	BakaShrot_IsMessageAttachmentReady = BakaShrot_ClientFunction("BakaShrot_IsMessageAttachmentReady")
	BakaShrot_GetMessageData      = BakaShrot_ClientFunction("BakaShrot_GetMessageDataW")
	BakaShrot_GetMessageTopic     = BakaShrot_ClientFunction("BakaShrot_GetMessageTopicW")
	BakaShrot_GetMessageNode      = BakaShrot_ClientFunction("BakaShrot_GetMessageNodeW")
	BakaShrot_ListTopics          = BakaShrot_ClientFunction("BakaShrot_ListTopics")
	BakaShrot_ListNodes           = BakaShrot_ClientFunction("BakaShrot_ListNodes")
	BakaShrot_GetNamesList        = BakaShrot_ClientFunction("BakaShrot_GetNamesListW")
	BakaShrot_Query               = BakaShrot_ClientFunction("BakaShrot_QueryW")
	BakaShrot_GetQueryResult      = BakaShrot_ClientFunction("BakaShrot_GetQueryResultW")
	BakaShrot_PushMessageWithFile = BakaShrot_ClientFunction("BakaShrot_PushMessageWithFileW")
	BakaShrot_PushMessageWithData = BakaShrot_ClientFunction("BakaShrot_PushMessageWithDataW")
	BakaShrot_SaveAttachment      = BakaShrot_ClientFunction("BakaShrot_SaveAttachmentW")
	BakaShrot_LoadAttachment      = BakaShrot_ClientFunction("BakaShrot_LoadAttachmentW")
	BakaShrot_GetAttachmentData   = BakaShrot_ClientFunction("BakaShrot_GetAttachmentData")
	BakaShrot_FreeAttachmentData  = BakaShrot_ClientFunction("BakaShrot_FreeAttachmentData")

	If BakaShrot_ClientMissing <> ""
		BakaShrot_UnloadClient()
		ProcedureReturn #False
	EndIf
	ProcedureReturn #True
EndProcedure


; Calls a string getter of the DLL (Getter(*Buffer, BufferSize)) and
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

; The string getters, as strings.
Procedure.s BakaShrot_GetRefusalReasonString()
	ProcedureReturn BakaShrot_GetString(BakaShrot_GetRefusalReason)
EndProcedure

Procedure.s BakaShrot_GetNodeString()
	ProcedureReturn BakaShrot_GetString(BakaShrot_GetNode)
EndProcedure

Procedure.s BakaShrot_GetMessageDataString()
	ProcedureReturn BakaShrot_GetString(BakaShrot_GetMessageData)
EndProcedure

Procedure.s BakaShrot_GetMessageTopicString()
	ProcedureReturn BakaShrot_GetString(BakaShrot_GetMessageTopic)
EndProcedure

Procedure.s BakaShrot_GetMessageNodeString()
	ProcedureReturn BakaShrot_GetString(BakaShrot_GetMessageNode)
EndProcedure

Procedure.s BakaShrot_GetNamesListString()
	ProcedureReturn BakaShrot_GetString(BakaShrot_GetNamesList)
EndProcedure

Procedure.s BakaShrot_GetQueryResultString()
	ProcedureReturn BakaShrot_GetString(BakaShrot_GetQueryResult)
EndProcedure


; Usage example. Only compiled when this file is run directly (F5 in the
; IDE), not when it's included by an app.
;   ClientExample <DllPath> <CaFile> <CertificateFile> <KeyFile> <Host> <Port>
; Pushes a message to "logs", reads it back, pushes one with an
; attachment and reads that back, lists the topics.
CompilerIf #PB_Compiler_IsMainFile

	Define Id.q, Size.q, *Attachment, *Copy

	; Prints why the last call failed, then ends.
	Procedure Failed(What.s)
		PrintN(What + " failed: " + BakaShrot_ErrorName(BakaShrot_GetLastError()) + ", " + BakaShrot_GetRefusalReasonString())
		BakaShrot_UnloadClient()
		End 1
	EndProcedure

	OpenConsole()
	If CountProgramParameters() < 6
		PrintN("Usage: ClientExample <DllPath> <CaFile> <CertificateFile> <KeyFile> <Host> <Port>")
		End 2
	EndIf

	If Not BakaShrot_LoadClient(ProgramParameter(0))
		PrintN("Failed to load " + ProgramParameter(0) + " " + BakaShrot_ClientMissing)
		End 1
	EndIf

	If Not BakaShrot_SetCaCertificate(ProgramParameter(1)) : Failed("Setting the CA's certificate") : EndIf
	If Not BakaShrot_SetCertificate(ProgramParameter(2)) : Failed("Setting the certificate") : EndIf
	If Not BakaShrot_SetPrivateKey(ProgramParameter(3)) : Failed("Setting the private key") : EndIf
	If Not BakaShrot_Connect(ProgramParameter(4), Val(ProgramParameter(5))) : Failed("Connecting") : EndIf
	PrintN("Connected as " + BakaShrot_GetNodeString())

	Id = BakaShrot_PushMessageTo("logs", ~"{\"from\": \"PureBasic\", \"text\": \"hello\"}")
	If Id < 1 : Failed("Pushing") : EndIf
	PrintN("Pushed #" + Str(Id))

	If Not BakaShrot_GetLatestMessageOf("logs", BakaShrot_GetNodeString()) : Failed("Reading") : EndIf
	PrintN("Latest: #" + Str(BakaShrot_GetMessageId()) + " " + BakaShrot_GetMessageDataString())

	*Attachment = AllocateMemory(3000)
	FillMemory(*Attachment, 3000, 42, #PB_Byte)
	Id = BakaShrot_PushMessageWithData("logs", ~"{\"photo\": 1}", *Attachment, 3000)
	If Id < 1 : Failed("Pushing an attachment") : EndIf
	Size = BakaShrot_LoadAttachment("logs", BakaShrot_GetNodeString(), Id)
	If Size < 0 : Failed("Reading the attachment") : EndIf
	*Copy = AllocateMemory(Size)
	BakaShrot_GetAttachmentData(*Copy, Size)
	BakaShrot_FreeAttachmentData()
	If CompareMemory(*Attachment, *Copy, 3000)
		PrintN("Pushed #" + Str(Id) + " with " + Str(Size) + " bytes, read back the same")
	Else
		PrintN("The attachment read back differs")
		End 1
	EndIf
	FreeMemory(*Attachment) : FreeMemory(*Copy)

	If BakaShrot_ListTopics() < 0 : Failed("Listing") : EndIf
	PrintN("Topics: " + BakaShrot_GetNamesListString())

	If BakaShrot_PushMessageTo("nothing", "{}") < 0
		PrintN("A push to an unknown topic: " + BakaShrot_ErrorName(BakaShrot_GetLastError()) + ", " + BakaShrot_GetRefusalReasonString())
	EndIf

	BakaShrot_Disconnect()
	PrintN("IsConnected after disconnecting: " + Str(BakaShrot_IsConnected()))
	BakaShrot_UnloadClient()
	End 0

CompilerEndIf
