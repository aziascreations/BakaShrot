;{- Code Header
; ==- Basic Info -================================
;     Name: BakaShrot_ErrorCodes.pbi
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
; BakaShrot error codes
;
; What BakaShrot_GetLastError() returns after a failed call of the client DLL
; (BakaShrot_Client.pbi), and the code a server sends with each refusal
; (RequestRefused, protocol 6). The Python client has the same numbers in
; bakashrot.ErrorCode. Shipped next to BakaShrot_Client_Prototypes.pbi,
; which includes it.
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
;   fix the config:          AuthRejected, ServerNotVerified, NotAllowed,
;                            UnknownName, NoDefaultTopic
;   fix the call:            InvalidArgument, InvalidRequest, TooBig,
;                            QueryFailed, FileError
;   gone, or not yet there:  NotFound
;   sent again by itself:    DataMismatch (an upload that doesn't match its
;                            SHA-256: upload it again), AttachmentMismatch (a
;                            downloaded one that doesn't: read it again)
;
; A push whose answer was lost (ConnectionLost) may still have been stored:
; pushing it again can store it twice, under the next id. Delivery is at
; least once; check the latest message first if a duplicate matters.
; ============================================================================

; --- Refused by the server (RequestRefused's Code) ----------------------------

; Not allowed to this client: AllowRead / AllowWrite / AllowQuery, its
; PushTopics / ReadTopics, or a request only peers may make.
#BakaShrot_Refused_NotAllowed     = 1
; A topic or node name (or id) this server doesn't know.
#BakaShrot_Refused_UnknownName    = 2
; No such message, attachment or upload.
#BakaShrot_Refused_NotFound       = 3
; The attachment isn't on this server yet (still being replicated).
#BakaShrot_Refused_NotReady       = 4
; A message, attachment or query result over a limit, or an attachment
; bigger than this server keeps.
#BakaShrot_Refused_TooBig         = 5
; A push without a topic, and no DefaultTopic for this client.
#BakaShrot_Refused_NoDefaultTopic = 6
; A request that doesn't fit: parts out of order, an upload for another
; topic or already attached, a part that doesn't exist...
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
; The server closed the connection during the handshake: wrong
; ServerPublicKey, a key or node it doesn't allow, or another protocol
; version (its log says which).
#BakaShrot_Error_AuthRejected       = 102
; The server couldn't prove it holds ServerPublicKey's private key.
#BakaShrot_Error_ServerNotVerified  = 103
; The connection broke during a request (it's closed now). A push may
; still have been stored.
#BakaShrot_Error_ConnectionLost     = 104
; The server answered something unexpected or malformed: the connection is
; closed.
#BakaShrot_Error_ProtocolError      = 105
; A bad argument: a ref that's neither a name nor an id, a null pointer, a
; message or attachment over the limits, a setting missing before connecting.
#BakaShrot_Error_InvalidArgument    = 106
; A file couldn't be opened, read or written.
#BakaShrot_Error_FileError          = 107
; A downloaded attachment doesn't match its SHA-256.
#BakaShrot_Error_AttachmentMismatch = 108
; Already connected: disconnect first.
#BakaShrot_Error_AlreadyConnected   = 109
; Out of memory, or another failure inside the client.
#BakaShrot_Error_Internal           = 110


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
	EndSelect
	ProcedureReturn "Error " + Str(Code)
EndProcedure

; #True for a code a server sends with a refusal (1-99).
Procedure.i BakaShrot_IsRefusalCode(Code.l)
	ProcedureReturn Bool(Code >= 1 And Code <= #BakaShrot_Refused_Max)
EndProcedure
