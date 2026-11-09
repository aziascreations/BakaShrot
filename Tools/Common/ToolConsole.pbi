; ============================================================================
; BakaShrot Tools - Console
;
; Shared by every tool. Started from Explorer (a double-click, a shortcut),
; a console program gets a console of its own that closes as soon as it
; ends, before what it printed can be read: ToolConsole_End() waits for
; Enter then, and ends at once otherwise.
; As https://github.com/aziascreations/PB-Template-Win32-CliApp does it: a
; program started from a shell shares the shell's console, one started
; directly is alone in its own.
; ============================================================================

CompilerIf #PB_Compiler_OS = #PB_OS_Windows
	; Not in PureBasic 5.73's API functions, named so it can't clash with a
	; compiler that has it.
	Import "kernel32.lib"
		CompilerIf #PB_Compiler_Processor = #PB_Processor_x86
			ToolConsole_GetConsoleProcessList.l(*ProcessList, ProcessCount.l) As "_GetConsoleProcessList@8"
		CompilerElse
			ToolConsole_GetConsoleProcessList.l(*ProcessList, ProcessCount.l) As "GetConsoleProcessList"
		CompilerEndIf
	EndImport
CompilerEndIf


; #True if the tool was started directly rather than from a shell: it is the
; only process on its console. Input or output redirected is #False, someone
; else reads it (a test starting it with Start-Process gets a new hidden
; console too, alone on it). Always #False outside of Windows.
Procedure.i ToolConsole_IsRunDirectly()
	CompilerIf #PB_Compiler_OS = #PB_OS_Windows
		Protected Mode.l, ProcessList.q ; ProcessList: room for 2 process ids

		If Not GetConsoleMode_(GetStdHandle_(#STD_INPUT_HANDLE), @Mode)
			ProcedureReturn #False
		EndIf
		If Not GetConsoleMode_(GetStdHandle_(#STD_OUTPUT_HANDLE), @Mode)
			ProcedureReturn #False
		EndIf
		ProcedureReturn Bool(ToolConsole_GetConsoleProcessList(@ProcessList, 2) <= 1)
	CompilerElse
		ProcedureReturn #False
	CompilerEndIf
EndProcedure


; Ends the tool with ExitCode, after waiting for Enter if it was started
; directly (ToolConsole_IsRunDirectly()).
Procedure ToolConsole_End(ExitCode.i)
	If ToolConsole_IsRunDirectly()
		PrintN("")
		Print("Press Enter to close...")
		Input()
	EndIf
	End ExitCode
EndProcedure
