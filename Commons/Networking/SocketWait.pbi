; ============================================================================
; BakaShrot Socket waits
;
; Sleeps until one of a few sockets has something to read (data, a new
; connection, or a disconnect), instead of polling NetworkClientEvent() /
; NetworkServerEvent() with Delay():
;   BakaShrot_SocketSet_Clear(@Set)
;   BakaShrot_SocketSet_Add(@Set, ConnectionID(Connection))  ; or ServerID()
;   BakaShrot_SocketSet_Wait(@Set, TimeoutMs)
;   ... then NetworkClientEvent() / NetworkServerEvent() as usual.
; Only call it once those returned #PB_NetworkEvent_None: PureBasic may
; already hold events it hasn't returned yet, that select() can't see.
;
; Windows: select() from ws2_32. Elsewhere: a plain Delay(1) for now.
; ============================================================================

; Most sockets in one wait, the others are left out (they're still served,
; just with up to TimeoutMs of delay).
#BakaShrot_SocketSet_MaxSockets = 1024


CompilerIf #PB_Compiler_OS = #PB_OS_Windows

	; Same layout as Winsock's fd_set, with a bigger array: Winsock reads
	; Count entries, whatever FD_SETSIZE says.
	Structure BakaShrot_SocketSet
		Count.l
		CompilerIf #PB_Compiler_Processor = #PB_Processor_x64
			Padding.l
		CompilerEndIf
		Sockets.i[#BakaShrot_SocketSet_MaxSockets]
	EndStructure

	Structure BakaShrot_TimeVal
		Seconds.l
		Microseconds.l
	EndStructure

	Prototype.l BakaShrot_Select_Prototype(Ignored.l, *ReadSet, *WriteSet, *ErrorSet, *Timeout)

	Global BakaShrot_Select.BakaShrot_Select_Prototype = 0
	Global BakaShrot_SelectLoaded.i = #False
	Global BakaShrot_SelectMutex.i = CreateMutex()

	Procedure BakaShrot_SocketSet_Load()
		Protected Library.i

		LockMutex(BakaShrot_SelectMutex)
		If Not BakaShrot_SelectLoaded
			Library = OpenLibrary(#PB_Any, "ws2_32.dll")
			If Library
				BakaShrot_Select = GetFunction(Library, "select")
			EndIf
			BakaShrot_SelectLoaded = #True
		EndIf
		UnlockMutex(BakaShrot_SelectMutex)
	EndProcedure

	Procedure BakaShrot_SocketSet_Clear(*Set.BakaShrot_SocketSet)
		*Set\Count = 0
	EndProcedure

	Procedure BakaShrot_SocketSet_Add(*Set.BakaShrot_SocketSet, Socket.i)
		If Socket And *Set\Count < #BakaShrot_SocketSet_MaxSockets
			*Set\Sockets[*Set\Count] = Socket
			*Set\Count + 1
		EndIf
	EndProcedure

	; Waits until a socket of *Set is readable, for up to TimeoutMs.
	; Returns #True if one is (or select() failed, to be safe), #False if it
	; timed out. *Set is overwritten, clear and fill it again before reusing it.
	Procedure.i BakaShrot_SocketSet_Wait(*Set.BakaShrot_SocketSet, TimeoutMs.i)
		Protected Timeout.BakaShrot_TimeVal, Result.l

		If Not BakaShrot_SelectLoaded
			BakaShrot_SocketSet_Load()
		EndIf
		If Not BakaShrot_Select Or *Set\Count = 0
			Delay(1)
			ProcedureReturn #True
		EndIf

		Timeout\Seconds      = TimeoutMs / 1000
		Timeout\Microseconds = (TimeoutMs % 1000) * 1000
		Result = BakaShrot_Select(0, *Set, 0, 0, @Timeout)
		If Result < 0
			; A socket closed meanwhile by another thread, most likely.
			Delay(1)
			ProcedureReturn #True
		EndIf
		ProcedureReturn Bool(Result > 0)
	EndProcedure

CompilerElse

	Structure BakaShrot_SocketSet
		Count.l
	EndStructure

	Procedure BakaShrot_SocketSet_Clear(*Set.BakaShrot_SocketSet)
		*Set\Count = 0
	EndProcedure

	Procedure BakaShrot_SocketSet_Add(*Set.BakaShrot_SocketSet, Socket.i)
		*Set\Count + 1
	EndProcedure

	Procedure.i BakaShrot_SocketSet_Wait(*Set.BakaShrot_SocketSet, TimeoutMs.i)
		Delay(1)
		ProcedureReturn #True
	EndProcedure

CompilerEndIf


; Waits until Socket is readable, for up to TimeoutMs.
Procedure.i BakaShrot_WaitSocket(Socket.i, TimeoutMs.i)
	Protected Set.BakaShrot_SocketSet

	BakaShrot_SocketSet_Clear(@Set)
	BakaShrot_SocketSet_Add(@Set, Socket)
	ProcedureReturn BakaShrot_SocketSet_Wait(@Set, TimeoutMs)
EndProcedure
