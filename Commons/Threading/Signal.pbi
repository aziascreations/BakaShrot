; ============================================================================
; BakaShrot Signal
;
; Wakes up a thread waiting for something, instead of it polling with Delay():
;   Waiter:  BakaShrot_Signal_Wait(Signal, TimeoutMs), then checks for work.
;   Waker:   does the work's setup, then BakaShrot_Signal_Set(Signal).
; Signals don't stack: several Set() before a Wait() wake it once, so the
; waiter must handle everything that's there once woken. A Set() before the
; Wait() isn't lost, the Wait() returns right away.
;
; Windows: an auto-reset event. Elsewhere: a semaphore polled every ms, until
; something better is needed there.
; ============================================================================

CompilerIf #PB_Compiler_OS = #PB_OS_Windows

	; Returns 0 on failure.
	Procedure.i BakaShrot_Signal_Create()
		; Auto-reset, not set.
		ProcedureReturn CreateEvent_(0, #False, #False, 0)
	EndProcedure

	Procedure BakaShrot_Signal_Set(Signal.i)
		SetEvent_(Signal)
	EndProcedure

	; Waits until Signal is set, for up to TimeoutMs.
	; Returns #True if it was set, #False if it timed out.
	Procedure.i BakaShrot_Signal_Wait(Signal.i, TimeoutMs.i)
		; WAIT_OBJECT_0
		ProcedureReturn Bool(WaitForSingleObject_(Signal, TimeoutMs) = 0)
	EndProcedure

	Procedure BakaShrot_Signal_Free(Signal.i)
		CloseHandle_(Signal)
	EndProcedure

CompilerElse

	Procedure.i BakaShrot_Signal_Create()
		ProcedureReturn CreateSemaphore(0)
	EndProcedure

	Procedure BakaShrot_Signal_Set(Signal.i)
		SignalSemaphore(Signal)
	EndProcedure

	Procedure.i BakaShrot_Signal_Wait(Signal.i, TimeoutMs.i)
		Protected StartTime.i = ElapsedMilliseconds()

		Repeat
			If TrySemaphore(Signal)
				; Doesn't stack, like the Windows version.
				While TrySemaphore(Signal)
				Wend
				ProcedureReturn #True
			EndIf
			If ElapsedMilliseconds() - StartTime >= TimeoutMs
				ProcedureReturn #False
			EndIf
			Delay(1)
		ForEver
	EndProcedure

	Procedure BakaShrot_Signal_Free(Signal.i)
		FreeSemaphore(Signal)
	EndProcedure

CompilerEndIf
