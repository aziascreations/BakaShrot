;{- Code Header
; ==- Basic Info -================================
;     Name: Names.pbi
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
; BakaShrot Names
;
; Topics and nodes have a numeric id (0-65535) on each server, and a name
; that's the same on every server: replication sends names, and each server
; translates them to its own ids (see Server/Storage/Names.pbi).
;
; Wherever a topic or node is given (config, requests, tools), it's a "ref":
;   - a name: 1-64 characters out of A-Z a-z 0-9 _ . -, not only digits,
;     compared without case ("Logs" is "logs"),
;   - or an id written in digits, 0-65535, which is always that id.
; A topic or node without a name is known by its id in digits, "7".
; ============================================================================


#BakaShrot_MaxNameLength = 64
#BakaShrot_MaxId         = 65535


; #True if Text is made of digits only (and isn't empty).
Procedure.i BakaShrot_IsDigits(Text.s)
	Protected i.i, c.i

	If Text = ""
		ProcedureReturn #False
	EndIf
	For i = 1 To Len(Text)
		c = Asc(Mid(Text, i, 1))
		If c < '0' Or c > '9'
			ProcedureReturn #False
		EndIf
	Next
	ProcedureReturn #True
EndProcedure


; #True if Name can be a topic or node name: see the top of this file.
Procedure.i BakaShrot_IsValidName(Name.s)
	Protected i.i, c.i

	If Name = "" Or Len(Name) > #BakaShrot_MaxNameLength Or BakaShrot_IsDigits(Name)
		ProcedureReturn #False
	EndIf
	For i = 1 To Len(Name)
		c = Asc(Mid(Name, i, 1))
		If Not ((c >= 'a' And c <= 'z') Or (c >= 'A' And c <= 'Z') Or (c >= '0' And c <= '9') Or c = '_' Or c = '.' Or c = '-')
			ProcedureReturn #False
		EndIf
	Next
	ProcedureReturn #True
EndProcedure


; The id a ref written in digits stands for, or -1 if it isn't one (a name,
; or out of range). Leading zeros are refused, "007" isn't "7".
Procedure.i BakaShrot_RefToId(Ref.s)
	Protected Id.i

	If Not BakaShrot_IsDigits(Ref) Or Len(Ref) > 5
		ProcedureReturn -1
	EndIf
	Id = Val(Ref)
	If Str(Id) <> Ref Or Id > #BakaShrot_MaxId
		ProcedureReturn -1
	EndIf
	ProcedureReturn Id
EndProcedure


; #True if Ref is a valid name or a valid id in digits.
Procedure.i BakaShrot_IsValidRef(Ref.s)
	ProcedureReturn Bool(BakaShrot_RefToId(Ref) >= 0 Or BakaShrot_IsValidName(Ref))
EndProcedure


; #True if Ref designates the topic or node Id, named Name ("" if unnamed).
Procedure.i BakaShrot_RefMatches(Ref.s, Id.i, Name.s)
	If BakaShrot_IsDigits(Ref)
		ProcedureReturn Bool(BakaShrot_RefToId(Ref) = Id)
	EndIf
	ProcedureReturn Bool(Name <> "" And LCase(Ref) = LCase(Name))
EndProcedure


; --- Wildcards ---------------------------------------------------------------
; Server-side lists of topics and nodes (topic lists, SendNodes, ...) also
; take patterns, like file names: "*" any characters (none included), "?"
; exactly one, everything else itself, without case. "sensors.*",
; "kitchen-??", "*". A pattern only matches names, never ids in digits.

; #True if Pattern is a valid pattern: has a * or a ?, and otherwise only
; characters a name can have.
Procedure.i BakaShrot_IsValidPattern(Pattern.s)
	Protected i.i, c.i

	If Pattern = "" Or Len(Pattern) > #BakaShrot_MaxNameLength
		ProcedureReturn #False
	EndIf
	If Not FindString(Pattern, "*") And Not FindString(Pattern, "?")
		ProcedureReturn #False
	EndIf
	For i = 1 To Len(Pattern)
		c = Asc(Mid(Pattern, i, 1))
		If Not ((c >= 'a' And c <= 'z') Or (c >= 'A' And c <= 'Z') Or (c >= '0' And c <= '9') Or c = '_' Or c = '.' Or c = '-' Or c = '*' Or c = '?')
			ProcedureReturn #False
		EndIf
	Next
	ProcedureReturn #True
EndProcedure


; #True if Name matches Pattern (see above), without case. Ids in digits
; never match.
Procedure.i BakaShrot_GlobMatch(Pattern.s, Name.s)
	Protected p.i = 1, n.i = 1, StarP.i = 0, StarN.i = 0
	Protected PLen.i, NLen.i, pc.s

	If Not BakaShrot_IsValidName(Name)
		ProcedureReturn #False
	EndIf
	Pattern = LCase(Pattern)
	Name    = LCase(Name)
	PLen = Len(Pattern)
	NLen = Len(Name)

	; Greedy with backtracking to the last "*": linear enough for 64 characters.
	While n <= NLen
		If p <= PLen
			pc = Mid(Pattern, p, 1)
		Else
			pc = ""
		EndIf
		If pc = "*"
			StarP = p
			StarN = n
			p + 1
		ElseIf pc <> "" And (pc = "?" Or pc = Mid(Name, n, 1))
			p + 1
			n + 1
		ElseIf StarP
			p = StarP + 1
			StarN + 1
			n = StarN
		Else
			ProcedureReturn #False
		EndIf
	Wend
	While p <= PLen And Mid(Pattern, p, 1) = "*"
		p + 1
	Wend
	ProcedureReturn Bool(p > PLen)
EndProcedure
