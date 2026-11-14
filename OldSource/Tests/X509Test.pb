;{- Code Header
; ==- Basic Info -================================
;     Name: X509Test.pb
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
; Tests of Commons/Cryptography/Der.pbi and X509.pbi, no sockets:
;   - DER: integers, lengths, OIDs (2.25 UUID arcs too), times, booleans,
;     strings, and what isn't DER refused.
;   - Certificates: a CA, an intermediate, leaves with custom extensions,
;     issued, read back, checked; every way a check must fail; every
;     truncation and every flipped byte of a certificate refused; PEM and
;     private keys.
; With a folder argument (Tests/X509-Test.ps1 gives one): also checks the
; certificates OpenSSL made there (openssl-*.pem), and writes its own for
; OpenSSL to check (bakashrot-*.pem).
; Compile as a console program into Build\ (libsodium.dll is there), run it
; from there. Exits with 0 if every check passed, 1 otherwise.
; ============================================================================

EnableExplicit

XIncludeFile "../Commons/Cryptography/X509.pbi"

Global Fails.i = 0

Procedure Check(What.s, Ok.i, Detail.s = "")
	If Ok
		PrintN("PASS " + What)
	Else
		PrintN("FAIL " + What)
		Fails + 1
	EndIf
	If Detail <> ""
		PrintN("      -> " + Detail)
	EndIf
EndProcedure

; Expects a #BakaShrot_X509_* code.
Procedure CheckCode(What.s, Code.i, Expected.i)
	Check(What, Bool(Code = Expected), "got " + BakaShrot_X509_ErrorName(Code) + ", expected " + BakaShrot_X509_ErrorName(Expected))
EndProcedure

; Hex ("30 03 02 01 05", spaces ignored) as a new buffer, its size in *Size\i.
Procedure.i FromHex(Hex.s, *Size.Integer)
	Protected *Buffer, Size.i

	Hex = RemoveString(Hex, " ")
	*Buffer = AllocateMemory(Len(Hex) / 2 + 1)
	Size = BakaShrot_X509_FromHex(Hex, *Buffer, MemorySize(*Buffer))
	*Size\i = Size
	ProcedureReturn *Buffer
EndProcedure

; What a writer wrote, in hex.
Procedure.s Written(*Writer.BakaShrot_DerWriter)
	Protected *Der, Size.Integer, Hex.s

	*Der = BakaShrot_Der_Finish(*Writer, @Size)
	If Not *Der
		ProcedureReturn "(failed)"
	EndIf
	Hex = BakaShrot_X509_Hex(*Der, Size\i)
	FreeMemory(*Der)
	ProcedureReturn Hex
EndProcedure

; Reads the single element in Hex into *Element, its buffer into *Buffer\i
; (free it). #False if it isn't one valid element.
Procedure.i ReadOne(Hex.s, *Element.BakaShrot_DerElement, *Buffer.Integer)
	Protected Size.Integer, Reader.BakaShrot_DerReader

	*Buffer\i = FromHex(Hex, @Size)
	BakaShrot_Der_InitReader(@Reader, *Buffer\i, Size\i)
	ProcedureReturn Bool(BakaShrot_Der_Read(@Reader, *Element) And BakaShrot_Der_AtEnd(@Reader))
EndProcedure

Procedure.i IsRefused(Hex.s)
	Protected Element.BakaShrot_DerElement, *Buffer, Ok.i
	Ok = ReadOne(Hex, @Element, @*Buffer)
	FreeMemory(*Buffer)
	ProcedureReturn Bool(Not Ok)
EndProcedure

Procedure.s IntegerHex(Value.q)
	Protected Writer.BakaShrot_DerWriter
	BakaShrot_Der_InitWriter(@Writer)
	BakaShrot_Der_WriteInteger(@Writer, Value)
	ProcedureReturn Written(@Writer)
EndProcedure

; Whether Value goes through an INTEGER and back.
Procedure.i IntegerRoundTrip(Value.q)
	Protected Element.BakaShrot_DerElement, *Buffer, Back.q, Ok.i
	Ok = Bool(ReadOne(IntegerHex(Value), @Element, @*Buffer) And BakaShrot_Der_GetInteger(@Element, @Back) And Back = Value)
	FreeMemory(*Buffer)
	ProcedureReturn Ok
EndProcedure

; The OID read back from writing Oid, "(failed)" if either failed.
Procedure.s OidRoundTrip(Oid.s, *Hex.String = 0)
	Protected Writer.BakaShrot_DerWriter, Element.BakaShrot_DerElement, *Buffer, Hex.s, Back.s = "(failed)"

	BakaShrot_Der_InitWriter(@Writer)
	BakaShrot_Der_WriteOid(@Writer, Oid)
	Hex = Written(@Writer)
	If *Hex
		*Hex\s = Hex
	EndIf
	If Hex <> "(failed)" And ReadOne(Hex, @Element, @*Buffer)
		Back = BakaShrot_Der_GetOid(@Element)
	EndIf
	If *Buffer
		FreeMemory(*Buffer)
	EndIf
	ProcedureReturn Back
EndProcedure

; The OID in the DER Hex, "" if refused.
Procedure.s OidOf(Hex.s)
	Protected Element.BakaShrot_DerElement, *Buffer, Oid.s
	If ReadOne(Hex, @Element, @*Buffer)
		Oid = BakaShrot_Der_GetOid(@Element)
	EndIf
	FreeMemory(*Buffer)
	ProcedureReturn Oid
EndProcedure

; The time written for Seconds, its tag into *Tag\i, and whether it reads
; back the same.
Procedure.i TimeRoundTrip(Seconds.q, *Tag.Integer)
	Protected Writer.BakaShrot_DerWriter, Element.BakaShrot_DerElement, *Buffer, Back.q, Ok.i
	BakaShrot_Der_InitWriter(@Writer)
	BakaShrot_Der_WriteTime(@Writer, Seconds)
	Ok = Bool(ReadOne(Written(@Writer), @Element, @*Buffer) And BakaShrot_Der_GetTime(@Element, @Back) And Back = Seconds)
	*Tag\i = Element\Tag
	FreeMemory(*Buffer)
	ProcedureReturn Ok
EndProcedure

; Whether the time element Tag with Text is refused.
Procedure.i TimeRefused(Tag.i, Text.s)
	Protected Element.BakaShrot_DerElement, *Buffer, Seconds.q, Ok.i, Encoded.s, i.i
	Encoded = RSet(Hex(Tag), 2, "0") + RSet(Hex(Len(Text)), 2, "0")
	For i = 1 To Len(Text)
		Encoded + RSet(Hex(Asc(Mid(Text, i, 1))), 2, "0")
	Next
	Ok = Bool(ReadOne(Encoded, @Element, @*Buffer) And BakaShrot_Der_GetTime(@Element, @Seconds))
	FreeMemory(*Buffer)
	ProcedureReturn Bool(Not Ok)
EndProcedure

; Issues *Template, returns it parsed (0 if either failed, the code in *Error\l).
Procedure.i IssueParsed(*Template.BakaShrot_X509Template, *Issuer, *Key, *Error.Long)
	Protected *Der, Size.Integer, *Cert
	*Der = BakaShrot_X509_Issue(*Template, *Issuer, *Key, @Size, *Error)
	If Not *Der
		ProcedureReturn 0
	EndIf
	*Cert = BakaShrot_X509_Parse(*Der, Size\i, *Error)
	FreeMemory(*Der)
	ProcedureReturn *Cert
EndProcedure

Procedure WriteText(Path.s, Text.s)
	Protected File.i = CreateFile(#PB_Any, Path)
	If File
		WriteString(File, Text, #PB_Ascii)
		CloseFile(File)
	Else
		Check("Writing " + Path, #False)
	EndIf
EndProcedure

Procedure.s ReadText(Path.s)
	Protected *Data, Size.Integer, Text.s
	*Data = BakaShrot_X509_ReadFile(Path, @Size)
	If *Data
		Text = PeekS(*Data, Size\i, #PB_UTF8 | #PB_ByteLength)
		FreeMemory(*Data)
	EndIf
	ProcedureReturn Text
EndProcedure


OpenConsole()
If Not InitCryptography()
	PrintN("FAIL libsodium didn't start")
	End 1
EndIf

Define Folder.s = ProgramParameter(0)
If Folder <> "" And Right(Folder, 1) <> "\" And Right(Folder, 1) <> "/"
	Folder + "/"
EndIf

Define Writer.BakaShrot_DerWriter, Element.BakaShrot_DerElement, Reader.BakaShrot_DerReader
Define *Buffer, Size.Integer, Value.q, Flag.i, Text.String, HexOut.String, Tag.Integer, i.i, Ok.i, Item.s


;- DER: integers

Check("Integer 0", Bool(IntegerHex(0) = "020100"), IntegerHex(0))
Check("Integer 127", Bool(IntegerHex(127) = "02017f"), IntegerHex(127))
Check("Integer 128 gets a sign byte", Bool(IntegerHex(128) = "02020080"), IntegerHex(128))
Check("Integer 256", Bool(IntegerHex(256) = "02020100"), IntegerHex(256))
Check("Integer -1", Bool(IntegerHex(-1) = "0201ff"), IntegerHex(-1))
Check("Integer -128", Bool(IntegerHex(-128) = "020180"), IntegerHex(-128))
Check("Integer -129", Bool(IntegerHex(-129) = "0202ff7f"), IntegerHex(-129))
Ok = #True
For i = 0 To 62
	Ok = Ok & IntegerRoundTrip(1 << i) & IntegerRoundTrip(-(1 << i)) & IntegerRoundTrip((1 << i) - 1)
Next
Ok = Ok & IntegerRoundTrip($7FFFFFFFFFFFFFFF) & IntegerRoundTrip(-$7FFFFFFFFFFFFFFF - 1)
Check("Integers round trip, 0 to 2^63", Ok)

ReadOne("0202007f", @Element, @*Buffer)
Check("Integer with a useless 00 refused", Bool(Not BakaShrot_Der_GetInteger(@Element, @Value)))
FreeMemory(*Buffer)
ReadOne("0202ff80", @Element, @*Buffer)
Check("Integer with a useless ff refused", Bool(Not BakaShrot_Der_GetInteger(@Element, @Value)))
FreeMemory(*Buffer)
ReadOne("0200", @Element, @*Buffer)
Check("Empty integer refused", Bool(Not BakaShrot_Der_GetInteger(@Element, @Value)))
FreeMemory(*Buffer)
ReadOne("0209010000000000000000", @Element, @*Buffer)
Check("9-byte integer refused as a small one", Bool(Not BakaShrot_Der_GetInteger(@Element, @Value)))
Check("... but minimal as a big one (a serial)", BakaShrot_Der_IsMinimalInteger(@Element))
FreeMemory(*Buffer)


;- DER: lengths

Check("Long length for under 128 refused", IsRefused("04810100"))
Check("Indefinite length refused", IsRefused("04800000"))
Check("Length with a leading zero refused", IsRefused("0482000100"))
Check("Length past the end refused", IsRefused("04050102"))
Check("Over 4 length bytes refused", IsRefused("0485000000000100"))
Check("High tag number refused", IsRefused("1f0100"))
Check("Nothing refused", IsRefused(""))
Check("A lone tag refused", IsRefused("04"))
Check("Trailing bytes refused", IsRefused("04010000"))

BakaShrot_Der_InitWriter(@Writer)
*Buffer = AllocateMemory(70000)
BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
BakaShrot_Der_WriteOctetString(@Writer, *Buffer, 200)
BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
BakaShrot_Der_WriteOctetString(@Writer, *Buffer, 70000)
BakaShrot_Der_End(@Writer)
BakaShrot_Der_End(@Writer)
FreeMemory(*Buffer)
*Buffer = BakaShrot_Der_Finish(@Writer, @Size)
Ok = #False
If *Buffer
	BakaShrot_Der_InitReader(@Reader, *Buffer, Size\i)
	If BakaShrot_Der_Expect(@Reader, #BakaShrot_Der_Sequence, @Element) And BakaShrot_Der_AtEnd(@Reader)
		BakaShrot_Der_ReaderOf(@Reader, @Element)
		Ok = Bool(BakaShrot_Der_Expect(@Reader, #BakaShrot_Der_OctetString, @Element) And Element\ContentSize = 200 And Element\Size = 203)
		Ok = Bool(Ok And BakaShrot_Der_Expect(@Reader, #BakaShrot_Der_Sequence, @Element) And Element\ContentSize = 70005 And Element\Size = 70010 And BakaShrot_Der_AtEnd(@Reader))
	EndIf
	Check("Nested elements of 200 and 70000 bytes: 81 and 83 lengths", Bool(Ok And PeekA(*Buffer + 1) = $83), BakaShrot_X509_Hex(*Buffer, 12))
	FreeMemory(*Buffer)
Else
	Check("Nested elements of 200 and 70000 bytes", #False, "the writer failed")
EndIf

BakaShrot_Der_InitWriter(@Writer)
BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
Check("A writer with an element left open gives nothing", Bool(Written(@Writer) = "(failed)"))
BakaShrot_Der_InitWriter(@Writer)
BakaShrot_Der_End(@Writer)
Check("An End without a Begin fails the writer", Bool(Written(@Writer) = "(failed)"))


;- DER: OIDs

OidRoundTrip(#BakaShrot_Oid_Ed25519, @HexOut)
Check("OID 1.3.101.112 is 06032b6570", Bool(HexOut\s = "06032b6570"), HexOut\s)
OidRoundTrip("2.999.3", @HexOut)
Check("OID 2.999.3 is 0603883703", Bool(HexOut\s = "0603883703"), HexOut\s)
OidRoundTrip("1.2.840.113549.1.9.1", @HexOut)
Check("OID 1.2.840.113549.1.9.1", Bool(HexOut\s = "06092a864886f70d010901"), HexOut\s)
Ok = #True
Restore Oids
Repeat
	Read.s Item
	If Item <> ""
		If OidRoundTrip(Item) <> Item
			Ok = #False
			PrintN("      -> " + Item + " came back as " + OidRoundTrip(Item))
		EndIf
	EndIf
Until Item = ""
Check("OIDs round trip (0.x, 1.x, 2.x, UUID arcs of 128 bits)", Ok)
Check("BakaShrot's arc round trips", Bool(OidRoundTrip(#BakaShrot_Oid_Extensions + ".9000") = #BakaShrot_Oid_Extensions + ".9000"))
OidRoundTrip(#BakaShrot_Oid_Arc, @HexOut)
Check("BakaShrot's arc encoded as Python does it", Bool(HexOut\s = "06146982dd8ec38edbae929ee5a2c2dda290b6a69e65"), HexOut\s)
Ok = #True
Restore BadOids
Repeat
	Read.s Item
	If Item <> "end"
		If BakaShrot_Der_IsValidOid(Item)
			Ok = #False
			PrintN("      -> '" + Item + "' taken")
		EndIf
	EndIf
Until Item = "end"
Check("Invalid OID texts refused (empty, one arc, 3.x, 1.40, leading zeros, letters, 141-bit arc)", Ok)
Check("OID with a padded arc refused", Bool(OidOf("06032b8001") = ""))
Check("OID ending mid-arc refused", Bool(OidOf("06022b81") = ""))
Check("Empty OID refused", Bool(OidOf("0600") = ""))


;- DER: times, booleans, strings, bits

Check("1970-01-01 as a UTCTime", Bool(TimeRoundTrip(0, @Tag) And Tag\i = #BakaShrot_Der_UtcTime))
Check("1950-01-01 as a UTCTime", Bool(TimeRoundTrip(-631152000, @Tag) And Tag\i = #BakaShrot_Der_UtcTime))
Check("1949-12-31 23:59:59 as a GeneralizedTime", Bool(TimeRoundTrip(-631152001, @Tag) And Tag\i = #BakaShrot_Der_GeneralizedTime))
Check("2049-12-31 23:59:59 as a UTCTime", Bool(TimeRoundTrip(2524607999, @Tag) And Tag\i = #BakaShrot_Der_UtcTime))
Check("2050-01-01 as a GeneralizedTime", Bool(TimeRoundTrip(2524608000, @Tag) And Tag\i = #BakaShrot_Der_GeneralizedTime))
Check("9999-12-31 23:59:59 (no expiry, RFC 5280)", Bool(TimeRoundTrip(253402300799, @Tag) And Tag\i = #BakaShrot_Der_GeneralizedTime))
Check("2024-02-29 12:34:56 (a leap day)", Bool(TimeRoundTrip(1709210096, @Tag)))
Ok = #True
For i = 0 To 400
	Ok = Ok & TimeRoundTrip(i * 31622399 + 1234, @Tag)
Next
Check("Times round trip, 1970 to 2371", Ok)
Check("Month 13 refused", TimeRefused(#BakaShrot_Der_UtcTime, "491301000000Z"))
Check("February 30th refused", TimeRefused(#BakaShrot_Der_UtcTime, "500230000000Z"))
Check("February 29th 2023 refused", TimeRefused(#BakaShrot_Der_UtcTime, "230229000000Z"))
Check("Second 60 refused", TimeRefused(#BakaShrot_Der_UtcTime, "240101000060Z"))
Check("No Z refused", TimeRefused(#BakaShrot_Der_GeneralizedTime, "202401010000001"))
Check("No seconds refused", TimeRefused(#BakaShrot_Der_UtcTime, "2401010000Z"))
Check("Fractions refused", TimeRefused(#BakaShrot_Der_GeneralizedTime, "20240101000000.5Z"))
Check("A time zone refused", TimeRefused(#BakaShrot_Der_UtcTime, "240101000000+0100"))
Check("Non-digits refused", TimeRefused(#BakaShrot_Der_UtcTime, "24O101000000Z"))

ReadOne("0101ff", @Element, @*Buffer)
Check("Boolean ff is true", Bool(BakaShrot_Der_GetBoolean(@Element, @Flag) And Flag = #True))
FreeMemory(*Buffer)
ReadOne("010101", @Element, @*Buffer)
Check("Boolean 01 refused", Bool(Not BakaShrot_Der_GetBoolean(@Element, @Flag)))
FreeMemory(*Buffer)

ReadOne("0c03e282ac", @Element, @*Buffer)
Check("UTF8String", Bool(BakaShrot_Der_GetText(@Element, @Text) And Text\s = Chr($20AC)))
FreeMemory(*Buffer)
ReadOne("1e0400e920ac", @Element, @*Buffer)
Check("BMPString", Bool(BakaShrot_Der_GetText(@Element, @Text) And Text\s = Chr($E9) + Chr($20AC)))
FreeMemory(*Buffer)
ReadOne("0c03610062", @Element, @*Buffer)
Check("A NUL in a string refused", Bool(Not BakaShrot_Der_GetText(@Element, @Text)))
FreeMemory(*Buffer)
ReadOne("1302e961", @Element, @*Buffer)
Check("PrintableString that isn't ASCII refused", Bool(Not BakaShrot_Der_GetText(@Element, @Text)))
FreeMemory(*Buffer)
BakaShrot_Der_InitWriter(@Writer)
BakaShrot_Der_WriteText(@Writer, #BakaShrot_Der_PrintableString, "a_b")
Check("Writing '_' in a PrintableString refused", Bool(Written(@Writer) = "(failed)"))

BakaShrot_Der_InitWriter(@Writer)
BakaShrot_Der_WriteBitFlags(@Writer, #BakaShrot_X509_KeyUsage_KeyCertSign | #BakaShrot_X509_KeyUsage_CrlSign)
Check("KeyUsage keyCertSign + cRLSign is 03020106", Bool(Written(@Writer) = "03020106"))
BakaShrot_Der_InitWriter(@Writer)
BakaShrot_Der_WriteBitFlags(@Writer, #BakaShrot_X509_KeyUsage_DigitalSignature | #BakaShrot_X509_KeyUsage_DecipherOnly)
Check("KeyUsage digitalSignature + decipherOnly is 0303078080", Bool(Written(@Writer) = "0303078080"))
ReadOne("0303078080", @Element, @*Buffer)
Check("... and reads back", Bool(BakaShrot_Der_GetBitFlags(@Element, @Flag) And Flag = (#BakaShrot_X509_KeyUsage_DigitalSignature | #BakaShrot_X509_KeyUsage_DecipherOnly)))
FreeMemory(*Buffer)
ReadOne("03020107", @Element, @*Buffer)
Check("Unused bits that aren't zero refused", Bool(Not BakaShrot_Der_GetBitFlags(@Element, @Flag)))
FreeMemory(*Buffer)


;- Certificates

Define Now.q = 1800000000
Define Year.q = 365 * 86400
Dim CaPub.a(31) : Dim CaKey.a(63)
Dim InterPub.a(31) : Dim InterKey.a(63)
Dim LeafPub.a(31) : Dim LeafKey.a(63)
Dim OtherPub.a(31) : Dim OtherKey.a(63)
GenerateKeyPair(@CaPub(0), @CaKey(0))
GenerateKeyPair(@InterPub(0), @InterKey(0))
GenerateKeyPair(@LeafPub(0), @LeafKey(0))
GenerateKeyPair(@OtherPub(0), @OtherKey(0))

Define Template.BakaShrot_X509Template, Error.Long, *Der, DerSize.Integer
Define *Ca.BakaShrot_X509Certificate, *Inter.BakaShrot_X509Certificate, *Leaf.BakaShrot_X509Certificate
Define *Other.BakaShrot_X509Certificate, *Cert.BakaShrot_X509Certificate, *Copy.BakaShrot_X509Certificate
Define NewList Chain.i()
Define TextExtension.s    = #BakaShrot_Oid_Extensions + ".9000"
Define IntegerExtension.s = #BakaShrot_Oid_Extensions + ".9001"
Define RawExtension.s     = #BakaShrot_Oid_Extensions + ".9002"
Define CriticalExtension.s = #BakaShrot_Oid_Extensions + ".9003"

; The CA, self-signed.
BakaShrot_X509_InitTemplate(@Template)
BakaShrot_X509_NameAdd(@Template\Subject, "CN", "BakaShrot Test CA")
BakaShrot_X509_NameAdd(@Template\Subject, "O", "BakaShrot")
BakaShrot_X509_NameAdd(@Template\Subject, "C", "LU")
Template\NotBefore  = Now - 3600
Template\NotAfter   = Now + 10 * Year
Template\IsCa       = #True
Template\PathLength = 1
Template\KeyUsage   = #BakaShrot_X509_KeyUsage_KeyCertSign | #BakaShrot_X509_KeyUsage_CrlSign
CopyMemory(@CaPub(0), @Template\PublicKey[0], 32)
Check("A self-signed certificate needs the subject's own key", Bool(BakaShrot_X509_Issue(@Template, 0, @OtherKey(0), @DerSize, @Error) = 0 And Error\l = #BakaShrot_X509_Error_KeyMismatch))
*Ca = IssueParsed(@Template, 0, @CaKey(0), @Error)
BakaShrot_X509_ClearTemplate(@Template)
Check("CA issued and read back", Bool(*Ca <> 0), BakaShrot_X509_ErrorName(Error\l))
If Not *Ca
	PrintN("Can't go on without the CA")
	End 1
EndIf
Check("CA: version 3, Ed25519", Bool(*Ca\Version = 3 And *Ca\SignatureAlgorithm = #BakaShrot_Oid_Ed25519 And *Ca\KeyAlgorithm = #BakaShrot_Oid_Ed25519 And *Ca\HasEd25519Key And *Ca\HasEd25519Signature))
Check("CA: subject", Bool(BakaShrot_X509_NameToString(@*Ca\Subject) = "CN=BakaShrot Test CA, O=BakaShrot, C=LU"), BakaShrot_X509_NameToString(@*Ca\Subject))
Check("CA: CN, and C as a PrintableString", Bool(BakaShrot_X509_NameGet(@*Ca\Subject, "cn") = "BakaShrot Test CA" And *Ca\Subject\Attributes(2)\StringTag = #BakaShrot_Der_PrintableString))
Check("CA: issuer is its subject", Bool(*Ca\IssuerSize = *Ca\SubjectSize And CompareMemory(*Ca\Der + *Ca\IssuerOffset, *Ca\Der + *Ca\SubjectOffset, *Ca\IssuerSize)))
Check("CA: validity", Bool(*Ca\NotBefore = Now - 3600 And *Ca\NotAfter = Now + 10 * Year))
Check("CA: its key", CompareMemory(@*Ca\PublicKey[0], @CaPub(0), 32))
Check("CA: CA, path length 1, key usage", Bool(*Ca\HasBasicConstraints And *Ca\IsCa And *Ca\PathLength = 1 And *Ca\HasKeyUsage And *Ca\KeyUsage = Template\KeyUsage))
Check("CA: key ids, its own as the authority's", Bool(Len(*Ca\SubjectKeyId) = 40 And *Ca\AuthorityKeyId = *Ca\SubjectKeyId))
Check("CA: a random 16-byte positive serial", Bool(Len(*Ca\Serial) = 32 And Val("$" + Left(*Ca\Serial, 2)) >= $40 And Val("$" + Left(*Ca\Serial, 2)) < $80), *Ca\Serial)
Check("CA: 4 extensions", Bool(*Ca\ExtensionCount = 4 And BakaShrot_X509_FindExtension(*Ca, #BakaShrot_Oid_BasicConstraints) = 0 And *Ca\Extensions(0)\Critical And *Ca\Extensions(1)\Critical And Not *Ca\Extensions(2)\Critical))
CheckCode("CA: signed by itself", BakaShrot_X509_CheckSignature(*Ca, @CaPub(0)), #BakaShrot_X509_Ok)
CheckCode("CA: not by another key", BakaShrot_X509_CheckSignature(*Ca, @OtherPub(0)), #BakaShrot_X509_Error_BadSignature)
CheckCode("CA: issued by itself", BakaShrot_X509_CheckIssuedBy(*Ca, *Ca, Now), #BakaShrot_X509_Ok)
Check("CA: fingerprint, the same for the same DER", Bool(Len(BakaShrot_X509_Fingerprint(*Ca)) = 64))

; The leaf: a client, with custom extensions.
BakaShrot_X509_InitTemplate(@Template)
BakaShrot_X509_NameAdd(@Template\Subject, "CN", "kitchen")
BakaShrot_X509_NameAdd(@Template\Subject, "OU", "clients")
Template\Serial    = "0102030405"
Template\NotBefore = Now - 60
Template\NotAfter  = Now + Year
Template\KeyUsage  = #BakaShrot_X509_KeyUsage_DigitalSignature
CopyMemory(@LeafPub(0), @Template\PublicKey[0], 32)
Check("Text extension added", BakaShrot_X509_AddTextExtension(@Template, TextExtension, "kitchen " + Chr($20AC)))
Check("Integer extension added", BakaShrot_X509_AddIntegerExtension(@Template, IntegerExtension, -1234567890123))
BakaShrot_Der_InitWriter(@Writer)
BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
BakaShrot_Der_WriteText(@Writer, #BakaShrot_Der_Utf8String, "logs")
BakaShrot_Der_WriteText(@Writer, #BakaShrot_Der_Utf8String, "sensors")
BakaShrot_Der_End(@Writer)
*Der = BakaShrot_Der_Finish(@Writer, @DerSize)
Check("Any DER extension added", BakaShrot_X509_AddExtension(@Template, RawExtension, *Der, DerSize\i))
Check("The same OID twice refused", Bool(Not BakaShrot_X509_AddExtension(@Template, RawExtension, *Der, DerSize\i)))
Check("A standard extension refused (Issue writes it)", Bool(Not BakaShrot_X509_AddExtension(@Template, #BakaShrot_Oid_KeyUsage, *Der, DerSize\i)))
Check("A value that isn't one DER element refused", Bool(Not BakaShrot_X509_AddExtension(@Template, CriticalExtension, *Der, DerSize\i - 1)))
Check("An invalid OID refused", Bool(Not BakaShrot_X509_AddTextExtension(@Template, "1.2.03", "x")))
FreeMemory(*Der)
Template\PathLength = 0
Check("A leaf with a path length refused", Bool(BakaShrot_X509_Issue(@Template, *Ca, @CaKey(0), @DerSize, @Error) = 0 And Error\l = #BakaShrot_X509_Error_InvalidArgument))
Template\PathLength = -1
Check("Issuing needs the issuer's key", Bool(BakaShrot_X509_Issue(@Template, *Ca, @OtherKey(0), @DerSize, @Error) = 0 And Error\l = #BakaShrot_X509_Error_KeyMismatch))
*Leaf = IssueParsed(@Template, *Ca, @CaKey(0), @Error)
Check("Leaf issued by the CA and read back", Bool(*Leaf <> 0), BakaShrot_X509_ErrorName(Error\l))
If Not *Leaf
	PrintN("Can't go on without the leaf")
	End 1
EndIf
Check("Leaf: issuer, subject, serial", Bool(BakaShrot_X509_NameToString(@*Leaf\Issuer) = BakaShrot_X509_NameToString(@*Ca\Subject) And BakaShrot_X509_NameGet(@*Leaf\Subject, "CN") = "kitchen" And *Leaf\Serial = "0102030405"), *Leaf\Serial)
Check("Leaf: not a CA, no path length", Bool(*Leaf\HasBasicConstraints And Not *Leaf\IsCa And *Leaf\PathLength = -1 And *Leaf\KeyUsage = #BakaShrot_X509_KeyUsage_DigitalSignature))
Check("Leaf: the CA's key id as its authority's", Bool(*Leaf\AuthorityKeyId = *Ca\SubjectKeyId And *Leaf\SubjectKeyId <> *Ca\SubjectKeyId))
Check("Leaf: text extension", Bool(BakaShrot_X509_GetExtensionText(*Leaf, TextExtension, @Text) And Text\s = "kitchen " + Chr($20AC)), Text\s)
Check("Leaf: integer extension", Bool(BakaShrot_X509_GetExtensionInteger(*Leaf, IntegerExtension, @Value) And Value = -1234567890123))
i = BakaShrot_X509_FindExtension(*Leaf, RawExtension)
Check("Leaf: raw extension, as given", Bool(i >= 0 And *Leaf\Extensions(i)\ValueSize = 17 And Not *Leaf\Extensions(i)\Critical))
Check("Leaf: no such extension", Bool(BakaShrot_X509_FindExtension(*Leaf, CriticalExtension) = -1 And Not BakaShrot_X509_GetExtensionText(*Leaf, CriticalExtension, @Text)))
Check("Leaf: a text extension isn't an integer", Bool(Not BakaShrot_X509_GetExtensionInteger(*Leaf, TextExtension, @Value)))
CheckCode("Leaf: issued by the CA", BakaShrot_X509_CheckIssuedBy(*Leaf, *Ca, Now), #BakaShrot_X509_Ok)
CheckCode("Leaf: valid from its NotBefore", BakaShrot_X509_CheckIssuedBy(*Leaf, *Ca, Now - 60), #BakaShrot_X509_Ok)
CheckCode("Leaf: valid up to its NotAfter", BakaShrot_X509_CheckIssuedBy(*Leaf, *Ca, Now + Year), #BakaShrot_X509_Ok)
CheckCode("Leaf: not yet valid", BakaShrot_X509_CheckIssuedBy(*Leaf, *Ca, Now - 61), #BakaShrot_X509_Error_NotYetValid)
CheckCode("Leaf: expired", BakaShrot_X509_CheckIssuedBy(*Leaf, *Ca, Now + Year + 1), #BakaShrot_X509_Error_Expired)
CheckCode("Leaf: not issued by itself", BakaShrot_X509_CheckIssuedBy(*Leaf, *Leaf, Now), #BakaShrot_X509_Error_IssuerMismatch)
AddElement(Chain()) : Chain() = *Leaf
CheckCode("Leaf: chain up to the CA", BakaShrot_X509_VerifyChain(Chain(), *Ca, Now), #BakaShrot_X509_Ok)
CheckCode("Leaf: chain, the CA expired", BakaShrot_X509_VerifyChain(Chain(), *Ca, Now + 11 * Year), #BakaShrot_X509_Error_Expired)
Check("Leaf can't issue", Bool(BakaShrot_X509_Issue(@Template, *Leaf, @LeafKey(0), @DerSize, @Error) = 0 And Error\l = #BakaShrot_X509_Error_NotCa))
CheckCode("A leaf as a root refused", BakaShrot_X509_VerifyChain(Chain(), *Leaf, Now), #BakaShrot_X509_Error_NotCa)
Check("Describe", Bool(FindString(BakaShrot_X509_Describe(*Leaf), "CN=kitchen, OU=clients") > 0 And FindString(BakaShrot_X509_Describe(*Leaf), TextExtension) > 0))
BakaShrot_X509_ClearTemplate(@Template)

; Another CA with the same name, another key: its key id doesn't match.
BakaShrot_X509_InitTemplate(@Template)
BakaShrot_X509_NameAdd(@Template\Subject, "CN", "BakaShrot Test CA")
BakaShrot_X509_NameAdd(@Template\Subject, "O", "BakaShrot")
BakaShrot_X509_NameAdd(@Template\Subject, "C", "LU")
Template\NotBefore = Now - 3600
Template\NotAfter  = Now + Year
Template\IsCa      = #True
CopyMemory(@OtherPub(0), @Template\PublicKey[0], 32)
*Other = IssueParsed(@Template, 0, @OtherKey(0), @Error)
CheckCode("Same name, other CA: key ids differ", BakaShrot_X509_CheckIssuedBy(*Leaf, *Other, Now), #BakaShrot_X509_Error_IssuerMismatch)
BakaShrot_X509_Free(*Other)
BakaShrot_X509_ClearTemplate(@Template)
*Other = 0

; A CA that may only sign CRLs.
BakaShrot_X509_InitTemplate(@Template)
BakaShrot_X509_NameAdd(@Template\Subject, "CN", "CRL only")
Template\NotBefore = Now - 3600
Template\NotAfter  = Now + Year
Template\IsCa      = #True
Template\KeyUsage  = #BakaShrot_X509_KeyUsage_CrlSign
CopyMemory(@OtherPub(0), @Template\PublicKey[0], 32)
*Other = IssueParsed(@Template, 0, @OtherKey(0), @Error)
Check("A CA without keyCertSign can't issue", Bool(*Other <> 0 And BakaShrot_X509_CanIssue(*Other) = #False))
BakaShrot_X509_ClearTemplate(@Template)

; A leaf with a critical custom extension.
BakaShrot_X509_InitTemplate(@Template)
BakaShrot_X509_NameAdd(@Template\Subject, "CN", "strict")
Template\NotBefore = Now - 60
Template\NotAfter  = Now + Year
CopyMemory(@LeafPub(0), @Template\PublicKey[0], 32)
BakaShrot_X509_AddTextExtension(@Template, CriticalExtension, "must be understood", #True)
*Cert = IssueParsed(@Template, *Ca, @CaKey(0), @Error)
CheckCode("Critical extension nobody handles", BakaShrot_X509_CheckIssuedBy(*Cert, *Ca, Now), #BakaShrot_X509_Error_UnknownCritical)
CheckCode("... handled by the caller", BakaShrot_X509_CheckIssuedBy(*Cert, *Ca, Now, "1.2.3;" + CriticalExtension), #BakaShrot_X509_Ok)
BakaShrot_X509_Free(*Cert)
BakaShrot_X509_ClearTemplate(@Template)

; A name that can't be written.
BakaShrot_X509_InitTemplate(@Template)
BakaShrot_X509_NameAdd(@Template\Subject, "C", "LUX")
Template\NotAfter = Now
CopyMemory(@LeafPub(0), @Template\PublicKey[0], 32)
Check("A 3-letter country refused", Bool(BakaShrot_X509_Issue(@Template, *Ca, @CaKey(0), @DerSize, @Error) = 0))
Check("An unknown name type refused", Bool(Not BakaShrot_X509_NameAdd(@Template\Subject, "XX", "x")))
Template\Subject\Count = 0
Template\NotBefore = Now + 1
Check("NotAfter before NotBefore refused", Bool(BakaShrot_X509_Issue(@Template, *Ca, @CaKey(0), @DerSize, @Error) = 0 And Error\l = #BakaShrot_X509_Error_InvalidArgument))
BakaShrot_X509_ClearTemplate(@Template)

; Chains: CA (path length 1) -> intermediate (path length 0) -> leaf.
BakaShrot_X509_InitTemplate(@Template)
BakaShrot_X509_NameAdd(@Template\Subject, "CN", "Intermediate")
Template\NotBefore  = Now - 3600
Template\NotAfter   = Now + 5 * Year
Template\IsCa       = #True
Template\PathLength = 0
Template\KeyUsage   = #BakaShrot_X509_KeyUsage_KeyCertSign
CopyMemory(@InterPub(0), @Template\PublicKey[0], 32)
*Inter = IssueParsed(@Template, *Ca, @CaKey(0), @Error)
BakaShrot_X509_ClearTemplate(@Template)
BakaShrot_X509_InitTemplate(@Template)
BakaShrot_X509_NameAdd(@Template\Subject, "CN", "deep")
Template\NotBefore = Now - 60
Template\NotAfter  = Now + Year
CopyMemory(@LeafPub(0), @Template\PublicKey[0], 32)
*Cert = IssueParsed(@Template, *Inter, @InterKey(0), @Error)
BakaShrot_X509_ClearTemplate(@Template)
Check("Intermediate and its leaf issued", Bool(*Inter <> 0 And *Cert <> 0))
ClearList(Chain())
AddElement(Chain()) : Chain() = *Cert
AddElement(Chain()) : Chain() = *Inter
CheckCode("Leaf, intermediate, CA (path length 1)", BakaShrot_X509_VerifyChain(Chain(), *Ca, Now), #BakaShrot_X509_Ok)
If Folder <> ""
	WriteText(Folder + "bakashrot-deep.pem", BakaShrot_X509_ToPem(*Cert))
EndIf
ClearList(Chain())
AddElement(Chain()) : Chain() = *Cert
CheckCode("The intermediate missing", BakaShrot_X509_VerifyChain(Chain(), *Ca, Now), #BakaShrot_X509_Error_IssuerMismatch)
; The intermediate (path length 0) under itself: one CA too many.
BakaShrot_X509_InitTemplate(@Template)
BakaShrot_X509_NameAdd(@Template\Subject, "CN", "Sub-intermediate")
Template\NotBefore = Now - 3600
Template\NotAfter  = Now + Year
Template\IsCa      = #True
CopyMemory(@OtherPub(0), @Template\PublicKey[0], 32)
BakaShrot_X509_Free(*Other)
*Other = IssueParsed(@Template, *Inter, @InterKey(0), @Error)
BakaShrot_X509_ClearTemplate(@Template)
BakaShrot_X509_InitTemplate(@Template)
BakaShrot_X509_NameAdd(@Template\Subject, "CN", "deeper")
Template\NotBefore = Now - 60
Template\NotAfter  = Now + Year
CopyMemory(@LeafPub(0), @Template\PublicKey[0], 32)
*Copy = IssueParsed(@Template, *Other, @OtherKey(0), @Error)
BakaShrot_X509_ClearTemplate(@Template)
ClearList(Chain())
AddElement(Chain()) : Chain() = *Copy
AddElement(Chain()) : Chain() = *Other
AddElement(Chain()) : Chain() = *Inter
CheckCode("A CA under a path length 0 one", BakaShrot_X509_VerifyChain(Chain(), *Ca, Now), #BakaShrot_X509_Error_PathTooLong)
BakaShrot_X509_Free(*Copy)
BakaShrot_X509_Free(*Cert)

; Damage: every truncation, every flipped byte, trailing data.
*Buffer = AllocateMemory(*Leaf\DerSize + 1)
Ok = #True
For i = 0 To *Leaf\DerSize - 1
	*Cert = BakaShrot_X509_Parse(*Leaf\Der, i, @Error)
	If *Cert
		Ok = #False
		BakaShrot_X509_Free(*Cert)
	EndIf
Next
Check("Every truncation of the leaf refused (" + Str(*Leaf\DerSize) + ")", Ok)
Define Taken.i = 0, Parsed.i = 0
For i = 0 To *Leaf\DerSize - 1
	CopyMemory(*Leaf\Der, *Buffer, *Leaf\DerSize)
	PokeA(*Buffer + i, PeekA(*Buffer + i) ! $01)
	*Cert = BakaShrot_X509_Parse(*Buffer, *Leaf\DerSize)
	If *Cert
		Parsed + 1
		If BakaShrot_X509_CheckIssuedBy(*Cert, *Ca, Now, CriticalExtension) = #BakaShrot_X509_Ok
			Taken + 1
		EndIf
		BakaShrot_X509_Free(*Cert)
	EndIf
Next
Check("Every flipped bit of the leaf refused, by parsing or checking", Bool(Taken = 0), Str(Parsed) + " of " + Str(*Leaf\DerSize) + " still parsed, " + Str(Taken) + " taken")
CopyMemory(*Leaf\Der, *Buffer, *Leaf\DerSize)
PokeA(*Buffer + *Leaf\DerSize, 0)
Check("Trailing data refused", Bool(BakaShrot_X509_Parse(*Buffer, *Leaf\DerSize + 1, @Error) = 0 And Error\l = #BakaShrot_X509_Error_Malformed))
CopyMemory(*Leaf\Der, *Buffer, *Leaf\DerSize)
PokeA(*Buffer + *Leaf\DerSize - 1, PeekA(*Buffer + *Leaf\DerSize - 1) ! $80)
*Cert = BakaShrot_X509_Parse(*Buffer, *Leaf\DerSize)
Check("A damaged signature: read, but refused", Bool(*Cert <> 0 And BakaShrot_X509_CheckIssuedBy(*Cert, *Ca, Now) = #BakaShrot_X509_Error_BadSignature))
BakaShrot_X509_Free(*Cert)
FreeMemory(*Buffer)
Check("Nothing refused", Bool(BakaShrot_X509_Parse(0, 0, @Error) = 0 And Error\l = #BakaShrot_X509_Error_InvalidArgument))

; PEM
Define Pem.s = BakaShrot_X509_ToPem(*Leaf)
*Cert = BakaShrot_X509_ParsePem(Pem)
Check("PEM round trip", Bool(*Cert <> 0 And *Cert\DerSize = *Leaf\DerSize And CompareMemory(*Cert\Der, *Leaf\Der, *Leaf\DerSize) And Left(Pem, 27) = "-----BEGIN CERTIFICATE-----"))
BakaShrot_X509_Free(*Cert)
*Cert = BakaShrot_X509_ParsePem("Some text" + #CRLF$ + ReplaceString(Pem, #LF$, #CRLF$) + "more text")
Check("PEM with CRLF, text around it", Bool(*Cert <> 0))
BakaShrot_X509_Free(*Cert)
Check("PEM with a bad character refused", Bool(BakaShrot_X509_ParsePem(Left(Pem, 40) + "*" + Mid(Pem, 41)) = 0))
Check("PEM of another label refused", Bool(BakaShrot_X509_ParsePem(ReplaceString(Pem, "CERTIFICATE", "PUBLIC KEY")) = 0))
Check("PEM without its end refused", Bool(BakaShrot_X509_ParsePem(Left(Pem, Len(Pem) - 30)) = 0))

; Private keys
Dim Back.a(63)
Pem = BakaShrot_X509_PrivateKeyToPem(@LeafKey(0))
Check("Private key PEM round trip", Bool(BakaShrot_X509_PrivateKeyFromPem(Pem, @Back(0)) And CompareMemory(@Back(0), @LeafKey(0), 64) And Left(Pem, 27) = "-----BEGIN PRIVATE KEY-----"))
Check("A certificate isn't a private key", Bool(Not BakaShrot_X509_PrivateKeyFromPem(BakaShrot_X509_ToPem(*Leaf), @Back(0))))


;- OpenSSL, both ways

If Folder <> ""
	WriteText(Folder + "bakashrot-ca.pem", BakaShrot_X509_ToPem(*Ca))
	WriteText(Folder + "bakashrot-intermediate.pem", BakaShrot_X509_ToPem(*Inter))
	WriteText(Folder + "bakashrot-leaf.pem", BakaShrot_X509_ToPem(*Leaf))
	WriteText(Folder + "bakashrot-leaf-key.pem", BakaShrot_X509_PrivateKeyToPem(@LeafKey(0)))
	WriteText(Folder + "bakashrot-leaf.sha256", BakaShrot_X509_Fingerprint(*Leaf))
	PrintN("Wrote bakashrot-*.pem")

	If FileSize(Folder + "openssl-ca.pem") > 0
		Define *OpenSslCa.BakaShrot_X509Certificate = BakaShrot_X509_Load(Folder + "openssl-ca.pem", @Error)
		Define *OpenSslLeaf.BakaShrot_X509Certificate = BakaShrot_X509_Load(Folder + "openssl-leaf.der", @Error)
		Define *Rsa.BakaShrot_X509Certificate = BakaShrot_X509_Load(Folder + "openssl-rsa.pem", @Error)
		Define OpenSslNow.q
		Check("OpenSSL's CA read", Bool(*OpenSslCa <> 0))
		Check("OpenSSL's leaf read (DER)", Bool(*OpenSslLeaf <> 0))
		If *OpenSslCa And *OpenSslLeaf
			OpenSslNow = *OpenSslLeaf\NotBefore + 60
			Check("OpenSSL's CA: a CA with its key ids", Bool(*OpenSslCa\IsCa And BakaShrot_X509_CanIssue(*OpenSslCa) And *OpenSslCa\SubjectKeyId <> ""))
			Check("OpenSSL's leaf: names", Bool(BakaShrot_X509_NameGet(@*OpenSslLeaf\Subject, "CN") = "kitchen" And BakaShrot_X509_NameGet(@*OpenSslLeaf\Issuer, "CN") = "OpenSSL Test CA"), BakaShrot_X509_NameToString(@*OpenSslLeaf\Subject))
			Check("OpenSSL's leaf: our text extension", Bool(BakaShrot_X509_GetExtensionText(*OpenSslLeaf, TextExtension, @Text) And Text\s = "from-openssl"), Text\s)
			Check("OpenSSL's leaf: our integer extension", Bool(BakaShrot_X509_GetExtensionInteger(*OpenSslLeaf, IntegerExtension, @Value) And Value = 42))
			CheckCode("OpenSSL's leaf: issued by OpenSSL's CA", BakaShrot_X509_CheckIssuedBy(*OpenSslLeaf, *OpenSslCa, OpenSslNow), #BakaShrot_X509_Ok)
			CheckCode("OpenSSL's leaf: not by ours", BakaShrot_X509_CheckIssuedBy(*OpenSslLeaf, *Ca, OpenSslNow), #BakaShrot_X509_Error_IssuerMismatch)

			; Issued here with OpenSSL's CA and key, for OpenSSL to check.
			Dim OpenSslKey.a(63)
			Dim OpenSslPub.a(31)
			Check("OpenSSL's private key read", BakaShrot_X509_PrivateKeyFromPem(ReadText(Folder + "openssl-ca-key.pem"), @OpenSslKey(0)))
			GetPublicKeyFromPrivateKey(@OpenSslKey(0), @OpenSslPub(0))
			Check("... and it's its CA's", CompareMemory(@OpenSslPub(0), @*OpenSslCa\PublicKey[0], 32))
			BakaShrot_X509_InitTemplate(@Template)
			BakaShrot_X509_NameAdd(@Template\Subject, "CN", "garage")
			Template\NotBefore = BakaShrot_X509_Now() - 3600
			Template\NotAfter  = BakaShrot_X509_Now() + Year
			Template\KeyUsage  = #BakaShrot_X509_KeyUsage_DigitalSignature
			CopyMemory(@LeafPub(0), @Template\PublicKey[0], 32)
			BakaShrot_X509_AddTextExtension(@Template, TextExtension, "from-bakashrot")
			*Der = BakaShrot_X509_Issue(@Template, *OpenSslCa, @OpenSslKey(0), @DerSize, @Error)
			BakaShrot_X509_ClearTemplate(@Template)
			Check("Issued with OpenSSL's CA", Bool(*Der <> 0), BakaShrot_X509_ErrorName(Error\l))
			If *Der
				WriteText(Folder + "bakashrot-by-openssl-ca.pem", BakaShrot_Pem_Encode(*Der, DerSize\i, "CERTIFICATE"))
				FreeMemory(*Der)
			EndIf
		EndIf
		Check("OpenSSL's RSA certificate read", Bool(*Rsa <> 0 And *Rsa\KeyAlgorithm = "1.2.840.113549.1.1.1" And Not *Rsa\HasEd25519Key And BakaShrot_X509_NameGet(@*Rsa\Subject, "CN") = "RSA"))
		If *Rsa
			CheckCode("... it can't be checked", BakaShrot_X509_CheckSignature(*Rsa, @CaPub(0)), #BakaShrot_X509_Error_Unsupported)
			Check("... nor issue", Bool(BakaShrot_X509_Issue(@Template, *Rsa, @CaKey(0), @DerSize, @Error) = 0 And Error\l = #BakaShrot_X509_Error_Unsupported))
		EndIf
		BakaShrot_X509_Free(*OpenSslCa)
		BakaShrot_X509_Free(*OpenSslLeaf)
		BakaShrot_X509_Free(*Rsa)
	Else
		PrintN("SKIP OpenSSL's certificates: none in " + Folder)
	EndIf
EndIf

BakaShrot_X509_Free(*Ca)
BakaShrot_X509_Free(*Inter)
BakaShrot_X509_Free(*Leaf)
BakaShrot_X509_Free(*Other)

PrintN("")
If Fails
	PrintN(Str(Fails) + " check(s) failed")
	End 1
EndIf
PrintN("All checks passed")
End 0


DataSection
	Oids:
	Data.s "0.0", "0.39", "1.0", "1.39", "2.0", "2.47", "2.48", "2.999", "2.5.29.19", "1.3.6.1.4.1.311.21.7"
	Data.s "0.9.2342.19200300.100.1.25", "2.25.232025699926348910519219903487382490981"
	Data.s "2.25.340282366920938463463374607431768211455", "1.2.18446744073709551615.18446744073709551616"
	Data.s "1.2.1393796574908163946345982392040522594123775"
	Data.s ""
	BadOids:
	Data.s "", "1", "3.1", "1.40", "0.40", "1.2.03", "1..2", "1.2.", ".1.2", "a.b", "1.2.-3", "1.2. 3"
	Data.s "1.2.1393796574908163946345982392040522594123776"
	Data.s "end"
EndDataSection
