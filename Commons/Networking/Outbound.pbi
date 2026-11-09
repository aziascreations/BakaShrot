; ============================================================================
; BakaShrot Outbound connections
;
; The client side of a connection: connecting to a server and running the
; handshake from Connections.pbi as the one being authenticated, then
; sending requests (BakaShrot_Outbound_Send()) and waiting for the answers
; (BakaShrot_Outbound_WaitPacket()), encrypted for this connection.
; Used by the client DLL, and by the server to link to its peers.
;
; A BakaShrot_Outbound must only be used by one thread at a time.
; ============================================================================

XIncludeFile "Connections.pbi"
XIncludeFile "SocketWait.pbi"


#BakaShrot_Outbound_ReceiveBufferSize = 65536

; How long the server gets to send each packet, handshake or answer.
#BakaShrot_Outbound_Timeout = 10000


; Who to authenticate as.
Structure BakaShrot_OutboundIdentity
	; The node it writes as, a name or an id in digits (Names.pbi), resolved
	; by the server, which must allow it for this key.
	Node.s

	; Ed25519 public key (Base64), sent in the Hello.
	PublicKey.s

	; Ed25519 private key, #BakaShrot_Ed25519_PrivateKeySize bytes, used to
	; answer the challenge. Must stay valid while connecting.
	*PrivateKey
EndStructure


Structure BakaShrot_Outbound
	; 0 when not connected.
	ConnectionId.i
	Inbox.BakaShrot_Inbox
	Metadata.BakaShrot_ConnectionMetadata

	; Optional, set by the owner: while it points to a non-zero value, waits
	; for the server's packets give up right away, as if they timed out.
	; Lets a server stop its peer links without waiting out their timeouts.
	*StopRequested.Integer

	; Why BakaShrot_Outbound_Connect() failed, a #BakaShrot_Error_* of
	; Client/BakaShrot_ErrorCodes.pbi, 0 once it succeeded.
	LastError.l
EndStructure


; Closes *Outbound's connection, if any, and sets its status to Status.
Procedure BakaShrot_Outbound_Close(*Outbound.BakaShrot_Outbound, Status.i)
	If *Outbound\ConnectionId
		CloseNetworkConnection(*Outbound\ConnectionId)
	EndIf
	*Outbound\ConnectionId = 0
	BakaShrot_Inbox_Clear(@*Outbound\Inbox)
	BakaShrot_ClearConnectionMetadata(@*Outbound\Metadata)
	*Outbound\Metadata\Status = Status
EndProcedure


; Sends *Packet to the server, encrypted for this connection.
; Returns #False if it couldn't be sent: close the connection then.
Procedure.i BakaShrot_Outbound_Send(*Outbound.BakaShrot_Outbound, *Packet, PacketSize.i)
	If Not *Outbound\ConnectionId
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_SendPacket(*Outbound\ConnectionId, *Packet, PacketSize, @*Outbound\Metadata\Cipher)
EndProcedure


