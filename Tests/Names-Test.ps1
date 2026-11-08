# End-to-end test of topic/node names, filters and replication by name:
# two servers with different ids for the same names, strict "named on both
# sides" replication, wildcards (taking undeclared names, filtering),
# old and new config keys, the list tool.
# Needs Build\ (Build.ps1) and Build\Bench\BenchServer.exe (Bench-Replication.ps1,
# or compile Tests\Bench\BenchServer.pb into it). Uses ports 12401-12402.
# Usage: powershell -ExecutionPolicy Bypass -File Tests\Names-Test.ps1
param([string]$Build = (Join-Path $PSScriptRoot "..\Build"))
$ErrorActionPreference = "Stop"
$Dir = Join-Path $Build "_namestest"
Remove-Item -Recurse -Force $Dir -ErrorAction SilentlyContinue
New-Item -ItemType Directory $Dir | Out-Null
$Server = Join-Path $Build "Bench\BenchServer.exe"
$Fails = 0

function New-KeyPair {
    $L = & (Join-Path $Build "KeyGen.exe")
    @{ Priv = $L[0] -replace "^PrivateKey = ", ""; Pub = $L[1] -replace "^PublicKey = ", "" }
}
function Test-Port($P) {
    $C = New-Object System.Net.Sockets.TcpClient
    try { $A = $C.BeginConnect("127.0.0.1", $P, $null, $null); $A.AsyncWaitHandle.WaitOne(200) -and $C.Connected } catch { $false } finally { $C.Close() }
}
function Tool([string]$Name, [string[]]$A) {
    $O = & (Join-Path $Build $Name) @A 2>&1
    @{ Code = $LASTEXITCODE; Out = ($O -join " | ") }
}
function Expect([string]$What, $Result, [string]$Pattern, [int]$Code = 0) {
    $Ok = ($Result.Code -eq $Code) -and ($Result.Out -match $Pattern)
    if (-not $Ok) { $script:Fails++ }
    "{0} {1}`n      -> [{2}] {3}" -f $(if ($Ok) { "PASS" } else { "FAIL" }), $What, $Result.Code, $Result.Out
}
function Start-Srv($Name) {
    $Stop = Join-Path $Dir "$Name.stop"
    Remove-Item $Stop -ErrorAction SilentlyContinue
    $P = Start-Process -FilePath $Server -ArgumentList "`"$(Join-Path $Dir "$Name.ini")`"", "`"$Stop`"" -WorkingDirectory $Dir `
        -RedirectStandardOutput (Join-Path $Dir "$Name.log") -WindowStyle Hidden -PassThru
    $null = $P.Handle
    @{ P = $P; Stop = $Stop; Name = $Name }
}
function Stop-Srv($S) {
    Set-Content $S.Stop "x"
    if (-not $S.P.WaitForExit(15000)) { Stop-Process -Id $S.P.Id -Force }
}
function Wait-Port($Port, $S) {
    $D = (Get-Date).AddSeconds(15)
    while (-not (Test-Port $Port)) {
        if ($S.P.HasExited) { throw "$($S.Name) exited: $(Get-Content (Join-Path $Dir "$($S.Name).log") -Raw)" }
        if ((Get-Date) -gt $D) { throw "$($S.Name) not listening" }
        Start-Sleep -Milliseconds 100
    }
}
function Query($Sql, $Ini) {
    $F = Join-Path $Dir "q.sql"; Set-Content $F -Encoding Ascii -Value $Sql
    Tool "Query.exe" @("@$F", $Ini)
}

$A = New-KeyPair; $B = New-KeyPair; $K = New-KeyPair; $G = New-KeyPair; $BC = New-KeyPair; $K2 = New-KeyPair

