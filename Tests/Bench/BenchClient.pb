; ============================================================================
; BakaShrot Bench Client
;
; Usage: BenchClient <run|query> <Plan.ini>
;
;   run    One benchmark stage:
;            1. One thread per pushing node, each with its own connection to
;               its server, all connected before the clock starts.
;            2. They push for [Bench] PushSeconds, at [Bench] Rate messages
;               per second each (0: as fast as the server answers).
;            3. Meanwhile, every [Bench] SampleMs, samples every server:
;               how many messages of every node it has (replication lag),
;               its CPU and RAM, its database's size.
;            4. Then keeps sampling, every [Bench] DrainSampleMs, until every
;               server has every message (drained) or [Bench] DrainTimeout.
;          Optionally, a thread runs [Bench] QueryFile in a loop against the
;          servers with QueryLoad = 1 while pushing, to see how queries hold
;          up under load.
;          Writes every sample to [Bench] SamplesCsv, and the stage's summary
;          to [Bench] SummaryOut (JSON).
;   query  Runs every query of [Bench] QueryFile against every server with
;          Query = 1, [Bench] QueryRepeats times each (plus a warm-up), and
;          writes their timings to [Bench] QueryOut (JSON).
;
; Plan.ini (written by Tests/Bench/Bench-Replication.ps1):
;   [Bench]
;   PrivateKey, PublicKey   The client key every server registers.
;   TopicId                 Topic every node pushes into.
;   ServerCount             Number of [Server<i>] sections, 1-based.
;   PushSeconds, Rate, MessageSize, SampleMs, DrainSampleMs, DrainTimeout
;   SamplesCsv, SummaryOut, QueryFile, QueryRepeats, QueryOut
;   [Server<i>]
;   Name, Host, Port, Pid, DatabasePath
;   PublicKey               The server's, it must prove it holds the private one.
;   FirstNode, MaxNodes     Its nodes are FirstNode to FirstNode+MaxNodes-1,
;                           all of them are monitored.
;   NodeCount               How many of them push in this stage, from FirstNode.
;   MonitorNode, QueryNode  Identities used by the sampler and the queries.
;   QueryLoad, Query        0/1, see above.
;
; Query file: one query per line, "Name | SQL", # starts a comment.
;   {TOPIC} and {NODE} are replaced by the topic id and the server's FirstNode.
;   "@latest" as the SQL does a GetLatestMessage of {NODE} instead.
;
; CPU is in % of one core (200 = two cores busy), the system's in % of the
; whole machine. RAM is the working set and the private bytes, in MB.
; Windows only (process sampling), compile as a thread-safe console program.
; ============================================================================

EnableExplicit

CompilerIf Not #PB_Compiler_Thread
	CompilerError "BenchClient needs the thread-safe option."
CompilerEndIf

XIncludeFile "../../Commons/Networking/Outbound.pbi"


#Bench_RequestTimeout = 60000
#Bench_MaxNodes       = 512


; --- Windows process sampling ------------------------------------------------

Structure BenchMemoryCounters
	cb.l
	PageFaultCount.l
	PeakWorkingSetSize.i
	WorkingSetSize.i
	QuotaPeakPagedPoolUsage.i
	QuotaPagedPoolUsage.i
	QuotaPeakNonPagedPoolUsage.i
	QuotaNonPagedPoolUsage.i
	PagefileUsage.i
	PeakPagefileUsage.i
EndStructure

