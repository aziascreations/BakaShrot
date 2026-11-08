; ============================================================================
; Simulates the Hello -> ChallengeRequest -> ChallengeResponse handshake
; between a client and a server, without sockets.
; Each "send" is an encoded buffer, each "receive" decodes that same buffer.
;
; Compile as a console program, exits with 0 if everything passed, 1 otherwise.
; The keys and signatures are placeholders, only the packets and the nonce
; check are tested: the cryptography is Tests/CipherTest.pb's.
; ============================================================================

EnableExplicit

XIncludeFile "../Commons/Networking/Packets/HelloPacket.pbi"
XIncludeFile "../Commons/Networking/Packets/ChallengeRequestPacket.pbi"
XIncludeFile "../Commons/Networking/Packets/ChallengeResponsePacket.pbi"


; Prints the result of a check, and stops the test on the first failure.
Procedure Check(Condition.b, Message.s)
    If Condition
        PrintN("[OK]   " + Message)
        ProcedureReturn
    EndIf

    PrintN("[FAIL] " + Message)
    End 1
EndProcedure


Define *Wire, WireSize.Integer, *View.MsgPackData

; Client side
Define ClientHello.BakaShrot_AuthHello
Define *ClientChallenge.BakaShrot_ChallengeRequest
Define ClientResponse.BakaShrot_ChallengeResponse

; Server side
Define *ServerHello.BakaShrot_AuthHello
Define ServerChallenge.BakaShrot_ChallengeRequest
Define *ServerResponse.BakaShrot_ChallengeResponse
Define *ServerReplayed.BakaShrot_ChallengeResponse
Define *ServerWrongType.BakaShrot_ChallengeResponse

