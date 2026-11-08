; ============================================================================
; BakaShrot Bench Server
;
; Usage: BenchServer <ConfigFile> <StopFile>
;
; The real server (Server/Root.pbi), without the console commands: it runs
; until StopFile exists, then stops its workers cleanly and exits.
; BakaShrot_Server.exe can't run headless, with no console input its
; Input() returns Chr(4) and it stops right away, see Notes.md.
;
; Used by Tests/Bench/Bench-Replication.ps1, compile as a thread-safe console
; program.
; ============================================================================

EnableExplicit

XIncludeFile "../../Server/Root.pbi"


Define Root.BakaShrot_Root
Define StopFile.s

OpenConsole("BakaShrot Bench Server")

If CountProgramParameters() < 2
	PrintN("Usage: BenchServer <ConfigFile> <StopFile>")
	End 1
EndIf

Root\ConfigPath = ProgramParameter(0)
StopFile        = ProgramParameter(1)

If Not BakaShrot_Root_LoadConfig(@Root)
	End 1
EndIf

If Not BakaShrot_Root_OpenDatabase(@Root)
	FreeConfig(Root\Config)
	End 1
EndIf

If Not BakaShrot_Root_StartWorkers(@Root)
	BakaShrot_Root_CloseDatabase(@Root)
	FreeConfig(Root\Config)
	End 1
EndIf

PrintN("Running until '" + StopFile + "' exists.")

While FileSize(StopFile) < 0
	Delay(200)
Wend

PrintN("Stopping...")
BakaShrot_Root_StopWorkers(@Root)
BakaShrot_Root_CloseDatabase(@Root)
FreeConfig(Root\Config)
End 0
