; ============================================================================
; BakaShrotResolveIds
;
; Usage: BakaShrotResolveIds <topic|node> <NameOrId> [ClientIni]
;   topic|node  What to look up.
;   NameOrId    A name, to get its id on the server, or an id, to get its name.
;   ClientIni   Identity and server to use, defaults to "client.ini".
;
; Prints the server's id and name for it, as "topic logs = 1". Each server
; can have different ids for the same names. The server only resolves the
; topics the client may push to or read, unless it may query.
; Compile as a console program, exits with 0 on success, 1 on failure.
; ============================================================================

EnableExplicit

XIncludeFile "../Common/ToolClient.pbi"
XIncludeFile "../../Commons/Networking/Names.pbi"


Define Kind.s, Ref.s, IniPath.s, Id.l, Name.s

OpenConsole()

If CountProgramParameters() < 2
	PrintN("Usage: BakaShrotResolveIds <topic|node> <NameOrId> [ClientIni]")
	ToolConsole_End(1)
EndIf

Kind = LCase(ProgramParameter(0))
If Kind <> "topic" And Kind <> "node"
	PrintN("Expected 'topic' or 'node', not '" + ProgramParameter(0) + "'")
	ToolConsole_End(1)
EndIf

Ref = ProgramParameter(1)
If Not BakaShrot_IsValidRef(Ref)
	PrintN("Invalid " + Kind + " '" + Ref + "', expected a name or an id 0-65535")
	ToolConsole_End(1)
EndIf

IniPath = "client.ini"
If CountProgramParameters() > 2
	IniPath = ProgramParameter(2)
EndIf

If Not ToolClient_Connect(IniPath)
	ToolConsole_End(1)
EndIf

If Kind = "topic"
	Id = BakaShrot_ResolveTopic(Ref)
Else
	Id = BakaShrot_ResolveNode(Ref)
EndIf
If Id < 0
	ToolClient_PrintFailure()
	ToolClient_Close()
	ToolConsole_End(1)
EndIf

Name = BakaShrot_GetResolvedNameString()
If Name = ""
	Name = "(unnamed)"
EndIf
PrintN(Kind + " " + Name + " = " + Str(Id))

ToolClient_Close()
ToolConsole_End(0)
