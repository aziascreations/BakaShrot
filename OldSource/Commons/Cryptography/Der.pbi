;{- Code Header
; ==- Basic Info -================================
;     Name: Der.pbi
;  Version: 0.0.1
;   Author: Herwin Bozet (NibblePoker)
;
; ==- Compatibility -=============================
;  Tested compiler versions:
;    * PureBasic 5.73 LTS (Windows x64)
;    * PureBasic 6.40 C Backend (Windows x64)
;
; ==- Links -=====================================
;  GitHub: https://github.com/aziascreations/BakaShrot
;}

; ============================================================================
; BakaShrot DER
;
; Reading and writing ASN.1 DER, the encoding of X.509 certificates, for
; Commons/Cryptography/X509.pbi. Only what certificates use: universal
; tags, context tags [0]-[30], lengths up to #BakaShrot_Der_MaxSize.
;
; Reading is strict, anything that isn't DER is refused:
;   - definite lengths only, in their shortest form,
;   - tag numbers under 31 (one identifier byte),
;   - integers in their shortest form, booleans $00 or $FF,
;   - OIDs without padded arcs, times as UTCTime "YYMMDDHHMMSSZ" or
;     GeneralizedTime "YYYYMMDDHHMMSSZ" (UTC, whole seconds, real dates),
;   - strings without a NUL, PrintableString and IA5String in ASCII.
; A reader never reads past its end: element and contents sizes are checked
; before anything is read.
;
; Reading: a BakaShrot_DerReader walks the elements of a buffer, or of a
; constructed element's contents (BakaShrot_Der_ReaderOf()). Once a read
; fails, the reader stays failed. The elements point into the buffer read,
; which must outlive them.
;
; Writing: a BakaShrot_DerWriter appends elements to a buffer it grows;
; BakaShrot_Der_Begin()/_End() wrap what's written between them in a
; constructed element (SEQUENCE, SET, [n], or an OCTET STRING holding DER).
; Once a write fails the writer stays failed, BakaShrot_Der_Finish() gives
; the result or 0.
;
; Times are seconds since 1970-01-01 00:00:00 UTC, years 0000 to 9999.
; OIDs are dotted text ("1.3.101.112"), arcs of any size up to 140 bits
; (2.25.<UUID> OIDs have 128-bit arcs).
;
; No globals: any number of threads, each with its own readers and writers.
; ============================================================================


; Universal tags, as their whole identifier byte.
#BakaShrot_Der_Boolean         = $01
#BakaShrot_Der_Integer         = $02
#BakaShrot_Der_BitString       = $03
#BakaShrot_Der_OctetString     = $04
#BakaShrot_Der_Null            = $05
#BakaShrot_Der_Oid             = $06
#BakaShrot_Der_Utf8String      = $0C
#BakaShrot_Der_PrintableString = $13
#BakaShrot_Der_T61String       = $14
#BakaShrot_Der_Ia5String       = $16
#BakaShrot_Der_UtcTime         = $17
#BakaShrot_Der_GeneralizedTime = $18
#BakaShrot_Der_BmpString       = $1E
#BakaShrot_Der_Sequence        = $30
#BakaShrot_Der_Set             = $31

; Context-specific tags: #BakaShrot_Der_Context | n for a primitive [n]
; (IMPLICIT of a primitive type), #BakaShrot_Der_ContextConstructed | n for
; a constructed one (EXPLICIT, or IMPLICIT of a constructed type).
#BakaShrot_Der_Context            = $80
#BakaShrot_Der_ContextConstructed = $A0

; Biggest element read or written, far more than any certificate.
#BakaShrot_Der_MaxSize = $1000000

; Most constructed elements a writer keeps open at once.
#BakaShrot_Der_MaxDepth = 16

; Longest OID arc, encoded: 20 bytes of 7 bits, 140 bits.
#BakaShrot_Der_MaxArcBytes = 20

; Longest OID arc in decimal digits (2^140 has 43; DecimalToArc() refuses
; what still takes more than 20 bytes).
#BakaShrot_Der_MaxArcDigits = 43


; An element read: its whole identifier byte, where it starts, its size
; with its header, and its contents.
Structure BakaShrot_DerElement
	Tag.i
	*Start
	Size.i
	*Content
	ContentSize.i
EndStructure


Structure BakaShrot_DerReader
	*Position
	*End
	Failed.i
EndStructure