# --- Server A: new keys, logs = 1, sensors = 2 -----------------------------
Set-Content (Join-Path $Dir "a.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($A.Priv)
Topic = logs
Node = serverA

[BakaShrot.Topics]
logs = 1
sensors = 2
secret = 3
sensors.temp = 4

[BakaShrot.Nodes]
serverA = 10
serverB = 11
kitchen = 2
garage = 5
kitchen-2 = 6
blocal = 20
bsecret = 21

[BakaShrot.Server]
Host = 127.0.0.1
Port = 12401
ReplicatingTopics = logs;sensors*
DatabasePath = $(Join-Path $Dir "a.sqlite")
PeerSyncInterval = 1
PeerRetryDelay = 1

[BakaShrot.Peer.b]
Host = 127.0.0.1
Port = 12402
Topic = logs
Node = serverB
PublicKey = $($B.Pub)
AcceptTopics = logs

[BakaShrot.Client.b]
PublicKeys = $($B.Pub)
Identities = logs:serverB

[BakaShrot.Client.kitchen]
PublicKeys = $($K.Pub)
Identities = logs:kitchen
PushTopics = logs;sensors*
ReadTopics = *
AllowQuery = 1

[BakaShrot.Client.kitchen2]
PublicKeys = $($K2.Pub)
Identities = logs:kitchen-2
PushTopics = logs;sensors.temp

[BakaShrot.Client.garage]
PublicKeys = $($G.Pub)
Identities = logs:garage
"@

# --- Server B: the old key names, logs = 200, sensors = 201 ----------------
# garage isn't named here (dropped from A), extra isn't named on A (dropped
# from B), node 9 isn't named anywhere (dropped both ways). sensors.temp and
# kitchen-2 aren't named here either, but taken by AcceptTopics/AcceptNodes
# patterns. bsecret is named on both, but held back by SendNodes.
function Write-B([string]$Kitchen) {
Set-Content (Join-Path $Dir "b.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($B.Priv)
TopicId = logs
NodeId = serverB

[BakaShrot.Topics]
logs = 200
sensors = 201
extra = 202

[BakaShrot.Nodes]
serverA = 1
serverB = 2
kitchen = $Kitchen
blocal = 3
bsecret = 4

[BakaShrot.Server]
Host = 127.0.0.1
Port = 12402
ReplicatingTopicIds = *
DatabasePath = $(Join-Path $Dir "b.sqlite")
PeerSyncInterval = 1
PeerRetryDelay = 1

[BakaShrot.Peer.a]
Host = 127.0.0.1
Port = 12401
TopicId = logs
NodeId = serverA
PublicKey = $($A.Pub)
AcceptTopics = logs;sensors;sensors.*
AcceptNodes = kitchen;blocal;kitchen-*
SendNodes = blocal;9

[BakaShrot.Client.a]
PublicKeys = $($A.Pub)
Identities = logs:serverA

[BakaShrot.Client.local]
PublicKeys = $($BC.Pub)
Identities = sensors:blocal;logs:9;logs:bsecret
PushTopics = sensors;logs;extra
ReadTopics = *
AllowQuery = 1
"@
}
Write-B "7"

# New key names, except garage's (TopicId / NodeId, by ids).
$ServerKeys = @{ 12401 = $A.Pub; 12402 = $B.Pub }
function Client-Ini($Name, $Keys, $Topic, $Node, $Port, [switch]$OldKeys) {
    $P = Join-Path $Dir "$Name.ini"
    $TK = "Topic"; $NK = "Node"
    if ($OldKeys) { $TK = "TopicId"; $NK = "NodeId" }
    Set-Content $P -Encoding Ascii -Value "[BakaShrot]`r`nPrivateKey = $($Keys.Priv)`r`nPublicKey = $($Keys.Pub)`r`n$TK = $Topic`r`n$NK = $Node`r`nServerHost = 127.0.0.1`r`nServerPort = $Port`r`nServerPublicKey = $($ServerKeys[$Port])"
    $P
}
$Kitchen = Client-Ini "kitchen" $K "logs" "kitchen" 12401
$Garage  = Client-Ini "garage" $G "1" "5" 12401 -OldKeys
$Local   = Client-Ini "local" $BC "sensors" "blocal" 12402
$Anon    = Client-Ini "anon" $BC "logs" "9" 12402
$BSecret = Client-Ini "bsecret" $BC "logs" "bsecret" 12402
$Kitchen2 = Client-Ini "kitchen2" $K2 "logs" "kitchen-2" 12401
Set-Content (Join-Path $Dir "m1.json") -Encoding Ascii -Value '{"temp":21}'
Set-Content (Join-Path $Dir "m2.json") -Encoding Ascii -Value '{"temp":22,"where":"kitchen"}'
Set-Content (Join-Path $Dir "m3.json") -Encoding Ascii -Value '{"from":"b-local"}'
$M1 = "@" + (Join-Path $Dir "m1.json"); $M2 = "@" + (Join-Path $Dir "m2.json"); $M3 = "@" + (Join-Path $Dir "m3.json")

$SA = Start-Srv "a"; $SB = Start-Srv "b"
try {
    Wait-Port 12401 $SA; Wait-Port 12402 $SB
    "--- Server A: pushes and the push filter"
    Expect "kitchen pushes into its own topic (logs)" (Tool "PushMessage.exe" @($M1, $Kitchen)) "message #1"
    Expect "kitchen pushes into sensors by name" (Tool "PushMessage.exe" @("-t", "sensors", $M2, $Kitchen)) "message #1"
    Expect "kitchen pushes into logs by id" (Tool "PushMessage.exe" @("-t", "1", $M2, $Kitchen)) "message #2"
    Expect "kitchen can't push into secret" (Tool "PushMessage.exe" @("-t", "secret", $M1, $Kitchen)) "Not allowed to push to topic 'secret'" 1
    Expect "unknown topic refused" (Tool "PushMessage.exe" @("-t", "nope", $M1, $Kitchen)) "Unknown topic 'nope'" 1
    Expect "garage (old keys, by ids 1:5) pushes into logs" (Tool "PushMessage.exe" @($M1, $Garage)) "message #1"
    Expect "kitchen pushes into sensors.temp (PushTopics sensors*)" (Tool "PushMessage.exe" @("-t", "sensors.temp", $M2, $Kitchen)) "message #1"
    Expect "kitchen-2 pushes into logs" (Tool "PushMessage.exe" @($M1, $Kitchen2)) "message #1"
    Expect "kitchen-2 pushes into sensors.temp" (Tool "PushMessage.exe" @("-t", "sensors.temp", $M1, $Kitchen2)) "message #1"
    Expect "kitchen-2 can't push into sensors" (Tool "PushMessage.exe" @("-t", "sensors", $M1, $Kitchen2)) "Not allowed to push to topic 'sensors'" 1

    "--- Server A: reads and the read filter"
    Expect "garage reads logs:kitchen by name" (Tool "GetLatestMessage.exe" @("logs", "kitchen", $Garage)) "logs:kitchen#2 \(ids 1:2\)"
    Expect "garage reads it by ids, case-insensitive name" (Tool "GetLatestMessage.exe" @("1", "KITCHEN", $Garage)) "logs:kitchen#2"
    Expect "garage can't read sensors (default ReadTopics)" (Tool "GetLatestMessage.exe" @("sensors", "kitchen", $Garage)) "Not allowed to read topic 'sensors'" 1
    Expect "kitchen reads sensors (ReadTopics = *)" (Tool "GetLatestMessage.exe" @("sensors", "kitchen", $Kitchen)) "sensors:kitchen#1 \(ids 2:2\)"

    "--- Server A: resolving and listing"
    Expect "kitchen resolves topic sensors" (Tool "Resolve.exe" @("topic", "sensors", $Kitchen)) "topic sensors = 2"
    Expect "kitchen resolves topic id 1" (Tool "Resolve.exe" @("topic", "1", $Kitchen)) "topic logs = 1"
    Expect "kitchen resolves node garage" (Tool "Resolve.exe" @("node", "garage", $Kitchen)) "node garage = 5"
    Expect "garage can't resolve sensors (no access)" (Tool "Resolve.exe" @("topic", "sensors", $Garage)) "Unknown topic" 1
    Expect "kitchen can resolve secret (it may query)" (Tool "Resolve.exe" @("topic", "secret", $Kitchen)) "topic secret = 3"
    Expect "kitchen lists every topic (it may query)" (Tool "ListNames.exe" @("topics", $Kitchen)) "Topics \(4\): \|\s+1  logs\s+config \|\s+2  sensors\s+config \|\s+3  secret\s+config \|\s+4  sensors.temp\s+config"
    Expect "garage lists only the topics it can use" (Tool "ListNames.exe" @("topics", $Garage)) "Topics \(1\): \|\s+1  logs"
    Expect "the nodes, as JSON" (Tool "ListNames.exe" @("nodes", "--json", $Kitchen)) '(?=.*"kind":"node")(?=.*\{[^}]*"name":"kitchen"[^}]*\})(?=.*\{[^}]*"id":2[,}])'

    "--- Server A: queries by name through the view"
    Expect "messages view, by names" (Query "SELECT topic, node, message_id FROM messages WHERE topic = 'logs' AND node = 'kitchen' ORDER BY message_id" $Kitchen) '\[\["logs","kitchen","1"\],\["logs","kitchen","2"\]\]'

    "--- Replication, A -> B, translated (logs 1 -> 200, kitchen 2 -> 7)"
    Start-Sleep -Seconds 4
    Expect "B has logs:kitchen, under its own ids" (Tool "GetLatestMessage.exe" @("logs", "kitchen", $Local)) "logs:kitchen#2 \(ids 200:7\)"
    Expect "B has sensors:kitchen" (Tool "GetLatestMessage.exe" @("sensors", "kitchen", $Local)) "sensors:kitchen#1 \(ids 201:7\)"
    Expect "B didn't get logs:garage (garage isn't named on B)" (Tool "GetLatestMessage.exe" @("logs", "garage", $Local)) "Unknown node 'garage'" 1
    Expect "B took sensors.temp by AcceptTopics sensors.* (new topic id 65535)" (Tool "GetLatestMessage.exe" @("sensors.temp", "kitchen", $Local)) "sensors.temp:kitchen#1 \(ids 65535:7\)"
    Expect "B took kitchen-2 by AcceptNodes kitchen-* (new node id 65535)" (Tool "GetLatestMessage.exe" @("logs", "kitchen-2", $Local)) "logs:kitchen-2#1 \(ids 200:65535\)"
    Expect "B: both new ones" (Tool "GetLatestMessage.exe" @("sensors.temp", "kitchen-2", $Local)) "sensors.temp:kitchen-2#1 \(ids 65535:65535\)"
    Expect "B: added from the peer, nothing else" (Query "SELECT 'topic', name, topic_id FROM topics WHERE origin = 'peer' UNION ALL SELECT 'node', name, node_id FROM nodes WHERE origin = 'peer'" $Local) '\[\["topic","sensors.temp","65535"\],\["node","kitchen-2","65535"\]\]'
    Expect "B's view: same messages by name" (Query "SELECT topic, node, message_id, topic_id, node_id FROM messages WHERE topic = 'sensors'" $Local) '\[\["sensors","kitchen","1","201","7"\]\]'

    "--- Replication, B -> A: only what A names and takes (AcceptTopics = logs)"
    Expect "B's local pushes into sensors" (Tool "PushMessage.exe" @($M3, $Local)) "message #1"
    Expect "B's local pushes into logs" (Tool "PushMessage.exe" @("-t", "logs", $M3, $Local)) "message #1"
    Expect "B's local pushes into extra" (Tool "PushMessage.exe" @("-t", "extra", $M3, $Local)) "message #1"
    Expect "B's unnamed node 9 pushes into logs" (Tool "PushMessage.exe" @($M3, $Anon)) "message #1"
    Expect "B's bsecret pushes into logs" (Tool "PushMessage.exe" @($M3, $BSecret)) "message #1"
    Start-Sleep -Seconds 4
    Expect "A got logs:blocal (ids 1:20)" (Tool "GetLatestMessage.exe" @("logs", "blocal", $Kitchen)) 'logs:blocal#1 \(ids 1:20\), pushed \d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z \| \{"from":"b-local"\}'
    Expect "A didn't get sensors:blocal (not accepted)" (Tool "GetLatestMessage.exe" @("sensors", "blocal", $Kitchen)) "No message" 1
    Expect "A didn't get logs:9 (unnamed)" (Tool "GetLatestMessage.exe" @("logs", "9", $Kitchen)) "No message" 1
    Expect "A didn't get logs:bsecret (B's SendNodes)" (Tool "GetLatestMessage.exe" @("logs", "bsecret", $Kitchen)) "No message" 1
    Expect "A's pairs, nothing more, nothing twice" (Query "SELECT topic, node, COUNT(*) FROM messages GROUP BY 1, 2 ORDER BY 1, 2" $Kitchen) '\[\["logs","blocal","1"\],\["logs","garage","1"\],\["logs","kitchen","2"\],\["logs","kitchen-2","1"\],\["sensors","kitchen","1"\],\["sensors.temp","kitchen","1"\],\["sensors.temp","kitchen-2","1"\]\]'
} finally {
    Stop-Srv $SA; Stop-Srv $SB
}

"--- No refusals: each side only sent what the other one knows"
$Refusals = @(Get-Content (Join-Path $Dir "a.log"), (Join-Path $Dir "b.log") | Select-String "replicated here|known here|refused:")
$Ok = $Refusals.Count -eq 0
if (-not $Ok) { $Fails++ }
"{0} no replication refusals in either log`n      -> {1}" -f $(if ($Ok) { "PASS" } else { "FAIL" }), $(if ($Ok) { "none" } else { $Refusals -join " | " })
"A:"; Get-Content (Join-Path $Dir "a.log") | Select-String "\[Peer\] Sent|Names" | % { "  $_" }
"B:"; Get-Content (Join-Path $Dir "b.log") | Select-String "\[Peer\] Sent|Names" | % { "  $_" }

"--- Conflict: B's config now says kitchen = 8, but its messages are under 7"
Write-B "8"
$SB = Start-Srv "b"
$SB.P.WaitForExit(15000) | Out-Null
$Log = Get-Content (Join-Path $Dir "b.log") -Raw
$Ok = $SB.P.HasExited -and $SB.P.ExitCode -eq 1 -and $Log -match "give it id 7"
if (-not $Ok) { $Fails++ }
"{0} B refuses to start`n      -> [{1}] {2}" -f $(if ($Ok) { "PASS" } else { "FAIL" }), $SB.P.ExitCode, (($Log -split "`n") | Select-String "names don't match")
if (-not $SB.P.HasExited) { Stop-Srv $SB }

"--- Conflict fixed: kitchen = 7 again"
Write-B "7"
$SB = Start-Srv "b"
try {
    Wait-Port 12402 $SB
    Expect "B starts, kitchen still 7" (Tool "ListNames.exe" @("nodes", $Local)) "\s+7  kitchen\s+config"
} finally { Stop-Srv $SB }

""
if ($Fails -eq 0) { "ALL PASSED" } else { "$Fails FAILED" }
