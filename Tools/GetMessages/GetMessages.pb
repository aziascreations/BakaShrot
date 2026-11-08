; ============================================================================
; BakaShrot GetMessages
;
; Usage: GetMessages <Topic> <Node> [options] [ClientIni]
;   Topic, Node        Whose messages to get, each a name or an id.
;   --after <Id>       Starts after that message id, defaults to 0: from the
;                      first one. "latest" starts after the latest one,
;                      only new messages then (with --follow).
;   --limit <N>        Stops after N messages, defaults to 100, or to no
;                      limit with --follow. 0 is no limit.
;   --follow, -f       Keeps going once caught up: checks for new messages
;                      every --interval ms, until stopped (Ctrl+C) or the
;                      connection fails.
;   --interval <Ms>    How often --follow checks, defaults to 500.
;   ClientIni          Identity and server to use, defaults to "client.ini".
;
; Prints each message on its own line, in message id order, as its id, a
; tab, and its data as stored (JSON or not, a message with line breaks spans
; several lines). The server refuses if the client's ReadTopics don't allow
; the topic, or if either is unknown.
; Compile as a console program, exits with 0 on success, 1 on failure.
; ============================================================================

EnableExplicit

XIncludeFile "../Common/ToolClient.pbi"
XIncludeFile "../../Commons/Networking/Names.pbi"


; Most messages asked for at once, the server's maximum.
#GetMessages_BatchLimit = 10000

Define Topic.s, Node.s, IniPath.s = "client.ini", AfterText.s = "0"
Define Limit.q = -1, Follow.i = #False, IntervalMs.i = 500
Define i.i, Argument.s, Value.s, Positional.i
Define AfterMessageId.q, Printed.q, Asked.l, Count.l, n.l

OpenConsole()

; Prints the usage and exits.
Procedure Usage()
	PrintN("Usage: GetMessages <Topic> <Node> [--after <Id|latest>] [--limit <N>] [--follow] [--interval <Ms>] [ClientIni]")
	PrintN("  Topic and Node are names or ids. Prints each message as its id, a tab, and its data.")
	End 1
EndProcedure

; Whether Text is a whole number of digits, 0 or more.
Procedure.i IsNumber(Text.s)
	Protected i.i
	If Text = "" Or Len(Text) > 18
		ProcedureReturn #False
	EndIf
	For i = 1 To Len(Text)
		If Mid(Text, i, 1) < "0" Or Mid(Text, i, 1) > "9"
			ProcedureReturn #False
		EndIf
	Next
	ProcedureReturn #True
EndProcedure

i = 0
While i < CountProgramParameters()
	Argument = ProgramParameter(i)
	Select LCase(Argument)
		Case "--after", "--limit", "--interval"
			If i + 1 >= CountProgramParameters()
				PrintN("Missing the value of " + Argument)
				End 1
			EndIf
			i + 1
			Value = ProgramParameter(i)
			Select LCase(Argument)
				Case "--after"
					If LCase(Value) <> "latest" And Not IsNumber(Value)
						PrintN("Invalid --after '" + Value + "', expected a message id or 'latest'")
						End 1
					EndIf
					AfterText = LCase(Value)
				Case "--limit"
					If Not IsNumber(Value)
						PrintN("Invalid --limit '" + Value + "', expected a number")
						End 1
					EndIf
					Limit = Val(Value)
				Case "--interval"
					If Not IsNumber(Value) Or Val(Value) < 10 Or Val(Value) > 3600000
						PrintN("Invalid --interval '" + Value + "', expected 10 to 3600000 ms")
						End 1
					EndIf
					IntervalMs = Val(Value)
			EndSelect
		Case "--follow", "-f"
			Follow = #True
		Default
			If Left(Argument, 2) = "--"
				PrintN("Unknown option '" + Argument + "'")
				Usage()
			EndIf
			Select Positional
				Case 0 : Topic = Argument
				Case 1 : Node = Argument
				Case 2 : IniPath = Argument
				Default
					Usage()
			EndSelect
			Positional + 1
	EndSelect
	i + 1
Wend

If Positional < 2
	Usage()
EndIf
If Not BakaShrot_IsValidRef(Topic)
	PrintN("Invalid topic '" + Topic + "', expected a name or an id 0-65535")
	End 1
EndIf
If Not BakaShrot_IsValidRef(Node)
	PrintN("Invalid node '" + Node + "', expected a name or an id 0-65535")
	End 1
EndIf
If Limit < 0
	If Follow
		Limit = 0
	Else
		Limit = 100
	EndIf
EndIf

If Not ToolClient_Connect(IniPath)
	End 1
EndIf

; "latest": after the latest message, or from the start if there's none yet.
If AfterText = "latest"
	If BakaShrot_GetLatestMessageOf(Topic, Node)
		AfterMessageId = BakaShrot_GetMessageId()
	ElseIf Not BakaShrot_IsConnected()
		ToolClient_PrintFailure()
		ToolClient_Close()
		End 1
	EndIf
Else
	AfterMessageId = Val(AfterText)
EndIf

Printed = 0
Repeat
	Asked = #GetMessages_BatchLimit
	If Limit > 0 And Limit - Printed < Asked
		Asked = Limit - Printed
	EndIf

	Count = BakaShrot_GetMessages(Topic, Node, AfterMessageId, Asked)
	If Count < 0
		ToolClient_PrintFailure()
		ToolClient_Close()
		End 1
	EndIf

	For n = 0 To Count - 1
		BakaShrot_SelectMessage(n)
		AfterMessageId = BakaShrot_GetMessageId()
		PrintN(Str(AfterMessageId) + #TAB$ + BakaShrot_GetMessageDataString())
	Next
	Printed + Count

	If Limit > 0 And Printed >= Limit
		Break
	EndIf
	If Not BakaShrot_HasMoreMessages()
		If Not Follow
			Break
		EndIf
		Delay(IntervalMs)
	EndIf
ForEver

ToolClient_Close()
End 0
