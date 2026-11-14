;{- Code Header
; ==- Basic Info -================================
;     Name: BakaShrot_ErrorCodes.pbi
;  Version: 0.0.1
;   Author: Herwin Bozet (NibblePoker)
;
; ==- Compatibility -=============================
;  Tested compiler versions:
;    * PureBasic 5.73 LTS (Windows x64)
;
; ==- Links -=====================================
;  GitHub: https://github.com/aziascreations/BakaShrot
;}

; ============================================================================
; BakaShrot error codes
;
; What BakaShrot_GetLastError() returns after a failed call of the client DLL
; (bakashrot.dll), and the code a server sends with each refusal (protocol 7,
; Source/crates/bakashrot-proto/src/error.rs, the same numbers as protocol 6).
; The Python client has them in bakashrot.ErrorCode. Shipped next to
; BakaShrot_Client_Prototypes.pbi, which includes it.
;
;   0       no error (the last call succeeded)
;   1-99    refused by the server: the connection is still open, see
;           BakaShrot_GetRefusalReason() for the details
;   100+    the client's own: the connection, the arguments, the files
;
; What to do about each:
;   reconnect, then retry:   NotConnected, ConnectFailed, ConnectionLost,
;                            ProtocolError (the connection is closed)
;   retry later:             NotReady (an attachment still on its way),
;                            ServerError (the server's storage failed)
;   fix the certificates or
;   the server's config:     AuthRejected, ServerNotVerified, NotAllowed,
;                            UnknownName, VersionMismatch
;   fix the call:            InvalidArgument, InvalidRequest, TooBig,
;                            QueryFailed, FileError
;   gone, or not yet there:  NotFound
;   sent again by itself:    DataMismatch, AttachmentMismatch
;
; A push whose answer was lost (ConnectionLost) may still have been stored:
; pushing it again can store it twice, under the next id. Delivery is at
; least once; check the latest message first if a duplicate matters.
; ============================================================================

; --- Refused by the server (RequestRefused's code) ----------------------------

; Not allowed to this client: its roles' permissions (or, when connecting,
; none of its roles is the server's).
#BakaShrot_Refused_NotAllowed     = 1
; A topic or node this server doesn't know.
#BakaShrot_Refused_UnknownName    = 2
; No such message or attachment.
#BakaShrot_Refused_NotFound       = 3
; The attachment isn't on this server yet (still being replicated).
#BakaShrot_Refused_NotReady       = 4
; A message, attachment or query result over a limit, or an attachment
; bigger than this server keeps.
#BakaShrot_Refused_TooBig         = 5
; Protocol 6's (a push without a topic): never sent any more.
#BakaShrot_Refused_NoDefaultTopic = 6
; A request that doesn't fit: an attachment's parts not matching its size,
; a part that doesn't exist...
#BakaShrot_Refused_InvalidRequest = 7
; An uploaded attachment that doesn't match its SHA-256: dropped.
#BakaShrot_Refused_DataMismatch   = 8
; The SQL of a query failed (its error in the reason).
#BakaShrot_Refused_QueryFailed    = 9
; The server couldn't store or read something: its database failed.
#BakaShrot_Refused_ServerError    = 10

; The highest a refusal can have, anything above is the client's own.
#BakaShrot_Refused_Max = 99

; --- The client's own (BakaShrot_GetLastError()) --------------------------------

#BakaShrot_Error_None = 0
; Not connected: never, or the connection was closed or lost before.
#BakaShrot_Error_NotConnected       = 100
; The server couldn't be reached at that host and port.
#BakaShrot_Error_ConnectFailed      = 101
; The server refused this client's certificate: another CA's, revoked,
; expired.
#BakaShrot_Error_AuthRejected       = 102
; This client refused the server's certificate: not the CA's, or revoked.
#BakaShrot_Error_ServerNotVerified  = 103
; The connection broke during a request (it's closed now). A push may
; still have been stored.
#BakaShrot_Error_ConnectionLost     = 104
; The server answered something unexpected or malformed: the connection is
; closed.
#BakaShrot_Error_ProtocolError      = 105
; A bad argument: a topic or node that isn't a name, a null pointer, a
; message over the limit, a certificate missing before connecting.
#BakaShrot_Error_InvalidArgument    = 106
; A file couldn't be opened, read or written.
#BakaShrot_Error_FileError          = 107
; A downloaded attachment doesn't match its SHA-256.
#BakaShrot_Error_AttachmentMismatch = 108
; Already connected: disconnect first.
#BakaShrot_Error_AlreadyConnected   = 109
; A failure inside the DLL.
#BakaShrot_Error_Internal           = 110
; The server speaks another version of the protocol: update one or the
; other.
#BakaShrot_Error_VersionMismatch    = 111


; The name of an error code, as the constants have it ("NotFound"), or
; "Error <code>" for an unknown one.
Procedure.s BakaShrot_ErrorName(Code.l)
	Select Code
		Case #BakaShrot_Error_None : ProcedureReturn "None"
		Case #BakaShrot_Refused_NotAllowed : ProcedureReturn "NotAllowed"
		Case #BakaShrot_Refused_UnknownName : ProcedureReturn "UnknownName"
		Case #BakaShrot_Refused_NotFound : ProcedureReturn "NotFound"
		Case #BakaShrot_Refused_NotReady : ProcedureReturn "NotReady"
		Case #BakaShrot_Refused_TooBig : ProcedureReturn "TooBig"
		Case #BakaShrot_Refused_NoDefaultTopic : ProcedureReturn "NoDefaultTopic"
		Case #BakaShrot_Refused_InvalidRequest : ProcedureReturn "InvalidRequest"
		Case #BakaShrot_Refused_DataMismatch : ProcedureReturn "DataMismatch"
		Case #BakaShrot_Refused_QueryFailed : ProcedureReturn "QueryFailed"
		Case #BakaShrot_Refused_ServerError : ProcedureReturn "ServerError"
		Case #BakaShrot_Error_NotConnected : ProcedureReturn "NotConnected"
		Case #BakaShrot_Error_ConnectFailed : ProcedureReturn "ConnectFailed"
		Case #BakaShrot_Error_AuthRejected : ProcedureReturn "AuthRejected"
		Case #BakaShrot_Error_ServerNotVerified : ProcedureReturn "ServerNotVerified"
		Case #BakaShrot_Error_ConnectionLost : ProcedureReturn "ConnectionLost"
		Case #BakaShrot_Error_ProtocolError : ProcedureReturn "ProtocolError"
		Case #BakaShrot_Error_InvalidArgument : ProcedureReturn "InvalidArgument"
		Case #BakaShrot_Error_FileError : ProcedureReturn "FileError"
		Case #BakaShrot_Error_AttachmentMismatch : ProcedureReturn "AttachmentMismatch"
		Case #BakaShrot_Error_AlreadyConnected : ProcedureReturn "AlreadyConnected"
		Case #BakaShrot_Error_Internal : ProcedureReturn "Internal"
		Case #BakaShrot_Error_VersionMismatch : ProcedureReturn "VersionMismatch"
	EndSelect
	ProcedureReturn "Error " + Str(Code)
EndProcedure

; #True for a code a server sends with a refusal (1-99).
Procedure.i BakaShrot_IsRefusalCode(Code.l)
	ProcedureReturn Bool(Code >= 1 And Code <= #BakaShrot_Refused_Max)
EndProcedure