Structure BakaShrot_DerWriter
	*Buffer
	Capacity.i
	Size.i
	; The constructed elements begun and not ended yet: where their contents
	; start in Buffer, and their tags.
	Depth.i
	Starts.i[#BakaShrot_Der_MaxDepth]
	Tags.i[#BakaShrot_Der_MaxDepth]
	Failed.i
EndStructure


;- Reading

; Reads Size bytes at *Data.
Procedure BakaShrot_Der_InitReader(*Reader.BakaShrot_DerReader, *Data, Size.i)
	*Reader\Position = *Data
	*Reader\End      = *Data
	*Reader\Failed   = #True
	If *Data And Size >= 0
		*Reader\End    = *Data + Size
		*Reader\Failed = #False
	EndIf
EndProcedure


; Reads the contents of *Element (a SEQUENCE, a SET, an EXPLICIT [n]...).
Procedure BakaShrot_Der_ReaderOf(*Reader.BakaShrot_DerReader, *Element.BakaShrot_DerElement)
	BakaShrot_Der_InitReader(*Reader, *Element\Content, *Element\ContentSize)
EndProcedure


; #True once everything was read, and nothing failed.
Procedure.i BakaShrot_Der_AtEnd(*Reader.BakaShrot_DerReader)
	ProcedureReturn Bool(Not *Reader\Failed And *Reader\Position = *Reader\End)
EndProcedure


; The identifier byte of the next element, -1 at the end or once failed.
; Doesn't move: for OPTIONAL and DEFAULT elements.
Procedure.i BakaShrot_Der_PeekTag(*Reader.BakaShrot_DerReader)
	If *Reader\Failed Or *Reader\Position >= *Reader\End
		ProcedureReturn -1
	EndIf
	ProcedureReturn PeekA(*Reader\Position)
EndProcedure


; Reads the next element, whatever its tag, into *Element.
; Returns #False, and the reader fails, at the end or if it isn't DER.
Procedure.i BakaShrot_Der_Read(*Reader.BakaShrot_DerReader, *Element.BakaShrot_DerElement)
	Protected *P, Left.i, Tag.i, First.i, Count.i, Length.q, i.i

	If *Reader\Failed
		ProcedureReturn #False
	EndIf
	*P   = *Reader\Position
	Left = *Reader\End - *P
	If Left < 2
		Goto ReadFailed
	EndIf

	; High tag numbers (31 and up) take more bytes, certificates never use them.
	Tag = PeekA(*P)
	If (Tag & $1F) = $1F
		Goto ReadFailed
	EndIf

	First = PeekA(*P + 1)
	If First < $80
		Length = First
		Count  = 0
	ElseIf First = $80 Or First > $84
		; Indefinite (BER only), or over 4 bytes of length.
		Goto ReadFailed
	Else
		Count = First & $7F
		If Left < 2 + Count
			Goto ReadFailed
		EndIf
		; The shortest form only: no leading zero, the long form from 128 on.
		If PeekA(*P + 2) = 0
			Goto ReadFailed
		EndIf
		Length = 0
		For i = 0 To Count - 1
			Length = (Length << 8) | PeekA(*P + 2 + i)
		Next
		If Length < $80
			Goto ReadFailed
		EndIf
	EndIf

	If Length > #BakaShrot_Der_MaxSize Or Length > Left - 2 - Count
		Goto ReadFailed
	EndIf

	*Element\Tag         = Tag
	*Element\Start       = *P
	*Element\Content     = *P + 2 + Count
	*Element\ContentSize = Length
	*Element\Size        = 2 + Count + Length
	*Reader\Position     = *P + *Element\Size
	ProcedureReturn #True

	ReadFailed:
	*Reader\Failed = #True
	ProcedureReturn #False
EndProcedure


; Reads the next element, which must have Tag, into *Element.
; Returns #False, and the reader fails, otherwise.
Procedure.i BakaShrot_Der_Expect(*Reader.BakaShrot_DerReader, Tag.i, *Element.BakaShrot_DerElement)
	If Not BakaShrot_Der_Read(*Reader, *Element)
		ProcedureReturn #False
	EndIf
	If *Element\Tag <> Tag
		*Reader\Failed = #True
		ProcedureReturn #False
	EndIf
	ProcedureReturn #True
EndProcedure


; #True if *Element's contents are a DER integer: at least a byte, and no
; leading byte that only repeats the sign. Any size.
Procedure.i BakaShrot_Der_IsMinimalInteger(*Element.BakaShrot_DerElement)
	Protected *C = *Element\Content

	If *Element\ContentSize < 1
		ProcedureReturn #False
	EndIf
	If *Element\ContentSize > 1
		If (PeekA(*C) = $00 And PeekA(*C + 1) < $80) Or (PeekA(*C) = $FF And PeekA(*C + 1) >= $80)
			ProcedureReturn #False
		EndIf
	EndIf
	ProcedureReturn #True
EndProcedure


; An integer of up to 8 bytes into *Value\q (signed).
Procedure.i BakaShrot_Der_GetInteger(*Element.BakaShrot_DerElement, *Value.Quad)
	Protected *C = *Element\Content, Value.q, i.i

	If *Element\ContentSize > 8 Or Not BakaShrot_Der_IsMinimalInteger(*Element)
		ProcedureReturn #False
	EndIf
	; The first byte sign-extended, then the others.
	Value = PeekB(*C)
	For i = 1 To *Element\ContentSize - 1
		Value = (Value << 8) | PeekA(*C + i)
	Next
	*Value\q = Value
	ProcedureReturn #True
EndProcedure


; A BOOLEAN into *Value\i, #True or #False.
Procedure.i BakaShrot_Der_GetBoolean(*Element.BakaShrot_DerElement, *Value.Integer)
	If *Element\ContentSize <> 1
		ProcedureReturn #False
	EndIf
	Select PeekA(*Element\Content)
		Case $00
			*Value\i = #False
		Case $FF
			*Value\i = #True
		Default
			ProcedureReturn #False
	EndSelect
	ProcedureReturn #True
EndProcedure


; A BIT STRING of whole bytes (keys, signatures): *Bytes\i points to them in
; the element, *Size\i is how many.
Procedure.i BakaShrot_Der_GetBitStringBytes(*Element.BakaShrot_DerElement, *Bytes.Integer, *Size.Integer)
	If *Element\ContentSize < 1 Or PeekA(*Element\Content) <> 0
		ProcedureReturn #False
	EndIf
	*Bytes\i = *Element\Content + 1
	*Size\i  = *Element\ContentSize - 1
	ProcedureReturn #True
EndProcedure


; A BIT STRING of named bits (KeyUsage) as flags: bit n of the string, the
; first one being 0, is 1 << n. Up to 32 bits.
Procedure.i BakaShrot_Der_GetBitFlags(*Element.BakaShrot_DerElement, *Flags.Integer)
	Protected *C = *Element\Content, Size.i = *Element\ContentSize, Unused.i, Flags.i, i.i, Bit.i, Byte.i

	If Size < 1 Or Size > 5
		ProcedureReturn #False
	EndIf
	Unused = PeekA(*C)
	If Unused > 7 Or (Size = 1 And Unused <> 0)
		ProcedureReturn #False
	EndIf
	; The unused bits of the last byte must be zero.
	If Size > 1 And (PeekA(*C + Size - 1) & ((1 << Unused) - 1)) <> 0
		ProcedureReturn #False
	EndIf
	For i = 1 To Size - 1
		Byte = PeekA(*C + i)
		For Bit = 0 To 7
			If Byte & ($80 >> Bit)
				Flags = Flags | (1 << ((i - 1) * 8 + Bit))
			EndIf
		Next
	Next
	*Flags\i = Flags
	ProcedureReturn #True
EndProcedure


;- OIDs

; #True if Text is one or more digits, without a leading zero (but "0").
Procedure.i BakaShrot_Der_IsDecimal(Text.s)
	Protected i.i, c.i

	If Text = "" Or Len(Text) > #BakaShrot_Der_MaxArcDigits Or (Len(Text) > 1 And Left(Text, 1) = "0")
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


; The arc in Count bytes of base-128 groups at *P, in decimal.
Procedure.s BakaShrot_Der_ArcToDecimal(*P, Count.i)
	Protected Dim Digits.a(63)
	Protected Length.i = 1, i.i, j.i, Carry.i, x.i, Text.s

	; Digits(), least significant first: times 128 plus the group, per group.
	For i = 0 To Count - 1
		Carry = PeekA(*P + i) & $7F
		For j = 0 To Length - 1
			x = Digits(j) * 128 + Carry
			Digits(j) = x % 10
			Carry = x / 10
		Next
		While Carry
			Digits(Length) = Carry % 10
			Carry = Carry / 10
			Length + 1
		Wend
	Next
	For j = Length - 1 To 0 Step -1
		Text + Chr('0' + Digits(j))
	Next
	ProcedureReturn Text
EndProcedure


; Writes the arc Decimal (BakaShrot_Der_IsDecimal()) as base-128 groups at
; *Out (#BakaShrot_Der_MaxArcBytes bytes), the high bit on all but the last.
; Returns how many bytes, 0 if it takes more than #BakaShrot_Der_MaxArcBytes.
Procedure.i BakaShrot_Der_DecimalToArc(Decimal.s, *Out)
	Protected Dim Groups.a(#BakaShrot_Der_MaxArcBytes)
	Protected Count.i, Quotient.s, Remainder.i, Current.i, Digit.i, i.i

	; Divides by 128 until nothing's left, the remainders least significant first.
	Repeat
		Quotient  = ""
		Remainder = 0
		For i = 1 To Len(Decimal)
			Current   = Remainder * 10 + (Asc(Mid(Decimal, i, 1)) - '0')
			Digit     = Current / 128
			Remainder = Current % 128
			If Digit > 0 Or Quotient <> ""
				Quotient + Chr('0' + Digit)
			EndIf
		Next
		If Count >= #BakaShrot_Der_MaxArcBytes
			ProcedureReturn 0
		EndIf
		Groups(Count) = Remainder
		Count + 1
		Decimal = Quotient
	Until Decimal = ""

	For i = 0 To Count - 1
		If i < Count - 1
			PokeA(*Out + i, Groups(Count - 1 - i) | $80)
		Else
			PokeA(*Out + i, Groups(Count - 1 - i))
		EndIf
	Next
	ProcedureReturn Count
EndProcedure


; Writes the DER contents of the OID Oid ("1.3.101.112") at *Out, OutSize
; bytes. Returns their size, 0 if Oid isn't a valid OID or doesn't fit.
; Valid: two arcs or more, each digits without a leading zero, the first 0,
; 1 or 2, the second under 40 after a 0 or 1.
Procedure.i BakaShrot_Der_EncodeOid(Oid.s, *Out, OutSize.i)
	Protected Count.i, i.i, Arc.s, First.q, Second.q, Size.i, Written.i
	Protected Dim ArcBytes.a(#BakaShrot_Der_MaxArcBytes)

	Count = CountString(Oid, ".") + 1
	If Count < 2
		ProcedureReturn 0
	EndIf
	For i = 1 To Count
		If Not BakaShrot_Der_IsDecimal(StringField(Oid, i, "."))
			ProcedureReturn 0
		EndIf
	Next

	; The first two arcs share one: 40 * First + Second, kept within a quad.
	First = Val(StringField(Oid, 1, "."))
	Arc   = StringField(Oid, 2, ".")
	If First > 2 Or Len(Arc) > 17
		ProcedureReturn 0
	EndIf
	Second = Val(Arc)
	If First < 2 And Second >= 40
		ProcedureReturn 0
	EndIf

	For i = 2 To Count
		If i = 2
			Arc = Str(40 * First + Second)
		Else
			Arc = StringField(Oid, i, ".")
		EndIf
		Written = BakaShrot_Der_DecimalToArc(Arc, @ArcBytes(0))
		If Written = 0 Or Size + Written > OutSize
			ProcedureReturn 0
		EndIf
		CopyMemory(@ArcBytes(0), *Out + Size, Written)
		Size + Written
	Next
	ProcedureReturn Size
EndProcedure


; #True if Oid is a valid OID's dotted text, see BakaShrot_Der_EncodeOid().
Procedure.i BakaShrot_Der_IsValidOid(Oid.s)
	Protected *Buffer, Size.i

	*Buffer = AllocateMemory((CountString(Oid, ".") + 1) * #BakaShrot_Der_MaxArcBytes)
	If Not *Buffer
		ProcedureReturn #False
	EndIf
	Size = BakaShrot_Der_EncodeOid(Oid, *Buffer, MemorySize(*Buffer))
	FreeMemory(*Buffer)
	ProcedureReturn Bool(Size > 0)
EndProcedure


; An OBJECT IDENTIFIER's dotted text, "" if it isn't a valid one.
Procedure.s BakaShrot_Der_GetOid(*Element.BakaShrot_DerElement)
	Protected *C = *Element\Content, Size.i = *Element\ContentSize
	Protected i.i, Start.i, Text.s, First.q

	; Each arc: base-128 groups, the high bit on all of them but the last,
	; no padding group ($80) first.
	If Size < 1 Or (PeekA(*C + Size - 1) & $80) <> 0
		ProcedureReturn ""
	EndIf
	For i = 0 To Size - 1
		If i = Start And PeekA(*C + i) = $80
			ProcedureReturn ""
		EndIf
		If (PeekA(*C + i) & $80) = 0
			If i - Start + 1 > #BakaShrot_Der_MaxArcBytes
				ProcedureReturn ""
			EndIf
			If Start = 0
				; The first two arcs, 40 * X + Y: kept within a quad (8 groups).
				If i + 1 > 8
					ProcedureReturn ""
				EndIf
				First = Val(BakaShrot_Der_ArcToDecimal(*C, i + 1))
				If First < 40
					Text = "0." + Str(First)
				ElseIf First < 80
					Text = "1." + Str(First - 40)
				Else
					Text = "2." + Str(First - 80)
				EndIf
			Else
				Text + "." + BakaShrot_Der_ArcToDecimal(*C + Start, i - Start + 1)
			EndIf
			Start = i + 1
		EndIf
	Next
	ProcedureReturn Text
EndProcedure


;- Times

; Days since 1970-01-01 of a date of the proleptic Gregorian calendar
; (Howard Hinnant's days_from_civil), any time zone or locale aside.
Procedure.q BakaShrot_Der_DaysFromCivil(Year.q, Month.q, Day.q)
	Protected Era.q, YearOfEra.q, DayOfYear.q, DayOfEra.q, M.q

	If Month <= 2
		Year - 1
		M = Month + 9
	Else
		M = Month - 3
	EndIf
	If Year >= 0
		Era = Year / 400
	Else
		Era = (Year - 399) / 400
	EndIf
	YearOfEra = Year - Era * 400
	DayOfYear = (153 * M + 2) / 5 + Day - 1
	DayOfEra  = YearOfEra * 365 + YearOfEra / 4 - YearOfEra / 100 + DayOfYear
	ProcedureReturn Era * 146097 + DayOfEra - 719468
EndProcedure


; The date of Days since 1970-01-01, the other way (civil_from_days).
Procedure BakaShrot_Der_CivilFromDays(Days.q, *Year.Quad, *Month.Quad, *Day.Quad)
	Protected Era.q, DayOfEra.q, YearOfEra.q, DayOfYear.q, Mp.q, Year.q, Month.q

	Days + 719468
	If Days >= 0
		Era = Days / 146097
	Else
		Era = (Days - 146096) / 146097
	EndIf
	DayOfEra  = Days - Era * 146097
	YearOfEra = (DayOfEra - DayOfEra / 1460 + DayOfEra / 36524 - DayOfEra / 146096) / 365
	Year      = YearOfEra + Era * 400
	DayOfYear = DayOfEra - (365 * YearOfEra + YearOfEra / 4 - YearOfEra / 100)
	Mp        = (5 * DayOfYear + 2) / 153
	*Day\q    = DayOfYear - (153 * Mp + 2) / 5 + 1
	If Mp < 10
		Month = Mp + 3
	Else
		Month = Mp - 9
	EndIf
	If Month <= 2
		Year + 1
	EndIf
	*Year\q  = Year
	*Month\q = Month
EndProcedure


; The number written by Count digits at *P, -1 if one isn't a digit.
Procedure.i BakaShrot_Der_ReadDigits(*P, Count.i)
	Protected i.i, c.i, Value.i

	For i = 0 To Count - 1
		c = PeekA(*P + i)
		If c < '0' Or c > '9'
			ProcedureReturn -1
		EndIf
		Value = Value * 10 + (c - '0')
	Next
	ProcedureReturn Value
EndProcedure


; A UTCTime or a GeneralizedTime into *Seconds\q, since 1970 UTC.
; UTCTime's years: 50-99 are 1950-1999, 00-49 are 2000-2049 (RFC 5280).
Procedure.i BakaShrot_Der_GetTime(*Element.BakaShrot_DerElement, *Seconds.Quad)
	Protected *C = *Element\Content, Year.q, Month.q, Day.q, Hour.i, Minute.i, Second.i, Days.q
	Protected CheckYear.q, CheckMonth.q, CheckDay.q

	If *Element\Tag = #BakaShrot_Der_UtcTime And *Element\ContentSize = 13
		Year = BakaShrot_Der_ReadDigits(*C, 2)
		If Year < 0
			ProcedureReturn #False
		ElseIf Year >= 50
			Year + 1900
		Else
			Year + 2000
		EndIf
		*C + 2
	ElseIf *Element\Tag = #BakaShrot_Der_GeneralizedTime And *Element\ContentSize = 15
		Year = BakaShrot_Der_ReadDigits(*C, 4)
		If Year < 0
			ProcedureReturn #False
		EndIf
		*C + 4
	Else
		ProcedureReturn #False
	EndIf

	Month  = BakaShrot_Der_ReadDigits(*C, 2)
	Day    = BakaShrot_Der_ReadDigits(*C + 2, 2)
	Hour   = BakaShrot_Der_ReadDigits(*C + 4, 2)
	Minute = BakaShrot_Der_ReadDigits(*C + 6, 2)
	Second = BakaShrot_Der_ReadDigits(*C + 8, 2)
	If PeekA(*C + 10) <> 'Z' Or Month < 1 Or Month > 12 Or Day < 1 Or Day > 31 Or Hour < 0 Or Hour > 23 Or Minute < 0 Or Minute > 59 Or Second < 0 Or Second > 59
		ProcedureReturn #False
	EndIf

	; A real date: no 30th of February.
	Days = BakaShrot_Der_DaysFromCivil(Year, Month, Day)
	BakaShrot_Der_CivilFromDays(Days, @CheckYear, @CheckMonth, @CheckDay)
	If CheckYear <> Year Or CheckMonth <> Month Or CheckDay <> Day
		ProcedureReturn #False
	EndIf

	*Seconds\q = Days * 86400 + Hour * 3600 + Minute * 60 + Second
	ProcedureReturn #True
EndProcedure


;- Strings

; A string's text into *Text\s: UTF8String, PrintableString, IA5String,
; T61String (taken as Latin-1) or BMPString (UTF-16BE). #False for another
; type, a NUL in it, or a PrintableString or IA5String that isn't ASCII.
Procedure.i BakaShrot_Der_GetText(*Element.BakaShrot_DerElement, *Text.String)
	Protected *C = *Element\Content, Size.i = *Element\ContentSize, i.i, c.i, Text.s

	Select *Element\Tag
		Case #BakaShrot_Der_Utf8String
			For i = 0 To Size - 1
				If PeekA(*C + i) = 0
					ProcedureReturn #False
				EndIf
			Next
			If Size > 0
				Text = PeekS(*C, Size, #PB_UTF8 | #PB_ByteLength)
			EndIf

		Case #BakaShrot_Der_PrintableString, #BakaShrot_Der_Ia5String
			For i = 0 To Size - 1
				c = PeekA(*C + i)
				If c = 0 Or c > 127
					ProcedureReturn #False
				EndIf
			Next
			If Size > 0
				Text = PeekS(*C, Size, #PB_Ascii)
			EndIf

		Case #BakaShrot_Der_T61String
			For i = 0 To Size - 1
				c = PeekA(*C + i)
				If c = 0
					ProcedureReturn #False
				EndIf
				Text + Chr(c)
			Next

		Case #BakaShrot_Der_BmpString
			If Size % 2
				ProcedureReturn #False
			EndIf
			For i = 0 To Size - 2 Step 2
				c = (PeekA(*C + i) << 8) | PeekA(*C + i + 1)
				If c = 0
					ProcedureReturn #False
				EndIf
				Text + Chr(c)
			Next

		Default
			ProcedureReturn #False
	EndSelect

	*Text\s = Text
	ProcedureReturn #True
EndProcedure


; #True if Text may be a PrintableString: A-Z a-z 0-9 space ' ( ) + , - . / : = ?
Procedure.i BakaShrot_Der_IsPrintable(Text.s)
	Protected i.i, c.i

	For i = 1 To Len(Text)
		c = Asc(Mid(Text, i, 1))
		If Not ((c >= 'a' And c <= 'z') Or (c >= 'A' And c <= 'Z') Or (c >= '0' And c <= '9') Or FindString(" '()+,-./:=?", Chr(c)))
			ProcedureReturn #False
		EndIf
	Next
	ProcedureReturn #True
EndProcedure


;- Writing

Procedure BakaShrot_Der_InitWriter(*Writer.BakaShrot_DerWriter)
	*Writer\Buffer   = 0
	*Writer\Capacity = 0
	*Writer\Size     = 0
	*Writer\Depth    = 0
	*Writer\Failed   = #False
EndProcedure


; Frees what *Writer wrote, for when it's abandoned (BakaShrot_Der_Finish()
; does it otherwise). Zeroed first: it may have held a private key.
Procedure BakaShrot_Der_FreeWriter(*Writer.BakaShrot_DerWriter)
	If *Writer\Buffer
		FillMemory(*Writer\Buffer, *Writer\Capacity, 0)
		FreeMemory(*Writer\Buffer)
	EndIf
	BakaShrot_Der_InitWriter(*Writer)
	*Writer\Failed = #True
EndProcedure


; Room for Count more bytes. #False, and the writer fails, without memory or
; past #BakaShrot_Der_MaxSize.
Procedure.i BakaShrot_Der_Reserve(*Writer.BakaShrot_DerWriter, Count.i)
	Protected Capacity.i, *Buffer

	If *Writer\Failed
		ProcedureReturn #False
	EndIf
	If Count < 0 Or *Writer\Size + Count > #BakaShrot_Der_MaxSize + 64
		*Writer\Failed = #True
		ProcedureReturn #False
	EndIf
	If *Writer\Size + Count <= *Writer\Capacity
		ProcedureReturn #True
	EndIf

	Capacity = *Writer\Capacity * 2
	If Capacity < 256
		Capacity = 256
	EndIf
	While Capacity < *Writer\Size + Count
		Capacity = Capacity * 2
	Wend
	If *Writer\Buffer
		*Buffer = ReAllocateMemory(*Writer\Buffer, Capacity)
	Else
		*Buffer = AllocateMemory(Capacity)
	EndIf
	If Not *Buffer
		*Writer\Failed = #True
		ProcedureReturn #False
	EndIf
	*Writer\Buffer   = *Buffer
	*Writer\Capacity = Capacity
	ProcedureReturn #True
EndProcedure


; The size of the header (tag and length) of Length bytes of contents.
Procedure.i BakaShrot_Der_HeaderSize(Length.i)
	If Length < $80
		ProcedureReturn 2
	ElseIf Length <= $FF
		ProcedureReturn 3
	ElseIf Length <= $FFFF
		ProcedureReturn 4
	ElseIf Length <= $FFFFFF
		ProcedureReturn 5
	EndIf
	ProcedureReturn 6
EndProcedure


; Writes the header of Tag with Length bytes of contents at *P.
Procedure BakaShrot_Der_PokeHeader(*P, Tag.i, Length.i)
	Protected Count.i = BakaShrot_Der_HeaderSize(Length) - 2, i.i

	PokeA(*P, Tag)
	If Count = 0
		PokeA(*P + 1, Length)
	Else
		PokeA(*P + 1, $80 | Count)
		For i = 0 To Count - 1
			PokeA(*P + 2 + i, (Length >> ((Count - 1 - i) * 8)) & $FF)
		Next
	EndIf
EndProcedure


; Writes an element: Tag, and Size bytes of contents from *Content.
Procedure.i BakaShrot_Der_WriteElement(*Writer.BakaShrot_DerWriter, Tag.i, *Content, Size.i)
	Protected HeaderSize.i = BakaShrot_Der_HeaderSize(Size)

	If Size < 0 Or (Size > 0 And Not *Content) Or Not BakaShrot_Der_Reserve(*Writer, HeaderSize + Size)
		*Writer\Failed = #True
		ProcedureReturn #False
	EndIf
	BakaShrot_Der_PokeHeader(*Writer\Buffer + *Writer\Size, Tag, Size)
	If Size > 0
		CopyMemory(*Content, *Writer\Buffer + *Writer\Size + HeaderSize, Size)
	EndIf
	*Writer\Size + HeaderSize + Size
	ProcedureReturn #True
EndProcedure


; Writes Size bytes of DER as they are (an element encoded elsewhere).
Procedure.i BakaShrot_Der_WriteRaw(*Writer.BakaShrot_DerWriter, *Data, Size.i)
	If Size < 1 Or Not *Data Or Not BakaShrot_Der_Reserve(*Writer, Size)
		*Writer\Failed = #True
		ProcedureReturn #False
	EndIf
	CopyMemory(*Data, *Writer\Buffer + *Writer\Size, Size)
	*Writer\Size + Size
	ProcedureReturn #True
EndProcedure


; Begins a constructed element with Tag: what's written until its
; BakaShrot_Der_End() is its contents.
Procedure.i BakaShrot_Der_Begin(*Writer.BakaShrot_DerWriter, Tag.i)
	If *Writer\Failed Or *Writer\Depth >= #BakaShrot_Der_MaxDepth
		*Writer\Failed = #True
		ProcedureReturn #False
	EndIf
	*Writer\Starts[*Writer\Depth] = *Writer\Size
	*Writer\Tags[*Writer\Depth]   = Tag
	*Writer\Depth + 1
	ProcedureReturn #True
EndProcedure


; Ends the element begun last: moves its contents to fit its header before.
Procedure.i BakaShrot_Der_End(*Writer.BakaShrot_DerWriter)
	Protected Start.i, Length.i, HeaderSize.i

	If *Writer\Failed Or *Writer\Depth = 0
		*Writer\Failed = #True
		ProcedureReturn #False
	EndIf
	*Writer\Depth - 1
	Start      = *Writer\Starts[*Writer\Depth]
	Length     = *Writer\Size - Start
	HeaderSize = BakaShrot_Der_HeaderSize(Length)
	If Not BakaShrot_Der_Reserve(*Writer, HeaderSize)
		ProcedureReturn #False
	EndIf
	If Length > 0
		MoveMemory(*Writer\Buffer + Start, *Writer\Buffer + Start + HeaderSize, Length)
	EndIf
	BakaShrot_Der_PokeHeader(*Writer\Buffer + Start, *Writer\Tags[*Writer\Depth], Length)
	*Writer\Size + HeaderSize
	ProcedureReturn #True
EndProcedure


; What *Writer wrote, in a new buffer (free it with FreeMemory), its size in
; *OutSize\i. 0 if a write failed or an element wasn't ended.
; The writer is freed either way.
Procedure.i BakaShrot_Der_Finish(*Writer.BakaShrot_DerWriter, *OutSize.Integer)
	Protected *Result = 0

	If Not *Writer\Failed And *Writer\Depth = 0 And *Writer\Size > 0
		*Result = AllocateMemory(*Writer\Size)
		If *Result
			CopyMemory(*Writer\Buffer, *Result, *Writer\Size)
			*OutSize\i = *Writer\Size
		EndIf
	EndIf
	BakaShrot_Der_FreeWriter(*Writer)
	ProcedureReturn *Result
EndProcedure


; An INTEGER, in its shortest form.
Procedure.i BakaShrot_Der_WriteInteger(*Writer.BakaShrot_DerWriter, Value.q)
	Protected Dim Bytes.a(7)
	Protected i.i, Start.i

	For i = 0 To 7
		Bytes(i) = (Value >> ((7 - i) * 8)) & $FF
	Next
	; Drops the leading bytes that only repeat the sign.
	While Start < 7 And ((Bytes(Start) = $00 And Bytes(Start + 1) < $80) Or (Bytes(Start) = $FF And Bytes(Start + 1) >= $80))
		Start + 1
	Wend
	ProcedureReturn BakaShrot_Der_WriteElement(*Writer, #BakaShrot_Der_Integer, @Bytes(Start), 8 - Start)
EndProcedure


; An INTEGER of Size unsigned big-endian bytes at *Bytes, any size (a
; serial number): leading zeros dropped, a zero added if the first bit is set.
Procedure.i BakaShrot_Der_WriteUnsigned(*Writer.BakaShrot_DerWriter, *Bytes, Size.i)
	Protected *Content, Start.i, Length.i, Result.i

	While Start < Size And PeekA(*Bytes + Start) = 0
		Start + 1
	Wend
	*Content = AllocateMemory(Size - Start + 1)
	If Not *Content
		*Writer\Failed = #True
		ProcedureReturn #False
	EndIf
	If Start = Size
		Length = 1
	ElseIf PeekA(*Bytes + Start) >= $80
		CopyMemory(*Bytes + Start, *Content + 1, Size - Start)
		Length = Size - Start + 1
	Else
		CopyMemory(*Bytes + Start, *Content, Size - Start)
		Length = Size - Start
	EndIf
	Result = BakaShrot_Der_WriteElement(*Writer, #BakaShrot_Der_Integer, *Content, Length)
	FreeMemory(*Content)
	ProcedureReturn Result
EndProcedure


Procedure.i BakaShrot_Der_WriteBoolean(*Writer.BakaShrot_DerWriter, Value.i)
	Protected Byte.a = $00

	If Value
		Byte = $FF
	EndIf
	ProcedureReturn BakaShrot_Der_WriteElement(*Writer, #BakaShrot_Der_Boolean, @Byte, 1)
EndProcedure


Procedure.i BakaShrot_Der_WriteNull(*Writer.BakaShrot_DerWriter)
	ProcedureReturn BakaShrot_Der_WriteElement(*Writer, #BakaShrot_Der_Null, 0, 0)
EndProcedure


; An OBJECT IDENTIFIER from its dotted text. Fails if it isn't valid.
Procedure.i BakaShrot_Der_WriteOid(*Writer.BakaShrot_DerWriter, Oid.s)
	Protected *Buffer, Size.i, Result.i

	*Buffer = AllocateMemory((CountString(Oid, ".") + 1) * #BakaShrot_Der_MaxArcBytes)
	If Not *Buffer
		*Writer\Failed = #True
		ProcedureReturn #False
	EndIf
	Size = BakaShrot_Der_EncodeOid(Oid, *Buffer, MemorySize(*Buffer))
	If Size > 0
		Result = BakaShrot_Der_WriteElement(*Writer, #BakaShrot_Der_Oid, *Buffer, Size)
	Else
		*Writer\Failed = #True
	EndIf
	FreeMemory(*Buffer)
	ProcedureReturn Result
EndProcedure


Procedure.i BakaShrot_Der_WriteOctetString(*Writer.BakaShrot_DerWriter, *Bytes, Size.i)
	ProcedureReturn BakaShrot_Der_WriteElement(*Writer, #BakaShrot_Der_OctetString, *Bytes, Size)
EndProcedure


; A BIT STRING of Size whole bytes (a key, a signature).
Procedure.i BakaShrot_Der_WriteBitStringBytes(*Writer.BakaShrot_DerWriter, *Bytes, Size.i)
	Protected *Content, Result.i

	*Content = AllocateMemory(Size + 1)
	If Not *Content
		*Writer\Failed = #True
		ProcedureReturn #False
	EndIf
	If Size > 0
		CopyMemory(*Bytes, *Content + 1, Size)
	EndIf
	Result = BakaShrot_Der_WriteElement(*Writer, #BakaShrot_Der_BitString, *Content, Size + 1)
	FreeMemory(*Content)
	ProcedureReturn Result
EndProcedure


; A BIT STRING of named bits from flags (BakaShrot_Der_GetBitFlags()), up
; to 32 bits, without trailing zero bits as DER wants.
Procedure.i BakaShrot_Der_WriteBitFlags(*Writer.BakaShrot_DerWriter, Flags.i)
	Protected Dim Content.a(4)
	Protected Highest.i = -1, Bit.i, Count.i

	Flags = Flags & $FFFFFFFF
	For Bit = 0 To 31
		If Flags & (1 << Bit)
			Highest = Bit
			Content(1 + Bit / 8) = Content(1 + Bit / 8) | ($80 >> (Bit % 8))
		EndIf
	Next
	If Highest < 0
		ProcedureReturn BakaShrot_Der_WriteElement(*Writer, #BakaShrot_Der_BitString, @Content(0), 1)
	EndIf
	Count      = Highest / 8 + 1
	Content(0) = 7 - (Highest % 8)
	ProcedureReturn BakaShrot_Der_WriteElement(*Writer, #BakaShrot_Der_BitString, @Content(0), Count + 1)
EndProcedure


; A string of type Tag: #BakaShrot_Der_Utf8String, or
; #BakaShrot_Der_PrintableString / #BakaShrot_Der_Ia5String (fails if Text
; doesn't fit them). Fails on a NUL.
Procedure.i BakaShrot_Der_WriteText(*Writer.BakaShrot_DerWriter, Tag.i, Text.s)
	Protected *Buffer, Size.i, Result.i, i.i

	If FindString(Text, Chr(0))
		*Writer\Failed = #True
		ProcedureReturn #False
	EndIf
	Select Tag
		Case #BakaShrot_Der_Utf8String
			Size = StringByteLength(Text, #PB_UTF8)
			*Buffer = AllocateMemory(Size + 1)
			If *Buffer
				PokeS(*Buffer, Text, -1, #PB_UTF8)
			EndIf

		Case #BakaShrot_Der_PrintableString, #BakaShrot_Der_Ia5String
			For i = 1 To Len(Text)
				If Asc(Mid(Text, i, 1)) > 127
					*Writer\Failed = #True
				EndIf
			Next
			If Tag = #BakaShrot_Der_PrintableString And Not BakaShrot_Der_IsPrintable(Text)
				*Writer\Failed = #True
			EndIf
			Size = Len(Text)
			*Buffer = AllocateMemory(Size + 1)
			If *Buffer
				PokeS(*Buffer, Text, -1, #PB_Ascii)
			EndIf

		Default
			*Writer\Failed = #True
	EndSelect

	If *Buffer And Not *Writer\Failed
		Result = BakaShrot_Der_WriteElement(*Writer, Tag, *Buffer, Size)
	Else
		*Writer\Failed = #True
	EndIf
	If *Buffer
		FreeMemory(*Buffer)
	EndIf
	ProcedureReturn Result
EndProcedure


; A time, Seconds since 1970 UTC: a UTCTime from 1950 to 2049, a
; GeneralizedTime otherwise (RFC 5280), years 0000 to 9999.
Procedure.i BakaShrot_Der_WriteTime(*Writer.BakaShrot_DerWriter, Seconds.q)
	Protected Days.q, Rest.q, Year.q, Month.q, Day.q, Text.s, Tag.i, *Buffer, Result.i

	Days = Seconds / 86400
	Rest = Seconds % 86400
	If Rest < 0
		Days - 1
		Rest + 86400
	EndIf
	BakaShrot_Der_CivilFromDays(Days, @Year, @Month, @Day)
	If Year < 0 Or Year > 9999
		*Writer\Failed = #True
		ProcedureReturn #False
	EndIf

	Text = RSet(Str(Month), 2, "0") + RSet(Str(Day), 2, "0") + RSet(Str(Rest / 3600), 2, "0") + RSet(Str((Rest / 60) % 60), 2, "0") + RSet(Str(Rest % 60), 2, "0") + "Z"
	If Year >= 1950 And Year <= 2049
		Tag  = #BakaShrot_Der_UtcTime
		Text = RSet(Str(Year % 100), 2, "0") + Text
	Else
		Tag  = #BakaShrot_Der_GeneralizedTime
		Text = RSet(Str(Year), 4, "0") + Text
	EndIf

	*Buffer = AllocateMemory(Len(Text) + 1)
	If Not *Buffer
		*Writer\Failed = #True
		ProcedureReturn #False
	EndIf
	PokeS(*Buffer, Text, -1, #PB_Ascii)
	Result = BakaShrot_Der_WriteElement(*Writer, Tag, *Buffer, Len(Text))
	FreeMemory(*Buffer)
	ProcedureReturn Result
EndProcedure