; Waits for the next packet from the server, for up to TimeoutMs, decrypted
; once the connection's cipher is set up.
; Returns the packet (free it with FreeMemory) with its size in *OutSize\i,
; or 0 if the server disconnected, sent an invalid frame, one that doesn't
; decrypt or too much data, timed out, or the owner asked to stop (see
; *StopRequested).
Procedure.i BakaShrot_Outbound_WaitPacket(*Outbound.BakaShrot_Outbound, *OutSize.Integer, TimeoutMs.i)
	Protected *Packet = 0, *Buffer, Result.i, Received.i, StartTime.i, WaitMs.i

	*Buffer = AllocateMemory(#BakaShrot_Outbound_ReceiveBufferSize)
	If Not *Buffer
		ProcedureReturn 0
	EndIf

	StartTime = ElapsedMilliseconds()

	Repeat
		Result = BakaShrot_Inbox_TakePacket(@*Outbound\Inbox, @*Packet, *OutSize)
		If Result = #BakaShrot_Inbox_Packet Or Result = #BakaShrot_Inbox_Invalid
			Break
		EndIf

		If ElapsedMilliseconds() - StartTime > TimeoutMs
			Break
		EndIf

		If *Outbound\StopRequested
			If *Outbound\StopRequested\i
				Break
			EndIf
		EndIf

		Select NetworkClientEvent(*Outbound\ConnectionId)

			Case #PB_NetworkEvent_Data
				Received = ReceiveNetworkData(*Outbound\ConnectionId, *Buffer, #BakaShrot_Outbound_ReceiveBufferSize)
				If Received <= 0
					Break
				EndIf
				If Not BakaShrot_Inbox_Append(@*Outbound\Inbox, *Buffer, Received)
					Break
				EndIf

			Case #PB_NetworkEvent_Disconnect
				Break

			Default
				; Sleeps until the server sends something, waking up at least
				; every 50 ms to check the timeout and *StopRequested.
				WaitMs = TimeoutMs - (ElapsedMilliseconds() - StartTime)
				If WaitMs > 50
					WaitMs = 50
				EndIf
				If WaitMs < 1
					WaitMs = 1
				EndIf
				BakaShrot_WaitSocket(ConnectionID(*Outbound\ConnectionId), WaitMs)

		EndSelect
	ForEver

	FreeMemory(*Buffer)
	If *Packet
		*Packet = BakaShrot_OpenFrame(@*Outbound\Metadata\Cipher, *Packet, *OutSize\i, *OutSize)
	EndIf
	ProcedureReturn *Packet
EndProcedure


; Connects to Host:Port and authenticates as *Identity, to the server whose
; Ed25519 public key is *ServerPublicKey (#BakaShrot_Ed25519_PublicKeySize
; bytes): sends the Hello sealed for that key, checks the server's
; signature in the challenge it gets back, sets up the connection's cipher,
; signs the handshake, then waits for the server to accept it.
; Fails if already connected, if *Identity's public key isn't valid Base64,
; if the server can't prove it holds *ServerPublicKey's private key, or if
; anything in the handshake is out of order or unexpected, in which case
; the connection is closed.
Procedure.i BakaShrot_Outbound_Connect(*Outbound.BakaShrot_Outbound, Host.s, Port.i, *Identity.BakaShrot_OutboundIdentity, *ServerPublicKey)
	Protected *Packet, PacketSize.Integer, *View.MsgPackData, Sent.i, *Sealed, SealedSize.Integer
	Protected Hello.BakaShrot_AuthHello
	Protected *Request.BakaShrot_ChallengeRequest
	Protected Response.BakaShrot_ChallengeResponse
	Protected *Accepted.BakaShrot_AuthAccepted
	Protected Proof.BakaShrot_ChallengeProof
	Protected KeyPair.BakaShrot_SessionKeyPair
	Protected ChallengeDecoded.i, ServerProved.i

	*Outbound\LastError = #BakaShrot_Error_None
	If *Outbound\ConnectionId
		*Outbound\LastError = #BakaShrot_Error_AlreadyConnected
		ProcedureReturn #False
	EndIf

	If Not *ServerPublicKey Or Port < 1 Or Port > 65535
		*Outbound\LastError = #BakaShrot_Error_InvalidArgument
		ProcedureReturn #False
	EndIf

	; Only needed before PureBasic 6.00.
	CompilerIf #PB_Compiler_Version < 600
		If Not InitNetwork()
			*Outbound\LastError = #BakaShrot_Error_Internal
			ProcedureReturn #False
		EndIf
	CompilerEndIf

	If Not InitCryptography()
		*Outbound\LastError = #BakaShrot_Error_Internal
		ProcedureReturn #False
	EndIf

	BakaShrot_ClearConnectionMetadata(@*Outbound\Metadata)
	ClearStructure(@*Outbound\Metadata, BakaShrot_ConnectionMetadata)
	If Not DecodeKeyFromString(*Identity\PublicKey, @*Outbound\Metadata\PublicKey[0], #BakaShrot_Ed25519_PublicKeySize)
		*Outbound\Metadata\Status = #BakaShrot_ConnectionStatus_Aborted
		*Outbound\LastError = #BakaShrot_Error_InvalidArgument
		ProcedureReturn #False
	EndIf
	CopyMemory(*ServerPublicKey, @*Outbound\Metadata\ServerPublicKey[0], #BakaShrot_Ed25519_PublicKeySize)

	*Outbound\ConnectionId = OpenNetworkConnection(Host, Port, #PB_Network_TCP | #PB_Network_IPv4)
	If Not *Outbound\ConnectionId
		*Outbound\Metadata\Status = #BakaShrot_ConnectionStatus_Aborted
		*Outbound\LastError = #BakaShrot_Error_ConnectFailed
		ProcedureReturn #False
	EndIf
	*Outbound\Metadata\Status = #BakaShrot_ConnectionStatus_New

	; This connection's key pair, the public half goes in the Hello.
	BakaShrot_Session_NewKeyPair(@KeyPair)
	CopyMemory(@KeyPair\PublicKey[0], @*Outbound\Metadata\ClientSessionKey[0], #BakaShrot_SessionKeySize)


	; 1. Hello, sealed for the server
	Hello\ClientNode      = *Identity\Node
	Hello\ClientPubKeyB64 = *Identity\PublicKey
	CopyMemory(@KeyPair\PublicKey[0], @Hello\ClientSessionKey[0], #BakaShrot_SessionKeySize)

	*Outbound\LastError = #BakaShrot_Error_Internal
	*Packet = BakaShrot_HelloPacket_Encode(@Hello, @PacketSize)
	If Not *Packet
		Goto ConnectFailed
	EndIf
	*Sealed = BakaShrot_Session_SealHello(*ServerPublicKey, *Packet, PacketSize\i, @SealedSize)
	FreeMemory(*Packet)
	If Not *Sealed
		Goto ConnectFailed
	EndIf
	*Outbound\LastError = #BakaShrot_Error_ConnectFailed
	Sent = BakaShrot_SendPacket(*Outbound\ConnectionId, *Sealed, SealedSize\i, 0)
	FreeMemory(*Sealed)
	If Not Sent
		Goto ConnectFailed
	EndIf


	; 2. Challenge request, in plain text. No answer: the server closed the
	; connection, it couldn't open the Hello or doesn't allow this key and
	; node (or speaks another protocol version).
	*Outbound\LastError = #BakaShrot_Error_AuthRejected
	*Packet = BakaShrot_Outbound_WaitPacket(*Outbound, @PacketSize, #BakaShrot_Outbound_Timeout)
	If Not *Packet
		Goto ConnectFailed
	EndIf

	*Outbound\LastError = #BakaShrot_Error_ProtocolError

	*Request = 0
	*View = MsgPackWrapMsgBuffer(*Packet, PacketSize\i)
	If *View
		*Request = BakaShrot_ChallengeRequestPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*Packet)
	If Not *Request
		Goto ConnectFailed
	EndIf

	ChallengeDecoded = DecodeKeyFromString(*Request\ChallengeB64, @*Outbound\Metadata\Challenge[0], #BakaShrot_ChallengeSize)
	CopyMemory(@*Request\Nonce[0], @*Outbound\Metadata\Nonce[0], #BakaShrot_NonceSize)
	CopyMemory(@*Request\ServerSessionKey[0], @*Outbound\Metadata\ServerSessionKey[0], #BakaShrot_SessionKeySize)
	CopyMemory(@*Request\ServerSignature[0], @Proof\Signature[0], #BakaShrot_Ed25519_SignatureSize)
	FreeStructure(*Request)
	If Not ChallengeDecoded
		Goto ConnectFailed
	EndIf

	; Only the server holding *ServerPublicKey's private key could sign this
	; connection's halves and challenge.
	BakaShrot_MakeHandshakeTranscript(@*Outbound\Metadata, #BakaShrot_TranscriptServerLabel, @Proof)
	ServerProved = BakaShrot_VerifyHandshake(@Proof, *ServerPublicKey)
	If Not ServerProved
		*Outbound\LastError = #BakaShrot_Error_ServerNotVerified
		Goto ConnectFailed
	EndIf

	; Every packet is encrypted from now on.
	*Outbound\LastError = #BakaShrot_Error_Internal
	If Not BakaShrot_Session_StartClient(@*Outbound\Metadata\Cipher, @KeyPair, @*Outbound\Metadata\ServerSessionKey[0])
		Goto ConnectFailed
	EndIf

	*Outbound\Metadata\Status = #BakaShrot_ConnectionStatus_Challenged


	; 3. Challenge response
	BakaShrot_MakeHandshakeTranscript(@*Outbound\Metadata, #BakaShrot_TranscriptClientLabel, @Proof)
	If Not BakaShrot_SignHandshake(@Proof, *Identity\PrivateKey)
		Goto ConnectFailed
	EndIf

	Response\ChallengeResponseB64 = EncodeKeyToString(@Proof\Signature[0], #BakaShrot_Ed25519_SignatureSize)
	CopyMemory(@*Outbound\Metadata\Nonce[0], @Response\Nonce[0], #BakaShrot_NonceSize)

	*Packet = BakaShrot_ChallengeResponsePacket_Encode(@Response, @PacketSize)
	If Not *Packet
		Goto ConnectFailed
	EndIf
	*Outbound\LastError = #BakaShrot_Error_AuthRejected
	Sent = BakaShrot_Outbound_Send(*Outbound, *Packet, PacketSize\i)
	FreeMemory(*Packet)
	If Not Sent
		Goto ConnectFailed
	EndIf


	; 4. Accepted. No answer: the server didn't accept this key's signature.
	*Packet = BakaShrot_Outbound_WaitPacket(*Outbound, @PacketSize, #BakaShrot_Outbound_Timeout)
	If Not *Packet
		Goto ConnectFailed
	EndIf
	*Outbound\LastError = #BakaShrot_Error_ProtocolError

	*Accepted = 0
	*View = MsgPackWrapMsgBuffer(*Packet, PacketSize\i)
	If *View
		*Accepted = BakaShrot_AuthAcceptedPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*Packet)
	If Not *Accepted
		Goto ConnectFailed
	EndIf
	FreeStructure(*Accepted)

	; The server's answers may be big from now on.
	BakaShrot_Inbox_Lift(@*Outbound\Inbox)
	*Outbound\Metadata\Status = #BakaShrot_ConnectionStatus_Authenticated
	*Outbound\LastError = #BakaShrot_Error_None
	ProcedureReturn #True


	ConnectFailed:
	BakaShrot_Session_ClearKeyPair(@KeyPair)
	BakaShrot_Outbound_Close(*Outbound, #BakaShrot_ConnectionStatus_Aborted)
	ProcedureReturn #False
EndProcedure


; Returns #True while *Outbound is connected, notices when the server closed
; the connection.
; Data the server sent is left to read, only a disconnect is acted upon.
Procedure.i BakaShrot_Outbound_IsConnected(*Outbound.BakaShrot_Outbound)
	If Not *Outbound\ConnectionId
		ProcedureReturn #False
	EndIf

	If NetworkClientEvent(*Outbound\ConnectionId) = #PB_NetworkEvent_Disconnect
		BakaShrot_Outbound_Close(*Outbound, #BakaShrot_ConnectionStatus_Disconnected)
		ProcedureReturn #False
	EndIf

	ProcedureReturn #True
EndProcedure
