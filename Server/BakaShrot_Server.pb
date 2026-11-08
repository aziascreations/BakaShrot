; ============================================================================
; BakaShrot Server - CLI entry point
;
; Usage: BakaShrot_Server [ConfigFile]
;   ConfigFile  Path to the server's ini config, defaults to "config.ini".
;               See Config/schema.ini for its layout.
;
; Loads the config, opens and sets up the database at [BakaShrot.Server]
; DatabasePath, listens on [BakaShrot.Server] Host:Port, and links to every
; [BakaShrot.Peer.<name>]. Then reads commands from the console:
;   (empty), quit  Stops the server.
;   restart        Stops every worker, reloads the config, starts again.
;   vacuum         Stops every worker, VACUUMs the database, starts again.
;   names          Lists every topic and node with its id and name.
;   help           Lists the commands.
; See Root.pbi for how the workers are stopped.
; Exits with 0 on success, 1 on failure.
;
; Compile as a thread-safe console program.
; ============================================================================

EnableExplicit

XIncludeFile "Root.pbi"


#BakaShrot_Server_DefaultConfigPath = "config.ini"


Procedure PrintCommands()
	PrintN("Commands: quit (or an empty line), restart, vacuum, names, help")
EndProcedure


Define Root.BakaShrot_Root
Define Command.s, ExitCode.i

OpenConsole("BakaShrot Server")

Root\ConfigPath = #BakaShrot_Server_DefaultConfigPath
If CountProgramParameters() > 0
	Root\ConfigPath = ProgramParameter(0)
EndIf

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

PrintN("Running.")
PrintCommands()

ExitCode = 0
Repeat
	Command = LCase(Trim(Input()))

	; Once there's no more input (no console, closed standard input), every
	; Input() returns Chr(4) right away. Without this, it would loop forever.
	If FindString(Command, Chr(4))
		PrintN("No more input, stopping")
		Break
	EndIf

	Select Command
		Case "", "quit"
			Break

		Case "restart"
			If Not BakaShrot_Root_Restart(@Root)
				PrintN("[Root] Restart failed, stopping")
				ExitCode = 1
				Break
			EndIf

		Case "vacuum"
			If Not BakaShrot_Root_Vacuum(@Root)
				PrintN("[Root] Couldn't start again after vacuuming, stopping")
				ExitCode = 1
				Break
			EndIf

		Case "names"
			BakaShrot_Names_Print()

		Case "help"
			PrintCommands()

		Default
			PrintN("Unknown command '" + Command + "'")
			PrintCommands()
	EndSelect
ForEver

PrintN("Stopping...")
BakaShrot_Root_StopWorkers(@Root)
BakaShrot_Root_CloseDatabase(@Root)
FreeConfig(Root\Config)
End ExitCode
