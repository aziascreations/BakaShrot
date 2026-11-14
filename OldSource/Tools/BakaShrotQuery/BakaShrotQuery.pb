;{- Code Header
; ==- Basic Info -================================
;     Name: BakaShrotQuery.pb
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
; BakaShrotQuery
;
; Usage: BakaShrotQuery <Sql|@SqlFile> [ClientIni]
;   Sql         A single read-only SELECT (or WITH ... SELECT), or @ followed
;               by a file holding it. Command-line arguments lose their
;               double quotes, use single quotes or @SqlFile.
;   ClientIni   Identity and server to use, defaults to "client.ini".
;
; Runs a raw SQL query on the server and prints its result as JSON:
;   {"columns": ["name", ...], "rows": [["value", ...], ...]}
; The client must be allowed to query: AllowQuery = 1 in its server-side
; [BakaShrot.Client.<name>].
; Compile as a console program, exits with 0 on success, 1 on failure.
; ============================================================================

EnableExplicit

XIncludeFile "../Common/ToolClient.pbi"


Define Sql.s, IniPath.s, FileText.String

OpenConsole()

If CountProgramParameters() < 1
	PrintN("Usage: BakaShrotQuery <Sql|@SqlFile> [ClientIni]")
	PrintN("  Command-line arguments lose their double quotes, use single quotes or @SqlFile.")
	ToolConsole_End(1)
EndIf

Sql = ProgramParameter(0)
If Left(Sql, 1) = "@"
	If Not ToolClient_ReadTextFile(Mid(Sql, 2), @FileText)
		ToolConsole_End(1)
	EndIf
	Sql = FileText\s
EndIf

IniPath = "client.ini"
If CountProgramParameters() > 1
	IniPath = ProgramParameter(1)
EndIf

If Not ToolClient_Connect(IniPath)
	ToolConsole_End(1)
EndIf

If Not BakaShrot_Query(Sql)
	ToolClient_PrintFailure()
	ToolClient_Close()
	ToolConsole_End(1)
EndIf

PrintN(BakaShrot_GetQueryResultString())

ToolClient_Close()
ToolConsole_End(0)
