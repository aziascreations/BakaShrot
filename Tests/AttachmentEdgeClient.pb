;{- Code Header
; ==- Basic Info -================================
;     Name: AttachmentEdgeClient.pb
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
; A raw protocol client for the attachment cases the DLL never produces, run
; by Tests/AttachmentEdges-Test.ps1 against a running server.
;
; Usage:
;   AttachmentEdgeClient edge <KitchenIni> <GarageIni>
;     Wrong SHA-256, parts out of order / of the wrong size / repeated,
;     someone else's upload, the wrong topic, an upload attached twice, too
;     big, a part out of range. Then starts two uploads it leaves behind
;     (one half sent, one complete but never pushed) and prints
;     "LEFT <PartialId> <CompleteId>".
;   AttachmentEdgeClient late <KitchenIni> <PartialId> <CompleteId>
;     Once they expired: both refused.
; The inis are client.ini's: PrivateKey, PublicKey, ServerPublicKey, Topic,
; Node, ServerHost, ServerPort. Kitchen may push to logs and other, garage
; to logs; the server's MaxAttachmentSize must be under 1G.
; Compile as a thread-safe console program into Build\. Exits with 0 if
; every check passed, 1 otherwise.
; ============================================================================

EnableExplicit

XIncludeFile "../Commons/Networking/Outbound.pbi"

Structure EdgeClient
	Outbound.BakaShrot_Outbound
	Identity.BakaShrot_OutboundIdentity
	PrivateKey.a[#BakaShrot_Ed25519_PrivateKeySize]
	ServerPublicKey.a[#BakaShrot_Ed25519_PublicKeySize]
EndStructure

Global Fails.i = 0

Procedure Check(What.s, Ok.i, Detail.s = "")
	If Ok
		PrintN("PASS " + What)
	Else
		PrintN("FAIL " + What)
		Fails + 1
	EndIf
	PrintN("      -> " + Detail)
EndProcedure

Procedure.i ConnectIni(*Client.EdgeClient, IniPath.s)
	Protected Host.s, Port.i, Ok.i

	If Not OpenPreferences(IniPath)
		ProcedureReturn #False
	EndIf
	PreferenceGroup("BakaShrot")
	Ok = DecodeKeyFromString(ReadPreferenceString("PrivateKey", ""), @*Client\PrivateKey[0], #BakaShrot_Ed25519_PrivateKeySize)
	Ok = Bool(Ok And DecodeKeyFromString(ReadPreferenceString("ServerPublicKey", ""), @*Client\ServerPublicKey[0], #BakaShrot_Ed25519_PublicKeySize))
	*Client\Identity\PublicKey  = ReadPreferenceString("PublicKey", "")
	*Client\Identity\Node       = ReadPreferenceString("Node", "")
	*Client\Identity\PrivateKey = @*Client\PrivateKey[0]
	Host = ReadPreferenceString("ServerHost", "127.0.0.1")
	Port = ReadPreferenceLong("ServerPort", 0)
	ClosePreferences()
	If Not Ok
		ProcedureReturn #False
	EndIf
	ProcedureReturn BakaShrot_Outbound_Connect(@*Client\Outbound, Host, Port, @*Client\Identity, @*Client\ServerPublicKey[0])
EndProcedure

; Sends *Packet (freed), returns the answer with its type, 0 if the link failed.
Procedure.i Exchange(*Client.EdgeClient, *Packet, Size.i, *Type.Integer, *AnswerSize.Integer)
	Protected *Answer
	*Type\i = 0
	If Not *Packet
		ProcedureReturn 0
	EndIf
	If Not BakaShrot_Outbound_Send(@*Client\Outbound, *Packet, Size)
		FreeMemory(*Packet)
		ProcedureReturn 0
	EndIf
	FreeMemory(*Packet)
	*Answer = BakaShrot_Outbound_WaitPacket(@*Client\Outbound, *AnswerSize, 20000)
	If *Answer
		*Type\i = BakaShrot_GetPacketType(*Answer, *AnswerSize\i)
	EndIf
	ProcedureReturn *Answer
EndProcedure

Procedure.s Refusal(*Answer, Size.i)
	Protected *View.MsgPackData, *Refused.BakaShrot_RequestRefused, Reason.s
	*View = MsgPackWrapMsgBuffer(*Answer, Size)
	If *View
		*Refused = BakaShrot_RequestRefusedPacket_Decode(*View)
		MsgPackFree(*View, #False)
		If *Refused
			Reason = *Refused\Reason
			FreeStructure(*Refused)
		EndIf
	EndIf
	ProcedureReturn Reason
EndProcedure

; Starts an upload. Returns its id, 0 if refused (reason in *Reason\s).
Procedure.q StartUpload(*Client.EdgeClient, Topic.s, Size.q, *Sha256, *Reason.String)
	Protected Start.BakaShrot_UploadStart, *Started.BakaShrot_UploadStarted
	Protected *Packet, PacketSize.Integer, *Answer, AnswerSize.Integer, Type.Integer, *View.MsgPackData, Id.q

	*Reason\s = ""
	Start\Topic = Topic
	Start\Size  = Size
	CopyMemory(*Sha256, @Start\Sha256[0], #BakaShrot_Sha256Size)
	*Packet = BakaShrot_UploadStartPacket_Encode(@Start, @PacketSize)
	*Answer = Exchange(*Client, *Packet, PacketSize\i, @Type, @AnswerSize)
	If Not *Answer
		*Reason\s = "the link failed"
		ProcedureReturn 0
	EndIf
	If Type\i = #BakaShrot_PacketType_RequestRefused
		*Reason\s = Refusal(*Answer, AnswerSize\i)
	ElseIf Type\i = #BakaShrot_PacketType_UploadStarted
		*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
		*Started = BakaShrot_UploadStartedPacket_Decode(*View)
		MsgPackFree(*View, #False)
		If *Started
			Id = *Started\UploadId
			FreeStructure(*Started)
		EndIf
	EndIf
	FreeMemory(*Answer)
	ProcedureReturn Id
EndProcedure

; Sends a part. Returns 1 if stored (*Complete\i set), 0 if refused (reason), -1 if the link failed.
Procedure.i SendChunk(*Client.EdgeClient, UploadId.q, Index.i, *Data, Size.i, *Complete.Integer, *Reason.String)
	Protected Chunk.BakaShrot_UploadChunk, *Stored.BakaShrot_ChunkStored
	Protected *Packet, PacketSize.Integer, *Answer, AnswerSize.Integer, Type.Integer, *View.MsgPackData, Result.i = -1

	*Reason\s = ""
	Chunk\UploadId   = UploadId
	Chunk\ChunkIndex = Index
	Chunk\Data       = *Data
	Chunk\DataSize   = Size
	*Packet = BakaShrot_UploadChunkPacket_Encode(@Chunk, @PacketSize)
	*Answer = Exchange(*Client, *Packet, PacketSize\i, @Type, @AnswerSize)
	If Not *Answer
		ProcedureReturn -1
	EndIf
	If Type\i = #BakaShrot_PacketType_RequestRefused
		*Reason\s = Refusal(*Answer, AnswerSize\i)
		Result = 0
	ElseIf Type\i = #BakaShrot_PacketType_ChunkStored
		*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
		*Stored = BakaShrot_ChunkStoredPacket_Decode(*View)
		MsgPackFree(*View, #False)
		If *Stored
			*Complete\i = *Stored\Complete
			FreeStructure(*Stored)
			Result = 1
		EndIf
	EndIf
	FreeMemory(*Answer)
	ProcedureReturn Result
EndProcedure

; Pushes a message with UploadId. Returns its id, 0 if refused (reason).
Procedure.q Push(*Client.EdgeClient, Topic.s, Json.s, UploadId.q, *Reason.String)
	Protected Push.BakaShrot_PushMessage, *Pushed.BakaShrot_MessagePushed
	Protected *Packet, PacketSize.Integer, *Answer, AnswerSize.Integer, Type.Integer, *View.MsgPackData, Id.q

	*Reason\s = ""
	Push\Topic    = Topic
	Push\JsonData = Json
	Push\UploadId = UploadId
	*Packet = BakaShrot_PushMessagePacket_Encode(@Push, @PacketSize)
	*Answer = Exchange(*Client, *Packet, PacketSize\i, @Type, @AnswerSize)
	If Not *Answer
		*Reason\s = "the link failed"
		ProcedureReturn 0
	EndIf
	If Type\i = #BakaShrot_PacketType_RequestRefused
		*Reason\s = Refusal(*Answer, AnswerSize\i)
	ElseIf Type\i = #BakaShrot_PacketType_MessagePushed
		*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
		*Pushed = BakaShrot_MessagePushedPacket_Decode(*View)
		MsgPackFree(*View, #False)
		If *Pushed
			Id = *Pushed\MessageId
			FreeStructure(*Pushed)
		EndIf
	EndIf
	FreeMemory(*Answer)
	ProcedureReturn Id
EndProcedure

; Asks for a part. Returns it (free with _Free), 0 if refused (reason).
Procedure.i GetChunk(*Client.EdgeClient, Topic.s, Node.s, MessageId.q, Index.i, *Reason.String)
	Protected Request.BakaShrot_GetAttachment, *Chunk.BakaShrot_AttachmentChunk
	Protected *Packet, PacketSize.Integer, *Answer, AnswerSize.Integer, Type.Integer, *View.MsgPackData

	*Reason\s = ""
	Request\Topic      = Topic
	Request\Node       = Node
	Request\MessageId  = MessageId
	Request\ChunkIndex = Index
	*Packet = BakaShrot_GetAttachmentPacket_Encode(@Request, @PacketSize)
	*Answer = Exchange(*Client, *Packet, PacketSize\i, @Type, @AnswerSize)
	If Not *Answer
		*Reason\s = "the link failed"
		ProcedureReturn 0
	EndIf
	If Type\i = #BakaShrot_PacketType_RequestRefused
		*Reason\s = Refusal(*Answer, AnswerSize\i)
	ElseIf Type\i = #BakaShrot_PacketType_AttachmentChunk
		*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
		*Chunk = BakaShrot_AttachmentChunkPacket_Decode(*View)
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*Answer)
	ProcedureReturn *Chunk
EndProcedure

; Size random bytes.
Procedure.i RandomBytes(Size.i)
	Protected *Data = AllocateMemory(Size)
	RandomData(*Data, Size)
	ProcedureReturn *Data
EndProcedure

Procedure Sha256Of(*Data, Size.q, *Out)
	Protected Hash.BakaShrot_Sha256
	BakaShrot_Sha256_Start(@Hash)
	BakaShrot_Sha256_Add(@Hash, *Data, Size)
	BakaShrot_Sha256_Finish(@Hash, *Out)
EndProcedure

; Uploads Size bytes of *Data properly. Returns the upload id, 0 on failure.
Procedure.q UploadAll(*Client.EdgeClient, Topic.s, *Data, Size.q)
	Protected Dim Sha.a(31), Id.q, Index.i, Complete.Integer, Reason.String
	Sha256Of(*Data, Size, @Sha(0))
	Id = StartUpload(*Client, Topic, Size, @Sha(0), @Reason)
	If Not Id
		ProcedureReturn 0
	EndIf
	For Index = 0 To BakaShrot_AttachmentChunkCount(Size) - 1
		If SendChunk(*Client, Id, Index, *Data + Index * #BakaShrot_AttachmentChunkSize, BakaShrot_AttachmentChunkBytes(Size, Index), @Complete, @Reason) <> 1
			ProcedureReturn 0
		EndIf
	Next
	If Not Complete\i
		ProcedureReturn 0
	EndIf
	ProcedureReturn Id
EndProcedure


Define Kitchen.EdgeClient, Garage.EdgeClient, Reason.String, Complete.Integer
Define Dim Sha.a(31), Dim WrongSha.a(31)
Define *Data, *Other, Id.q, Id2.q, MessageId.q, Result.i, *Chunk.BakaShrot_AttachmentChunk, Size.q
Define PartialId.q, CompleteId.q

OpenConsole()
If CountProgramParameters() < 3
	PrintN("Usage: AttachmentEdgeClient edge <KitchenIni> <GarageIni> | late <KitchenIni> <PartialId> <CompleteId>")
	End 1
EndIf
If Not ConnectIni(@Kitchen, ProgramParameter(1))
	PrintN("FAIL can't connect with " + ProgramParameter(1))
	End 1
EndIf

If LCase(ProgramParameter(0)) = "late"
	PartialId  = Val(ProgramParameter(2))
	CompleteId = Val(ProgramParameter(3))
	*Data = RandomBytes(#BakaShrot_AttachmentChunkSize)
	Result = SendChunk(@Kitchen, PartialId, 1, *Data, 1000, @Complete, @Reason)
	Check("An expired upload: its next part refused", Bool(Result = 0 And FindString(Reason\s, "No such upload in progress")), Reason\s)
	MessageId = Push(@Kitchen, "logs", "{" + Chr(34) + "late" + Chr(34) + ":1}", CompleteId, @Reason)
	Check("An expired complete upload: pushing with it refused", Bool(MessageId = 0 And (FindString(Reason\s, "No such upload") Or FindString(Reason\s, "isn't complete"))), Reason\s)
	Check("Still connected after the refusals", BakaShrot_Outbound_IsConnected(@Kitchen\Outbound))
	BakaShrot_Outbound_Close(@Kitchen\Outbound, #BakaShrot_ConnectionStatus_Disconnected)
	PrintN("")
	If Fails : PrintN(Str(Fails) + " FAILED") : End 1 : EndIf
	PrintN("All passed")
	End 0
EndIf

If Not ConnectIni(@Garage, ProgramParameter(2))
	PrintN("FAIL can't connect with " + ProgramParameter(2))
	End 1
EndIf

; --- A wrong SHA-256 --------------------------------------------------------------
Size  = #BakaShrot_AttachmentChunkSize + 500000
*Data = RandomBytes(Size)
*Other = RandomBytes(Size)
Sha256Of(*Other, Size, @WrongSha(0))
Id = StartUpload(@Kitchen, "logs", Size, @WrongSha(0), @Reason)
Check("Upload with a wrong SHA-256: started", Bool(Id > 0), Reason\s)
Result = SendChunk(@Kitchen, Id, 0, *Data, #BakaShrot_AttachmentChunkSize, @Complete, @Reason)
Check("  part 0 stored, not complete", Bool(Result = 1 And Complete\i = 0), Reason\s)
Result = SendChunk(@Kitchen, Id, 1, *Data + #BakaShrot_AttachmentChunkSize, 500000, @Complete, @Reason)
Check("  the last part: refused, doesn't match", Bool(Result = 0 And FindString(Reason\s, "doesn't match its SHA-256")), Reason\s)
MessageId = Push(@Kitchen, "logs", "{" + Chr(34) + "bad" + Chr(34) + ":1}", Id, @Reason)
Check("  pushing with it: refused", Bool(MessageId = 0 And FindString(Reason\s, "isn't complete")), Reason\s)
Result = SendChunk(@Kitchen, Id, 1, *Data + #BakaShrot_AttachmentChunkSize, 500000, @Complete, @Reason)
Check("  sending the last part again: refused, it's dropped", Bool(Result = 0 And FindString(Reason\s, "No such upload in progress")), Reason\s)

; --- Parts out of order, wrong size, repeated ---------------------------------------
Size = 2 * #BakaShrot_AttachmentChunkSize + 1234
FreeMemory(*Data) : *Data = RandomBytes(Size)
Sha256Of(*Data, Size, @Sha(0))
Id = StartUpload(@Kitchen, "logs", Size, @Sha(0), @Reason)
Check("Upload of 3 parts: started", Bool(Id > 0), Reason\s)
Result = SendChunk(@Kitchen, Id, 1, *Data + #BakaShrot_AttachmentChunkSize, #BakaShrot_AttachmentChunkSize, @Complete, @Reason)
Check("  part 1 first: refused", Bool(Result = 0 And FindString(Reason\s, "Expected part 0 of 3")), Reason\s)
Result = SendChunk(@Kitchen, Id, 0, *Data, 1000, @Complete, @Reason)
Check("  part 0 too short: refused", Bool(Result = 0 And FindString(Reason\s, "1048576 bytes")), Reason\s)
Result = SendChunk(@Kitchen, Id, 0, *Data, #BakaShrot_AttachmentChunkSize, @Complete, @Reason)
Check("  part 0 right: stored, the refusals didn't drop the upload", Bool(Result = 1 And Complete\i = 0), Reason\s)
Result = SendChunk(@Kitchen, Id, 0, *Data, #BakaShrot_AttachmentChunkSize, @Complete, @Reason)
Check("  part 0 again: refused", Bool(Result = 0 And FindString(Reason\s, "Expected part 1")), Reason\s)
Result = SendChunk(@Garage, Id, 1, *Data + #BakaShrot_AttachmentChunkSize, #BakaShrot_AttachmentChunkSize, @Complete, @Reason)
Check("  part 1 from another client: refused", Bool(Result = 0 And FindString(Reason\s, "No such upload in progress")), Reason\s)
Result = SendChunk(@Kitchen, Id, 1, *Data + #BakaShrot_AttachmentChunkSize, #BakaShrot_AttachmentChunkSize, @Complete, @Reason)
Check("  part 1: stored", Bool(Result = 1 And Complete\i = 0), Reason\s)
Result = SendChunk(@Kitchen, Id, 2, *Data + 2 * #BakaShrot_AttachmentChunkSize, 1234, @Complete, @Reason)
Check("  part 2, the last: complete", Bool(Result = 1 And Complete\i = 1), Reason\s)
Result = SendChunk(@Kitchen, Id, 3, *Data, 10, @Complete, @Reason)
Check("  a part past the end: refused", Bool(Result = 0), Reason\s)

; --- Whose, which topic, how many times -------------------------------------------------
MessageId = Push(@Garage, "logs", "{" + Chr(34) + "theirs" + Chr(34) + ":1}", Id, @Reason)
Check("Another client pushing with it: refused", Bool(MessageId = 0 And FindString(Reason\s, "No such upload")), Reason\s)
MessageId = Push(@Kitchen, "other", "{" + Chr(34) + "topic" + Chr(34) + ":1}", Id, @Reason)
Check("Pushing it to another topic: refused", Bool(MessageId = 0 And FindString(Reason\s, "is for topic 'logs'")), Reason\s)
MessageId = Push(@Kitchen, "logs", "{" + Chr(34) + "edge" + Chr(34) + ":1}", Id, @Reason)
Check("Pushing it: stored", Bool(MessageId > 0), "message #" + Str(MessageId) + " " + Reason\s)
Id2 = Push(@Kitchen, "logs", "{" + Chr(34) + "edge" + Chr(34) + ":2}", Id, @Reason)
Check("Pushing it again: refused, attached already", Bool(Id2 = 0 And FindString(Reason\s, "attached already")), Reason\s)
Id2 = Push(@Kitchen, "logs", "{" + Chr(34) + "edge" + Chr(34) + ":3}", 999999, @Reason)
Check("An upload id that doesn't exist: refused", Bool(Id2 = 0 And FindString(Reason\s, "No such upload")), Reason\s)

; --- Reading it back, part by part ---------------------------------------------------------
*Chunk = GetChunk(@Kitchen, "logs", "kitchen", MessageId, 2, @Reason)
Check("GetAttachment part 2 first: the right bytes", Bool(*Chunk And *Chunk\DataSize = 1234 And *Chunk\Size = Size And CompareMemory(*Chunk\Data, *Data + 2 * #BakaShrot_AttachmentChunkSize, 1234) And CompareMemory(@*Chunk\Sha256[0], @Sha(0), 32)), Reason\s)
BakaShrot_AttachmentChunkPacket_Free(*Chunk)
*Chunk = GetChunk(@Kitchen, "logs", "kitchen", MessageId, 0, @Reason)
Check("  part 0: the right bytes", Bool(*Chunk And *Chunk\DataSize = #BakaShrot_AttachmentChunkSize And CompareMemory(*Chunk\Data, *Data, #BakaShrot_AttachmentChunkSize)), Reason\s)
BakaShrot_AttachmentChunkPacket_Free(*Chunk)
*Chunk = GetChunk(@Kitchen, "logs", "kitchen", MessageId, 3, @Reason)
Check("  part 3, past the end: refused", Bool(Not *Chunk And FindString(Reason\s, "has 3 parts")), Reason\s)
*Chunk = GetChunk(@Garage, "secret", "kitchen", MessageId, 0, @Reason)
Check("  from a topic garage may not read: refused", Bool(Not *Chunk And FindString(Reason\s, "Not allowed to read topic")), Reason\s)

; --- Limits ------------------------------------------------------------------------------------
Id = StartUpload(@Kitchen, "logs", 1024 * 1024 * 1024, @Sha(0), @Reason)
Check("Upload of 1 GB (over MaxAttachmentSize): refused", Bool(Id = 0 And FindString(Reason\s, "too big")), Reason\s)
Id = StartUpload(@Garage, "other", 1000, @Sha(0), @Reason)
Check("Upload to a topic garage may not push to: refused", Bool(Id = 0 And FindString(Reason\s, "Not allowed to push")), Reason\s)
Check("Both still connected after every refusal", Bool(BakaShrot_Outbound_IsConnected(@Kitchen\Outbound) And BakaShrot_Outbound_IsConnected(@Garage\Outbound)))

; --- Left behind, for the expiry ---------------------------------------------------------------------
Size = 2 * #BakaShrot_AttachmentChunkSize
FreeMemory(*Data) : *Data = RandomBytes(Size)
Sha256Of(*Data, Size, @Sha(0))
PartialId = StartUpload(@Kitchen, "logs", Size, @Sha(0), @Reason)
Result = SendChunk(@Kitchen, PartialId, 0, *Data, #BakaShrot_AttachmentChunkSize, @Complete, @Reason)
CompleteId = UploadAll(@Kitchen, "logs", *Data, 5000)
Check("Two uploads left behind: half sent, and complete but never pushed", Bool(PartialId > 0 And Result = 1 And CompleteId > 0), Str(PartialId) + ", " + Str(CompleteId))

BakaShrot_Outbound_Close(@Kitchen\Outbound, #BakaShrot_ConnectionStatus_Disconnected)
BakaShrot_Outbound_Close(@Garage\Outbound, #BakaShrot_ConnectionStatus_Disconnected)
PrintN("LEFT " + Str(PartialId) + " " + Str(CompleteId))
PrintN("")
If Fails : PrintN(Str(Fails) + " FAILED") : End 1 : EndIf
PrintN("All passed")
End 0
