; ============================================================================
; BakaShrot GetLatestMessage
;
; Usage: GetLatestMessage <Topic> <Node> [ClientIni]
;   Topic, Node  Whose latest message to get, each a name or an id.
;   ClientIni    Identity and server to use, defaults to "client.ini".
;
; Prints the latest message stored for that topic/node, and when it was
; pushed (UTC), its attachment if it has one (GetAttachment saves it), then
; its data. The server refuses
; if the client's ReadTopics don't allow the topic, if either is unknown, or
; if there's no message.
; Compile as a console program, exits with 0 on success, 1 on failure.
; ============================================================================

EnableExplicit

XIncludeFile "../Common/ToolClient.pbi"
XIncludeFile "../../Commons/Networking/Names.pbi"


Define Topic.s, Node.s, IniPath.s

OpenConsole()

If CountProgramParameters() < 2
	PrintN("Usage: GetLatestMessage <Topic> <Node> [ClientIni]")
	PrintN("  Topic and Node are names or ids.")
	End 1
EndIf

Topic = ProgramParameter(0)
If Not BakaShrot_IsValidRef(Topic)
	PrintN("Invalid topic '" + Topic + "', expected a name or an id 0-65535")
	End 1
EndIf

Node = ProgramParameter(1)
If Not BakaShrot_IsValidRef(Node)
	PrintN("Invalid node '" + Node + "', expected a name or an id 0-65535")
	End 1
EndIf

IniPath = "client.ini"
If CountProgramParameters() > 2
	IniPath = ProgramParameter(2)
EndIf

If Not ToolClient_Connect(IniPath)
	End 1
EndIf

If Not BakaShrot_GetLatestMessageOf(Topic, Node)
	ToolClient_PrintFailure()
	ToolClient_Close()
	End 1
EndIf

PrintN("Message " + BakaShrot_GetMessageTopicString() + ":" + BakaShrot_GetMessageNodeString() + "#" + Str(BakaShrot_GetMessageId()) +
       " (ids " + Str(BakaShrot_GetMessageTopicId()) + ":" + Str(BakaShrot_GetMessageNodeId()) + "), pushed " + ToolClient_FormatUtc(BakaShrot_GetMessagePushedAt()))
If BakaShrot_GetMessageAttachmentSize() > 0
	If BakaShrot_IsMessageAttachmentReady()
		PrintN("Attachment: " + Str(BakaShrot_GetMessageAttachmentSize()) + " bytes")
	Else
		PrintN("Attachment: " + Str(BakaShrot_GetMessageAttachmentSize()) + " bytes, not on this server yet")
	EndIf
EndIf
PrintN(BakaShrot_GetMessageDataString())

ToolClient_Close()
End 0
