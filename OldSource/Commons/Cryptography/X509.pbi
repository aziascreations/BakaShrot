;{- Code Header
; ==- Basic Info -================================
;     Name: X509.pbi
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
; BakaShrot X.509 certificates
;
; Reading, issuing and checking X.509 v3 certificates (RFC 5280) with
; Ed25519 keys (RFC 8410), the same identity keys as the rest of BakaShrot.
; The same code on Windows and Linux: DER is read and written by Der.pbi,
; every bit of cryptography is libsodium's (Libsodium.pbi): signatures,
; SHA-256, random serial numbers, Base64 and hex.
; Not the OS's certificate APIs: Windows' CryptoAPI can't check Ed25519
; certificates, and OpenSSL would be another library to ship. The
; certificates are standard all the same: OpenSSL reads and checks them,
; and they're checked against it (Tests/X509-Test.ps1).
;
; Reading: BakaShrot_X509_Parse() (DER), _ParsePem(), _Load() (a file, PEM
; or DER) give a BakaShrot_X509Certificate, freed with BakaShrot_X509_Free().
; Any certificate is read (RSA, ECDSA...), its fields and extensions are
; there, but only Ed25519 ones can be checked or issue others.
;
; Issuing: fill a BakaShrot_X509Template (subject, validity, the subject's
; public key, CA or not, key usage, custom extensions), then
; BakaShrot_X509_Issue() with the issuer's certificate and private key, or
; none for a self-signed one. BakaShrot_X509_ClearTemplate() once done.
;
; Checking: BakaShrot_X509_CheckIssuedBy() for one link, _VerifyChain()
; from a leaf up to a trusted root, _CheckSignature(), _CheckValidity().
; Each returns a #BakaShrot_X509_* code, #BakaShrot_X509_Ok (0) if it
; holds; BakaShrot_X509_ErrorName() names it.
;
; Custom fields are extensions under #BakaShrot_Oid_Extensions:
; BakaShrot_X509_AddTextExtension() / _AddIntegerExtension() /
; _AddExtension() (any DER) on a template, BakaShrot_X509_GetExtensionText()
; / _GetExtensionInteger() / _FindExtension() on a certificate. Critical
; ones a reader doesn't know make the certificate refused, unless the
; caller says it handles them (the Handled argument of the checks).
;
; Times are seconds since 1970-01-01 00:00:00 UTC (BakaShrot_X509_Now()).
; Hex is lowercase, without separators.
;
; Threads: no globals. A parsed certificate is only read once parsed, its
; names and extensions are arrays, not lists: any number of threads may
; read and check one at once (the server's CA, say).
; ============================================================================

XIncludeFile "Libsodium.pbi"
XIncludeFile "Der.pbi"


;- OIDs

#BakaShrot_Oid_Ed25519 = "1.3.101.112"

; Name attributes. BakaShrot_X509_NameAdd() also takes their short names.
#BakaShrot_Oid_CommonName         = "2.5.4.3"
#BakaShrot_Oid_SerialNumber       = "2.5.4.5"
#BakaShrot_Oid_Country            = "2.5.4.6"
#BakaShrot_Oid_Locality           = "2.5.4.7"
#BakaShrot_Oid_State              = "2.5.4.8"
#BakaShrot_Oid_Organization       = "2.5.4.10"
#BakaShrot_Oid_OrganizationalUnit = "2.5.4.11"
#BakaShrot_Oid_EmailAddress       = "1.2.840.113549.1.9.1"
#BakaShrot_Oid_DomainComponent    = "0.9.2342.19200300.100.1.25"
#BakaShrot_Oid_UserId             = "0.9.2342.19200300.100.1.1"

; The extensions this file reads and writes itself.
#BakaShrot_Oid_SubjectKeyId     = "2.5.29.14"
#BakaShrot_Oid_KeyUsage         = "2.5.29.15"
#BakaShrot_Oid_BasicConstraints = "2.5.29.19"
#BakaShrot_Oid_AuthorityKeyId   = "2.5.29.35"

; BakaShrot's own OID arc: a UUID OID (2.25, ITU-T X.667 / RFC 4122), which
; needs no registration. Made 2026-11-13 from the random UUID
; ae8e863a-dae2-47b2-a285-751106c98f65.
#BakaShrot_Oid_Arc = "2.25.232025699926348910519219903487382490981"

; BakaShrot's custom certificate extensions: #BakaShrot_Oid_Extensions +
; ".<n>", numbered as they're defined, a number never reused. None yet.
; (Tests/X509Test.pb uses .9000 and up.)
#BakaShrot_Oid_Extensions = #BakaShrot_Oid_Arc + ".1"


;- Key usage

; KeyUsage bits as flags (bit n of the extension's BIT STRING is 1 << n).
#BakaShrot_X509_KeyUsage_DigitalSignature = 1 << 0
#BakaShrot_X509_KeyUsage_NonRepudiation   = 1 << 1
#BakaShrot_X509_KeyUsage_KeyEncipherment  = 1 << 2
#BakaShrot_X509_KeyUsage_DataEncipherment = 1 << 3
#BakaShrot_X509_KeyUsage_KeyAgreement     = 1 << 4
#BakaShrot_X509_KeyUsage_KeyCertSign      = 1 << 5
#BakaShrot_X509_KeyUsage_CrlSign          = 1 << 6
#BakaShrot_X509_KeyUsage_EncipherOnly     = 1 << 7
#BakaShrot_X509_KeyUsage_DecipherOnly     = 1 << 8


;- Results

Enumeration BakaShrot_X509Results
	#BakaShrot_X509_Ok                   = 0
	; Not a DER X.509 certificate (or PEM of one), or broken somewhere.
	#BakaShrot_X509_Error_Malformed      = 1
	; Not Ed25519: it can be read, not checked nor used to issue.
	#BakaShrot_X509_Error_Unsupported    = 2
	; Its signature isn't its issuer's.
	#BakaShrot_X509_Error_BadSignature   = 3
	; Checked before its NotBefore, or after its NotAfter.
	#BakaShrot_X509_Error_NotYetValid    = 4
	#BakaShrot_X509_Error_Expired        = 5
	; It names another issuer (name, or key id) than the one it's checked with.
	#BakaShrot_X509_Error_IssuerMismatch = 6
	; Its issuer isn't a CA (BasicConstraints), or may not sign certificates (KeyUsage).
	#BakaShrot_X509_Error_NotCa          = 7
	; More CAs under a CA than its PathLength allows.
	#BakaShrot_X509_Error_PathTooLong    = 8
	; A critical extension nobody handles.
	#BakaShrot_X509_Error_UnknownCritical = 9
	; Issuing: the private key isn't the issuer's (or, self-signed, the subject's).
	#BakaShrot_X509_Error_KeyMismatch    = 10
	; A missing or invalid argument, a template that can't be issued.
	#BakaShrot_X509_Error_InvalidArgument = 11
	; Out of memory, a file that can't be read.
	#BakaShrot_X509_Error_Internal       = 12
EndEnumeration


Procedure.s BakaShrot_X509_ErrorName(Code.i)
	Select Code
		Case #BakaShrot_X509_Ok : ProcedureReturn "Ok"
		Case #BakaShrot_X509_Error_Malformed : ProcedureReturn "Malformed"
		Case #BakaShrot_X509_Error_Unsupported : ProcedureReturn "Unsupported"
		Case #BakaShrot_X509_Error_BadSignature : ProcedureReturn "BadSignature"
		Case #BakaShrot_X509_Error_NotYetValid : ProcedureReturn "NotYetValid"
		Case #BakaShrot_X509_Error_Expired : ProcedureReturn "Expired"
		Case #BakaShrot_X509_Error_IssuerMismatch : ProcedureReturn "IssuerMismatch"
		Case #BakaShrot_X509_Error_NotCa : ProcedureReturn "NotCa"
		Case #BakaShrot_X509_Error_PathTooLong : ProcedureReturn "PathTooLong"
		Case #BakaShrot_X509_Error_UnknownCritical : ProcedureReturn "UnknownCritical"
		Case #BakaShrot_X509_Error_KeyMismatch : ProcedureReturn "KeyMismatch"
		Case #BakaShrot_X509_Error_InvalidArgument : ProcedureReturn "InvalidArgument"
		Case #BakaShrot_X509_Error_Internal : ProcedureReturn "Internal"
	EndSelect
	ProcedureReturn "Unknown" + Str(Code)
EndProcedure


;- Structures

; Key ids are the first 20 bytes of the SHA-256 of the public key (RFC 7093).
#BakaShrot_X509_KeyIdSize = 20

; Random serial numbers, when the template has none.
#BakaShrot_X509_SerialSize = 16

; The longest serial number taken (RFC 5280 allows 20 bytes, some write 21).
#BakaShrot_X509_MaxSerialSize = 32


Structure BakaShrot_X509NameAttribute
	; Its type's OID ("2.5.4.3" for CN).
	Oid.s
	Value.s
	; Read: its DER string type (#BakaShrot_Der_Utf8String...). Issuing: 0
	; picks the usual one (PrintableString for C, IA5String for emailAddress
	; and DC, UTF8String otherwise).
	StringTag.i
	; Read: its RDN's index, attributes of a multi-valued RDN share it.
	; Issuing: each attribute is its own RDN, this is ignored.
	Rdn.i
EndStructure

; A distinguished name, its attributes in the certificate's order.
Structure BakaShrot_X509Name
	Count.i
	Array Attributes.BakaShrot_X509NameAttribute(0)
EndStructure


Structure BakaShrot_X509Extension
	Oid.s
	Critical.i
	; extnValue's contents: the extension's own DER. Owned by the
	; certificate or template it's in.
	*Value
	ValueSize.i
EndStructure


Structure BakaShrot_X509Certificate
	; The whole certificate, DER, owned. The offsets point into it.
	*Der
	DerSize.i
	; What the signature covers (tbsCertificate).
	TbsOffset.i
	TbsSize.i
	; The issuer's and subject's names as encoded: issuers are matched on these.
	IssuerOffset.i
	IssuerSize.i
	SubjectOffset.i
	SubjectSize.i

	; 1 to 3.
	Version.i
	; Hex, without the sign byte.
	Serial.s
	SignatureAlgorithm.s
	Issuer.BakaShrot_X509Name
	Subject.BakaShrot_X509Name
	NotBefore.q
	NotAfter.q
	KeyAlgorithm.s

	; Ed25519 only.
	HasEd25519Key.i
	PublicKey.a[#BakaShrot_Ed25519_PublicKeySize]
	HasEd25519Signature.i
	Signature.a[#BakaShrot_Ed25519_SignatureSize]

	; Every extension, in order, the known ones too.
	ExtensionCount.i
	Array Extensions.BakaShrot_X509Extension(0)

	; From BasicConstraints. PathLength -1 when there's none.
	HasBasicConstraints.i
	IsCa.i
	PathLength.i
	; From KeyUsage, #BakaShrot_X509_KeyUsage_* flags.
	HasKeyUsage.i
	KeyUsage.i
	; Hex, "" when absent.
	SubjectKeyId.s
	AuthorityKeyId.s
EndStructure


; What BakaShrot_X509_Issue() makes a certificate of. Set PathLength -1
; (no limit) or call BakaShrot_X509_InitTemplate() first, and
; BakaShrot_X509_ClearTemplate() once done (it holds the extensions' values).
Structure BakaShrot_X509Template
	; Hex; "" for #BakaShrot_X509_SerialSize random bytes.
	Serial.s
	Subject.BakaShrot_X509Name
	NotBefore.q
	NotAfter.q
	; The subject's Ed25519 public key.
	PublicKey.a[#BakaShrot_Ed25519_PublicKeySize]
	; BasicConstraints, always written (critical). PathLength: CAs only, the
	; most CAs under this one, -1 for no limit.
	IsCa.i
	PathLength.i
	; KeyUsage (critical), #BakaShrot_X509_KeyUsage_* flags. 0: none written.
	KeyUsage.i
	; Added with BakaShrot_X509_Add*Extension(), written after the standard ones.
	ExtensionCount.i
	Array Extensions.BakaShrot_X509Extension(0)
EndStructure


;- Helpers

; Now, in seconds since 1970 UTC, for the checks.
CompilerIf #PB_Compiler_OS <> #PB_OS_Windows
	ImportC ""
		BakaShrot_X509_GetTimeOfDay.l(*TimeVal, *TimeZone) As "gettimeofday"
	EndImport
CompilerEndIf

Procedure.q BakaShrot_X509_Now()
	CompilerIf #PB_Compiler_OS = #PB_OS_Windows
		; 100 ns intervals since 1601-01-01 UTC.
		Protected FileTime.q
		GetSystemTimeAsFileTime_(@FileTime)
		ProcedureReturn (FileTime - 116444736000000000) / 10000000
	CompilerElse
		Protected Dim TimeVal.q(1)
		BakaShrot_X509_GetTimeOfDay(@TimeVal(0), 0)
		ProcedureReturn TimeVal(0)
	CompilerEndIf
EndProcedure


; Size bytes at *Data in lowercase hex.
Procedure.s BakaShrot_X509_Hex(*Data, Size.i)
	Protected *Text, Text.s

	If Size < 1
		ProcedureReturn ""
	EndIf
	*Text = AllocateMemory(Size * 2 + 1)
	If Not *Text
		ProcedureReturn ""
	EndIf
	sodium_bin2hex(*Text, Size * 2 + 1, *Data, Size)
	Text = PeekS(*Text, Size * 2, #PB_Ascii)
	FreeMemory(*Text)
	ProcedureReturn Text
EndProcedure


; Text as a new buffer of ASCII, its size (without the terminator) in
; *Size\i. 0 if it isn't ASCII. Free it with FreeMemory.
Procedure.i BakaShrot_X509_Ascii(Text.s, *Size.Integer)
	Protected *Buffer, i.i

	For i = 1 To Len(Text)
		If Asc(Mid(Text, i, 1)) > 127
			ProcedureReturn 0
		EndIf
	Next
	*Buffer = AllocateMemory(Len(Text) + 1)
	If *Buffer
		PokeS(*Buffer, Text, -1, #PB_Ascii)
		*Size\i = Len(Text)
	EndIf
	ProcedureReturn *Buffer
EndProcedure


; Hex (any case) into *Out, at most MaxSize bytes. Returns how many, -1 if
; it isn't hex or doesn't fit.
Procedure.i BakaShrot_X509_FromHex(Hex.s, *Out, MaxSize.i)
	Protected *Text, TextSize.Integer, Size.Integer, Result.i = -1

	*Text = BakaShrot_X509_Ascii(Hex, @TextSize)
	If *Text
		If sodium_hex2bin(*Out, MaxSize, *Text, TextSize\i, 0, @Size, 0) = 0
			Result = Size\i
		EndIf
		FreeMemory(*Text)
	EndIf
	ProcedureReturn Result
EndProcedure


; The key id of an Ed25519 public key into *Out (#BakaShrot_X509_KeyIdSize
; bytes): the first 20 bytes of its SHA-256 (RFC 7093, method 1).
Procedure BakaShrot_X509_KeyId(*PublicKey, *Out)
	Protected Dim Hash.a(#BakaShrot_Sha256_HashSize - 1)

	crypto_hash_sha256(@Hash(0), *PublicKey, #BakaShrot_Ed25519_PublicKeySize)
	CopyMemory(@Hash(0), *Out, #BakaShrot_X509_KeyIdSize)
EndProcedure


;- Names

; The OID of an attribute type: a short name (CN, O, OU, C, L, ST,
; serialNumber, emailAddress, DC, UID, any case) or an OID as is. "" if
; neither.
Procedure.s BakaShrot_X509_NameTypeOid(Type.s)
	Select LCase(Type)
		Case "cn" : ProcedureReturn #BakaShrot_Oid_CommonName
		Case "serialnumber" : ProcedureReturn #BakaShrot_Oid_SerialNumber
		Case "c" : ProcedureReturn #BakaShrot_Oid_Country
		Case "l" : ProcedureReturn #BakaShrot_Oid_Locality
		Case "st" : ProcedureReturn #BakaShrot_Oid_State
		Case "o" : ProcedureReturn #BakaShrot_Oid_Organization
		Case "ou" : ProcedureReturn #BakaShrot_Oid_OrganizationalUnit
		Case "emailaddress" : ProcedureReturn #BakaShrot_Oid_EmailAddress
		Case "dc" : ProcedureReturn #BakaShrot_Oid_DomainComponent
		Case "uid" : ProcedureReturn #BakaShrot_Oid_UserId
	EndSelect
	If BakaShrot_Der_IsValidOid(Type)
		ProcedureReturn Type
	EndIf
	ProcedureReturn ""
EndProcedure


; The short name of an attribute type's OID, the OID itself if it has none.
Procedure.s BakaShrot_X509_NameTypeShort(Oid.s)
	Select Oid
		Case #BakaShrot_Oid_CommonName : ProcedureReturn "CN"
		Case #BakaShrot_Oid_SerialNumber : ProcedureReturn "serialNumber"
		Case #BakaShrot_Oid_Country : ProcedureReturn "C"
		Case #BakaShrot_Oid_Locality : ProcedureReturn "L"
		Case #BakaShrot_Oid_State : ProcedureReturn "ST"
		Case #BakaShrot_Oid_Organization : ProcedureReturn "O"
		Case #BakaShrot_Oid_OrganizationalUnit : ProcedureReturn "OU"
		Case #BakaShrot_Oid_EmailAddress : ProcedureReturn "emailAddress"
		Case #BakaShrot_Oid_DomainComponent : ProcedureReturn "DC"
		Case #BakaShrot_Oid_UserId : ProcedureReturn "UID"
	EndSelect
	ProcedureReturn Oid
EndProcedure


; Adds an attribute at the end of *Name. Type: a short name or an OID, see
; BakaShrot_X509_NameTypeOid(). StringTag: see BakaShrot_X509NameAttribute.
; Returns #False if Type is neither.
Procedure.i BakaShrot_X509_NameAdd(*Name.BakaShrot_X509Name, Type.s, Value.s, StringTag.i = 0, Rdn.i = -1)
	Protected Oid.s = BakaShrot_X509_NameTypeOid(Type)

	If Oid = ""
		ProcedureReturn #False
	EndIf
	If *Name\Count > ArraySize(*Name\Attributes())
		ReDim *Name\Attributes(*Name\Count * 2 + 3)
	EndIf
	If Rdn < 0
		Rdn = *Name\Count
	EndIf
	*Name\Attributes(*Name\Count)\Oid       = Oid
	*Name\Attributes(*Name\Count)\Value     = Value
	*Name\Attributes(*Name\Count)\StringTag = StringTag
	*Name\Attributes(*Name\Count)\Rdn       = Rdn
	*Name\Count + 1
	ProcedureReturn #True
EndProcedure


; The first value of the attribute Type (a short name or an OID) in *Name,
; "" if it has none.
Procedure.s BakaShrot_X509_NameGet(*Name.BakaShrot_X509Name, Type.s)
	Protected Oid.s = BakaShrot_X509_NameTypeOid(Type), i.i

	For i = 0 To *Name\Count - 1
		If *Name\Attributes(i)\Oid = Oid
			ProcedureReturn *Name\Attributes(i)\Value
		EndIf
	Next
	ProcedureReturn ""
EndProcedure


; *Name as "CN=demo, O=BakaShrot", in the certificate's order, the
; attributes of a multi-valued RDN joined with "+". For people: values
; aren't escaped.
Procedure.s BakaShrot_X509_NameToString(*Name.BakaShrot_X509Name)
	Protected i.i, Text.s

	For i = 0 To *Name\Count - 1
		If i > 0
			If *Name\Attributes(i)\Rdn = *Name\Attributes(i - 1)\Rdn
				Text + "+"
			Else
				Text + ", "
			EndIf
		EndIf
		Text + BakaShrot_X509_NameTypeShort(*Name\Attributes(i)\Oid) + "=" + *Name\Attributes(i)\Value
	Next
	ProcedureReturn Text
EndProcedure


;- Reading

; Frees a certificate from BakaShrot_X509_Parse() and the like.
Procedure BakaShrot_X509_Free(*Cert.BakaShrot_X509Certificate)
	Protected i.i

	If Not *Cert
		ProcedureReturn
	EndIf
	For i = 0 To *Cert\ExtensionCount - 1
		If *Cert\Extensions(i)\Value
			FreeMemory(*Cert\Extensions(i)\Value)
		EndIf
	Next
	If *Cert\Der
		FreeMemory(*Cert\Der)
	EndIf
	FreeStructure(*Cert)
EndProcedure


; An AlgorithmIdentifier: its OID into *Oid\s, and whether it has
; parameters (any) into *HasParameters\i.
Procedure.i BakaShrot_X509_ReadAlgorithm(*Element.BakaShrot_DerElement, *Oid.String, *HasParameters.Integer)
	Protected Reader.BakaShrot_DerReader, Item.BakaShrot_DerElement

	BakaShrot_Der_ReaderOf(@Reader, *Element)
	If Not BakaShrot_Der_Expect(@Reader, #BakaShrot_Der_Oid, @Item)
		ProcedureReturn #False
	EndIf
	*Oid\s = BakaShrot_Der_GetOid(@Item)
	If *Oid\s = ""
		ProcedureReturn #False
	EndIf
	*HasParameters\i = #False
	If Not BakaShrot_Der_AtEnd(@Reader)
		*HasParameters\i = #True
		If Not BakaShrot_Der_Read(@Reader, @Item)
			ProcedureReturn #False
		EndIf
	EndIf
	ProcedureReturn BakaShrot_Der_AtEnd(@Reader)
EndProcedure


; A Name: a SEQUENCE of RDNs, each a SET of (type, string) pairs.
Procedure.i BakaShrot_X509_ReadName(*Element.BakaShrot_DerElement, *Name.BakaShrot_X509Name)
	Protected Names.BakaShrot_DerReader, Rdns.BakaShrot_DerReader, Pair.BakaShrot_DerReader
	Protected RdnSet.BakaShrot_DerElement, Attribute.BakaShrot_DerElement, Item.BakaShrot_DerElement
	Protected Rdn.i, Oid.s, Value.String

	BakaShrot_Der_ReaderOf(@Names, *Element)
	While Not BakaShrot_Der_AtEnd(@Names)
		If Not BakaShrot_Der_Expect(@Names, #BakaShrot_Der_Set, @RdnSet)
			ProcedureReturn #False
		EndIf
		BakaShrot_Der_ReaderOf(@Rdns, @RdnSet)
		; An RDN has one attribute at least.
		If BakaShrot_Der_AtEnd(@Rdns)
			ProcedureReturn #False
		EndIf
		While Not BakaShrot_Der_AtEnd(@Rdns)
			If Not BakaShrot_Der_Expect(@Rdns, #BakaShrot_Der_Sequence, @Attribute)
				ProcedureReturn #False
			EndIf
			BakaShrot_Der_ReaderOf(@Pair, @Attribute)
			If Not BakaShrot_Der_Expect(@Pair, #BakaShrot_Der_Oid, @Item)
				ProcedureReturn #False
			EndIf
			Oid = BakaShrot_Der_GetOid(@Item)
			If Oid = "" Or Not BakaShrot_Der_Read(@Pair, @Item) Or Not BakaShrot_Der_AtEnd(@Pair)
				ProcedureReturn #False
			EndIf
			If Not BakaShrot_Der_GetText(@Item, @Value)
				ProcedureReturn #False
			EndIf
			BakaShrot_X509_NameAdd(*Name, Oid, Value\s, Item\Tag, Rdn)
		Wend
		Rdn + 1
	Wend
	ProcedureReturn BakaShrot_Der_AtEnd(@Names)
EndProcedure


; The known extension *Extension's fields into *Cert. #False if malformed.
Procedure.i BakaShrot_X509_ReadKnownExtension(*Cert.BakaShrot_X509Certificate, *Extension.BakaShrot_X509Extension)
	Protected Reader.BakaShrot_DerReader, Inner.BakaShrot_DerReader
	Protected Item.BakaShrot_DerElement, Field.BakaShrot_DerElement, Value.q, Flag.i

	BakaShrot_Der_InitReader(@Reader, *Extension\Value, *Extension\ValueSize)
	Select *Extension\Oid

		Case #BakaShrot_Oid_BasicConstraints
			; SEQUENCE { cA BOOLEAN DEFAULT FALSE, pathLenConstraint INTEGER OPTIONAL }
			If Not BakaShrot_Der_Expect(@Reader, #BakaShrot_Der_Sequence, @Item)
				ProcedureReturn #False
			EndIf
			BakaShrot_Der_ReaderOf(@Inner, @Item)
			If BakaShrot_Der_PeekTag(@Inner) = #BakaShrot_Der_Boolean
				If Not BakaShrot_Der_Read(@Inner, @Field) Or Not BakaShrot_Der_GetBoolean(@Field, @Flag)
					ProcedureReturn #False
				EndIf
				*Cert\IsCa = Flag
			EndIf
			If BakaShrot_Der_PeekTag(@Inner) = #BakaShrot_Der_Integer
				If Not BakaShrot_Der_Read(@Inner, @Field) Or Not BakaShrot_Der_GetInteger(@Field, @Value) Or Value < 0 Or Value > 255
					ProcedureReturn #False
				EndIf
				*Cert\PathLength = Value
			EndIf
			If Not BakaShrot_Der_AtEnd(@Inner)
				ProcedureReturn #False
			EndIf
			*Cert\HasBasicConstraints = #True

		Case #BakaShrot_Oid_KeyUsage
			If Not BakaShrot_Der_Expect(@Reader, #BakaShrot_Der_BitString, @Item) Or Not BakaShrot_Der_GetBitFlags(@Item, @Flag)
				ProcedureReturn #False
			EndIf
			*Cert\KeyUsage    = Flag
			*Cert\HasKeyUsage = #True

		Case #BakaShrot_Oid_SubjectKeyId
			If Not BakaShrot_Der_Expect(@Reader, #BakaShrot_Der_OctetString, @Item) Or Item\ContentSize < 1
				ProcedureReturn #False
			EndIf
			*Cert\SubjectKeyId = BakaShrot_X509_Hex(Item\Content, Item\ContentSize)

		Case #BakaShrot_Oid_AuthorityKeyId
			; SEQUENCE { keyIdentifier [0] OPTIONAL, authorityCertIssuer [1] OPTIONAL, authorityCertSerialNumber [2] OPTIONAL }
			If Not BakaShrot_Der_Expect(@Reader, #BakaShrot_Der_Sequence, @Item)
				ProcedureReturn #False
			EndIf
			BakaShrot_Der_ReaderOf(@Inner, @Item)
			If BakaShrot_Der_PeekTag(@Inner) = #BakaShrot_Der_Context | 0
				If Not BakaShrot_Der_Read(@Inner, @Field) Or Field\ContentSize < 1
					ProcedureReturn #False
				EndIf
				*Cert\AuthorityKeyId = BakaShrot_X509_Hex(Field\Content, Field\ContentSize)
			EndIf
			If BakaShrot_Der_PeekTag(@Inner) = #BakaShrot_Der_ContextConstructed | 1
				BakaShrot_Der_Read(@Inner, @Field)
			EndIf
			If BakaShrot_Der_PeekTag(@Inner) = #BakaShrot_Der_Context | 2
				BakaShrot_Der_Read(@Inner, @Field)
			EndIf
			If Not BakaShrot_Der_AtEnd(@Inner)
				ProcedureReturn #False
			EndIf

		Default
			ProcedureReturn #True
	EndSelect

	ProcedureReturn BakaShrot_Der_AtEnd(@Reader)
EndProcedure


; Extensions: a SEQUENCE of one or more SEQUENCE { extnID OID, critical
; BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }, each OID once at most.
Procedure.i BakaShrot_X509_ReadExtensions(*Element.BakaShrot_DerElement, *Cert.BakaShrot_X509Certificate)
	Protected Items.BakaShrot_DerReader, Fields.BakaShrot_DerReader, Check.BakaShrot_DerReader
	Protected Extension.BakaShrot_DerElement, Item.BakaShrot_DerElement
	Protected Oid.s, Critical.i, i.i, Index.i

	BakaShrot_Der_ReaderOf(@Items, *Element)
	If BakaShrot_Der_AtEnd(@Items)
		ProcedureReturn #False
	EndIf
	While Not BakaShrot_Der_AtEnd(@Items)
		If Not BakaShrot_Der_Expect(@Items, #BakaShrot_Der_Sequence, @Extension)
			ProcedureReturn #False
		EndIf
		BakaShrot_Der_ReaderOf(@Fields, @Extension)
		If Not BakaShrot_Der_Expect(@Fields, #BakaShrot_Der_Oid, @Item)
			ProcedureReturn #False
		EndIf
		Oid = BakaShrot_Der_GetOid(@Item)
		If Oid = ""
			ProcedureReturn #False
		EndIf
		For i = 0 To *Cert\ExtensionCount - 1
			If *Cert\Extensions(i)\Oid = Oid
				ProcedureReturn #False
			EndIf
		Next
		Critical = #False
		If BakaShrot_Der_PeekTag(@Fields) = #BakaShrot_Der_Boolean
			If Not BakaShrot_Der_Read(@Fields, @Item) Or Not BakaShrot_Der_GetBoolean(@Item, @Critical)
				ProcedureReturn #False
			EndIf
		EndIf
		If Not BakaShrot_Der_Expect(@Fields, #BakaShrot_Der_OctetString, @Item) Or Not BakaShrot_Der_AtEnd(@Fields)
			ProcedureReturn #False
		EndIf
		; extnValue holds one DER element.
		BakaShrot_Der_ReaderOf(@Check, @Item)
		If Not BakaShrot_Der_Read(@Check, @Extension) Or Not BakaShrot_Der_AtEnd(@Check)
			ProcedureReturn #False
		EndIf

		Index = *Cert\ExtensionCount
		If Index > ArraySize(*Cert\Extensions())
			ReDim *Cert\Extensions(Index * 2 + 3)
		EndIf
		*Cert\Extensions(Index)\Oid       = Oid
		*Cert\Extensions(Index)\Critical  = Critical
		*Cert\Extensions(Index)\ValueSize = Item\ContentSize
		*Cert\Extensions(Index)\Value     = AllocateMemory(Item\ContentSize)
		If Not *Cert\Extensions(Index)\Value
			ProcedureReturn #False
		EndIf
		CopyMemory(Item\Content, *Cert\Extensions(Index)\Value, Item\ContentSize)
		*Cert\ExtensionCount + 1

		If Not BakaShrot_X509_ReadKnownExtension(*Cert, @*Cert\Extensions(Index))
			ProcedureReturn #False
		EndIf
	Wend
	ProcedureReturn #True
EndProcedure


; Reads a DER certificate, Size bytes at *Der (copied: it may be freed after).
; Returns a new BakaShrot_X509Certificate (free it with BakaShrot_X509_Free()),
; or 0 with *Error\l set (#BakaShrot_X509_Error_Malformed...), if given.
; Any algorithm is read; for Ed25519 the key and signature must be right.
; Nothing may follow the certificate.
Procedure.i BakaShrot_X509_Parse(*Der, Size.i, *Error.Long = 0)
	Protected *Cert.BakaShrot_X509Certificate, Code.i = #BakaShrot_X509_Error_Malformed
	Protected Top.BakaShrot_DerReader, Outer.BakaShrot_DerReader, Tbs.BakaShrot_DerReader, Inner.BakaShrot_DerReader
	Protected CertElement.BakaShrot_DerElement, TbsElement.BakaShrot_DerElement, OuterAlgorithm.BakaShrot_DerElement
	Protected SignatureElement.BakaShrot_DerElement, Item.BakaShrot_DerElement, Field.BakaShrot_DerElement
	Protected Value.q, Oid.String, HasParameters.i, *Bytes, BytesSize.i

	If Not *Der Or Size < 1 Or Size > #BakaShrot_Der_MaxSize
		Code = #BakaShrot_X509_Error_InvalidArgument
		Goto ParseFailed
	EndIf
	*Cert = AllocateStructure(BakaShrot_X509Certificate)
	If *Cert
		*Cert\Der = AllocateMemory(Size)
	EndIf
	If Not *Cert Or Not *Cert\Der
		Code = #BakaShrot_X509_Error_Internal
		Goto ParseFailed
	EndIf
	CopyMemory(*Der, *Cert\Der, Size)
	*Cert\DerSize    = Size
	*Cert\PathLength = -1

	; Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
	BakaShrot_Der_InitReader(@Top, *Cert\Der, Size)
	If Not BakaShrot_Der_Expect(@Top, #BakaShrot_Der_Sequence, @CertElement) Or Not BakaShrot_Der_AtEnd(@Top)
		Goto ParseFailed
	EndIf
	BakaShrot_Der_ReaderOf(@Outer, @CertElement)
	If Not BakaShrot_Der_Expect(@Outer, #BakaShrot_Der_Sequence, @TbsElement)
		Goto ParseFailed
	EndIf
	If Not BakaShrot_Der_Expect(@Outer, #BakaShrot_Der_Sequence, @OuterAlgorithm)
		Goto ParseFailed
	EndIf
	If Not BakaShrot_Der_Expect(@Outer, #BakaShrot_Der_BitString, @SignatureElement) Or Not BakaShrot_Der_AtEnd(@Outer)
		Goto ParseFailed
	EndIf
	*Cert\TbsOffset = TbsElement\Start - *Cert\Der
	*Cert\TbsSize   = TbsElement\Size

	BakaShrot_Der_ReaderOf(@Tbs, @TbsElement)

	; version [0] EXPLICIT INTEGER DEFAULT v1: v1 is never written.
	*Cert\Version = 1
	If BakaShrot_Der_PeekTag(@Tbs) = #BakaShrot_Der_ContextConstructed | 0
		BakaShrot_Der_Read(@Tbs, @Item)
		BakaShrot_Der_ReaderOf(@Inner, @Item)
		If Not BakaShrot_Der_Expect(@Inner, #BakaShrot_Der_Integer, @Field) Or Not BakaShrot_Der_AtEnd(@Inner)
			Goto ParseFailed
		EndIf
		If Not BakaShrot_Der_GetInteger(@Field, @Value) Or Value < 1 Or Value > 2
			Goto ParseFailed
		EndIf
		*Cert\Version = Value + 1
	EndIf

	; serialNumber
	If Not BakaShrot_Der_Expect(@Tbs, #BakaShrot_Der_Integer, @Item) Or Not BakaShrot_Der_IsMinimalInteger(@Item) Or Item\ContentSize > #BakaShrot_X509_MaxSerialSize
		Goto ParseFailed
	EndIf
	If Item\ContentSize > 1 And PeekA(Item\Content) = 0
		*Cert\Serial = BakaShrot_X509_Hex(Item\Content + 1, Item\ContentSize - 1)
	Else
		*Cert\Serial = BakaShrot_X509_Hex(Item\Content, Item\ContentSize)
	EndIf

	; signature: the same AlgorithmIdentifier as the outer one, byte for byte.
	If Not BakaShrot_Der_Expect(@Tbs, #BakaShrot_Der_Sequence, @Item)
		Goto ParseFailed
	EndIf
	If Item\Size <> OuterAlgorithm\Size Or Not CompareMemory(Item\Start, OuterAlgorithm\Start, Item\Size)
		Goto ParseFailed
	EndIf
	If Not BakaShrot_X509_ReadAlgorithm(@Item, @Oid, @HasParameters)
		Goto ParseFailed
	EndIf
	*Cert\SignatureAlgorithm = Oid\s
	; Ed25519 has no parameters (RFC 8410).
	If Oid\s = #BakaShrot_Oid_Ed25519 And HasParameters
		Goto ParseFailed
	EndIf

	; issuer
	If Not BakaShrot_Der_Expect(@Tbs, #BakaShrot_Der_Sequence, @Item) Or Not BakaShrot_X509_ReadName(@Item, @*Cert\Issuer)
		Goto ParseFailed
	EndIf
	*Cert\IssuerOffset = Item\Start - *Cert\Der
	*Cert\IssuerSize   = Item\Size

	; validity
	If Not BakaShrot_Der_Expect(@Tbs, #BakaShrot_Der_Sequence, @Item)
		Goto ParseFailed
	EndIf
	BakaShrot_Der_ReaderOf(@Inner, @Item)
	If Not BakaShrot_Der_Read(@Inner, @Field) Or Not BakaShrot_Der_GetTime(@Field, @*Cert\NotBefore)
		Goto ParseFailed
	EndIf
	If Not BakaShrot_Der_Read(@Inner, @Field) Or Not BakaShrot_Der_GetTime(@Field, @*Cert\NotAfter) Or Not BakaShrot_Der_AtEnd(@Inner)
		Goto ParseFailed
	EndIf

	; subject
	If Not BakaShrot_Der_Expect(@Tbs, #BakaShrot_Der_Sequence, @Item) Or Not BakaShrot_X509_ReadName(@Item, @*Cert\Subject)
		Goto ParseFailed
	EndIf
	*Cert\SubjectOffset = Item\Start - *Cert\Der
	*Cert\SubjectSize   = Item\Size

	; subjectPublicKeyInfo ::= SEQUENCE { algorithm, subjectPublicKey BIT STRING }
	If Not BakaShrot_Der_Expect(@Tbs, #BakaShrot_Der_Sequence, @Item)
		Goto ParseFailed
	EndIf
	BakaShrot_Der_ReaderOf(@Inner, @Item)
	If Not BakaShrot_Der_Expect(@Inner, #BakaShrot_Der_Sequence, @Field) Or Not BakaShrot_X509_ReadAlgorithm(@Field, @Oid, @HasParameters)
		Goto ParseFailed
	EndIf
	*Cert\KeyAlgorithm = Oid\s
	If Not BakaShrot_Der_Expect(@Inner, #BakaShrot_Der_BitString, @Field) Or Not BakaShrot_Der_AtEnd(@Inner)
		Goto ParseFailed
	EndIf
	If Oid\s = #BakaShrot_Oid_Ed25519
		If HasParameters Or Not BakaShrot_Der_GetBitStringBytes(@Field, @*Bytes, @BytesSize) Or BytesSize <> #BakaShrot_Ed25519_PublicKeySize
			Goto ParseFailed
		EndIf
		CopyMemory(*Bytes, @*Cert\PublicKey[0], #BakaShrot_Ed25519_PublicKeySize)
		*Cert\HasEd25519Key = #True
	EndIf

	; issuerUniqueID [1], subjectUniqueID [2]: v2 and v3 only, skipped.
	If BakaShrot_Der_PeekTag(@Tbs) = #BakaShrot_Der_Context | 1
		If *Cert\Version < 2 Or Not BakaShrot_Der_Read(@Tbs, @Item)
			Goto ParseFailed
		EndIf
	EndIf
	If BakaShrot_Der_PeekTag(@Tbs) = #BakaShrot_Der_Context | 2
		If *Cert\Version < 2 Or Not BakaShrot_Der_Read(@Tbs, @Item)
			Goto ParseFailed
		EndIf
	EndIf

	; extensions [3] EXPLICIT, v3 only.
	If BakaShrot_Der_PeekTag(@Tbs) = #BakaShrot_Der_ContextConstructed | 3
		If *Cert\Version <> 3
			Goto ParseFailed
		EndIf
		BakaShrot_Der_Read(@Tbs, @Item)
		BakaShrot_Der_ReaderOf(@Inner, @Item)
		If Not BakaShrot_Der_Expect(@Inner, #BakaShrot_Der_Sequence, @Field) Or Not BakaShrot_Der_AtEnd(@Inner)
			Goto ParseFailed
		EndIf
		If Not BakaShrot_X509_ReadExtensions(@Field, *Cert)
			Goto ParseFailed
		EndIf
	EndIf
	If Not BakaShrot_Der_AtEnd(@Tbs)
		Goto ParseFailed
	EndIf

	; signatureValue
	If Not BakaShrot_Der_GetBitStringBytes(@SignatureElement, @*Bytes, @BytesSize)
		Goto ParseFailed
	EndIf
	If *Cert\SignatureAlgorithm = #BakaShrot_Oid_Ed25519
		If BytesSize <> #BakaShrot_Ed25519_SignatureSize
			Goto ParseFailed
		EndIf
		CopyMemory(*Bytes, @*Cert\Signature[0], #BakaShrot_Ed25519_SignatureSize)
		*Cert\HasEd25519Signature = #True
	EndIf

	If *Error
		*Error\l = #BakaShrot_X509_Ok
	EndIf
	ProcedureReturn *Cert

	ParseFailed:
	BakaShrot_X509_Free(*Cert)
	If *Error
		*Error\l = Code
	EndIf
	ProcedureReturn 0
EndProcedure


; The index of the extension Oid in *Cert, -1 if it has none.
Procedure.i BakaShrot_X509_FindExtension(*Cert.BakaShrot_X509Certificate, Oid.s)
	Protected i.i

	For i = 0 To *Cert\ExtensionCount - 1
		If *Cert\Extensions(i)\Oid = Oid
			ProcedureReturn i
		EndIf
	Next
	ProcedureReturn -1
EndProcedure


; The text of the extension Oid, a single DER string (see
; BakaShrot_Der_GetText()), into *Text\s. #False if *Cert has none, or it
; isn't a string.
Procedure.i BakaShrot_X509_GetExtensionText(*Cert.BakaShrot_X509Certificate, Oid.s, *Text.String)
	Protected Index.i = BakaShrot_X509_FindExtension(*Cert, Oid)
	Protected Reader.BakaShrot_DerReader, Item.BakaShrot_DerElement

	If Index < 0
		ProcedureReturn #False
	EndIf
	BakaShrot_Der_InitReader(@Reader, *Cert\Extensions(Index)\Value, *Cert\Extensions(Index)\ValueSize)
	If Not BakaShrot_Der_Read(@Reader, @Item) Or Not BakaShrot_Der_AtEnd(@Reader)
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_Der_GetText(@Item, *Text)
EndProcedure


; The value of the extension Oid, a single INTEGER of up to 8 bytes, into
; *Value\q. #False if *Cert has none, or it isn't one.
Procedure.i BakaShrot_X509_GetExtensionInteger(*Cert.BakaShrot_X509Certificate, Oid.s, *Value.Quad)
	Protected Index.i = BakaShrot_X509_FindExtension(*Cert, Oid)
	Protected Reader.BakaShrot_DerReader, Item.BakaShrot_DerElement

	If Index < 0
		ProcedureReturn #False
	EndIf
	BakaShrot_Der_InitReader(@Reader, *Cert\Extensions(Index)\Value, *Cert\Extensions(Index)\ValueSize)
	If Not BakaShrot_Der_Expect(@Reader, #BakaShrot_Der_Integer, @Item) Or Not BakaShrot_Der_AtEnd(@Reader)
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_Der_GetInteger(@Item, *Value)
EndProcedure


; SHA-256 of the whole certificate, in hex: what `openssl x509 -fingerprint
; -sha256` shows (without its colons).
Procedure.s BakaShrot_X509_Fingerprint(*Cert.BakaShrot_X509Certificate)
	Protected Dim Hash.a(#BakaShrot_Sha256_HashSize - 1)

	crypto_hash_sha256(@Hash(0), *Cert\Der, *Cert\DerSize)
	ProcedureReturn BakaShrot_X509_Hex(@Hash(0), #BakaShrot_Sha256_HashSize)
EndProcedure


; A UTC time as "2026-11-13 14:03:59Z".
Procedure.s BakaShrot_X509_FormatTime(Seconds.q)
	Protected Days.q, Rest.q, Year.q, Month.q, Day.q

	Days = Seconds / 86400
	Rest = Seconds % 86400
	If Rest < 0
		Days - 1
		Rest + 86400
	EndIf
	BakaShrot_Der_CivilFromDays(Days, @Year, @Month, @Day)
	ProcedureReturn RSet(Str(Year), 4, "0") + "-" + RSet(Str(Month), 2, "0") + "-" + RSet(Str(Day), 2, "0") + " " +
	                RSet(Str(Rest / 3600), 2, "0") + ":" + RSet(Str((Rest / 60) % 60), 2, "0") + ":" + RSet(Str(Rest % 60), 2, "0") + "Z"
EndProcedure


; *Cert described in a few lines, for people (tools, logs).
Procedure.s BakaShrot_X509_Describe(*Cert.BakaShrot_X509Certificate)
	Protected Text.s, i.i, Flags.s

	Text = "Subject:     " + BakaShrot_X509_NameToString(@*Cert\Subject) + #LF$ +
	       "Issuer:      " + BakaShrot_X509_NameToString(@*Cert\Issuer) + #LF$ +
	       "Serial:      " + *Cert\Serial + #LF$ +
	       "Valid:       " + BakaShrot_X509_FormatTime(*Cert\NotBefore) + " to " + BakaShrot_X509_FormatTime(*Cert\NotAfter) + #LF$
	If *Cert\HasEd25519Key
		Text + "Key:         Ed25519 " + EncodeKeyToString(@*Cert\PublicKey[0], #BakaShrot_Ed25519_PublicKeySize) + #LF$
	Else
		Text + "Key:         " + *Cert\KeyAlgorithm + " (not Ed25519)" + #LF$
	EndIf
	If *Cert\HasBasicConstraints And *Cert\IsCa
		If *Cert\PathLength >= 0
			Text + "CA:          yes, path length " + Str(*Cert\PathLength) + #LF$
		Else
			Text + "CA:          yes" + #LF$
		EndIf
	Else
		Text + "CA:          no" + #LF$
	EndIf
	If *Cert\HasKeyUsage
		Text + "Key usage:   $" + Hex(*Cert\KeyUsage) + #LF$
	EndIf
	For i = 0 To *Cert\ExtensionCount - 1
		Flags = ""
		If *Cert\Extensions(i)\Critical
			Flags = " (critical)"
		EndIf
		Text + "Extension:   " + *Cert\Extensions(i)\Oid + Flags + ", " + Str(*Cert\Extensions(i)\ValueSize) + " bytes" + #LF$
	Next
	Text + "SHA-256:     " + BakaShrot_X509_Fingerprint(*Cert)
	ProcedureReturn Text
EndProcedure


;- PEM

; Size bytes at *Data as a PEM block: "-----BEGIN <Label>-----", Base64 in
; lines of 64, "-----END <Label>-----", LF line endings. "" on failure.
Procedure.s BakaShrot_Pem_Encode(*Data, Size.i, Label.s)
	Protected *Base64, Base64Size.i, Text.s, Body.s, i.i

	If Not *Data Or Size < 1
		ProcedureReturn ""
	EndIf
	Base64Size = sodium_base64_encoded_len(Size, #BakaShrot_Base64_Original)
	*Base64 = AllocateMemory(Base64Size)
	If Not *Base64
		ProcedureReturn ""
	EndIf
	sodium_bin2base64(*Base64, Base64Size, *Data, Size, #BakaShrot_Base64_Original)
	Body = PeekS(*Base64, Base64Size - 1, #PB_Ascii)
	FreeMemory(*Base64)

	Text = "-----BEGIN " + Label + "-----" + #LF$
	For i = 1 To Len(Body) Step 64
		Text + Mid(Body, i, 64) + #LF$
	Next
	ProcedureReturn Text + "-----END " + Label + "-----" + #LF$
EndProcedure


; The first PEM block of Label in Text, decoded into a new buffer (free it
; with FreeMemory), its size in *OutSize\i. 0 if there's none, or its
; Base64 isn't valid (spaces and line breaks are skipped).
Procedure.i BakaShrot_Pem_Decode(Text.s, Label.s, *OutSize.Integer)
	Protected Begin.s = "-----BEGIN " + Label + "-----", Finish.s = "-----END " + Label + "-----"
	Protected Start.i, Stop.i, Body.s, *Body, BodySize.Integer, *Ignore, IgnoreSize.Integer, *Out, OutSize.Integer

	Start = FindString(Text, Begin)
	If Not Start
		ProcedureReturn 0
	EndIf
	Start + Len(Begin)
	Stop = FindString(Text, Finish, Start)
	If Not Stop
		ProcedureReturn 0
	EndIf
	Body = Mid(Text, Start, Stop - Start)

	*Body   = BakaShrot_X509_Ascii(Body, @BodySize)
	*Ignore = BakaShrot_X509_Ascii(" " + #TAB$ + #CR$ + #LF$, @IgnoreSize)
	*Out    = AllocateMemory(Len(Body) * 3 / 4 + 4)
	If *Body And *Ignore And *Out
		If sodium_base642bin(*Out, MemorySize(*Out), *Body, BodySize\i, *Ignore, @OutSize, 0, #BakaShrot_Base64_Original) <> 0 Or OutSize\i < 1
			FreeMemory(*Out)
			*Out = 0
		Else
			*OutSize\i = OutSize\i
		EndIf
	ElseIf *Out
		FreeMemory(*Out)
		*Out = 0
	EndIf
	If *Body
		FreeMemory(*Body)
	EndIf
	If *Ignore
		FreeMemory(*Ignore)
	EndIf
	ProcedureReturn *Out
EndProcedure


; Reads the first "CERTIFICATE" PEM block in Text, see BakaShrot_X509_Parse().
Procedure.i BakaShrot_X509_ParsePem(Text.s, *Error.Long = 0)
	Protected *Der, Size.Integer, *Cert

	*Der = BakaShrot_Pem_Decode(Text, "CERTIFICATE", @Size)
	If Not *Der
		If *Error
			*Error\l = #BakaShrot_X509_Error_Malformed
		EndIf
		ProcedureReturn 0
	EndIf
	*Cert = BakaShrot_X509_Parse(*Der, Size\i, *Error)
	FreeMemory(*Der)
	ProcedureReturn *Cert
EndProcedure


; *Cert as a "CERTIFICATE" PEM block.
Procedure.s BakaShrot_X509_ToPem(*Cert.BakaShrot_X509Certificate)
	ProcedureReturn BakaShrot_Pem_Encode(*Cert\Der, *Cert\DerSize, "CERTIFICATE")
EndProcedure


; Reads a whole file into a new buffer (free it with FreeMemory), its size
; in *Size\i. 0 if it can't be read, is empty or over #BakaShrot_Der_MaxSize.
Procedure.i BakaShrot_X509_ReadFile(Path.s, *Size.Integer)
	Protected File.i, Length.q, *Data

	File = ReadFile(#PB_Any, Path)
	If Not File
		ProcedureReturn 0
	EndIf
	Length = Lof(File)
	If Length > 0 And Length <= #BakaShrot_Der_MaxSize
		*Data = AllocateMemory(Length)
		If *Data
			If ReadData(File, *Data, Length) = Length
				*Size\i = Length
			Else
				FreeMemory(*Data)
				*Data = 0
			EndIf
		EndIf
	EndIf
	CloseFile(File)
	ProcedureReturn *Data
EndProcedure


; Reads a certificate file: PEM (its first CERTIFICATE block) or DER.
; See BakaShrot_X509_Parse(); #BakaShrot_X509_Error_Internal if the file
; can't be read.
Procedure.i BakaShrot_X509_Load(Path.s, *Error.Long = 0)
	Protected *Data, Size.Integer, *Cert

	*Data = BakaShrot_X509_ReadFile(Path, @Size)
	If Not *Data
		If *Error
			*Error\l = #BakaShrot_X509_Error_Internal
		EndIf
		ProcedureReturn 0
	EndIf
	If PeekA(*Data) = #BakaShrot_Der_Sequence
		*Cert = BakaShrot_X509_Parse(*Data, Size\i, *Error)
	Else
		*Cert = BakaShrot_X509_ParsePem(PeekS(*Data, Size\i, #PB_UTF8 | #PB_ByteLength), *Error)
	EndIf
	FreeMemory(*Data)
	ProcedureReturn *Cert
EndProcedure


;- Private keys

; An Ed25519 private key (64 bytes, libsodium's) as a PKCS#8 "PRIVATE KEY"
; PEM block (RFC 8410), what `openssl genpkey -algorithm ed25519` writes.
; Not encrypted: keep the file private. "" on failure.
Procedure.s BakaShrot_X509_PrivateKeyToPem(*PrivateKey)
	Protected Writer.BakaShrot_DerWriter, *Der, Size.Integer, Text.s
	Protected Dim Seed.a(31)

	crypto_sign_ed25519_sk_to_seed(@Seed(0), *PrivateKey)

	; OneAsymmetricKey ::= SEQUENCE { version 0, AlgorithmIdentifier, privateKey OCTET STRING { CurvePrivateKey OCTET STRING } }
	BakaShrot_Der_InitWriter(@Writer)
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
	BakaShrot_Der_WriteInteger(@Writer, 0)
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
	BakaShrot_Der_WriteOid(@Writer, #BakaShrot_Oid_Ed25519)
	BakaShrot_Der_End(@Writer)
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_OctetString)
	BakaShrot_Der_WriteOctetString(@Writer, @Seed(0), 32)
	BakaShrot_Der_End(@Writer)
	BakaShrot_Der_End(@Writer)
	sodium_memzero(@Seed(0), 32)
	; The writer's buffer is wiped as it's freed, the result below.
	*Der = BakaShrot_Der_Finish(@Writer, @Size)
	If Not *Der
		ProcedureReturn ""
	EndIf
	Text = BakaShrot_Pem_Encode(*Der, Size\i, "PRIVATE KEY")
	sodium_memzero(*Der, Size\i)
	FreeMemory(*Der)
	ProcedureReturn Text
EndProcedure


; The Ed25519 private key of the first "PRIVATE KEY" PEM block in Text
; (PKCS#8 v1 or v2, not encrypted) into *PrivateKey (64 bytes, libsodium's).
; If the block has the public key too, it must match.
Procedure.i BakaShrot_X509_PrivateKeyFromPem(Text.s, *PrivateKey)
	Protected *Der, Size.Integer, Ok.i = #False, Version.q, Oid.String, HasParameters.i
	Protected Reader.BakaShrot_DerReader, Inner.BakaShrot_DerReader
	Protected Item.BakaShrot_DerElement, Field.BakaShrot_DerElement
	Protected Dim Seed.a(31)
	Protected Dim PublicKey.a(#BakaShrot_Ed25519_PublicKeySize - 1)
	Protected Dim Secret.a(#BakaShrot_Ed25519_PrivateKeySize - 1)

	*Der = BakaShrot_Pem_Decode(Text, "PRIVATE KEY", @Size)
	If Not *Der
		ProcedureReturn #False
	EndIf

	BakaShrot_Der_InitReader(@Reader, *Der, Size\i)
	If Not BakaShrot_Der_Expect(@Reader, #BakaShrot_Der_Sequence, @Item) Or Not BakaShrot_Der_AtEnd(@Reader)
		Goto KeyDone
	EndIf
	BakaShrot_Der_ReaderOf(@Reader, @Item)
	If Not BakaShrot_Der_Expect(@Reader, #BakaShrot_Der_Integer, @Item) Or Not BakaShrot_Der_GetInteger(@Item, @Version) Or Version < 0 Or Version > 1
		Goto KeyDone
	EndIf
	If Not BakaShrot_Der_Expect(@Reader, #BakaShrot_Der_Sequence, @Item) Or Not BakaShrot_X509_ReadAlgorithm(@Item, @Oid, @HasParameters)
		Goto KeyDone
	EndIf
	If Oid\s <> #BakaShrot_Oid_Ed25519 Or HasParameters
		Goto KeyDone
	EndIf
	If Not BakaShrot_Der_Expect(@Reader, #BakaShrot_Der_OctetString, @Item)
		Goto KeyDone
	EndIf
	BakaShrot_Der_ReaderOf(@Inner, @Item)
	If Not BakaShrot_Der_Expect(@Inner, #BakaShrot_Der_OctetString, @Field) Or Not BakaShrot_Der_AtEnd(@Inner) Or Field\ContentSize <> 32
		Goto KeyDone
	EndIf
	CopyMemory(Field\Content, @Seed(0), 32)
	crypto_sign_seed_keypair(@PublicKey(0), @Secret(0), @Seed(0))

	; attributes [0], skipped; publicKey [1] (v2), which must be this key's.
	If BakaShrot_Der_PeekTag(@Reader) = #BakaShrot_Der_ContextConstructed | 0
		BakaShrot_Der_Read(@Reader, @Item)
	EndIf
	If BakaShrot_Der_PeekTag(@Reader) = #BakaShrot_Der_Context | 1
		BakaShrot_Der_Read(@Reader, @Item)
		If Item\ContentSize <> #BakaShrot_Ed25519_PublicKeySize + 1 Or PeekA(Item\Content) <> 0 Or Not CompareMemory(Item\Content + 1, @PublicKey(0), #BakaShrot_Ed25519_PublicKeySize)
			Goto KeyDone
		EndIf
	EndIf
	If Not BakaShrot_Der_AtEnd(@Reader)
		Goto KeyDone
	EndIf

	CopyMemory(@Secret(0), *PrivateKey, #BakaShrot_Ed25519_PrivateKeySize)
	Ok = #True

	KeyDone:
	sodium_memzero(@Seed(0), 32)
	sodium_memzero(@Secret(0), #BakaShrot_Ed25519_PrivateKeySize)
	sodium_memzero(*Der, Size\i)
	FreeMemory(*Der)
	ProcedureReturn Ok
EndProcedure


;- Checking

; Whether *Cert's signature is *PublicKey's (Ed25519, 32 bytes).
Procedure.i BakaShrot_X509_CheckSignature(*Cert.BakaShrot_X509Certificate, *PublicKey)
	If Not *Cert\HasEd25519Signature
		ProcedureReturn #BakaShrot_X509_Error_Unsupported
	EndIf
	If Not DecodeData(*Cert\Der + *Cert\TbsOffset, *Cert\TbsSize, *PublicKey, @*Cert\Signature[0])
		ProcedureReturn #BakaShrot_X509_Error_BadSignature
	EndIf
	ProcedureReturn #BakaShrot_X509_Ok
EndProcedure


; Whether *Cert is valid at Now (seconds since 1970 UTC), its NotBefore
; and NotAfter included.
Procedure.i BakaShrot_X509_CheckValidity(*Cert.BakaShrot_X509Certificate, Now.q)
	If Now < *Cert\NotBefore
		ProcedureReturn #BakaShrot_X509_Error_NotYetValid
	EndIf
	If Now > *Cert\NotAfter
		ProcedureReturn #BakaShrot_X509_Error_Expired
	EndIf
	ProcedureReturn #BakaShrot_X509_Ok
EndProcedure


; Whether every critical extension of *Cert is handled: by this file
; (BasicConstraints, KeyUsage, the key ids), or by the caller, who lists
; their OIDs in Handled ("oid;oid"). RFC 5280: a certificate with a
; critical extension that isn't understood must be refused.
Procedure.i BakaShrot_X509_CheckCriticalExtensions(*Cert.BakaShrot_X509Certificate, Handled.s = "")
	Protected i.i, Oid.s

	Handled = ";" + RemoveString(Handled, " ") + ";"
	For i = 0 To *Cert\ExtensionCount - 1
		If *Cert\Extensions(i)\Critical
			Oid = *Cert\Extensions(i)\Oid
			If Oid <> #BakaShrot_Oid_BasicConstraints And Oid <> #BakaShrot_Oid_KeyUsage And Oid <> #BakaShrot_Oid_SubjectKeyId And Oid <> #BakaShrot_Oid_AuthorityKeyId
				If Not FindString(Handled, ";" + Oid + ";")
					ProcedureReturn #BakaShrot_X509_Error_UnknownCritical
				EndIf
			EndIf
		EndIf
	Next
	ProcedureReturn #BakaShrot_X509_Ok
EndProcedure


; Whether *Cert may sign certificates: a CA (BasicConstraints), and
; KeyCertSign if it has a KeyUsage.
Procedure.i BakaShrot_X509_CanIssue(*Cert.BakaShrot_X509Certificate)
	If Not *Cert\HasBasicConstraints Or Not *Cert\IsCa
		ProcedureReturn #False
	EndIf
	If *Cert\HasKeyUsage And (*Cert\KeyUsage & #BakaShrot_X509_KeyUsage_KeyCertSign) = 0
		ProcedureReturn #False
	EndIf
	ProcedureReturn #True
EndProcedure


; Whether *Cert was issued by *Issuer and holds at Now: *Cert names
; *Issuer's subject (as encoded) and key id (when both have one), *Issuer
; may issue (BakaShrot_X509_CanIssue()), *Cert's signature is *Issuer's
; key's, *Cert is valid at Now and has no critical extension unhandled (see
; BakaShrot_X509_CheckCriticalExtensions()).
; *Issuer itself isn't checked (its own validity, issuer): see
; BakaShrot_X509_VerifyChain().
Procedure.i BakaShrot_X509_CheckIssuedBy(*Cert.BakaShrot_X509Certificate, *Issuer.BakaShrot_X509Certificate, Now.q, Handled.s = "")
	Protected Result.i

	If Not *Cert Or Not *Issuer
		ProcedureReturn #BakaShrot_X509_Error_InvalidArgument
	EndIf
	If Not *Issuer\HasEd25519Key Or Not *Cert\HasEd25519Signature
		ProcedureReturn #BakaShrot_X509_Error_Unsupported
	EndIf
	If *Cert\IssuerSize <> *Issuer\SubjectSize Or Not CompareMemory(*Cert\Der + *Cert\IssuerOffset, *Issuer\Der + *Issuer\SubjectOffset, *Cert\IssuerSize)
		ProcedureReturn #BakaShrot_X509_Error_IssuerMismatch
	EndIf
	If *Cert\AuthorityKeyId <> "" And *Issuer\SubjectKeyId <> "" And *Cert\AuthorityKeyId <> *Issuer\SubjectKeyId
		ProcedureReturn #BakaShrot_X509_Error_IssuerMismatch
	EndIf
	If Not BakaShrot_X509_CanIssue(*Issuer)
		ProcedureReturn #BakaShrot_X509_Error_NotCa
	EndIf
	Result = BakaShrot_X509_CheckSignature(*Cert, @*Issuer\PublicKey[0])
	If Result = #BakaShrot_X509_Ok
		Result = BakaShrot_X509_CheckValidity(*Cert, Now)
	EndIf
	If Result = #BakaShrot_X509_Ok
		Result = BakaShrot_X509_CheckCriticalExtensions(*Cert, Handled)
	EndIf
	ProcedureReturn Result
EndProcedure


; Whether the chain holds at Now, up to *Root, which is trusted as it is
; (the CA a server or client is configured with). Chain() holds pointers to
; BakaShrot_X509Certificate: the leaf first, then each one's issuer, up to
; the one *Root issued (just the leaf when *Root issued it).
; Each link is checked with BakaShrot_X509_CheckIssuedBy(), *Root must be
; valid at Now and able to issue, and no CA may have more CAs under it
; than its PathLength.
Procedure.i BakaShrot_X509_VerifyChain(List Chain.i(), *Root.BakaShrot_X509Certificate, Now.q, Handled.s = "")
	Protected Count.i = ListSize(Chain()), i.i, Result.i
	Protected *Cert.BakaShrot_X509Certificate, *Issuer.BakaShrot_X509Certificate

	If Count < 1 Or Not *Root
		ProcedureReturn #BakaShrot_X509_Error_InvalidArgument
	EndIf
	If Not *Root\HasEd25519Key
		ProcedureReturn #BakaShrot_X509_Error_Unsupported
	EndIf
	Result = BakaShrot_X509_CheckValidity(*Root, Now)
	If Result <> #BakaShrot_X509_Ok
		ProcedureReturn Result
	EndIf
	If Not BakaShrot_X509_CanIssue(*Root)
		ProcedureReturn #BakaShrot_X509_Error_NotCa
	EndIf
	Result = BakaShrot_X509_CheckCriticalExtensions(*Root, Handled)
	If Result <> #BakaShrot_X509_Ok
		ProcedureReturn Result
	EndIf

	For i = 0 To Count - 1
		SelectElement(Chain(), i)
		*Cert = Chain()
		If i < Count - 1
			SelectElement(Chain(), i + 1)
			*Issuer = Chain()
		Else
			*Issuer = *Root
		EndIf
		If Not *Cert Or Not *Issuer
			ProcedureReturn #BakaShrot_X509_Error_InvalidArgument
		EndIf
		Result = BakaShrot_X509_CheckIssuedBy(*Cert, *Issuer, Now, Handled)
		If Result <> #BakaShrot_X509_Ok
			ProcedureReturn Result
		EndIf
		; The CAs under *Issuer: every certificate between it and the leaf.
		If *Issuer\PathLength >= 0 And i > *Issuer\PathLength
			ProcedureReturn #BakaShrot_X509_Error_PathTooLong
		EndIf
	Next
	ProcedureReturn #BakaShrot_X509_Ok
EndProcedure


;- Issuing

; Defaults: no serial (random), no limit under a CA, nothing else.
Procedure BakaShrot_X509_InitTemplate(*Template.BakaShrot_X509Template)
	*Template\Serial         = ""
	*Template\Subject\Count  = 0
	*Template\NotBefore      = 0
	*Template\NotAfter       = 0
	*Template\IsCa           = #False
	*Template\PathLength     = -1
	*Template\KeyUsage       = 0
	*Template\ExtensionCount = 0
	FillMemory(@*Template\PublicKey[0], #BakaShrot_Ed25519_PublicKeySize, 0)
EndProcedure


; Frees what *Template's extensions hold, and forgets them.
Procedure BakaShrot_X509_ClearTemplate(*Template.BakaShrot_X509Template)
	Protected i.i

	For i = 0 To *Template\ExtensionCount - 1
		If *Template\Extensions(i)\Value
			FreeMemory(*Template\Extensions(i)\Value)
			*Template\Extensions(i)\Value = 0
		EndIf
	Next
	*Template\ExtensionCount = 0
EndProcedure


; Adds an extension to *Template: Oid, and Size bytes of DER at *Value
; (one element, its value as the extension's definition says), copied.
; Critical: readers that don't know it must refuse the certificate.
; Returns #False if Oid isn't valid, is one of those BakaShrot_X509_Issue()
; writes itself or already in *Template, or *Value isn't one DER element.
Procedure.i BakaShrot_X509_AddExtension(*Template.BakaShrot_X509Template, Oid.s, *Value, Size.i, Critical.i = #False)
	Protected Reader.BakaShrot_DerReader, Item.BakaShrot_DerElement, i.i, Index.i

	If Not BakaShrot_Der_IsValidOid(Oid) Or Not *Value Or Size < 2
		ProcedureReturn #False
	EndIf
	If Oid = #BakaShrot_Oid_BasicConstraints Or Oid = #BakaShrot_Oid_KeyUsage Or Oid = #BakaShrot_Oid_SubjectKeyId Or Oid = #BakaShrot_Oid_AuthorityKeyId
		ProcedureReturn #False
	EndIf
	For i = 0 To *Template\ExtensionCount - 1
		If *Template\Extensions(i)\Oid = Oid
			ProcedureReturn #False
		EndIf
	Next
	BakaShrot_Der_InitReader(@Reader, *Value, Size)
	If Not BakaShrot_Der_Read(@Reader, @Item) Or Not BakaShrot_Der_AtEnd(@Reader)
		ProcedureReturn #False
	EndIf

	Index = *Template\ExtensionCount
	If Index > ArraySize(*Template\Extensions())
		ReDim *Template\Extensions(Index * 2 + 3)
	EndIf
	*Template\Extensions(Index)\Value = AllocateMemory(Size)
	If Not *Template\Extensions(Index)\Value
		ProcedureReturn #False
	EndIf
	CopyMemory(*Value, *Template\Extensions(Index)\Value, Size)
	*Template\Extensions(Index)\Oid       = Oid
	*Template\Extensions(Index)\Critical  = Bool(Critical)
	*Template\Extensions(Index)\ValueSize = Size
	*Template\ExtensionCount + 1
	ProcedureReturn #True
EndProcedure


; Adds an extension holding Text, as a UTF8String. See BakaShrot_X509_AddExtension().
Procedure.i BakaShrot_X509_AddTextExtension(*Template.BakaShrot_X509Template, Oid.s, Text.s, Critical.i = #False)
	Protected Writer.BakaShrot_DerWriter, *Der, Size.Integer, Result.i

	BakaShrot_Der_InitWriter(@Writer)
	BakaShrot_Der_WriteText(@Writer, #BakaShrot_Der_Utf8String, Text)
	*Der = BakaShrot_Der_Finish(@Writer, @Size)
	If *Der
		Result = BakaShrot_X509_AddExtension(*Template, Oid, *Der, Size\i, Critical)
		FreeMemory(*Der)
	EndIf
	ProcedureReturn Result
EndProcedure


; Adds an extension holding Value, as an INTEGER. See BakaShrot_X509_AddExtension().
Procedure.i BakaShrot_X509_AddIntegerExtension(*Template.BakaShrot_X509Template, Oid.s, Value.q, Critical.i = #False)
	Protected Writer.BakaShrot_DerWriter, *Der, Size.Integer, Result.i

	BakaShrot_Der_InitWriter(@Writer)
	BakaShrot_Der_WriteInteger(@Writer, Value)
	*Der = BakaShrot_Der_Finish(@Writer, @Size)
	If *Der
		Result = BakaShrot_X509_AddExtension(*Template, Oid, *Der, Size\i, Critical)
		FreeMemory(*Der)
	EndIf
	ProcedureReturn Result
EndProcedure


; Writes *Name, an RDN per attribute. #False if an attribute can't be
; written as its type wants (C: 2 letters in a PrintableString).
Procedure.i BakaShrot_X509_WriteName(*Writer.BakaShrot_DerWriter, *Name.BakaShrot_X509Name)
	Protected i.i, Tag.i, Oid.s, Value.s

	BakaShrot_Der_Begin(*Writer, #BakaShrot_Der_Sequence)
	For i = 0 To *Name\Count - 1
		Oid   = *Name\Attributes(i)\Oid
		Value = *Name\Attributes(i)\Value
		Tag   = *Name\Attributes(i)\StringTag
		If Tag = 0
			If Oid = #BakaShrot_Oid_Country
				Tag = #BakaShrot_Der_PrintableString
			ElseIf Oid = #BakaShrot_Oid_EmailAddress Or Oid = #BakaShrot_Oid_DomainComponent
				Tag = #BakaShrot_Der_Ia5String
			Else
				Tag = #BakaShrot_Der_Utf8String
			EndIf
		EndIf
		If Value = "" Or (Oid = #BakaShrot_Oid_Country And Len(Value) <> 2)
			*Writer\Failed = #True
		EndIf
		BakaShrot_Der_Begin(*Writer, #BakaShrot_Der_Set)
		BakaShrot_Der_Begin(*Writer, #BakaShrot_Der_Sequence)
		BakaShrot_Der_WriteOid(*Writer, Oid)
		BakaShrot_Der_WriteText(*Writer, Tag, Value)
		BakaShrot_Der_End(*Writer)
		BakaShrot_Der_End(*Writer)
	Next
	BakaShrot_Der_End(*Writer)
	ProcedureReturn Bool(Not *Writer\Failed)
EndProcedure


; Writes an extension: SEQUENCE { OID, critical if so, OCTET STRING { Size bytes at *Value } }.
Procedure BakaShrot_X509_WriteExtension(*Writer.BakaShrot_DerWriter, Oid.s, Critical.i, *Value, Size.i)
	BakaShrot_Der_Begin(*Writer, #BakaShrot_Der_Sequence)
	BakaShrot_Der_WriteOid(*Writer, Oid)
	If Critical
		BakaShrot_Der_WriteBoolean(*Writer, #True)
	EndIf
	BakaShrot_Der_WriteOctetString(*Writer, *Value, Size)
	BakaShrot_Der_End(*Writer)
EndProcedure


; Issues a certificate for *Template, signed with *IssuerPrivateKey (64
; bytes, libsodium's): by *Issuer, which must be that key's and able to
; issue (BakaShrot_X509_CanIssue()), or self-signed when *Issuer is 0, the
; key then the template's own. Writes BasicConstraints (critical), KeyUsage
; (critical, if any), the subject's key id and its issuer's, then the
; template's extensions.
; Returns the DER in a new buffer (free it with FreeMemory), its size in
; *OutSize\i, or 0 with *Error\l set, if given.
Procedure.i BakaShrot_X509_Issue(*Template.BakaShrot_X509Template, *Issuer.BakaShrot_X509Certificate, *IssuerPrivateKey, *OutSize.Integer, *Error.Long = 0)
	Protected Code.i = #BakaShrot_X509_Error_InvalidArgument, i.i
	Protected Writer.BakaShrot_DerWriter, *Tbs, TbsSize.Integer, *Der, DerSize.Integer
	Protected SerialSize.i, AuthorityKeyIdSize.i
	Protected Dim SignerKey.a(#BakaShrot_Ed25519_PublicKeySize - 1)
	Protected Dim Serial.a(#BakaShrot_X509_MaxSerialSize - 1)
	Protected Dim SubjectKeyId.a(#BakaShrot_X509_KeyIdSize - 1)
	Protected Dim AuthorityKeyId.a(#BakaShrot_X509_MaxSerialSize - 1)
	Protected Dim Signature.a(#BakaShrot_Ed25519_SignatureSize - 1)

	BakaShrot_Der_InitWriter(@Writer)
	If Not *Template Or Not *IssuerPrivateKey Or Not *OutSize
		Goto IssueFailed
	EndIf
	If *Template\NotAfter < *Template\NotBefore Or (*Template\PathLength >= 0 And Not *Template\IsCa) Or *Template\PathLength > 255
		Goto IssueFailed
	EndIf

	; The signer's key, which must be the issuer's (or the subject's).
	GetPublicKeyFromPrivateKey(*IssuerPrivateKey, @SignerKey(0))
	BakaShrot_X509_KeyId(@*Template\PublicKey[0], @SubjectKeyId(0))
	If *Issuer
		If Not *Issuer\HasEd25519Key
			Code = #BakaShrot_X509_Error_Unsupported
			Goto IssueFailed
		EndIf
		If Not CompareMemory(@SignerKey(0), @*Issuer\PublicKey[0], #BakaShrot_Ed25519_PublicKeySize)
			Code = #BakaShrot_X509_Error_KeyMismatch
			Goto IssueFailed
		EndIf
		If Not BakaShrot_X509_CanIssue(*Issuer)
			Code = #BakaShrot_X509_Error_NotCa
			Goto IssueFailed
		EndIf
		If *Issuer\SubjectKeyId <> ""
			AuthorityKeyIdSize = BakaShrot_X509_FromHex(*Issuer\SubjectKeyId, @AuthorityKeyId(0), #BakaShrot_X509_MaxSerialSize)
		EndIf
	Else
		If Not CompareMemory(@SignerKey(0), @*Template\PublicKey[0], #BakaShrot_Ed25519_PublicKeySize)
			Code = #BakaShrot_X509_Error_KeyMismatch
			Goto IssueFailed
		EndIf
		CopyMemory(@SubjectKeyId(0), @AuthorityKeyId(0), #BakaShrot_X509_KeyIdSize)
		AuthorityKeyIdSize = #BakaShrot_X509_KeyIdSize
	EndIf

	; A positive serial number: random, or the template's.
	If *Template\Serial = ""
		randombytes_buf(@Serial(0), #BakaShrot_X509_SerialSize)
		Serial(0) = (Serial(0) & $7F) | $40
		SerialSize = #BakaShrot_X509_SerialSize
	Else
		SerialSize = BakaShrot_X509_FromHex(*Template\Serial, @Serial(0), 20)
		If SerialSize < 1
			Goto IssueFailed
		EndIf
	EndIf

	; tbsCertificate
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_ContextConstructed | 0)
	BakaShrot_Der_WriteInteger(@Writer, 2)
	BakaShrot_Der_End(@Writer)
	BakaShrot_Der_WriteUnsigned(@Writer, @Serial(0), SerialSize)
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
	BakaShrot_Der_WriteOid(@Writer, #BakaShrot_Oid_Ed25519)
	BakaShrot_Der_End(@Writer)
	If *Issuer
		BakaShrot_Der_WriteRaw(@Writer, *Issuer\Der + *Issuer\SubjectOffset, *Issuer\SubjectSize)
	Else
		BakaShrot_X509_WriteName(@Writer, @*Template\Subject)
	EndIf
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
	BakaShrot_Der_WriteTime(@Writer, *Template\NotBefore)
	BakaShrot_Der_WriteTime(@Writer, *Template\NotAfter)
	BakaShrot_Der_End(@Writer)
	BakaShrot_X509_WriteName(@Writer, @*Template\Subject)
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
	BakaShrot_Der_WriteOid(@Writer, #BakaShrot_Oid_Ed25519)
	BakaShrot_Der_End(@Writer)
	BakaShrot_Der_WriteBitStringBytes(@Writer, @*Template\PublicKey[0], #BakaShrot_Ed25519_PublicKeySize)
	BakaShrot_Der_End(@Writer)

	; extensions
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_ContextConstructed | 3)
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)

	; BasicConstraints, critical: SEQUENCE { cA TRUE if so, pathLen }
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
	BakaShrot_Der_WriteOid(@Writer, #BakaShrot_Oid_BasicConstraints)
	BakaShrot_Der_WriteBoolean(@Writer, #True)
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_OctetString)
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
	If *Template\IsCa
		BakaShrot_Der_WriteBoolean(@Writer, #True)
		If *Template\PathLength >= 0
			BakaShrot_Der_WriteInteger(@Writer, *Template\PathLength)
		EndIf
	EndIf
	BakaShrot_Der_End(@Writer)
	BakaShrot_Der_End(@Writer)
	BakaShrot_Der_End(@Writer)

	; KeyUsage, critical
	If *Template\KeyUsage
		BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
		BakaShrot_Der_WriteOid(@Writer, #BakaShrot_Oid_KeyUsage)
		BakaShrot_Der_WriteBoolean(@Writer, #True)
		BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_OctetString)
		BakaShrot_Der_WriteBitFlags(@Writer, *Template\KeyUsage)
		BakaShrot_Der_End(@Writer)
		BakaShrot_Der_End(@Writer)
	EndIf

	; SubjectKeyIdentifier
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
	BakaShrot_Der_WriteOid(@Writer, #BakaShrot_Oid_SubjectKeyId)
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_OctetString)
	BakaShrot_Der_WriteOctetString(@Writer, @SubjectKeyId(0), #BakaShrot_X509_KeyIdSize)
	BakaShrot_Der_End(@Writer)
	BakaShrot_Der_End(@Writer)

	; AuthorityKeyIdentifier: SEQUENCE { [0] keyIdentifier }
	If AuthorityKeyIdSize > 0
		BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
		BakaShrot_Der_WriteOid(@Writer, #BakaShrot_Oid_AuthorityKeyId)
		BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_OctetString)
		BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
		BakaShrot_Der_WriteElement(@Writer, #BakaShrot_Der_Context | 0, @AuthorityKeyId(0), AuthorityKeyIdSize)
		BakaShrot_Der_End(@Writer)
		BakaShrot_Der_End(@Writer)
		BakaShrot_Der_End(@Writer)
	EndIf

	For i = 0 To *Template\ExtensionCount - 1
		BakaShrot_X509_WriteExtension(@Writer, *Template\Extensions(i)\Oid, *Template\Extensions(i)\Critical, *Template\Extensions(i)\Value, *Template\Extensions(i)\ValueSize)
	Next

	BakaShrot_Der_End(@Writer)
	BakaShrot_Der_End(@Writer)
	BakaShrot_Der_End(@Writer)

	*Tbs = BakaShrot_Der_Finish(@Writer, @TbsSize)
	If Not *Tbs
		Goto IssueFailed
	EndIf

	; Signed, then Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
	If Not EncodeData(*Tbs, TbsSize\i, *IssuerPrivateKey, @Signature(0))
		FreeMemory(*Tbs)
		Code = #BakaShrot_X509_Error_Internal
		Goto IssueFailed
	EndIf
	BakaShrot_Der_InitWriter(@Writer)
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
	BakaShrot_Der_WriteRaw(@Writer, *Tbs, TbsSize\i)
	BakaShrot_Der_Begin(@Writer, #BakaShrot_Der_Sequence)
	BakaShrot_Der_WriteOid(@Writer, #BakaShrot_Oid_Ed25519)
	BakaShrot_Der_End(@Writer)
	BakaShrot_Der_WriteBitStringBytes(@Writer, @Signature(0), #BakaShrot_Ed25519_SignatureSize)
	BakaShrot_Der_End(@Writer)
	FreeMemory(*Tbs)
	*Der = BakaShrot_Der_Finish(@Writer, @DerSize)
	If Not *Der
		Goto IssueFailed
	EndIf

	*OutSize\i = DerSize\i
	If *Error
		*Error\l = #BakaShrot_X509_Ok
	EndIf
	ProcedureReturn *Der

	IssueFailed:
	BakaShrot_Der_FreeWriter(@Writer)
	If *Error
		*Error\l = Code
	EndIf
	ProcedureReturn 0
EndProcedure