; CPU use is measured in cycles, not with GetProcessTimes(): that one is
; charged per clock tick, and threads that wake up from a Delay(), work a bit
; and sleep again before the next tick (all of BakaShrot's polling) are
; mostly never charged at all.
Prototype.i Proto_QueryProcessCycleTime(Process.i, *Cycles)
Prototype.i Proto_QueryThreadCycleTime(Thread.i, *Cycles)
Prototype.i Proto_QueryIdleProcessorCycleTime(*BufferLength, *Buffer)
Prototype.i Proto_GetProcessMemoryInfo(Process.i, *Counters, Cb.l)

Global Bench_QueryProcessCycleTime.Proto_QueryProcessCycleTime
Global Bench_QueryThreadCycleTime.Proto_QueryThreadCycleTime
Global Bench_QueryIdleProcessorCycleTime.Proto_QueryIdleProcessorCycleTime
Global Bench_GetProcessMemoryInfo.Proto_GetProcessMemoryInfo
Global Bench_CyclesPerMs.d
Global Bench_CpuCount.i
Global Bench_QpcFrequency.q


; --- State -------------------------------------------------------------------

Structure BenchLagSample
	T.d
	Lag.q
EndStructure

Structure BenchServer
	Name.s
	Host.s
	Port.i
	Pid.i
	DatabasePath.s
	FirstNode.i
	MaxNodes.i
	NodeCount.i
	MonitorNode.i
	QueryNode.i
	QueryLoad.i
	Query.i
	; The server's Ed25519 public key, it must prove it holds the private one.
	PublicKey.a[#BakaShrot_Ed25519_PublicKeySize]

	Monitor.BakaShrot_Outbound
	Process.i
	LastCpu.q

	; Latest sample
	Present.q
	Lag.q
	CpuPercent.d
	WorkingSetMb.d
	PrivateMb.d
	DbMb.d
	MonitorMs.d

	; Stage stats
	CpuSumPush.d
	CpuMaxPush.d
	CpuCountPush.i
	CpuSumDrain.d
	CpuMaxDrain.d
	CpuCountDrain.i
	WorkingSetMaxMb.d
	PrivateMaxMb.d
	PresentAtPushStart.q
	LagMaxPush.q
	LagAtPushEnd.q
	MonitorSumMs.d
	MonitorMaxMs.d
	MonitorCount.i
	MonitorFailures.i
	; Every lag sample while pushing, see Bench_TroughSlope().
	List PushLag.BenchLagSample()
EndStructure

Structure BenchPusher
	ServerIndex.i
	NodeId.i
	ThreadId.i
	Ready.i
	ConnectFailed.i
	Sent.q
	Failed.q
	Reconnects.i
	LastError.s
	List LatencyMs.f()
EndStructure

Structure BenchQueryStats
	Name.s
	Sql.s
	List LatencyMs.f()
	Failures.i
	LastError.s
EndStructure

Global Bench_PlanPath.s
Global Bench_TopicId.i
Global Bench_PublicKey.s
Global Dim Bench_PrivateKey.a(#BakaShrot_Ed25519_PrivateKeySize - 1)
Global Bench_PushSeconds.i, Bench_Rate.d, Bench_MessageSize.i
Global Bench_SampleMs.i, Bench_DrainSampleMs.i, Bench_DrainTimeout.i
Global Bench_SamplesCsv.s, Bench_SummaryOut.s, Bench_QueryFile.s, Bench_QueryOut.s
Global Bench_QueryRepeats.i

Global Bench_ServerCount.i
Global Dim Bench_Servers.BenchServer(0)

; Every monitored node, and how many messages of it each server has.
Global Bench_NodeCount.i
Global Dim Bench_Nodes.i(0)
Global Dim Bench_Present.q(0, 0)
Global Bench_MonitorSql.s

Global Bench_PusherCount.i
Global Dim Bench_Pushers.BenchPusher(0)

Global Bench_PushStarted.i, Bench_StopPush.i
Global Bench_StartMs.d

; Query load during the push
Global NewList Bench_LoadStats.BenchQueryStats()

; Sampling
Global Bench_LastSampleMs.d
Global Bench_LastIdleCycles.q
Global Bench_LastSelfCpu.q
Global Bench_SyncInterval.i
Global Bench_SystemCpu.d, Bench_SelfCpu.d
Global Bench_SystemCpuSum.d, Bench_SystemCpuMax.d, Bench_SystemCpuCount.i
Global Bench_SelfCpuSum.d, Bench_SelfCpuCount.i
Global Bench_LastPushed.q
Global Bench_CsvFile.i


Procedure.d Bench_NowMs()
	Protected Count.q
	QueryPerformanceCounter_(@Count)
	ProcedureReturn Count * 1000.0 / Bench_QpcFrequency
EndProcedure


Procedure Bench_Fail(Message.s)
	PrintN("[Bench] " + Message)
	End 1
EndProcedure


; --- Plan --------------------------------------------------------------------

Procedure Bench_LoadPlan(PlanPath.s)
	Protected i.i, n.i, Node.i

	If Not OpenPreferences(PlanPath)
		Bench_Fail("Failed to open the plan '" + PlanPath + "'")
	EndIf

	PreferenceGroup("Bench")
	Bench_PublicKey     = ReadPreferenceString("PublicKey", "")
	Bench_TopicId       = ReadPreferenceLong("TopicId", 1)
	Bench_ServerCount   = ReadPreferenceLong("ServerCount", 0)
	Bench_PushSeconds   = ReadPreferenceLong("PushSeconds", 10)
	Bench_Rate          = ReadPreferenceDouble("Rate", 10)
	Bench_MessageSize   = ReadPreferenceLong("MessageSize", 200)
	Bench_SampleMs      = ReadPreferenceLong("SampleMs", 1000)
	Bench_DrainSampleMs = ReadPreferenceLong("DrainSampleMs", 250)
	Bench_DrainTimeout  = ReadPreferenceLong("DrainTimeout", 120)
	Bench_SyncInterval  = ReadPreferenceLong("PeerSyncInterval", 5)
	Bench_SamplesCsv    = ReadPreferenceString("SamplesCsv", "samples.csv")
	Bench_SummaryOut    = ReadPreferenceString("SummaryOut", "summary.json")
	Bench_QueryFile     = ReadPreferenceString("QueryFile", "")
	Bench_QueryRepeats  = ReadPreferenceLong("QueryRepeats", 5)
	Bench_QueryOut      = ReadPreferenceString("QueryOut", "queries.json")
	If Not DecodeKeyFromString(ReadPreferenceString("PrivateKey", ""), @Bench_PrivateKey(0), #BakaShrot_Ed25519_PrivateKeySize)
		Bench_Fail("Invalid [Bench] PrivateKey")
	EndIf
	If Bench_ServerCount < 1
		Bench_Fail("No servers in the plan")
	EndIf

	Dim Bench_Servers.BenchServer(Bench_ServerCount - 1)
	Bench_NodeCount = 0
	For i = 0 To Bench_ServerCount - 1
		PreferenceGroup("Server" + Str(i + 1))
		With Bench_Servers(i)
			\Name         = ReadPreferenceString("Name", "server" + Str(i + 1))
			\Host         = ReadPreferenceString("Host", "127.0.0.1")
			\Port         = ReadPreferenceLong("Port", 0)
			\Pid          = ReadPreferenceLong("Pid", 0)
			\DatabasePath = ReadPreferenceString("DatabasePath", "")
			\FirstNode    = ReadPreferenceLong("FirstNode", 0)
			\MaxNodes     = ReadPreferenceLong("MaxNodes", 0)
			\NodeCount    = ReadPreferenceLong("NodeCount", 0)
			\MonitorNode  = ReadPreferenceLong("MonitorNode", 0)
			\QueryNode    = ReadPreferenceLong("QueryNode", 0)
			\QueryLoad    = ReadPreferenceLong("QueryLoad", 0)
			\Query        = ReadPreferenceLong("Query", 0)
			If Not DecodeKeyFromString(ReadPreferenceString("PublicKey", ""), @\PublicKey[0], #BakaShrot_Ed25519_PublicKeySize)
				Bench_Fail("Server" + Str(i + 1) + " has no valid PublicKey in the plan")
			EndIf
			If \NodeCount > \MaxNodes
				\MaxNodes = \NodeCount
			EndIf
			Bench_NodeCount + \MaxNodes
		EndWith
	Next
	ClosePreferences()

	If Bench_NodeCount > #Bench_MaxNodes
		Bench_Fail("Too many nodes")
	EndIf

	; Every monitored node, and one query asking a server for all of them.
	; One indexed MAX() per node: cheap, even with millions of rows. By name
	; ("bench", "n" + id, see Bench-Replication.ps1) through the "messages"
	; view: each server can have its own ids for them (-Names Wildcard).
	Dim Bench_Nodes.i(Bench_NodeCount - 1)
	Dim Bench_Present.q(Bench_ServerCount - 1, Bench_NodeCount - 1)
	n = 0
	Bench_MonitorSql = "SELECT "
	For i = 0 To Bench_ServerCount - 1
		For Node = Bench_Servers(i)\FirstNode To Bench_Servers(i)\FirstNode + Bench_Servers(i)\MaxNodes - 1
			Bench_Nodes(n) = Node
			If n > 0
				Bench_MonitorSql + ", "
			EndIf
			Bench_MonitorSql + "(SELECT COALESCE(MAX(message_id), 0) FROM messages WHERE topic = 'bench' AND node = 'n" + Str(Node) + "')"
			n + 1
		Next
	Next
EndProcedure


; --- Requests ----------------------------------------------------------------

Procedure.i Bench_Connect(*Outbound.BakaShrot_Outbound, *Server.BenchServer, NodeId.i)
	Protected Identity.BakaShrot_OutboundIdentity

	Identity\Topic      = Str(Bench_TopicId)
	Identity\Node       = Str(NodeId)
	Identity\PublicKey  = Bench_PublicKey
	Identity\PrivateKey = @Bench_PrivateKey(0)
	ProcedureReturn BakaShrot_Outbound_Connect(*Outbound, *Server\Host, *Server\Port, @Identity, @*Server\PublicKey[0])
EndProcedure


; Sends *Request, returns the answer (free it) or 0 if the connection failed.
Procedure.i Bench_Request(*Outbound.BakaShrot_Outbound, *Request, RequestSize.i, *AnswerSize.Integer)
	If Not BakaShrot_Outbound_Send(*Outbound, *Request, RequestSize)
		ProcedureReturn 0
	EndIf
	ProcedureReturn BakaShrot_Outbound_WaitPacket(*Outbound, *AnswerSize, #Bench_RequestTimeout)
EndProcedure


Procedure.s Bench_RefusalReason(*Answer, AnswerSize.i)
	Protected *View.MsgPackData, *Refused.BakaShrot_RequestRefused, Reason.s

	Reason = "unexpected answer"
	If BakaShrot_GetPacketType(*Answer, AnswerSize) = #BakaShrot_PacketType_RequestRefused
		*Refused = 0
		*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize)
		If *View
			*Refused = BakaShrot_RequestRefusedPacket_Decode(*View)
			MsgPackFree(*View, #False)
		EndIf
		If *Refused
			Reason = "refused: " + *Refused\Reason
			FreeStructure(*Refused)
		EndIf
	EndIf
	ProcedureReturn Reason
EndProcedure


; Runs a query (or "@latest", a GetLatestMessage of NodeId).
; Returns #True with the time it took in *Ms\d, the answer's size in
; *Bytes\i and the JSON result in *Result\s, or #False with *Error\s set.
; Reconnects as ConnectNode if the connection was lost.
Procedure.i Bench_RunQuery(*Outbound.BakaShrot_Outbound, *Server.BenchServer, ConnectNode.i, Sql.s, NodeId.i, *Ms.Double, *Bytes.Integer, *Result.String, *Error.String)
	Protected Request.BakaShrot_QueryRequest, Latest.BakaShrot_GetLatestMessage
	Protected *QueryResult.BakaShrot_QueryResult, *LatestMessage.BakaShrot_LatestMessage
	Protected *Packet, PacketSize.Integer, *Answer, AnswerSize.Integer, *View.MsgPackData
	Protected StartMs.d, Expected.i, Ok.i

	If Not *Outbound\ConnectionId
		If Not Bench_Connect(*Outbound, *Server, ConnectNode)
			*Error\s = "can't connect"
			ProcedureReturn #False
		EndIf
	EndIf

	If Sql = "@latest"
		Latest\Topic = Str(Bench_TopicId)
		Latest\Node  = Str(NodeId)
		*Packet = BakaShrot_GetLatestMessagePacket_Encode(@Latest, @PacketSize)
		Expected = #BakaShrot_PacketType_LatestMessage
	Else
		Request\Sql = Sql
		*Packet = BakaShrot_QueryRequestPacket_Encode(@Request, @PacketSize)
		Expected = #BakaShrot_PacketType_QueryResult
	EndIf
	If Not *Packet
		*Error\s = "can't encode"
		ProcedureReturn #False
	EndIf

	StartMs = Bench_NowMs()
	*Answer = Bench_Request(*Outbound, *Packet, PacketSize\i, @AnswerSize)
	*Ms\d = Bench_NowMs() - StartMs
	FreeMemory(*Packet)

	If Not *Answer
		BakaShrot_Outbound_Close(*Outbound, #BakaShrot_ConnectionStatus_Aborted)
		*Error\s = "connection lost"
		ProcedureReturn #False
	EndIf

	*Bytes\i = AnswerSize\i
	If BakaShrot_GetPacketType(*Answer, AnswerSize\i) <> Expected
		*Error\s = Bench_RefusalReason(*Answer, AnswerSize\i)
		FreeMemory(*Answer)
		ProcedureReturn #False
	EndIf

	Ok = #False
	*View = MsgPackWrapMsgBuffer(*Answer, AnswerSize\i)
	If *View
		If Expected = #BakaShrot_PacketType_QueryResult
			*QueryResult = BakaShrot_QueryResultPacket_Decode(*View)
			If *QueryResult
				*Result\s = *QueryResult\JsonResult
				FreeStructure(*QueryResult)
				Ok = #True
			EndIf
		Else
			*LatestMessage = BakaShrot_LatestMessagePacket_Decode(*View)
			If *LatestMessage
				*Result\s = ~"{\"columns\": [\"message_id\"], \"rows\": [[\"" + Str(*LatestMessage\MessageId) + ~"\"]]}"
				FreeStructure(*LatestMessage)
				Ok = #True
			EndIf
		EndIf
		MsgPackFree(*View, #False)
	EndIf
	FreeMemory(*Answer)

	If Not Ok
		*Error\s = "can't decode the answer"
	EndIf
	ProcedureReturn Ok
EndProcedure


; Number of rows in a query's JSON result, -1 if it can't be parsed.
Procedure.i Bench_CountRows(Result.s)
	Protected JsonId.i, *Rows, Count.i = -1

	JsonId = ParseJSON(#PB_Any, Result)
	If JsonId
		*Rows = GetJSONMember(JSONValue(JsonId), "rows")
		If *Rows
			Count = JSONArraySize(*Rows)
		EndIf
		FreeJSON(JsonId)
	EndIf
	ProcedureReturn Count
EndProcedure


; Loads the query file into Queries().
Procedure Bench_LoadQueries(Path.s, List Queries.BenchQueryStats())
	Protected FileId.i, Line.s, Separator.i

	ClearList(Queries())
	If Path = ""
		ProcedureReturn
	EndIf
	FileId = ReadFile(#PB_Any, Path)
	If Not FileId
		Bench_Fail("Failed to open the query file '" + Path + "'")
	EndIf
	While Not Eof(FileId)
		Line = Trim(ReadString(FileId, #PB_UTF8))
		If Line = "" Or Left(Line, 1) = "#"
			Continue
		EndIf
		Separator = FindString(Line, "|")
		If Separator < 2
			Continue
		EndIf
		AddElement(Queries())
		Queries()\Name = Trim(Left(Line, Separator - 1))
		Queries()\Sql  = Trim(Mid(Line, Separator + 1))
	Wend
	CloseFile(FileId)
EndProcedure


Procedure.s Bench_ExpandSql(Sql.s, *Server.BenchServer)
	Sql = ReplaceString(Sql, "{TOPIC}", Str(Bench_TopicId))
	Sql = ReplaceString(Sql, "{NODE}", Str(*Server\FirstNode))
	ProcedureReturn Sql
EndProcedure


; --- Pushers -----------------------------------------------------------------

Procedure Bench_PusherThread(*Pusher.BenchPusher)
	Protected *Server.BenchServer = @Bench_Servers(*Pusher\ServerIndex)
	Protected Outbound.BakaShrot_Outbound
	Protected Push.BakaShrot_PushMessage
	Protected *Request, RequestSize.Integer, *Answer, AnswerSize.Integer
	Protected Attempt.i, Seq.q, Kind.s, Pad.s, Json.s, Spread.i, Value.i
	Protected IntervalMs.d, NextDueMs.d, NowMs.d, StartMs.d, LatencyMs.d

	For Attempt = 1 To 5
		If Bench_Connect(@Outbound, *Server, *Pusher\NodeId)
			Break
		EndIf
		Delay(200 * Attempt)
	Next
	If Not Outbound\ConnectionId
		*Pusher\ConnectFailed = #True
		*Pusher\LastError = "can't connect"
		*Pusher\Ready = #True
		ProcedureReturn
	EndIf
	*Pusher\Ready = #True

	; About MessageSize bytes of JSON, ~90 without the padding.
	If Bench_MessageSize > 90
		Pad = LSet("", Bench_MessageSize - 90, "x")
	EndIf

	While Not Bench_PushStarted And Not Bench_StopPush
		Delay(1)
	Wend

	If Bench_Rate > 0
		IntervalMs = 1000.0 / Bench_Rate
		; Spread the nodes' pushes over the interval.
		Spread = *Pusher\NodeId % 97
		NextDueMs = Bench_NowMs() + IntervalMs * Spread / 97.0
	EndIf

	While Not Bench_StopPush
		If Bench_Rate > 0
			NowMs = Bench_NowMs()
			If NowMs < NextDueMs
				Delay(1)
				Continue
			EndIf
			NextDueMs + IntervalMs
			; More than a second behind: the server can't keep up, don't
			; build up a backlog to burst later.
			If NowMs - NextDueMs > 1000
				NextDueMs = NowMs
			EndIf
		EndIf

		Seq + 1
		If Seq % 50 = 0
			Kind = "alert"
		Else
			Select Seq % 4
				Case 0 : Kind = "temp"
				Case 1 : Kind = "humidity"
				Case 2 : Kind = "pressure"
				Default : Kind = "status"
			EndSelect
		EndIf
		Value = (Seq * 7919 + *Pusher\NodeId) % 10000
		Json = ~"{\"kind\":\"" + Kind + ~"\",\"node\":" + Str(*Pusher\NodeId) + ~",\"seq\":" + Str(Seq) +
		       ~",\"value\":" + StrD(Value / 100.0, 2) +
		       ~",\"ts\":" + Str(Date()) + ~",\"pad\":\"" + Pad + ~"\"}"

		Push\JsonData = Json
		*Request = BakaShrot_PushMessagePacket_Encode(@Push, @RequestSize)
		If Not *Request
			*Pusher\Failed + 1
			*Pusher\LastError = "can't encode"
			Continue
		EndIf

		StartMs = Bench_NowMs()
		*Answer = Bench_Request(@Outbound, *Request, RequestSize\i, @AnswerSize)
		LatencyMs = Bench_NowMs() - StartMs
		FreeMemory(*Request)

		If Not *Answer
			*Pusher\Failed + 1
			*Pusher\LastError = "connection lost"
			BakaShrot_Outbound_Close(@Outbound, #BakaShrot_ConnectionStatus_Aborted)
			*Pusher\Reconnects + 1
			If Not Bench_Connect(@Outbound, *Server, *Pusher\NodeId)
				Delay(500)
				If Not Bench_Connect(@Outbound, *Server, *Pusher\NodeId)
					*Pusher\LastError = "connection lost, can't reconnect"
					Break
				EndIf
			EndIf
			Continue
		EndIf

		If BakaShrot_GetPacketType(*Answer, AnswerSize\i) = #BakaShrot_PacketType_MessagePushed
			AddElement(*Pusher\LatencyMs())
			*Pusher\LatencyMs() = LatencyMs
			*Pusher\Sent + 1
		Else
			*Pusher\Failed + 1
			*Pusher\LastError = Bench_RefusalReason(*Answer, AnswerSize\i)
		EndIf
		FreeMemory(*Answer)
	Wend

	BakaShrot_Outbound_Close(@Outbound, #BakaShrot_ConnectionStatus_Disconnected)
EndProcedure


; Runs the query file in a loop against the QueryLoad servers until the push
; ends.
Procedure Bench_QueryLoadThread(Unused.i)
	Protected NewList Queries.BenchQueryStats()
	Protected Dim Outbounds.BakaShrot_Outbound(Bench_ServerCount - 1)
	Protected i.i, Ms.Double, Bytes.Integer, Result.String, Error.String, Sql.s

	While Not Bench_PushStarted And Not Bench_StopPush
		Delay(1)
	Wend

	While Not Bench_StopPush
		ForEach Bench_LoadStats()
			For i = 0 To Bench_ServerCount - 1
				If Not Bench_Servers(i)\QueryLoad
					Continue
				EndIf
				If Bench_StopPush
					Break 2
				EndIf
				Sql = Bench_ExpandSql(Bench_LoadStats()\Sql, @Bench_Servers(i))
				If Bench_RunQuery(@Outbounds(i), @Bench_Servers(i), Bench_Servers(i)\QueryNode, Sql, Bench_Servers(i)\FirstNode, @Ms, @Bytes, @Result, @Error)
					AddElement(Bench_LoadStats()\LatencyMs())
					Bench_LoadStats()\LatencyMs() = Ms\d
				Else
					Bench_LoadStats()\Failures + 1
					Bench_LoadStats()\LastError = Error\s
				EndIf
			Next
		Next
		Delay(100)
	Wend

	For i = 0 To Bench_ServerCount - 1
		BakaShrot_Outbound_Close(@Outbounds(i), #BakaShrot_ConnectionStatus_Disconnected)
	Next
EndProcedure


; --- Sampling ----------------------------------------------------------------

Procedure.q Bench_ProcessCycles(Process.i)
	Protected Cycles.q
	If Not Bench_QueryProcessCycleTime(Process, @Cycles)
		ProcedureReturn 0
	EndIf
	ProcedureReturn Cycles
EndProcedure


; Idle cycles of every processor, summed.
Procedure.q Bench_IdleCycles()
	Protected Dim Buffer.q(255), Size.l, i.i, Total.q

	Size = 256 * SizeOf(Quad)
	If Bench_QueryIdleProcessorCycleTime(@Size, @Buffer(0))
		Bench_CpuCount = Size / SizeOf(Quad)
		For i = 0 To Bench_CpuCount - 1
			Total + Buffer(i)
		Next
	EndIf
	ProcedureReturn Total
EndProcedure


; How many cycles a busy processor counts per ms: spins a few times for
; 200 ms, keeps the best (the least preempted).
Procedure Bench_CalibrateCycles()
	Protected Attempt.i, StartMs.d, NowMs.d, Start.q, Finish.q, Rate.d

	For Attempt = 1 To 3
		Bench_QueryThreadCycleTime(GetCurrentThread_(), @Start)
		StartMs = Bench_NowMs()
		Repeat
			NowMs = Bench_NowMs()
		Until NowMs - StartMs >= 200
		Bench_QueryThreadCycleTime(GetCurrentThread_(), @Finish)
		Rate = (Finish - Start) / (NowMs - StartMs)
		If Rate > Bench_CyclesPerMs
			Bench_CyclesPerMs = Rate
		EndIf
	Next
EndProcedure


Procedure Bench_InitSampling()
	Protected Kernel32.i, i.i

	Kernel32 = OpenLibrary(#PB_Any, "kernel32.dll")
	If Not Kernel32
		Bench_Fail("Can't open kernel32.dll")
	EndIf
	Bench_QueryProcessCycleTime       = GetFunction(Kernel32, "QueryProcessCycleTime")
	Bench_QueryThreadCycleTime        = GetFunction(Kernel32, "QueryThreadCycleTime")
	Bench_QueryIdleProcessorCycleTime = GetFunction(Kernel32, "QueryIdleProcessorCycleTime")
	Bench_GetProcessMemoryInfo        = GetFunction(Kernel32, "K32GetProcessMemoryInfo")
	If Not Bench_QueryProcessCycleTime Or Not Bench_QueryThreadCycleTime Or Not Bench_QueryIdleProcessorCycleTime Or Not Bench_GetProcessMemoryInfo
		Bench_Fail("Missing kernel32 functions")
	EndIf

	Bench_CalibrateCycles()
	Bench_LastIdleCycles = Bench_IdleCycles()
	Bench_LastSelfCpu    = Bench_ProcessCycles(GetCurrentProcess_())

	For i = 0 To Bench_ServerCount - 1
		With Bench_Servers(i)
			If \Pid
				; PROCESS_QUERY_INFORMATION | PROCESS_VM_READ
				\Process = OpenProcess_($0400 | $0010, 0, \Pid)
				If \Process
					\LastCpu = Bench_ProcessCycles(\Process)
				Else
					PrintN("[Bench] Can't open the process of '" + \Name + "' (pid " + Str(\Pid) + "), no CPU/RAM for it")
				EndIf
			EndIf
		EndWith
	Next
	Bench_LastSampleMs = Bench_NowMs()
EndProcedure


Procedure Bench_WriteCsvHeader()
	Protected Line.s, i.i, Prefix.s

	Bench_CsvFile = CreateFile(#PB_Any, Bench_SamplesCsv)
	If Not Bench_CsvFile
		Bench_Fail("Can't create '" + Bench_SamplesCsv + "'")
	EndIf
	Line = "t_s,phase,pushed,push_rate,system_cpu,bench_cpu"
	For i = 0 To Bench_ServerCount - 1
		Prefix = Bench_Servers(i)\Name + "_"
		Line + "," + Prefix + "present," + Prefix + "lag," + Prefix + "cpu," + Prefix + "ws_mb," + Prefix + "private_mb," + Prefix + "db_mb," + Prefix + "monitor_ms"
	Next
	WriteStringN(Bench_CsvFile, Line)
EndProcedure


Procedure.q Bench_TotalPushed()
	Protected i.i, Total.q
	For i = 0 To Bench_PusherCount - 1
		Total + Bench_Pushers(i)\Sent
	Next
	ProcedureReturn Total
EndProcedure


; Phase: "push", "push-end" or "drain". Returns the total lag of every server.
Procedure.q Bench_Sample(Phase.s)
	Protected NowMs.d, ElapsedS.d, IntervalMs.d, i.i, n.i
	Protected Idle.q, Cpu.q, BusyCycles.d
	Protected Counters.BenchMemoryCounters
	Protected Ms.Double, Bytes.Integer, Result.String, Error.String
	Protected JsonId.i, *Row, *Value, Expected.q, TotalLag.q, Pushed.q, PushRate.d, Line.s

	NowMs      = Bench_NowMs()
	IntervalMs = NowMs - Bench_LastSampleMs
	If IntervalMs < 1
		IntervalMs = 1
	EndIf
	Bench_LastSampleMs = NowMs
	ElapsedS = (NowMs - Bench_StartMs) / 1000.0

	; Machine and self CPU
	; Cycles a fully busy processor would have counted meanwhile.
	BusyCycles = Bench_CyclesPerMs * IntervalMs
	Idle = Bench_IdleCycles()
	If Bench_CpuCount > 0
		Bench_SystemCpu = 100.0 * (1.0 - (Idle - Bench_LastIdleCycles) / (BusyCycles * Bench_CpuCount))
		If Bench_SystemCpu < 0
			Bench_SystemCpu = 0
		EndIf
	EndIf
	Bench_LastIdleCycles = Idle
	Cpu = Bench_ProcessCycles(GetCurrentProcess_())
	Bench_SelfCpu = 100.0 * (Cpu - Bench_LastSelfCpu) / BusyCycles
	Bench_LastSelfCpu = Cpu

	For i = 0 To Bench_ServerCount - 1
		With Bench_Servers(i)
			If \Process
				Cpu = Bench_ProcessCycles(\Process)
				\CpuPercent = 100.0 * (Cpu - \LastCpu) / BusyCycles
				\LastCpu = Cpu
				Counters\cb = SizeOf(BenchMemoryCounters)
				If Bench_GetProcessMemoryInfo(\Process, @Counters, SizeOf(BenchMemoryCounters))
					\WorkingSetMb = Counters\WorkingSetSize / 1048576.0
					\PrivateMb    = Counters\PagefileUsage / 1048576.0
				EndIf
			EndIf
			If \DatabasePath <> ""
				\DbMb = FileSize(\DatabasePath) / 1048576.0
			EndIf

			; How many messages of every node it has.
			If Bench_RunQuery(@\Monitor, @Bench_Servers(i), \MonitorNode, Bench_MonitorSql, 0, @Ms, @Bytes, @Result, @Error)
				\MonitorMs = Ms\d
				\MonitorSumMs + Ms\d
				\MonitorCount + 1
				If Ms\d > \MonitorMaxMs
					\MonitorMaxMs = Ms\d
				EndIf
				JsonId = ParseJSON(#PB_Any, Result\s)
				If JsonId
					*Row = GetJSONElement(GetJSONMember(JSONValue(JsonId), "rows"), 0)
					If *Row
						For n = 0 To Bench_NodeCount - 1
							*Value = GetJSONElement(*Row, n)
							If *Value And JSONType(*Value) = #PB_JSON_String
								Bench_Present(i, n) = Val(GetJSONString(*Value))
							EndIf
						Next
					EndIf
					FreeJSON(JsonId)
				EndIf
			Else
				\MonitorMs = -1
				\MonitorFailures + 1
				PrintN("[Bench] Monitor query on '" + \Name + "' failed: " + Error\s)
			EndIf
		EndWith
	Next

	; A node's messages are only pushed to its own server, so whoever has the
	; most has all of them so far.
	For i = 0 To Bench_ServerCount - 1
		Bench_Servers(i)\Present = 0
		Bench_Servers(i)\Lag     = 0
	Next
	For n = 0 To Bench_NodeCount - 1
		Expected = 0
		For i = 0 To Bench_ServerCount - 1
			If Bench_Present(i, n) > Expected
				Expected = Bench_Present(i, n)
			EndIf
		Next
		For i = 0 To Bench_ServerCount - 1
			Bench_Servers(i)\Present + Bench_Present(i, n)
			Bench_Servers(i)\Lag     + Expected - Bench_Present(i, n)
		Next
	Next

	Pushed   = Bench_TotalPushed()
	PushRate = (Pushed - Bench_LastPushed) * 1000.0 / IntervalMs
	Bench_LastPushed = Pushed

	; Stats
	If Phase = "push"
		Bench_SystemCpuSum + Bench_SystemCpu
		Bench_SystemCpuCount + 1
		If Bench_SystemCpu > Bench_SystemCpuMax
			Bench_SystemCpuMax = Bench_SystemCpu
		EndIf
		Bench_SelfCpuSum + Bench_SelfCpu
		Bench_SelfCpuCount + 1
	EndIf
	For i = 0 To Bench_ServerCount - 1
		With Bench_Servers(i)
			TotalLag + \Lag
			If \WorkingSetMb > \WorkingSetMaxMb
				\WorkingSetMaxMb = \WorkingSetMb
			EndIf
			If \PrivateMb > \PrivateMaxMb
				\PrivateMaxMb = \PrivateMb
			EndIf
			If Phase = "push"
				\CpuSumPush + \CpuPercent
				\CpuCountPush + 1
				If \CpuPercent > \CpuMaxPush
					\CpuMaxPush = \CpuPercent
				EndIf
				If \Lag > \LagMaxPush
					\LagMaxPush = \Lag
				EndIf
				AddElement(\PushLag())
				\PushLag()\T   = ElapsedS
				\PushLag()\Lag = \Lag
			ElseIf Phase = "push-end"
				\LagAtPushEnd = \Lag
				If \Lag > \LagMaxPush
					\LagMaxPush = \Lag
				EndIf
			Else
				\CpuSumDrain + \CpuPercent
				\CpuCountDrain + 1
				If \CpuPercent > \CpuMaxDrain
					\CpuMaxDrain = \CpuPercent
				EndIf
			EndIf
		EndWith
	Next

	Line = StrD(ElapsedS, 3) + "," + Phase + "," + Str(Pushed) + "," + StrD(PushRate, 1) + "," + StrD(Bench_SystemCpu, 1) + "," + StrD(Bench_SelfCpu, 1)
	For i = 0 To Bench_ServerCount - 1
		With Bench_Servers(i)
			Line + "," + Str(\Present) + "," + Str(\Lag) + "," + StrD(\CpuPercent, 1) + "," + StrD(\WorkingSetMb, 1) + "," + StrD(\PrivateMb, 1) + "," + StrD(\DbMb, 2) + "," + StrD(\MonitorMs, 1)
		EndWith
	Next
	WriteStringN(Bench_CsvFile, Line)

	ProcedureReturn TotalLag
EndProcedure


; --- Stats helpers -----------------------------------------------------------

; Fills Sorted() from Values() and sorts it.
Procedure Bench_Sorted(List Values.f(), Array Sorted.f(1))
	Protected n.i

	If ListSize(Values()) = 0
		Dim Sorted.f(0)
		ProcedureReturn
	EndIf
	Dim Sorted.f(ListSize(Values()) - 1)
	ForEach Values()
		Sorted(n) = Values()
		n + 1
	Next
	SortArray(Sorted(), #PB_Sort_Ascending)
EndProcedure

Procedure.d Bench_Percentile(Array Sorted.f(1), Count.i, P.d)
	If Count = 0
		ProcedureReturn 0
	EndIf
	ProcedureReturn Sorted(Int((Count - 1) * P))
EndProcedure

Procedure.d Bench_Average(Array Sorted.f(1), Count.i)
	Protected i.i, Sum.d
	If Count = 0
		ProcedureReturn 0
	EndIf
	For i = 0 To Count - 1
		Sum + Sorted(i)
	Next
	ProcedureReturn Sum / Count
EndProcedure

Procedure Bench_AddLatencyStats(*Object, Prefix.s, List Values.f())
	Protected Dim Sorted.f(0), Count.i = ListSize(Values())

	Bench_Sorted(Values(), Sorted())
	SetJSONInteger(AddJSONMember(*Object, Prefix + "Count"), Count)
	SetJSONDouble(AddJSONMember(*Object, Prefix + "AvgMs"), Bench_Average(Sorted(), Count))
	SetJSONDouble(AddJSONMember(*Object, Prefix + "P50Ms"), Bench_Percentile(Sorted(), Count, 0.50))
	SetJSONDouble(AddJSONMember(*Object, Prefix + "P90Ms"), Bench_Percentile(Sorted(), Count, 0.90))
	SetJSONDouble(AddJSONMember(*Object, Prefix + "P99Ms"), Bench_Percentile(Sorted(), Count, 0.99))
	If Count > 0
		SetJSONDouble(AddJSONMember(*Object, Prefix + "MaxMs"), Sorted(Count - 1))
		SetJSONDouble(AddJSONMember(*Object, Prefix + "MinMs"), Sorted(0))
	Else
		SetJSONDouble(AddJSONMember(*Object, Prefix + "MaxMs"), 0)
		SetJSONDouble(AddJSONMember(*Object, Prefix + "MinMs"), 0)
	EndIf
EndProcedure


; Replication catches up in bursts, once per check-in (every PeerSyncInterval
; plus the catch-up's own time), and a message pushed to a leaf needs two
; check-ins to reach the other leaves through the hub, so the lag is a
; sawtooth. Whether it keeps up shows in its troughs: the lowest lag of every
; window of two check-ins. Returns how fast they rise, in messages per second
; (~0 keeps up, > 0 falls further behind every check-in), and the last full
; window's trough in *LastTrough\q. Needs a push of 3+ windows to mean much.
Procedure.d Bench_TroughSlope(List Samples.BenchLagSample(), *LastTrough.Quad)
	Protected Window.d, Index.i, LastIndex.i, n.d, SumT.d, SumL.d, SumTT.d, SumTL.d, Denominator.d
	Protected NewMap Troughs.q(), NewMap Centers.d()

	*LastTrough\q = 0
	Window = 2 * Bench_SyncInterval
	If Window <= 0
		Window = 10
	EndIf

	LastIndex = -1
	ForEach Samples()
		Index = Int(Samples()\T / Window)
		If Not FindMapElement(Troughs(), Str(Index)) Or Samples()\Lag < Troughs(Str(Index))
			Troughs(Str(Index)) = Samples()\Lag
		EndIf
		Centers(Str(Index)) = (Index + 0.5) * Window
		If Index > LastIndex
			LastIndex = Index
		EndIf
	Next

	; The last window is usually cut short by the end of the push.
	ForEach Troughs()
		If Val(MapKey(Troughs())) = LastIndex And MapSize(Troughs()) > 1
			Continue
		EndIf
		n + 1
		SumT  + Centers(MapKey(Troughs()))
		SumL  + Troughs()
		SumTT + Centers(MapKey(Troughs())) * Centers(MapKey(Troughs()))
		SumTL + Centers(MapKey(Troughs())) * Troughs()
		If Val(MapKey(Troughs())) = LastIndex - 1 Or MapSize(Troughs()) = 1
			*LastTrough\q = Troughs()
		EndIf
	Next

	Denominator = n * SumTT - SumT * SumT
	If n < 2 Or Denominator = 0
		ProcedureReturn 0
	EndIf
	ProcedureReturn (n * SumTL - SumT * SumL) / Denominator
EndProcedure


; --- run ---------------------------------------------------------------------

Procedure Bench_Run()
	Protected i.i, n.i, Node.i, NextSampleMs.d, PushEndMs.d, DrainMs.d, TotalLag.q
	Protected QueryThread.i, Connected.i, ConnectFailures.i, Pushed.q, Failed.q, Reconnects.i
	Protected JsonId.i, *Root, *Servers, *Server, *Queries, *Query, *Errors
	Protected NewList AllLatencies.f(), NewMap Errors.i()
	Protected PushMs.d, PushRate.d, Trough.Quad

	; Everyone's identity in place, nothing pushing yet.
	Bench_InitSampling()
	Bench_WriteCsvHeader()

	For i = 0 To Bench_ServerCount - 1
		If Not Bench_Connect(@Bench_Servers(i)\Monitor, @Bench_Servers(i), Bench_Servers(i)\MonitorNode)
			Bench_Fail("Can't connect the monitor to '" + Bench_Servers(i)\Name + "'")
		EndIf
	Next

	Bench_PusherCount = 0
	For i = 0 To Bench_ServerCount - 1
		Bench_PusherCount + Bench_Servers(i)\NodeCount
	Next
	If Bench_PusherCount > 0
		Dim Bench_Pushers.BenchPusher(Bench_PusherCount - 1)
	EndIf
	n = 0
	For i = 0 To Bench_ServerCount - 1
		For Node = Bench_Servers(i)\FirstNode To Bench_Servers(i)\FirstNode + Bench_Servers(i)\NodeCount - 1
			Bench_Pushers(n)\ServerIndex = i
			Bench_Pushers(n)\NodeId      = Node
			Bench_Pushers(n)\ThreadId    = CreateThread(@Bench_PusherThread(), @Bench_Pushers(n))
			If Not Bench_Pushers(n)\ThreadId
				Bench_Fail("Can't start a pusher thread")
			EndIf
			n + 1
		Next
	Next

	Bench_LoadQueries(Bench_QueryFile, Bench_LoadStats())
	If ListSize(Bench_LoadStats()) > 0
		For i = 0 To Bench_ServerCount - 1
			If Bench_Servers(i)\QueryLoad
				QueryThread = CreateThread(@Bench_QueryLoadThread(), 0)
				Break
			EndIf
		Next
	EndIf

	; Wait for every pusher to be connected.
	Repeat
		Connected = 0
		For i = 0 To Bench_PusherCount - 1
			If Bench_Pushers(i)\Ready
				Connected + 1
			EndIf
		Next
		If Connected = Bench_PusherCount
			Break
		EndIf
		Delay(10)
	ForEver
	For i = 0 To Bench_PusherCount - 1
		If Bench_Pushers(i)\ConnectFailed
			ConnectFailures + 1
		EndIf
	Next
	PrintN("[Bench] " + Str(Bench_PusherCount - ConnectFailures) + "/" + Str(Bench_PusherCount) + " pushers connected, pushing for " + Str(Bench_PushSeconds) + " s at " + StrD(Bench_Rate, 1) + " msg/s each")

	; Baseline, then go.
	Bench_StartMs = Bench_NowMs()
	Bench_Sample("start")
	For i = 0 To Bench_ServerCount - 1
		Bench_Servers(i)\PresentAtPushStart = Bench_Servers(i)\Present
	Next
	Bench_StartMs = Bench_NowMs()
	Bench_LastPushed = 0
	Bench_PushStarted = #True

	NextSampleMs = Bench_StartMs + Bench_SampleMs
	While Bench_NowMs() - Bench_StartMs < Bench_PushSeconds * 1000.0
		If Bench_NowMs() >= NextSampleMs
			Bench_Sample("push")
			NextSampleMs + Bench_SampleMs
		EndIf
		Delay(5)
	Wend
	Bench_StopPush = #True
	PushEndMs = Bench_NowMs()
	For i = 0 To Bench_PusherCount - 1
		If Bench_Pushers(i)\ThreadId
			WaitThread(Bench_Pushers(i)\ThreadId)
		EndIf
	Next
	If QueryThread
		WaitThread(QueryThread)
	EndIf
	PushMs = Bench_NowMs() - Bench_StartMs
	Pushed = Bench_TotalPushed()
	PushRate = Pushed * 1000.0 / PushMs
	PrintN("[Bench] Pushed " + Str(Pushed) + " in " + StrD(PushMs / 1000.0, 1) + " s (" + StrD(PushRate, 1) + " msg/s), draining")

	; Drain
	TotalLag = Bench_Sample("push-end")
	DrainMs = -1
	If TotalLag = 0
		DrainMs = Bench_NowMs() - PushEndMs
	Else
		NextSampleMs = Bench_NowMs() + Bench_DrainSampleMs
		While Bench_NowMs() - PushEndMs < Bench_DrainTimeout * 1000.0
			If Bench_NowMs() >= NextSampleMs
				TotalLag = Bench_Sample("drain")
				If TotalLag = 0
					DrainMs = Bench_NowMs() - PushEndMs
					Break
				EndIf
				NextSampleMs + Bench_DrainSampleMs
			EndIf
			Delay(5)
		Wend
	EndIf
	CloseFile(Bench_CsvFile)

	If DrainMs >= 0
		PrintN("[Bench] Drained in " + StrD(DrainMs / 1000.0, 2) + " s")
	Else
		PrintN("[Bench] NOT drained after " + Str(Bench_DrainTimeout) + " s, " + Str(TotalLag) + " messages still missing")
	EndIf

	; Summary
	For i = 0 To Bench_PusherCount - 1
		Failed + Bench_Pushers(i)\Failed
		Reconnects + Bench_Pushers(i)\Reconnects
		ForEach Bench_Pushers(i)\LatencyMs()
			AddElement(AllLatencies())
			AllLatencies() = Bench_Pushers(i)\LatencyMs()
		Next
		If Bench_Pushers(i)\LastError <> ""
			Errors(Bench_Pushers(i)\LastError) + 1
		EndIf
	Next

	JsonId = CreateJSON(#PB_Any)
	*Root = SetJSONObject(JSONValue(JsonId))
	SetJSONDouble(AddJSONMember(*Root, "Rate"), Bench_Rate)
	SetJSONInteger(AddJSONMember(*Root, "Pushers"), Bench_PusherCount)
	SetJSONInteger(AddJSONMember(*Root, "ConnectFailures"), ConnectFailures)
	SetJSONInteger(AddJSONMember(*Root, "MessageSize"), Bench_MessageSize)
	SetJSONDouble(AddJSONMember(*Root, "PushSeconds"), PushMs / 1000.0)
	SetJSONDouble(AddJSONMember(*Root, "OfferedRate"), Bench_Rate * Bench_PusherCount)
	SetJSONInteger(AddJSONMember(*Root, "Pushed"), Pushed)
	SetJSONInteger(AddJSONMember(*Root, "Failed"), Failed)
	SetJSONInteger(AddJSONMember(*Root, "Reconnects"), Reconnects)
	SetJSONDouble(AddJSONMember(*Root, "PushRate"), PushRate)
	Bench_AddLatencyStats(*Root, "Push", AllLatencies())
	SetJSONDouble(AddJSONMember(*Root, "DrainSeconds"), DrainMs / 1000.0)
	SetJSONBoolean(AddJSONMember(*Root, "Drained"), Bool(DrainMs >= 0))
	SetJSONInteger(AddJSONMember(*Root, "LagAtTimeout"), TotalLag)
	SetJSONInteger(AddJSONMember(*Root, "CpuCount"), Bench_CpuCount)
	SetJSONDouble(AddJSONMember(*Root, "CyclesPerMs"), Bench_CyclesPerMs)
	If Bench_SystemCpuCount > 0
		SetJSONDouble(AddJSONMember(*Root, "SystemCpuAvg"), Bench_SystemCpuSum / Bench_SystemCpuCount)
		SetJSONDouble(AddJSONMember(*Root, "BenchCpuAvg"), Bench_SelfCpuSum / Bench_SelfCpuCount)
	Else
		SetJSONDouble(AddJSONMember(*Root, "SystemCpuAvg"), 0)
		SetJSONDouble(AddJSONMember(*Root, "BenchCpuAvg"), 0)
	EndIf
	SetJSONDouble(AddJSONMember(*Root, "SystemCpuMax"), Bench_SystemCpuMax)

	*Errors = SetJSONObject(AddJSONMember(*Root, "Errors"))
	ForEach Errors()
		SetJSONInteger(AddJSONMember(*Errors, MapKey(Errors())), Errors())
	Next

	*Servers = SetJSONArray(AddJSONMember(*Root, "Servers"))
	For i = 0 To Bench_ServerCount - 1
		With Bench_Servers(i)
			*Server = SetJSONObject(AddJSONElement(*Servers))
			SetJSONString(AddJSONMember(*Server, "Name"), \Name)
			SetJSONInteger(AddJSONMember(*Server, "Nodes"), \NodeCount)
			SetJSONInteger(AddJSONMember(*Server, "Rows"), \Present)
			SetJSONDouble(AddJSONMember(*Server, "ReceiveRate"), (\Present - \PresentAtPushStart) * 1000.0 / PushMs)
			If \CpuCountPush > 0
				SetJSONDouble(AddJSONMember(*Server, "CpuAvgPush"), \CpuSumPush / \CpuCountPush)
			Else
				SetJSONDouble(AddJSONMember(*Server, "CpuAvgPush"), 0)
			EndIf
			SetJSONDouble(AddJSONMember(*Server, "CpuMaxPush"), \CpuMaxPush)
			If \CpuCountDrain > 0
				SetJSONDouble(AddJSONMember(*Server, "CpuAvgDrain"), \CpuSumDrain / \CpuCountDrain)
			Else
				SetJSONDouble(AddJSONMember(*Server, "CpuAvgDrain"), 0)
			EndIf
			SetJSONDouble(AddJSONMember(*Server, "WorkingSetMaxMb"), \WorkingSetMaxMb)
			SetJSONDouble(AddJSONMember(*Server, "PrivateMaxMb"), \PrivateMaxMb)
			SetJSONDouble(AddJSONMember(*Server, "DbMb"), \DbMb)
			SetJSONInteger(AddJSONMember(*Server, "LagMaxPush"), \LagMaxPush)
			; How many seconds of pushes that was.
			If PushRate > 0
				SetJSONDouble(AddJSONMember(*Server, "LagMaxSeconds"), \LagMaxPush / PushRate)
			Else
				SetJSONDouble(AddJSONMember(*Server, "LagMaxSeconds"), 0)
			EndIf
			SetJSONInteger(AddJSONMember(*Server, "LagAtPushEnd"), \LagAtPushEnd)
			; Messages per second it falls further behind, over the push's
			; second half. ~0 keeps up, > 0 doesn't.
			SetJSONDouble(AddJSONMember(*Server, "LagSlope"), Bench_TroughSlope(\PushLag(), @Trough))
			SetJSONInteger(AddJSONMember(*Server, "LagTroughLast"), Trough\q)
			If \MonitorCount > 0
				SetJSONDouble(AddJSONMember(*Server, "MonitorAvgMs"), \MonitorSumMs / \MonitorCount)
			Else
				SetJSONDouble(AddJSONMember(*Server, "MonitorAvgMs"), 0)
			EndIf
			SetJSONDouble(AddJSONMember(*Server, "MonitorMaxMs"), \MonitorMaxMs)
			SetJSONInteger(AddJSONMember(*Server, "MonitorFailures"), \MonitorFailures)
		EndWith
	Next

	*Queries = SetJSONArray(AddJSONMember(*Root, "QueriesUnderLoad"))
	ForEach Bench_LoadStats()
		*Query = SetJSONObject(AddJSONElement(*Queries))
		SetJSONString(AddJSONMember(*Query, "Name"), Bench_LoadStats()\Name)
		Bench_AddLatencyStats(*Query, "", Bench_LoadStats()\LatencyMs())
		SetJSONInteger(AddJSONMember(*Query, "Failures"), Bench_LoadStats()\Failures)
		SetJSONString(AddJSONMember(*Query, "LastError"), Bench_LoadStats()\LastError)
	Next

	If Not SaveJSON(JsonId, Bench_SummaryOut, #PB_JSON_PrettyPrint)
		Bench_Fail("Can't write '" + Bench_SummaryOut + "'")
	EndIf
	FreeJSON(JsonId)

	For i = 0 To Bench_ServerCount - 1
		BakaShrot_Outbound_Close(@Bench_Servers(i)\Monitor, #BakaShrot_ConnectionStatus_Disconnected)
		If Bench_Servers(i)\Process
			CloseHandle_(Bench_Servers(i)\Process)
		EndIf
	Next
EndProcedure


; --- query -------------------------------------------------------------------

Procedure Bench_Query()
	Protected NewList Queries.BenchQueryStats()
	Protected i.i, r.i, Sql.s, Ms.Double, Bytes.Integer, Result.String, Error.String, Ok.i, Rows.i
	Protected JsonId.i, *Root, *Entry, LastBytes.i

	Bench_LoadQueries(Bench_QueryFile, Queries())
	If ListSize(Queries()) = 0
		Bench_Fail("No queries in '" + Bench_QueryFile + "'")
	EndIf

	JsonId = CreateJSON(#PB_Any)
	*Root = SetJSONArray(JSONValue(JsonId))

	For i = 0 To Bench_ServerCount - 1
		With Bench_Servers(i)
			If Not \Query
				Continue
			EndIf
			ForEach Queries()
				ClearList(Queries()\LatencyMs())
				Queries()\Failures  = 0
				Queries()\LastError = ""
				Rows = -1
				LastBytes = 0
				Sql = Bench_ExpandSql(Queries()\Sql, @Bench_Servers(i))

				; Warm-up, also gives the row count.
				Ok = Bench_RunQuery(@\Monitor, @Bench_Servers(i), \QueryNode, Sql, \FirstNode, @Ms, @Bytes, @Result, @Error)
				If Ok
					Rows = Bench_CountRows(Result\s)
					LastBytes = Bytes\i
					For r = 1 To Bench_QueryRepeats
						If Bench_RunQuery(@\Monitor, @Bench_Servers(i), \QueryNode, Sql, \FirstNode, @Ms, @Bytes, @Result, @Error)
							AddElement(Queries()\LatencyMs())
							Queries()\LatencyMs() = Ms\d
						Else
							Queries()\Failures + 1
							Queries()\LastError = Error\s
						EndIf
					Next
				Else
					Queries()\Failures + 1
					Queries()\LastError = Error\s
				EndIf

				*Entry = SetJSONObject(AddJSONElement(*Root))
				SetJSONString(AddJSONMember(*Entry, "Server"), \Name)
				SetJSONString(AddJSONMember(*Entry, "Name"), Queries()\Name)
				Bench_AddLatencyStats(*Entry, "", Queries()\LatencyMs())
				SetJSONInteger(AddJSONMember(*Entry, "Rows"), Rows)
				SetJSONInteger(AddJSONMember(*Entry, "Bytes"), LastBytes)
				SetJSONInteger(AddJSONMember(*Entry, "Failures"), Queries()\Failures)
				SetJSONString(AddJSONMember(*Entry, "LastError"), Queries()\LastError)
				If ListSize(Queries()\LatencyMs()) > 0
					LastElement(Queries()\LatencyMs())
					PrintN("[Bench] " + \Name + " " + Queries()\Name + ": " + StrD(Queries()\LatencyMs(), 1) + " ms (last), " + Str(Rows) + " rows")
				Else
					PrintN("[Bench] " + \Name + " " + Queries()\Name + ": FAILED " + Queries()\LastError)
				EndIf
			Next
			BakaShrot_Outbound_Close(@\Monitor, #BakaShrot_ConnectionStatus_Disconnected)
		EndWith
	Next

	If Not SaveJSON(JsonId, Bench_QueryOut, #PB_JSON_PrettyPrint)
		Bench_Fail("Can't write '" + Bench_QueryOut + "'")
	EndIf
	FreeJSON(JsonId)
EndProcedure


; --- Main --------------------------------------------------------------------

Define Mode.s

OpenConsole()

If CountProgramParameters() < 2
	PrintN("Usage: BenchClient <run|query> <Plan.ini>")
	End 1
EndIf
Mode = LCase(ProgramParameter(0))

QueryPerformanceFrequency_(@Bench_QpcFrequency)
; Delay(1) closer to 1 ms, for the pacing.
timeBeginPeriod_(1)

CompilerIf #PB_Compiler_Version < 600
	InitNetwork()
CompilerEndIf
If Not InitCryptography()
	Bench_Fail("Can't initialize libsodium")
EndIf

Bench_LoadPlan(ProgramParameter(1))

Select Mode
	Case "run"
		Bench_Run()
	Case "query"
		Bench_Query()
	Default
		Bench_Fail("Unknown mode '" + Mode + "'")
EndSelect

timeEndPeriod_(1)
End 0
