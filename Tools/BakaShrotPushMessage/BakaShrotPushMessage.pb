; ============================================================================
; BakaShrotPushMessage
;
; Usage: BakaShrotPushMessage [-t <Topic>] [-a <File>] <Json|@JsonFile> [ClientIni]
;   -t Topic    The topic to push to, a name or an id. Defaults to the
;               client's own topic (its TopicId). The client's PushTopics on
;               the server must allow it.
;   -a File     Attaches File to the message (any size up to the server's
;               MaxAttachmentSize): uploaded first, the message is only
;               stored once all of it is. See Design/Attachments.md.
;   Json        The message to push, or @ followed by a file holding it.
;               Usually JSON, but anything goes: the server flags it in is_json.
;               PureBasic's ProgramParameter() drops double quotes and
;               doesn't understand \" escapes, so JSON with strings only
;               gets through intact from a file: use @JsonFile.
;   ClientIni   Identity and server to use, defaults to "client.ini".
;
; Pushes one message under the client's node, and prints the message id the
; server stored it under.
; Compile as a console program, exits with 0 on success, 1 on failure.
; ============================================================================

EnableExplicit

XIncludeFile "../Common/ToolClient.pbi"
XIncludeFile "../../Commons/Networking/Names.pbi"


Define JsonData.s, IniPath.s, Topic.s, AttachPath.s, FileText.String, MessageId.q, i.i, Argument.s
Define NewList Arguments.s()

OpenConsole()

For i = 0 To CountProgramParameters() - 1
	Argument = ProgramParameter(i)
	If (Argument = "-t" Or Argument = "--topic") And i < CountProgramParameters() - 1
		i + 1
		Topic = ProgramParameter(i)
		If Not BakaShrot_IsValidRef(Topic)
			PrintN("Invalid topic '" + Topic + "', expected a name or an id 0-65535")
			ToolConsole_End(1)
		EndIf
	ElseIf (Argument = "-a" Or Argument = "--attach") And i < CountProgramParameters() - 1
		i + 1
		AttachPath = ProgramParameter(i)
		If FileSize(AttachPath) < 1
			PrintN("Can't attach '" + AttachPath + "': no such file, or empty")
			ToolConsole_End(1)
		EndIf
	Else
		AddElement(Arguments())
		Arguments() = Argument
	EndIf
Next

If ListSize(Arguments()) < 1
	PrintN("Usage: BakaShrotPushMessage [-t <Topic>] [-a <File>] <Json|@JsonFile> [ClientIni]")
	PrintN("  Command-line arguments lose their double quotes, so use @JsonFile for JSON with strings.")
	ToolConsole_End(1)
EndIf

FirstElement(Arguments())
JsonData = Arguments()
If Left(JsonData, 1) = "@"
	If Not ToolClient_ReadTextFile(Mid(JsonData, 2), @FileText)
		ToolConsole_End(1)
	EndIf
	JsonData = FileText\s
EndIf

IniPath = "client.ini"
If NextElement(Arguments())
	IniPath = Arguments()
EndIf

If Not ToolClient_Connect(IniPath)
	ToolConsole_End(1)
EndIf

If AttachPath <> ""
	MessageId = BakaShrot_PushMessageWithFile(Topic, JsonData, AttachPath)
Else
	MessageId = BakaShrot_PushMessageTo(Topic, JsonData)
EndIf
If MessageId < 1
	ToolClient_PrintFailure()
	ToolClient_Close()
	ToolConsole_End(1)
EndIf

If AttachPath <> ""
	PrintN("Pushed as message #" + Str(MessageId) + ", with an attachment of " + Str(FileSize(AttachPath)) + " bytes")
Else
	PrintN("Pushed as message #" + Str(MessageId))
EndIf

ToolClient_Close()
ToolConsole_End(0)
