; ============================================================================
; BakaShrot PushMessage
;
; Usage: PushMessage [-t <Topic>] <Json|@JsonFile> [ClientIni]
;   -t Topic    The topic to push to, a name or an id. Defaults to the
;               client's own topic (its TopicId). The client's PushTopics on
;               the server must allow it.
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


Define JsonData.s, IniPath.s, Topic.s, FileText.String, MessageId.q, i.i, Argument.s
Define NewList Arguments.s()

OpenConsole()

For i = 0 To CountProgramParameters() - 1
	Argument = ProgramParameter(i)
	If (Argument = "-t" Or Argument = "--topic") And i < CountProgramParameters() - 1
		i + 1
		Topic = ProgramParameter(i)
		If Not BakaShrot_IsValidRef(Topic)
			PrintN("Invalid topic '" + Topic + "', expected a name or an id 0-65535")
			End 1
		EndIf
	Else
		AddElement(Arguments())
		Arguments() = Argument
	EndIf
Next

If ListSize(Arguments()) < 1
	PrintN("Usage: PushMessage [-t <Topic>] <Json|@JsonFile> [ClientIni]")
	PrintN("  Command-line arguments lose their double quotes, so use @JsonFile for JSON with strings.")
	End 1
EndIf

FirstElement(Arguments())
JsonData = Arguments()
If Left(JsonData, 1) = "@"
	If Not ToolClient_ReadTextFile(Mid(JsonData, 2), @FileText)
		End 1
	EndIf
	JsonData = FileText\s
EndIf

IniPath = "client.ini"
If NextElement(Arguments())
	IniPath = Arguments()
EndIf

If Not ToolClient_Connect(IniPath)
	End 1
EndIf

MessageId = BakaShrot_PushMessageTo(Topic, JsonData)
If MessageId < 1
	ToolClient_PrintFailure()
	ToolClient_Close()
	End 1
EndIf

PrintN("Pushed as message #" + Str(MessageId))

ToolClient_Close()
End 0
