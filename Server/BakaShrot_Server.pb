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
; Windows: it stops once there's no more console input (no console, closed
; standard input). Elsewhere, it runs on without one (a container, a
; service) and SIGTERM or SIGINT stops it the same way as "quit".
;
; Compile as a thread-safe console program.
; ============================================================================

EnableExplicit

XIncludeFile "Root.pbi"


#BakaShrot_Server_DefaultConfigPath = "config.ini"


Procedure PrintCommands()
	PrintN("Commands: quit (or an empty line), restart, vacuum, names, help")
EndProcedure


CompilerIf #PB_Compiler_OS <> #PB_OS_Windows
	; Same numbers on Linux and macOS.
	#BakaShrot_Server_SigInt  = 2
	#BakaShrot_Server_SigTerm = 15
	#BakaShrot_Server_PollIn  = $0001
	#BakaShrot_Server_FDupFd  = 0

	; struct pollfd
	Structure BakaShrot_Server_PollFd
		Fd.l
		Events.w
		REvents.w
	EndStructure

	ImportC ""
		BakaShrot_Server_Signal.i(Signal.l, *Handler) As "signal"
		BakaShrot_Server_Poll.l(*Fds, Count.i, TimeoutMs.l) As "poll"
		BakaShrot_Server_Read.i(Fd.l, *Buffer, Size.i) As "read"
		; dup() itself can't be imported: fasm reserves the name.
		BakaShrot_Server_Fcntl.l(Fd.l, Command.l, Argument.i) As "fcntl"
	EndImport

	; Longest command line kept, the rest of a longer one is dropped.
	#BakaShrot_Server_MaxCommandSize = 256

	; The signal that asked to stop, 0 until then. Only ever set by the
	; handler (all a handler may safely do), read by ReadCommand().
	Global BakaShrot_Server_StopSignal.l = 0

	; #True once standard input is closed: commands can't come any more.
	Global BakaShrot_Server_NoInput.i = #False

	; Standard input, taken before OpenConsole(): it moves descriptor 0
	; elsewhere and closes it (then reused by the next file opened).
	Global BakaShrot_Server_InputFd.l = -1

	ProcedureC BakaShrot_Server_OnSignal(Signal.l)
		BakaShrot_Server_StopSignal = Signal
	EndProcedure
CompilerEndIf


; Waits for the next command, Chr(4) once there's no more input.
; Windows: Input(). Elsewhere, Input() returns "" (quit) at the end of the
; input and blocks until a whole line came, so standard input is read here
; instead: never blocking for more than 250 ms without checking for a stop
; signal (it then returns "", see BakaShrot_Server_StopSignal).
Procedure.s ReadCommand()
	CompilerIf #PB_Compiler_OS = #PB_OS_Windows
		ProcedureReturn Input()
	CompilerElse
		Protected Fd.BakaShrot_Server_PollFd, Byte.a, BytesRead.i, Size.i
		Protected Dim Chars.a(#BakaShrot_Server_MaxCommandSize)

		Repeat
			If BakaShrot_Server_StopSignal
				ProcedureReturn ""
			EndIf
			If BakaShrot_Server_NoInput
				Delay(250)
				Continue
			EndIf
			If BakaShrot_Server_InputFd < 0
				ProcedureReturn Chr(4)
			EndIf

			Fd\Fd = BakaShrot_Server_InputFd
			Fd\Events = #BakaShrot_Server_PollIn
			Fd\REvents = 0
			If BakaShrot_Server_Poll(@Fd, 1, 250) <= 0
				Continue
			EndIf

			; Readable, or closed: one byte, so nothing is read past the line.
			BytesRead = BakaShrot_Server_Read(BakaShrot_Server_InputFd, @Byte, 1)
			If BytesRead = 0 Or (BytesRead < 0 And Not BakaShrot_Server_StopSignal)
				ProcedureReturn Chr(4)
			EndIf
			If BytesRead = 1
				If Byte = 10
					ProcedureReturn PeekS(@Chars(0), Size, #PB_UTF8 | #PB_ByteLength)
				EndIf
				; CR of a CRLF skipped.
				If Byte <> 13 And Size < #BakaShrot_Server_MaxCommandSize
					Chars(Size) = Byte
					Size + 1
				EndIf
			EndIf
		ForEver
	CompilerEndIf
EndProcedure


Define Root.BakaShrot_Root
Define Command.s, ExitCode.i

CompilerIf #PB_Compiler_OS <> #PB_OS_Windows
	BakaShrot_Server_InputFd = BakaShrot_Server_Fcntl(0, #BakaShrot_Server_FDupFd, 0)
CompilerEndIf

OpenConsole("BakaShrot Server")

CompilerIf #PB_Compiler_OS <> #PB_OS_Windows
	BakaShrot_Server_Signal(#BakaShrot_Server_SigTerm, @BakaShrot_Server_OnSignal())
	BakaShrot_Server_Signal(#BakaShrot_Server_SigInt, @BakaShrot_Server_OnSignal())
CompilerEndIf

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
	Command = LCase(Trim(ReadCommand()))

	CompilerIf #PB_Compiler_OS <> #PB_OS_Windows
		If BakaShrot_Server_StopSignal
			If BakaShrot_Server_StopSignal = #BakaShrot_Server_SigTerm
				PrintN("Got SIGTERM, stopping")
			Else
				PrintN("Got SIGINT, stopping")
			EndIf
			Break
		EndIf
	CompilerEndIf

	; Once there's no more input (no console, closed standard input), every
	; ReadCommand() returns Chr(4) right away. Without this, it would loop
	; forever.
	If FindString(Command, Chr(4))
		CompilerIf #PB_Compiler_OS = #PB_OS_Windows
			PrintN("No more input, stopping")
			Break
		CompilerElse
			PrintN("No console input, running until SIGTERM or SIGINT")
			BakaShrot_Server_NoInput = #True
			Continue
		CompilerEndIf
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
