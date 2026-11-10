; ============================================================================
; BakaShrot Connections
;
; What both ends need to keep track of a connection and authenticate it.
;
; Handshake, anything out of order or unexpected aborts the connection.
; The client must already know the server's public key (client.ini's
; ServerPublicKey, a peer section's PublicKey).
;   C->S Hello              Sealed for the server's public key, only it can
;                           read it (Session.pbi): the client's identity and
;                           public key, and the public half of its key pair
;                           for this connection.
;                           The server checks they're registered together.
;   S->C ChallengeRequest   In plain text: random challenge (Base64) and
;                           nonce, the public half of the server's key pair
;                           for this connection, and the server's signature
;                           of the handshake (BakaShrot_MakeHandshakeTranscript()).
;                           The client checks it with the server's public
;                           key: it's the right server, and nobody swapped
;                           the halves. Both ends now have this connection's
;                           keys, every packet from here on is encrypted
;                           (Cipher.pbi).
;   C->S ChallengeResponse  The client's signature of the handshake, and
;                           the nonce echoed back.
;   S->C AuthAccepted       The client is authenticated.
;
; Requests, only once authenticated, each one gets one answer:
;   C->S PushMessage        -> S->C MessagePushed or RequestRefused
;   C->S GetLatestMessage   -> S->C LatestMessage or RequestRefused
;   C->S GetMessages        -> S->C Messages (maybe none) or RequestRefused
;   C->S QueryRequest       -> S->C QueryResult or RequestRefused
;   C->S ResolveName        -> S->C NameResolved or RequestRefused
;   C->S ListNames          -> S->C NamesList
;   C->S UploadStart        -> S->C UploadStarted or RequestRefused
;   C->S UploadChunk        -> S->C ChunkStored or RequestRefused
;        then a PushMessage with the UploadId attaches it to the message
;   C->S GetAttachment      -> S->C AttachmentChunk or RequestRefused
; Topics and nodes are given by name or id, see Names.pbi.
; A refusal keeps the connection open, a malformed or unexpected packet
; still aborts it.
;
; Replication, only from a peer (see Server/Networking/Peers.pbi), over the
; link it opened to the server:
;   P->S SyncStateRequest   -> S->P SyncState or RequestRefused
;   P->S ReplicateMessages  -> S->P MessagePushed (last id) or RequestRefused
;   once the messages are caught up:
;   P->S MissingAttachmentsRequest -> S->P MissingAttachments or RequestRefused
;   P->S ReplicateAttachmentChunk  -> S->P ChunkStored or RequestRefused
;
;
; Framing: every packet is sent as its size (4 bytes, little-endian),
; followed by the packet itself, so the receiver knows where it ends.
; Once the connection's cipher is set up, the packet is encrypted first
; (#BakaShrot_Cipher_Overhead bytes more), the size isn't: see
; BakaShrot_SendPacket() and BakaShrot_OpenFrame().
; Up to #BakaShrot_MaxHandshakePacketSize until the other end authenticated,
; then up to #BakaShrot_MaxPacketSize (BakaShrot_Inbox_Lift()): anyone can
; connect, only those with a key get to make the other end hold big frames.
; ============================================================================


XIncludeFile "../Cryptography/Session.pbi"
XIncludeFile "Packets/HelloPacket.pbi"
XIncludeFile "Packets/ChallengeRequestPacket.pbi"
XIncludeFile "Packets/ChallengeResponsePacket.pbi"
XIncludeFile "Packets/AuthAcceptedPacket.pbi"
XIncludeFile "Packets/PushMessagePacket.pbi"
XIncludeFile "Packets/MessagePushedPacket.pbi"
XIncludeFile "Packets/GetLatestMessagePacket.pbi"
XIncludeFile "Packets/LatestMessagePacket.pbi"
XIncludeFile "Packets/RequestRefusedPacket.pbi"
XIncludeFile "Packets/SyncStateRequestPacket.pbi"
XIncludeFile "Packets/SyncStatePacket.pbi"
XIncludeFile "Packets/ReplicateMessagesPacket.pbi"
XIncludeFile "Packets/QueryRequestPacket.pbi"
XIncludeFile "Packets/QueryResultPacket.pbi"
XIncludeFile "Packets/ResolveNamePacket.pbi"
XIncludeFile "Packets/NameResolvedPacket.pbi"
XIncludeFile "Packets/ListNamesPacket.pbi"
XIncludeFile "Packets/NamesListPacket.pbi"
XIncludeFile "Packets/GetMessagesPacket.pbi"
XIncludeFile "Packets/MessagesPacket.pbi"
XIncludeFile "Packets/UploadStartPacket.pbi"
XIncludeFile "Packets/UploadStartedPacket.pbi"
XIncludeFile "Packets/UploadChunkPacket.pbi"
XIncludeFile "Packets/ChunkStoredPacket.pbi"
XIncludeFile "Packets/GetAttachmentPacket.pbi"
XIncludeFile "Packets/AttachmentChunkPacket.pbi"
XIncludeFile "Packets/MissingAttachmentsRequestPacket.pbi"
XIncludeFile "Packets/MissingAttachmentsPacket.pbi"
XIncludeFile "Packets/ReplicateAttachmentChunkPacket.pbi"


; Reads the type of a received packet, to know which decoder to use.
; Returns #BakaShrot_PacketType_None if the packet's base fields are invalid.
Procedure.i BakaShrot_GetPacketType(*Packet, PacketSize.i)
	Protected *View.MsgPackData, Base.BakaShrot_PacketBase, IsValid.i

	*View = MsgPackWrapMsgBuffer(*Packet, PacketSize)
	If Not *View
		ProcedureReturn #BakaShrot_PacketType_None
	EndIf
	IsValid = BakaShrot_ReadPacketBase(@Base, *View)
	MsgPackFree(*View, #False)

	If Not IsValid
		ProcedureReturn #BakaShrot_PacketType_None
	EndIf
	ProcedureReturn Base\PacketType
EndProcedure


Enumeration BakaShrot_ConnectionStatuses
	; Connected, the Hello hasn't been sent/received yet.
	#BakaShrot_ConnectionStatus_New
	; The challenge was issued, its response hasn't been sent/received yet.
	#BakaShrot_ConnectionStatus_Challenged
	#BakaShrot_ConnectionStatus_Authenticated
	#BakaShrot_ConnectionStatus_Disconnected
	#BakaShrot_ConnectionStatus_Aborted
EndEnumeration


CompilerIf #BakaShrot_SessionKeySize <> #BakaShrot_Session_PublicKeySize Or #BakaShrot_HandshakeSignatureSize <> #BakaShrot_Ed25519_SignatureSize
	CompilerError "Packets.pbi's handshake sizes don't match the cryptography's."
CompilerEndIf


Structure BakaShrot_ConnectionMetadata
	Status.i

	; Server side only, trusted once Status is Authenticated: the node from
	; the Hello, and the default topic of its pushes from its client
	; section's DefaultTopic (-1 without one: pushes must name their topic),
	; both as the server's own ids.
	DefaultTopicId.l
	NodeId.u
	; The client's Ed25519 public key, on both sides.
	PublicKey.a[#BakaShrot_Ed25519_PublicKeySize]
	; The server's Ed25519 public key, on both sides.
	ServerPublicKey.a[#BakaShrot_Ed25519_PublicKeySize]

	; TempKey to prevent replay attacks, fresh random data for every connection.
	Challenge.a[#BakaShrot_ChallengeSize]
	Nonce.a[#BakaShrot_NonceSize]

	; Public halves of both ends' key pairs for this connection.
	ClientSessionKey.a[#BakaShrot_SessionKeySize]
	ServerSessionKey.a[#BakaShrot_SessionKeySize]

	; Set up once both ends have their keys (after the ChallengeRequest),
	; then every packet is encrypted with it. Wiped when the connection ends.
	Cipher.BakaShrot_Cipher
EndStructure


; What each end signs: proves it holds its identity key, for this
; connection (the challenge, the nonce, both key pairs), to this other end.
; Label tells which end signed it, so one end's signature can't be sent
; back as the other's.
#BakaShrot_TranscriptLabelSize = 16
#BakaShrot_TranscriptServerLabel = "BakaShrot3 srv"
#BakaShrot_TranscriptClientLabel = "BakaShrot3 cli"

Structure BakaShrot_HandshakeTranscript
	Label.a[#BakaShrot_TranscriptLabelSize]
	ClientPublicKey.a[#BakaShrot_Ed25519_PublicKeySize]
	ServerPublicKey.a[#BakaShrot_Ed25519_PublicKeySize]
	ClientSessionKey.a[#BakaShrot_SessionKeySize]
	ServerSessionKey.a[#BakaShrot_SessionKeySize]
	Challenge.a[#BakaShrot_ChallengeSize]
	Nonce.a[#BakaShrot_NonceSize]
EndStructure

Structure BakaShrot_ChallengeProof
	Message.BakaShrot_HandshakeTranscript
	Signature.a[#BakaShrot_Ed25519_SignatureSize]
EndStructure

; Fills *Proof\Message from *Metadata, as signed by one end: Label is
; #BakaShrot_TranscriptServerLabel or #BakaShrot_TranscriptClientLabel.
Procedure BakaShrot_MakeHandshakeTranscript(*Metadata.BakaShrot_ConnectionMetadata, Label.s, *Proof.BakaShrot_ChallengeProof)
	FillMemory(@*Proof\Message, SizeOf(BakaShrot_HandshakeTranscript), 0)
	PokeS(@*Proof\Message\Label[0], Label, #BakaShrot_TranscriptLabelSize - 1, #PB_Ascii)
	CopyMemory(@*Metadata\PublicKey[0], @*Proof\Message\ClientPublicKey[0], #BakaShrot_Ed25519_PublicKeySize)
	CopyMemory(@*Metadata\ServerPublicKey[0], @*Proof\Message\ServerPublicKey[0], #BakaShrot_Ed25519_PublicKeySize)
	CopyMemory(@*Metadata\ClientSessionKey[0], @*Proof\Message\ClientSessionKey[0], #BakaShrot_SessionKeySize)
	CopyMemory(@*Metadata\ServerSessionKey[0], @*Proof\Message\ServerSessionKey[0], #BakaShrot_SessionKeySize)
	CopyMemory(@*Metadata\Challenge[0], @*Proof\Message\Challenge[0], #BakaShrot_ChallengeSize)
	CopyMemory(@*Metadata\Nonce[0], @*Proof\Message\Nonce[0], #BakaShrot_NonceSize)
EndProcedure

; Signs *Proof\Message with *PrivateKey into *Proof\Signature.
Procedure.i BakaShrot_SignHandshake(*Proof.BakaShrot_ChallengeProof, *PrivateKey)
	ProcedureReturn EncodeData(@*Proof\Message, SizeOf(BakaShrot_HandshakeTranscript), *PrivateKey, @*Proof\Signature[0])
EndProcedure

; #True if *Proof\Signature is *PublicKey's holder's signature of *Proof\Message.
Procedure.i BakaShrot_VerifyHandshake(*Proof.BakaShrot_ChallengeProof, *PublicKey)
	ProcedureReturn DecodeData(@*Proof\Message, SizeOf(BakaShrot_HandshakeTranscript), *PublicKey, @*Proof\Signature[0])
EndProcedure

; Wipes what's secret in *Metadata, once the connection is over.
Procedure BakaShrot_ClearConnectionMetadata(*Metadata.BakaShrot_ConnectionMetadata)
	BakaShrot_Cipher_Clear(@*Metadata\Cipher)
EndProcedure


; --- Framing -----------------------------------------------------------------

#BakaShrot_FrameHeaderSize = 4

; Biggest packet before the other end is authenticated. The handshake's are a
; few hundred bytes.
#BakaShrot_MaxHandshakePacketSize = 4096

; A buffer this big or more is freed once emptied, instead of kept for the
; next packets.
#BakaShrot_InboxKeptCapacity = 256 * 1024

; How long a send waits for the other end to make room, without a single
; byte going out, before it gives up. Same as how long a client waits for
; each packet (#BakaShrot_Outbound_Timeout).
#BakaShrot_SendStallTimeout = 10000

Enumeration BakaShrot_InboxResults
	#BakaShrot_Inbox_Incomplete
	#BakaShrot_Inbox_Packet
	#BakaShrot_Inbox_Invalid
EndEnumeration

; Received data that hasn't been read as packets yet: Size bytes, from
; Buffer + Start.
Structure BakaShrot_Inbox
	*Buffer
	Start.i
	Size.i
	Capacity.i

	; Biggest packet accepted: #BakaShrot_MaxHandshakePacketSize while 0,
	; #BakaShrot_MaxPacketSize once lifted.
	MaxPacketSize.i
EndStructure


; Biggest packet *Inbox accepts.
Procedure.i BakaShrot_Inbox_MaxPacketSize(*Inbox.BakaShrot_Inbox)
	If *Inbox\MaxPacketSize
		ProcedureReturn *Inbox\MaxPacketSize
	EndIf
	ProcedureReturn #BakaShrot_MaxHandshakePacketSize
EndProcedure

; Biggest amount of received data waiting to be read as packets, anything
; more aborts the connection: two of the biggest packets.
Procedure.i BakaShrot_Inbox_MaxSize(*Inbox.BakaShrot_Inbox)
	ProcedureReturn 2 * (#BakaShrot_FrameHeaderSize + BakaShrot_Inbox_MaxPacketSize(*Inbox))
EndProcedure

; Accepts packets up to #BakaShrot_MaxPacketSize (encrypted) from now on. Call
; it once the other end is authenticated, before it can send anything big:
; on the server, before sending AuthAccepted.
Procedure BakaShrot_Inbox_Lift(*Inbox.BakaShrot_Inbox)
	*Inbox\MaxPacketSize = #BakaShrot_MaxPacketSize + #BakaShrot_Cipher_Overhead
EndProcedure


; Sends *Packet as one frame, encrypted with *Cipher, or in plain text if
; *Cipher is 0: only the Hello (sealed on its own) and the ChallengeRequest.
; Returns #False if the packet is too big, *Cipher isn't set up, or the data
; couldn't be sent.
; PureBasic's sockets don't block: SendNetworkData() returns -1 once the
; system's send buffer is full (EAGAIN on Linux, a few hundred KB), so -1 is
; retried until nothing went out for #BakaShrot_SendStallTimeout. PureBasic
; doesn't tell that from a broken connection, which then takes that long to
; give up on.
Procedure.i BakaShrot_SendPacket(ConnectionId.i, *Packet, PacketSize.i, *Cipher.BakaShrot_Cipher)
	Protected *Frame, FrameSize.i, PayloadSize.i, Offset.i, Sent.i, LastProgress.i

	If PacketSize < 1 Or PacketSize > #BakaShrot_MaxPacketSize
		ProcedureReturn #False
	EndIf

	PayloadSize = PacketSize
	If *Cipher
		If Not *Cipher\IsReady
			ProcedureReturn #False
		EndIf
		PayloadSize + #BakaShrot_Cipher_Overhead
	EndIf

	FrameSize = #BakaShrot_FrameHeaderSize + PayloadSize
	*Frame = AllocateMemory(FrameSize, #PB_Memory_NoClear)
	If Not *Frame
		ProcedureReturn #False
	EndIf
	PokeL(*Frame, PayloadSize)
	If *Cipher
		If Not BakaShrot_Cipher_EncryptTo(*Cipher, *Packet, PacketSize, *Frame + #BakaShrot_FrameHeaderSize)
			FreeMemory(*Frame)
			ProcedureReturn #False
		EndIf
	Else
		CopyMemory(*Packet, *Frame + #BakaShrot_FrameHeaderSize, PacketSize)
	EndIf

	LastProgress = ElapsedMilliseconds()
	While Offset < FrameSize
		Sent = SendNetworkData(ConnectionId, *Frame + Offset, FrameSize - Offset)
		If Sent > 0
			Offset + Sent
			LastProgress = ElapsedMilliseconds()
		ElseIf ElapsedMilliseconds() - LastProgress > #BakaShrot_SendStallTimeout
			FreeMemory(*Frame)
			ProcedureReturn #False
		Else
			; Full, until the other end reads some of it.
			Delay(1)
		EndIf
	Wend

	FreeMemory(*Frame)
	ProcedureReturn #True
EndProcedure


; Adds received data at the end of *Inbox.
; Returns #False if it would go over BakaShrot_Inbox_MaxSize() or memory ran out.
Procedure.i BakaShrot_Inbox_Append(*Inbox.BakaShrot_Inbox, *Data, DataSize.i)
	Protected *NewBuffer, Needed.i, MaxSize.i, NewCapacity.i

	Needed  = *Inbox\Size + DataSize
	MaxSize = BakaShrot_Inbox_MaxSize(*Inbox)
	If Needed > MaxSize
		ProcedureReturn #False
	EndIf

	; Out of room at the end: moves what's left to the front, but only if it
	; isn't bigger than the room that frees, so each byte gets moved about
	; once. Otherwise the buffer grows instead, doubling: moving 32 MB under
	; the server's mutex for every 64 KB received, near the limit, would stall
	; every client. At worst it reaches twice BakaShrot_Inbox_MaxSize().
	If *Inbox\Start + Needed > *Inbox\Capacity And *Inbox\Start > 0 And *Inbox\Size <= *Inbox\Start
		MoveMemory(*Inbox\Buffer + *Inbox\Start, *Inbox\Buffer, *Inbox\Size)
		*Inbox\Start = 0
	EndIf

	If *Inbox\Start + Needed > *Inbox\Capacity
		NewCapacity = *Inbox\Capacity * 2
		If NewCapacity < *Inbox\Start + Needed
			NewCapacity = *Inbox\Start + Needed
		EndIf
		If NewCapacity > *Inbox\Start + MaxSize
			NewCapacity = *Inbox\Start + MaxSize
		EndIf

		If *Inbox\Buffer
			*NewBuffer = ReAllocateMemory(*Inbox\Buffer, NewCapacity, #PB_Memory_NoClear)
		Else
			*NewBuffer = AllocateMemory(NewCapacity, #PB_Memory_NoClear)
		EndIf
		If Not *NewBuffer
			ProcedureReturn #False
		EndIf
		*Inbox\Buffer   = *NewBuffer
		*Inbox\Capacity = NewCapacity
	EndIf

	CopyMemory(*Data, *Inbox\Buffer + *Inbox\Start + *Inbox\Size, DataSize)
	*Inbox\Size + DataSize

	ProcedureReturn #True
EndProcedure


; Takes the first complete packet out of *Inbox.
; Returns:
;   #BakaShrot_Inbox_Packet      *OutPacket\i receives the packet (free it with FreeMemory), *OutSize\i its size.
;   #BakaShrot_Inbox_Incomplete  The next packet hasn't fully arrived yet.
;   #BakaShrot_Inbox_Invalid     The frame's size is invalid (too big for now included), or memory ran out. Abort the connection.
Procedure.i BakaShrot_Inbox_TakePacket(*Inbox.BakaShrot_Inbox, *OutPacket.Integer, *OutSize.Integer)
	Protected PacketSize.i, *Packet, *Frame

	If *Inbox\Size < #BakaShrot_FrameHeaderSize
		ProcedureReturn #BakaShrot_Inbox_Incomplete
	EndIf

	; Checked as soon as the size arrived, not once the whole frame did.
	*Frame = *Inbox\Buffer + *Inbox\Start
	PacketSize = PeekL(*Frame) & $FFFFFFFF
	If PacketSize < 1 Or PacketSize > BakaShrot_Inbox_MaxPacketSize(*Inbox)
		ProcedureReturn #BakaShrot_Inbox_Invalid
	EndIf

	If *Inbox\Size < #BakaShrot_FrameHeaderSize + PacketSize
		ProcedureReturn #BakaShrot_Inbox_Incomplete
	EndIf

	*Packet = AllocateMemory(PacketSize, #PB_Memory_NoClear)
	If Not *Packet
		ProcedureReturn #BakaShrot_Inbox_Invalid
	EndIf
	CopyMemory(*Frame + #BakaShrot_FrameHeaderSize, *Packet, PacketSize)

	; What's left stays where it is, Append() moves it when it needs room.
	*Inbox\Start + #BakaShrot_FrameHeaderSize + PacketSize
	*Inbox\Size  - (#BakaShrot_FrameHeaderSize + PacketSize)
	If *Inbox\Size = 0
		*Inbox\Start = 0
		If *Inbox\Capacity >= #BakaShrot_InboxKeptCapacity
			FreeMemory(*Inbox\Buffer)
			*Inbox\Buffer   = 0
			*Inbox\Capacity = 0
		EndIf
	EndIf

	*OutPacket\i = *Packet
	*OutSize\i   = PacketSize
	ProcedureReturn #BakaShrot_Inbox_Packet
EndProcedure


; Turns a frame's content taken out of an inbox (*Frame, FrameSize bytes)
; into the packet: decrypts it with *Cipher once it's set up, as it must
; be from the ChallengeResponse on, else it's the packet already.
; Returns the packet (free it with FreeMemory), its size in *OutSize\i, or
; 0 if it doesn't decrypt: abort the connection. *Frame is freed or
; returned either way.
Procedure.i BakaShrot_OpenFrame(*Cipher.BakaShrot_Cipher, *Frame, FrameSize.i, *OutSize.Integer)
	Protected *Packet

	If Not *Cipher\IsReady
		*OutSize\i = FrameSize
		ProcedureReturn *Frame
	EndIf

	*Packet = BakaShrot_Cipher_Decrypt(*Cipher, *Frame, FrameSize, *OutSize)
	FreeMemory(*Frame)
	If *Packet And *OutSize\i < 1
		; Never sent: BakaShrot_SendPacket() refuses empty packets.
		FreeMemory(*Packet)
		*Packet = 0
	EndIf
	ProcedureReturn *Packet
EndProcedure


; Frees *Inbox's data, and puts its limit back to the handshake's.
Procedure BakaShrot_Inbox_Clear(*Inbox.BakaShrot_Inbox)
	If *Inbox\Buffer
		FreeMemory(*Inbox\Buffer)
	EndIf
	*Inbox\Buffer        = 0
	*Inbox\Start         = 0
	*Inbox\Size          = 0
	*Inbox\Capacity      = 0
	*Inbox\MaxPacketSize = 0
EndProcedure
