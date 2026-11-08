; ============================================================================
; BakaShrot Tools - Client connection
;
; Shared by the tools that talk to a server through BakaShrot_Client.dll.
; The DLL must be next to the tool, the identity and server come from an ini
; file laid out like the client.ini Build.ps1 writes:
;   [BakaShrot]
;   PrivateKey, PublicKey, Topic, Node, ServerHost, ServerPort,
;   ServerPublicKey (the server's, it logs it when it starts)
; Topic and Node can be names or ids (Commons/Networking/Names.pbi). They
; were TopicId and NodeId before, still read when Topic and Node are missing.
; ============================================================================

XIncludeFile "../../Client/BakaShrot_Client_Prototypes.pbi"


; Loads the DLL, reads IniPath and connects to its server with its identity.
; Prints what failed and returns #False on failure, the DLL is then unloaded.
Procedure.i ToolClient_Connect(IniPath.s)
	Protected PrivateKey.s, PublicKey.s, ServerPublicKey.s, Topic.s, Node.s, ServerHost.s, ServerPort.l

	If Not OpenPreferences(IniPath)
		PrintN("Failed to open '" + IniPath + "'")
		ProcedureReturn #False
	EndIf
	PreferenceGroup("BakaShrot")
	PrivateKey = ReadPreferenceString("PrivateKey", "")
	PublicKey  = ReadPreferenceString("PublicKey", "")
	ServerPublicKey = ReadPreferenceString("ServerPublicKey", "")
	Topic      = Trim(ReadPreferenceString("Topic", ReadPreferenceString("TopicId", "")))
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

	If Not BakaShrot_SetTopic(Topic)
		PrintN("Invalid Topic '" + Topic + "' in '" + IniPath + "', expected a name or an id")
		BakaShrot_UnloadClient()
		ProcedureReturn #False
	EndIf

	If Not BakaShrot_SetNode(Node)
		PrintN("Invalid Node '" + Node + "' in '" + IniPath + "', expected a name or an id")
		BakaShrot_UnloadClient()
		ProcedureReturn #False
	EndIf

	If Not BakaShrot_Connect(ServerHost, ServerPort)
		PrintN("Failed to connect and authenticate to " + ServerHost + ":" + Str(ServerPort))
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
Procedure ToolClient_PrintFailure()
	If BakaShrot_IsConnected()
		PrintN("Refused by the server: " + BakaShrot_GetRefusalReasonString())
	Else
		PrintN("The connection to the server failed")
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