; Nonce the server keeps for this connection, until the response arrives.
Define *ServerConnectionNonce = AllocateMemory(#BakaShrot_NonceSize)
; Nonce a second connection got, to test a replayed response.
Define *OtherConnectionNonce = AllocateMemory(#BakaShrot_NonceSize)

OpenConsole()

Check(Bool(*ServerConnectionNonce And *OtherConnectionNonce), "Allocated the server's nonce buffers")
Check(Bool(OpenCryptRandom()), "Opened the secure random generator")


; --- 1. Client -> Server: Hello ---------------------------------------------

ClientHello\ClientTopic     = "logs"
ClientHello\ClientNode      = "34"
ClientHello\ClientPubKeyB64 = "Q2xpZW50UHViS2V5"
Check(Bool(CryptRandomData(@ClientHello\ClientSessionKey[0], #BakaShrot_SessionKeySize)), "Client made a session key")

*Wire = BakaShrot_HelloPacket_Encode(@ClientHello, @WireSize)
Check(Bool(*Wire), "Client encoded its hello")

*View = MsgPackWrapMsgBuffer(*Wire, WireSize\i)
Check(Bool(*View), "Server wrapped the hello")
*ServerHello = BakaShrot_HelloPacket_Decode(*View)
MsgPackFree(*View, #False)
FreeMemory(*Wire)

Check(Bool(*ServerHello), "Server decoded the hello")
Check(Bool(*ServerHello\ClientTopic = "logs"), "Hello's ClientTopic survived")
Check(Bool(*ServerHello\ClientNode = "34"), "Hello's ClientNode survived")
Check(Bool(*ServerHello\ClientPubKeyB64 = "Q2xpZW50UHViS2V5"), "Hello's ClientPubKeyB64 survived")
Check(CompareMemory(@*ServerHello\ClientSessionKey[0], @ClientHello\ClientSessionKey[0], #BakaShrot_SessionKeySize), "Hello's ClientSessionKey survived")


; --- 2. Server -> Client: ChallengeRequest ----------------------------------

Check(Bool(CryptRandomData(@ServerChallenge\Nonce[0], #BakaShrot_NonceSize)), "Server generated a nonce")
CopyMemory(@ServerChallenge\Nonce[0], *ServerConnectionNonce, #BakaShrot_NonceSize)
ServerChallenge\ChallengeB64 = "U2VydmVyQ2hhbGxlbmdl"
Check(Bool(CryptRandomData(@ServerChallenge\ServerSessionKey[0], #BakaShrot_SessionKeySize)), "Server made a session key")
Check(Bool(CryptRandomData(@ServerChallenge\ServerSignature[0], #BakaShrot_HandshakeSignatureSize)), "Server made a placeholder signature")

*Wire = BakaShrot_ChallengeRequestPacket_Encode(@ServerChallenge, @WireSize)
Check(Bool(*Wire), "Server encoded the challenge request")

*View = MsgPackWrapMsgBuffer(*Wire, WireSize\i)
Check(Bool(*View), "Client wrapped the challenge request")
*ClientChallenge = BakaShrot_ChallengeRequestPacket_Decode(*View)
MsgPackFree(*View, #False)
FreeMemory(*Wire)

Check(Bool(*ClientChallenge), "Client decoded the challenge request")
Check(Bool(*ClientChallenge\ChallengeB64 = "U2VydmVyQ2hhbGxlbmdl"), "Challenge's ChallengeB64 survived")
Check(CompareMemory(@*ClientChallenge\Nonce[0], *ServerConnectionNonce, #BakaShrot_NonceSize), "Challenge's nonce survived")
Check(CompareMemory(@*ClientChallenge\ServerSessionKey[0], @ServerChallenge\ServerSessionKey[0], #BakaShrot_SessionKeySize), "Challenge's ServerSessionKey survived")
Check(CompareMemory(@*ClientChallenge\ServerSignature[0], @ServerChallenge\ServerSignature[0], #BakaShrot_HandshakeSignatureSize), "Challenge's ServerSignature survived")


; --- 3. Client -> Server: ChallengeResponse ---------------------------------

; Placeholder for the real signature of ChallengeB64 + Nonce.
ClientResponse\ChallengeResponseB64 = "U2lnbmVkOiAiU2VydmVyQ2hhbGxlbmdlIg=="
CopyMemory(@*ClientChallenge\Nonce[0], @ClientResponse\Nonce[0], #BakaShrot_NonceSize)

*Wire = BakaShrot_ChallengeResponsePacket_Encode(@ClientResponse, @WireSize)
Check(Bool(*Wire), "Client encoded the challenge response")

*View = MsgPackWrapMsgBuffer(*Wire, WireSize\i)
Check(Bool(*View), "Server wrapped the challenge response")
*ServerResponse = BakaShrot_ChallengeResponsePacket_Decode(*View)
MsgPackFree(*View, #False)

Check(Bool(*ServerResponse), "Server decoded the challenge response")
Check(Bool(*ServerResponse\ChallengeResponseB64 = "U2lnbmVkOiAiU2VydmVyQ2hhbGxlbmdlIg=="), "Response's ChallengeResponseB64 survived")
Check(CompareMemory(@*ServerResponse\Nonce[0], *ServerConnectionNonce, #BakaShrot_NonceSize), "Server accepted the nonce it issued")


; --- 4. Replay: the same response sent on another connection ----------------
; *Wire still holds the response captured in step 3.

Check(Bool(CryptRandomData(*OtherConnectionNonce, #BakaShrot_NonceSize)), "Server generated a nonce for another connection")

*View = MsgPackWrapMsgBuffer(*Wire, WireSize\i)
Check(Bool(*View), "Server wrapped the replayed response")
*ServerReplayed = BakaShrot_ChallengeResponsePacket_Decode(*View)
MsgPackFree(*View, #False)
FreeMemory(*Wire)

Check(Bool(*ServerReplayed), "Replayed response is still a well-formed packet")
Check(Bool(Not CompareMemory(@*ServerReplayed\Nonce[0], *OtherConnectionNonce, #BakaShrot_NonceSize)), "Server rejected the replayed response's nonce")


; --- 5. A hello sent where a challenge response is expected ------------------

*Wire = BakaShrot_HelloPacket_Encode(@ClientHello, @WireSize)
Check(Bool(*Wire), "Client encoded a second hello")

*View = MsgPackWrapMsgBuffer(*Wire, WireSize\i)
Check(Bool(*View), "Server wrapped the misplaced hello")
*ServerWrongType = BakaShrot_ChallengeResponsePacket_Decode(*View)
MsgPackFree(*View, #False)
FreeMemory(*Wire)

Check(Bool(Not *ServerWrongType), "Challenge response decoder rejected a hello")


; --- Cleanup -----------------------------------------------------------------

FreeStructure(*ServerHello)
FreeStructure(*ClientChallenge)
FreeStructure(*ServerResponse)
FreeStructure(*ServerReplayed)
FreeMemory(*ServerConnectionNonce)
FreeMemory(*OtherConnectionNonce)
CloseCryptRandom()

PrintN("")
PrintN("Handshake simulation passed.")
End 0
