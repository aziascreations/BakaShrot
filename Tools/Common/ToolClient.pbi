; ============================================================================
; BakaShrot Tools - Client connection
;
; Shared by the tools that talk to a server through BakaShrot_Client.dll.
; The DLL must be next to the tool, the identity and server come from an ini
; file laid out like the client.ini Build.ps1 writes:
;   [BakaShrot]
;   PrivateKey, PublicKey, Node, ServerHost, ServerPort,
;   ServerPublicKey (the server's, it logs it when it starts)
; Node is the node the client writes as, a name or an id
; (Commons/Networking/Names.pbi); NodeId before, still read when Node is
; missing. A Topic (TopicId) left in it is ignored: the client's default
; topic is in the server's config (DefaultTopic).
; ============================================================================

XIncludeFile "../../Client/BakaShrot_Client_Prototypes.pbi"
XIncludeFile "ToolConsole.pbi"


; What a client error code (100+, BakaShrot_ErrorCodes.pbi) means, for the
; tools' messages.
Procedure.s ToolClient_Explain(Code.l)
	Select Code
		Case #BakaShrot_Error_NotConnected : ProcedureReturn "not connected"
		Case #BakaShrot_Error_ConnectFailed : ProcedureReturn "nothing answers there"
		Case #BakaShrot_Error_AuthRejected : ProcedureReturn "the server closed the connection: wrong ServerPublicKey, a key or node it doesn't allow, or another version (its log says which)"
		Case #BakaShrot_Error_ServerNotVerified : ProcedureReturn "the server couldn't prove it holds ServerPublicKey's private key"
		Case #BakaShrot_Error_ConnectionLost : ProcedureReturn "the connection to the server failed"
		Case #BakaShrot_Error_ProtocolError : ProcedureReturn "the server answered something unexpected, the connection is closed"
		Case #BakaShrot_Error_InvalidArgument : ProcedureReturn "an invalid argument"
		Case #BakaShrot_Error_FileError : ProcedureReturn "a file couldn't be opened, read or written"
		Case #BakaShrot_Error_AttachmentMismatch : ProcedureReturn "the attachment doesn't match its SHA-256"
		Case #BakaShrot_Error_Internal : ProcedureReturn "out of memory, or another failure in the client"
	EndSelect
	ProcedureReturn BakaShrot_ErrorName(Code)
EndProcedure


; Loads the DLL, reads IniPath and connects to its server with its identity.
; Prints what failed and returns #False on failure, the DLL is then unloaded.
Procedure.i ToolClient_Connect(IniPath.s)
	Protected PrivateKey.s, PublicKey.s, ServerPublicKey.s, Node.s, ServerHost.s, ServerPort.l

	If Not OpenPreferences(IniPath)
		PrintN("Failed to open '" + IniPath + "'")
		ProcedureReturn #False
	EndIf
	PreferenceGroup("BakaShrot")
	PrivateKey = ReadPreferenceString("PrivateKey", "")
	PublicKey  = ReadPreferenceString("PublicKey", "")
	ServerPublicKey = ReadPreferenceString("ServerPublicKey", "")
	Node       = Trim(ReadPreferenceString("Node", ReadPreferenceString("NodeId", "")))
	ServerHost = ReadPreferenceString("ServerHost", "")
	ServerPort = ReadPreferenceLong("ServerPort", 0)
	ClosePreferences()

	If Not BakaShrot_LoadClient(GetPathPart(ProgramFilename()) + "BakaShrot_Client.dll")
		PrintN("Failed to load BakaShrot_Client.dll")
		ProcedureReturn #False
	EndIf

	If Not BakaShrot_SetPrivateKey(PrivateKey)
		PrintN("Invalid PrivateKey in '" + IniPath + "'")
		BakaShrot_UnloadClient()
		ProcedureReturn #False
	EndIf

	If Not BakaShrot_SetPublicKey(PublicKey)
		PrintN("Invalid PublicKey in '" + IniPath + "'")
		BakaShrot_UnloadClient()
		ProcedureReturn #False
	EndIf

	If Not BakaShrot_SetServerPublicKey(ServerPublicKey)
		PrintN("Missing or invalid ServerPublicKey in '" + IniPath + "', the server logs it when it starts")
		BakaShrot_UnloadClient()
		ProcedureReturn #False
	EndIf

	If Not BakaShrot_SetNode(Node)
		PrintN("Invalid Node '" + Node + "' in '" + IniPath + "', expected a name or an id")
		BakaShrot_UnloadClient()
		ProcedureReturn #False
	EndIf

	If Not BakaShrot_Connect(ServerHost, ServerPort)
		PrintN("Failed to connect and authenticate to " + ServerHost + ":" + Str(ServerPort) + " (" + BakaShrot_ErrorName(BakaShrot_GetLastError()) + "): " + ToolClient_Explain(BakaShrot_GetLastError()))
		BakaShrot_UnloadClient()
		ProcedureReturn #False
	EndIf

	ProcedureReturn #True
EndProcedure


; Ms (milliseconds since 1970 UTC, as BakaShrot_GetMessagePushedAt() gives
; it) as "2026-11-08T14:03:59.123Z".
Procedure.s ToolClient_FormatUtc(Ms.q)
	ProcedureReturn FormatDate("%yyyy-%mm-%ddT%hh:%ii:%ss", Ms / 1000) + "." + RSet(Str(Ms % 1000), 3, "0") + "Z"
EndProcedure


; Disconnects and unloads the DLL.
Procedure ToolClient_Close()
	BakaShrot_Disconnect()
	BakaShrot_UnloadClient()
EndProcedure


; Prints why the last request failed.
; With its code's name (BakaShrot_ErrorCodes.pbi), for scripts to match on.
Procedure ToolClient_PrintFailure()
	Protected Code.l = BakaShrot_GetLastError()

	If BakaShrot_IsRefusalCode(Code)
		PrintN("Refused by the server (" + BakaShrot_ErrorName(Code) + "): " + BakaShrot_GetRefusalReasonString())
	ElseIf BakaShrot_GetRefusalReasonString() <> ""
		; The client's own refusals: a message or attachment over the limits...
		PrintN("Failed (" + BakaShrot_ErrorName(Code) + "): " + BakaShrot_GetRefusalReasonString())
	Else
		PrintN("Failed (" + BakaShrot_ErrorName(Code) + "): " + ToolClient_Explain(Code))
	EndIf
EndProcedure


; Reads a whole UTF-8 text file (a byte order mark is skipped) into *Text.
; In one go: ReadString() with #PB_File_IgnoreEOL takes seconds on a 16 MB
; line. Prints why and returns #False if it can't be read.
Procedure.i ToolClient_ReadTextFile(Path.s, *Text.String)
	Protected FileId.i, Size.q, *Data, Offset.i

	FileId = ReadFile(#PB_Any, Path)
	If Not FileId
		PrintN("Failed to open '" + Path + "'")
		ProcedureReturn #False
	EndIf
	Size = Lof(FileId)
	*Data = AllocateMemory(Size + 1)
	If Not *Data
		CloseFile(FileId)
		PrintN("'" + Path + "' is too big to read")
		ProcedureReturn #False
	EndIf
	If ReadData(FileId, *Data, Size) <> Size
		FreeMemory(*Data)
		CloseFile(FileId)
		PrintN("Failed to read '" + Path + "'")
		ProcedureReturn #False
	EndIf
	CloseFile(FileId)

	If Size >= 3 And PeekA(*Data) = $EF And PeekA(*Data + 1) = $BB And PeekA(*Data + 2) = $BF
		Offset = 3
	EndIf
	*Text\s = ""
	If Size > Offset
		*Text\s = PeekS(*Data + Offset, Size - Offset, #PB_UTF8 | #PB_ByteLength)
	EndIf
	FreeMemory(*Data)
	ProcedureReturn #True
EndProcedure
