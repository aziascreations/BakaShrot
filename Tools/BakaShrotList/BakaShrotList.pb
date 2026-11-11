;{- Code Header
; ==- Basic Info -================================
;     Name: BakaShrotList.pb
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
; BakaShrotList
;
; Usage: BakaShrotList [topics|nodes|all] [ClientIni] [--json]
;   topics|nodes|all  What to list, defaults to all.
;   ClientIni         Identity and server to use, defaults to "client.ini".
;   --json            Prints the DLL's JSON instead of a table.
;
; Lists every topic and node the server has, with this server's id and its
; name: what the names in requests and queries stand for there. Unnamed ones
; aren't replicated. Topics: only those the client may push to or read,
; unless it may query.
; Compile as a console program, exits with 0 on success, 1 on failure.
; ============================================================================

EnableExplicit

XIncludeFile "../Common/ToolClient.pbi"


Define What.s = "all", IniPath.s = "client.ini", AsJson.i = #False
Define i.i, Argument.s, Count.l, Json.i, Items.i, Item.i, n.i, Name.s, Failed.i

OpenConsole()

For i = 0 To CountProgramParameters() - 1
	Argument = ProgramParameter(i)
	Select LCase(Argument)
		Case "topics", "nodes", "all"
			What = LCase(Argument)
		Case "--json"
			AsJson = #True
		Default
			IniPath = Argument
	EndSelect
Next

If Not ToolClient_Connect(IniPath)
	ToolConsole_End(1)
EndIf

; Prints one list, from the DLL's JSON.
Procedure.i PrintList(Label.s, AsJson.i)
	Protected Json.i, Items.i, Item.i, n.i, Name.s, Text.s

	Text = BakaShrot_GetNamesListString()
	If AsJson
		PrintN(Text)
		ProcedureReturn #True
	EndIf

	Json = ParseJSON(#PB_Any, Text)
	If Not Json
		PrintN("The server's list couldn't be read")
		ProcedureReturn #False
	EndIf
	Items = GetJSONMember(JSONValue(Json), "items")
	PrintN(Label + " (" + Str(JSONArraySize(Items)) + "):")
	For n = 0 To JSONArraySize(Items) - 1
		Item = GetJSONElement(Items, n)
		Name = GetJSONString(GetJSONMember(Item, "name"))
		If Name = ""
			Name = "(unnamed, not replicated)"
		EndIf
		PrintN("  " + RSet(Str(GetJSONInteger(GetJSONMember(Item, "id"))), 5) + "  " + LSet(Name, 30) + "  " + GetJSONString(GetJSONMember(Item, "origin")))
	Next
	If GetJSONBoolean(GetJSONMember(JSONValue(Json), "truncated"))
		PrintN("  ... more than fit in one answer")
	EndIf
	FreeJSON(Json)
	ProcedureReturn #True
EndProcedure

Failed = #False
If What = "topics" Or What = "all"
	If BakaShrot_ListTopics() < 0
		ToolClient_PrintFailure()
		Failed = #True
	ElseIf Not PrintList("Topics", AsJson)
		Failed = #True
	EndIf
EndIf
If Not Failed And (What = "nodes" Or What = "all")
	If BakaShrot_ListNodes() < 0
		ToolClient_PrintFailure()
		Failed = #True
	ElseIf Not PrintList("Nodes", AsJson)
		Failed = #True
	EndIf
EndIf

ToolClient_Close()
If Failed
	ToolConsole_End(1)
EndIf
ToolConsole_End(0)
