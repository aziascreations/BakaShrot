; ============================================================================
; BakaShrotGetAttachment
;
; Usage: BakaShrotGetAttachment <Topic> <Node> <MessageId> <OutFile> [ClientIni]
;   Topic, Node  Whose message, each a name or an id.
;   MessageId    Which message.
;   OutFile      Where to save its attachment (replaced).
;   ClientIni    Identity and server to use, defaults to "client.ini".
;
; Saves the attachment of a message, read from the server a part at a time
; and checked with its SHA-256, and prints its size. The server refuses if
; the client's ReadTopics don't allow the topic, if the message has none, or
; if it isn't on that server yet (a replicated one comes after its message).
; A failed one leaves no file. See Design/Attachments.md.
; Compile as a console program, exits with 0 on success, 1 on failure.
; ============================================================================

EnableExplicit

XIncludeFile "../Common/ToolClient.pbi"
XIncludeFile "../../Commons/Networking/Names.pbi"


Define Topic.s, Node.s, MessageText.s, OutFile.s, IniPath.s, MessageId.q, Size.q, StartTime.i

OpenConsole()

If CountProgramParameters() < 4
	PrintN("Usage: BakaShrotGetAttachment <Topic> <Node> <MessageId> <OutFile> [ClientIni]")
	PrintN("  Topic and Node are names or ids.")
	ToolConsole_End(1)
EndIf

Topic = ProgramParameter(0)
Node  = ProgramParameter(1)
If Not BakaShrot_IsValidRef(Topic) Or Not BakaShrot_IsValidRef(Node)
	PrintN("Invalid topic or node, expected names or ids 0-65535")
	ToolConsole_End(1)
EndIf
MessageText = ProgramParameter(2)
MessageId   = Val(MessageText)
If MessageId < 1 Or Str(MessageId) <> MessageText
	PrintN("Invalid message id '" + MessageText + "'")
	ToolConsole_End(1)
EndIf
OutFile = ProgramParameter(3)

IniPath = "client.ini"
If CountProgramParameters() > 4
	IniPath = ProgramParameter(4)
EndIf

If Not ToolClient_Connect(IniPath)
	ToolConsole_End(1)
EndIf

StartTime = ElapsedMilliseconds()
Size = BakaShrot_SaveAttachment(Topic, Node, MessageId, OutFile)
If Size < 0
	ToolClient_PrintFailure()
	ToolClient_Close()
	ToolConsole_End(1)
EndIf

PrintN("Saved " + Str(Size) + " bytes to '" + OutFile + "' in " + Str(ElapsedMilliseconds() - StartTime) + " ms")

ToolClient_Close()
ToolConsole_End(0)
