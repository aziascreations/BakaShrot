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
    $L = & (Join-Path $Build "BakaShrotGenerateKeyPairs.exe")
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
    Tool "BakaShrotQuery.exe" @("@$F", $Ini)
}

$A = New-KeyPair; $B = New-KeyPair; $K = New-KeyPair; $G = New-KeyPair; $BC = New-KeyPair; $K2 = New-KeyPair; $R = New-KeyPair

# --- Server A: new keys, logs = 1, sensors = 2 -----------------------------
Set-Content (Join-Path $Dir "a.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($A.Priv)
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
reader = 30

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
Node = serverB
PublicKey = $($B.Pub)
AcceptTopics = logs

[BakaShrot.Client.b]
PublicKeys = $($B.Pub)
Node = serverB
DefaultTopic = logs

[BakaShrot.Client.kitchen]
PublicKeys = $($K.Pub)
Node = kitchen
DefaultTopic = logs
PushTopics = logs;sensors*
ReadTopics = *
AllowQuery = 1

[BakaShrot.Client.kitchen2]
PublicKeys = $($K2.Pub)
Node = kitchen-2
DefaultTopic = logs
PushTopics = logs;sensors.temp

[BakaShrot.Client.garage]
PublicKeys = $($G.Pub)
Node = garage
DefaultTopic = logs

; No DefaultTopic: its pushes must name their topic.
[BakaShrot.Client.reader]
PublicKeys = $($R.Pub)
Node = reader
PushTopics = logs
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
NodeId = serverA
PublicKey = $($A.Pub)
AcceptTopics = logs;sensors;sensors.*
AcceptNodes = kitchen;blocal;kitchen-*
SendNodes = blocal;9

[BakaShrot.Client.a]
PublicKeys = $($A.Pub)
Node = serverA
DefaultTopic = logs

; One key, three nodes: a section each.
[BakaShrot.Client.local]
PublicKeys = $($BC.Pub)
Node = blocal
DefaultTopic = sensors
PushTopics = sensors;logs;extra
ReadTopics = *
AllowQuery = 1

[BakaShrot.Client.local9]
PublicKeys = $($BC.Pub)
Node = 9
DefaultTopic = logs
PushTopics = sensors;logs;extra
ReadTopics = *
AllowQuery = 1

[BakaShrot.Client.localsecret]
PublicKeys = $($BC.Pub)
Node = bsecret
DefaultTopic = logs
PushTopics = sensors;logs;extra
ReadTopics = *
AllowQuery = 1
"@
}
Write-B "7"

# New key names, except garage's (NodeId, by id). No Topic: the server's
# DefaultTopic for each client says where its pushes go.
$ServerKeys = @{ 12401 = $A.Pub; 12402 = $B.Pub }
function Client-Ini($Name, $Keys, $Topic, $Node, $Port, [switch]$OldKeys) {
    $P = Join-Path $Dir "$Name.ini"
    $NK = "Node"
    if ($OldKeys) { $NK = "NodeId" }
    Set-Content $P -Encoding Ascii -Value "[BakaShrot]`r`nPrivateKey = $($Keys.Priv)`r`nPublicKey = $($Keys.Pub)`r`n$NK = $Node`r`nServerHost = 127.0.0.1`r`nServerPort = $Port`r`nServerPublicKey = $($ServerKeys[$Port])"
    $P
}
$Kitchen = Client-Ini "kitchen" $K "logs" "kitchen" 12401
$Garage  = Client-Ini "garage" $G "1" "5" 12401 -OldKeys
$Local   = Client-Ini "local" $BC "sensors" "blocal" 12402
$Anon    = Client-Ini "anon" $BC "logs" "9" 12402
$BSecret = Client-Ini "bsecret" $BC "logs" "bsecret" 12402
$Kitchen2 = Client-Ini "kitchen2" $K2 "logs" "kitchen-2" 12401
$Reader   = Client-Ini "reader" $R "logs" "reader" 12401
# reader's key, but kitchen's node: its section only gives it reader.
$Impostor = Client-Ini "impostor" $R "logs" "kitchen" 12401
Set-Content (Join-Path $Dir "m1.json") -Encoding Ascii -Value '{"temp":21}'
Set-Content (Join-Path $Dir "m2.json") -Encoding Ascii -Value '{"temp":22,"where":"kitchen"}'
Set-Content (Join-Path $Dir "m3.json") -Encoding Ascii -Value '{"from":"b-local"}'
$M1 = "@" + (Join-Path $Dir "m1.json"); $M2 = "@" + (Join-Path $Dir "m2.json"); $M3 = "@" + (Join-Path $Dir "m3.json")

$SA = Start-Srv "a"; $SB = Start-Srv "b"
try {
    Wait-Port 12401 $SA; Wait-Port 12402 $SB
    "--- Server A: pushes and the push filter"
    Expect "kitchen pushes into its own topic (logs)" (Tool "BakaShrotPushMessage.exe" @($M1, $Kitchen)) "message #1"
    Expect "kitchen pushes into sensors by name" (Tool "BakaShrotPushMessage.exe" @("-t", "sensors", $M2, $Kitchen)) "message #1"
    Expect "kitchen pushes into logs by id" (Tool "BakaShrotPushMessage.exe" @("-t", "1", $M2, $Kitchen)) "message #2"
    Expect "kitchen can't push into secret" (Tool "BakaShrotPushMessage.exe" @("-t", "secret", $M1, $Kitchen)) "Not allowed to push to topic 'secret'" 1
    Expect "unknown topic refused, with its code" (Tool "BakaShrotPushMessage.exe" @("-t", "nope", $M1, $Kitchen)) "\(UnknownName\): Unknown topic 'nope'" 1
    Expect "garage (old keys, by ids 1:5) pushes into logs" (Tool "BakaShrotPushMessage.exe" @($M1, $Garage)) "message #1"
    Expect "kitchen pushes into sensors.temp (PushTopics sensors*)" (Tool "BakaShrotPushMessage.exe" @("-t", "sensors.temp", $M2, $Kitchen)) "message #1"
    Expect "kitchen-2 pushes into logs" (Tool "BakaShrotPushMessage.exe" @($M1, $Kitchen2)) "message #1"
    Expect "kitchen-2 pushes into sensors.temp" (Tool "BakaShrotPushMessage.exe" @("-t", "sensors.temp", $M1, $Kitchen2)) "message #1"
    Expect "kitchen-2 can't push into sensors" (Tool "BakaShrotPushMessage.exe" @("-t", "sensors", $M1, $Kitchen2)) "Not allowed to push to topic 'sensors'" 1

    "--- Server A: identities (a node per key, the default topic the server's)"
    Expect "reader (no DefaultTopic) can't push without naming a topic" (Tool "BakaShrotPushMessage.exe" @($M1, $Reader)) "\(NoDefaultTopic\): No default topic for this client" 1
    Expect "reader pushes when it names one" (Tool "BakaShrotPushMessage.exe" @("-t", "logs", $M1, $Reader)) "message #1"
    Expect "reader's key can't write as kitchen" (Tool "BakaShrotPushMessage.exe" @("-t", "logs", $M1, $Impostor)) "Failed to connect and authenticate to [^ ]+ \(AuthRejected\)" 1

    "--- Server A: reads and the read filter"
    Expect "garage reads logs:kitchen by name" (Tool "BakaShrotGetLatestMessage.exe" @("logs", "kitchen", $Garage)) "logs:kitchen#2 \(ids 1:2\)"
    Expect "garage reads it by ids, case-insensitive name" (Tool "BakaShrotGetLatestMessage.exe" @("1", "KITCHEN", $Garage)) "logs:kitchen#2"
    Expect "garage can't read sensors (default ReadTopics)" (Tool "BakaShrotGetLatestMessage.exe" @("sensors", "kitchen", $Garage)) "Not allowed to read topic 'sensors'" 1
    Expect "kitchen reads sensors (ReadTopics = *)" (Tool "BakaShrotGetLatestMessage.exe" @("sensors", "kitchen", $Kitchen)) "sensors:kitchen#1 \(ids 2:2\)"

    "--- Server A: resolving and listing"
    Expect "kitchen resolves topic sensors" (Tool "BakaShrotResolveIds.exe" @("topic", "sensors", $Kitchen)) "topic sensors = 2"
    Expect "kitchen resolves topic id 1" (Tool "BakaShrotResolveIds.exe" @("topic", "1", $Kitchen)) "topic logs = 1"
    Expect "kitchen resolves node garage" (Tool "BakaShrotResolveIds.exe" @("node", "garage", $Kitchen)) "node garage = 5"
    Expect "garage can't resolve sensors (no access)" (Tool "BakaShrotResolveIds.exe" @("topic", "sensors", $Garage)) "Unknown topic" 1
    Expect "kitchen can resolve secret (it may query)" (Tool "BakaShrotResolveIds.exe" @("topic", "secret", $Kitchen)) "topic secret = 3"
    Expect "kitchen lists every topic (it may query)" (Tool "BakaShrotList.exe" @("topics", $Kitchen)) "Topics \(4\): \|\s+1  logs\s+config \|\s+2  sensors\s+config \|\s+3  secret\s+config \|\s+4  sensors.temp\s+config"
    Expect "garage lists only the topics it can use" (Tool "BakaShrotList.exe" @("topics", $Garage)) "Topics \(1\): \|\s+1  logs"
    Expect "the nodes, as JSON" (Tool "BakaShrotList.exe" @("nodes", "--json", $Kitchen)) '(?=.*"kind":"node")(?=.*\{[^}]*"name":"kitchen"[^}]*\})(?=.*\{[^}]*"id":2[,}])'

    "--- Server A: queries by name through the view"
    Expect "messages view, by names" (Query "SELECT topic, node, message_id FROM messages WHERE topic = 'logs' AND node = 'kitchen' ORDER BY message_id" $Kitchen) '\[\["logs","kitchen","1"\],\["logs","kitchen","2"\]\]'

    "--- Replication, A -> B, translated (logs 1 -> 200, kitchen 2 -> 7)"
    Start-Sleep -Seconds 4
    Expect "B has logs:kitchen, under its own ids" (Tool "BakaShrotGetLatestMessage.exe" @("logs", "kitchen", $Local)) "logs:kitchen#2 \(ids 200:7\)"
    Expect "B has sensors:kitchen" (Tool "BakaShrotGetLatestMessage.exe" @("sensors", "kitchen", $Local)) "sensors:kitchen#1 \(ids 201:7\)"
    Expect "B didn't get logs:garage (garage isn't named on B)" (Tool "BakaShrotGetLatestMessage.exe" @("logs", "garage", $Local)) "Unknown node 'garage'" 1
    Expect "B took sensors.temp by AcceptTopics sensors.* (new topic id 65535)" (Tool "BakaShrotGetLatestMessage.exe" @("sensors.temp", "kitchen", $Local)) "sensors.temp:kitchen#1 \(ids 65535:7\)"
    Expect "B took kitchen-2 by AcceptNodes kitchen-* (new node id 65535)" (Tool "BakaShrotGetLatestMessage.exe" @("logs", "kitchen-2", $Local)) "logs:kitchen-2#1 \(ids 200:65535\)"
    Expect "B: both new ones" (Tool "BakaShrotGetLatestMessage.exe" @("sensors.temp", "kitchen-2", $Local)) "sensors.temp:kitchen-2#1 \(ids 65535:65535\)"
    Expect "B: added from the peer, nothing else" (Query "SELECT 'topic', name, topic_id FROM topics WHERE origin = 'peer' UNION ALL SELECT 'node', name, node_id FROM nodes WHERE origin = 'peer'" $Local) '\[\["topic","sensors.temp","65535"\],\["node","kitchen-2","65535"\]\]'
    Expect "B's view: same messages by name" (Query "SELECT topic, node, message_id, topic_id, node_id FROM messages WHERE topic = 'sensors'" $Local) '\[\["sensors","kitchen","1","201","7"\]\]'

    "--- Replication, B -> A: only what A names and takes (AcceptTopics = logs)"
    Expect "B's local pushes into sensors" (Tool "BakaShrotPushMessage.exe" @($M3, $Local)) "message #1"
    Expect "B's local pushes into logs" (Tool "BakaShrotPushMessage.exe" @("-t", "logs", $M3, $Local)) "message #1"
    Expect "B's local pushes into extra" (Tool "BakaShrotPushMessage.exe" @("-t", "extra", $M3, $Local)) "message #1"
    Expect "B's unnamed node 9 pushes into logs" (Tool "BakaShrotPushMessage.exe" @($M3, $Anon)) "message #1"
    Expect "B's bsecret pushes into logs" (Tool "BakaShrotPushMessage.exe" @($M3, $BSecret)) "message #1"
    Start-Sleep -Seconds 4
    Expect "A got logs:blocal (ids 1:20)" (Tool "BakaShrotGetLatestMessage.exe" @("logs", "blocal", $Kitchen)) 'logs:blocal#1 \(ids 1:20\), pushed \d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z \| \{"from":"b-local"\}'
    Expect "A didn't get sensors:blocal (not accepted)" (Tool "BakaShrotGetLatestMessage.exe" @("sensors", "blocal", $Kitchen)) "No message" 1
    Expect "A didn't get logs:9 (unnamed)" (Tool "BakaShrotGetLatestMessage.exe" @("logs", "9", $Kitchen)) "No message" 1
    Expect "A didn't get logs:bsecret (B's SendNodes)" (Tool "BakaShrotGetLatestMessage.exe" @("logs", "bsecret", $Kitchen)) "No message" 1
    Expect "A's pairs, nothing more, nothing twice" (Query "SELECT topic, node, COUNT(*) FROM messages GROUP BY 1, 2 ORDER BY 1, 2" $Kitchen) '\[\["logs","blocal","1"\],\["logs","garage","1"\],\["logs","kitchen","2"\],\["logs","kitchen-2","1"\],\["logs","reader","1"\],\["sensors","kitchen","1"\],\["sensors.temp","kitchen","1"\],\["sensors.temp","kitchen-2","1"\]\]'
} finally {
    Stop-Srv $SA; Stop-Srv $SB
}

"--- No refusals: each side only sent what the other one knows"
$Refusals = @(Get-Content (Join-Path $Dir "a.log"), (Join-Path $Dir "b.log") | Select-String "replicated here|known here|refused:")
$Ok = $Refusals.Count -eq 0
if (-not $Ok) { $Fails++ }
"{0} no replication refusals in either log`n      -> {1}" -f $(if ($Ok) { "PASS" } else { "FAIL" }), $(if ($Ok) { "none" } else { $Refusals -join " | " })
$Ok = (Get-Content (Join-Path $Dir "a.log") -Raw) -match "isn't allowed to write as node kitchen with its public key"
if (-not $Ok) { $Fails++ }
"{0} A logged why the impostor was refused" -f $(if ($Ok) { "PASS" } else { "FAIL" })
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
    Expect "B starts, kitchen still 7" (Tool "BakaShrotList.exe" @("nodes", $Local)) "\s+7  kitchen\s+config"
} finally { Stop-Srv $SB }

"--- The old Identities (before protocol 5): refused at start, saying what to write"
(Get-Content (Join-Path $Dir "a.ini") -Raw) -replace "Node = garage\r?\nDefaultTopic = logs", "Identities = logs:garage" | Set-Content (Join-Path $Dir "old.ini") -Encoding Ascii
$SO = Start-Srv "old"
$Exited = $SO.P.WaitForExit(10000)
if (-not $Exited) { Stop-Srv $SO }
$Log = Get-Content (Join-Path $Dir "old.log") -Raw
$Ok = $Exited -and $SO.P.ExitCode -ne 0 -and $Log -match "write Node = garage and DefaultTopic = logs instead of Identities = logs:garage"
if (-not $Ok) { $Fails++ }
"{0} refused, with what to write instead`n      -> {1}" -f $(if ($Ok) { "PASS" } else { "FAIL" }), (($Log -split "`n") | Select-String "Identities" | Select-Object -First 1)

# --- C and D: topics listed without ids, no nodes listed at all ------------
# The servers pick the ids, the nodes come from the sections (C's own, its
# peer's, its client's), D takes the client's node from C as it comes.
$C = New-KeyPair; $D = New-KeyPair; $KC = New-KeyPair
# LF line endings on purpose: the names sections are read by hand, the
# Preferences library misreads a bare name there (Config.pbi).
function Write-C([string]$Topics, [string]$Sync = "NORMAL") {
$Text = @"
[BakaShrot]
PrivateKey = $($C.Priv)
Node = serverC

[BakaShrot.Topics]
$Topics

[BakaShrot.Server]
Host = 127.0.0.1
Port = 12401
ReplicatingTopics = logs
DatabasePath = $(Join-Path $Dir "c.sqlite")
PeerSyncInterval = 1
PeerRetryDelay = 1
Synchronous = $Sync

[BakaShrot.Peer.d]
Host = 127.0.0.1
Port = 12402
Node = serverD
PublicKey = $($D.Pub)

[BakaShrot.Client.d]
PublicKeys = $($D.Pub)
Node = serverD
AllowWrite = 0

[BakaShrot.Client.kitchen]
PublicKeys = $($KC.Pub)
Node = kitchen
DefaultTopic = logs
ReadTopics = *
"@
[IO.File]::WriteAllText((Join-Path $Dir "c.ini"), ($Text -replace "`r`n", "`n"))
}
Write-C "logs`nsensors"
Set-Content (Join-Path $Dir "d.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($D.Priv)
Node = serverD

[BakaShrot.Topics]
logs

[BakaShrot.Server]
Host = 127.0.0.1
Port = 12402
ReplicatingTopics = logs
DatabasePath = $(Join-Path $Dir "d.sqlite")
PeerSyncInterval = 1
PeerRetryDelay = 1

[BakaShrot.Peer.c]
Host = 127.0.0.1
Port = 12401
Node = serverC
PublicKey = $($C.Pub)

[BakaShrot.Client.c]
PublicKeys = $($C.Pub)
Node = serverC
AllowWrite = 0

[BakaShrot.Client.watcher]
PublicKeys = $($KC.Pub)
Node = watcher
ReadTopics = *
"@
$ServerKeys[12401] = $C.Pub; $ServerKeys[12402] = $D.Pub
$KitchenC = Client-Ini "kitchen-c" $KC "logs" "kitchen" 12401
$Watcher  = Client-Ini "watcher" $KC "logs" "watcher" 12402

"--- C and D: names without ids"
$SC = Start-Srv "c"; $SD = Start-Srv "d"
try {
    Wait-Port 12401 $SC; Wait-Port 12402 $SD
    Expect "C gives the listed topics ids, in order" (Tool "BakaShrotList.exe" @("topics", $KitchenC)) "\s1  logs\s+config.*\s2  sensors\s+config"
    Expect "C names its own, its peer's and its client's nodes" (Tool "BakaShrotList.exe" @("nodes", $KitchenC)) "\s1  serverC\s+config.*\s2  serverD\s+config.*\s3  kitchen\s+config"
    Expect "kitchen pushes to its DefaultTopic" (Tool "BakaShrotPushMessage.exe" @($M1, $KitchenC)) "message #1"
    $Deadline = (Get-Date).AddSeconds(15)
    do {
        $R = Tool "BakaShrotGetLatestMessage.exe" @("logs", "kitchen", $Watcher)
        if ($R.Code -eq 0) { break }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $Deadline)
    Expect "D took logs:kitchen though it never named kitchen (AcceptNodes = * by default)" $R "logs:kitchen#1 \(ids 1:65535\)"
} finally {
    Stop-Srv $SC; Stop-Srv $SD
}

"--- C again, its topics reordered and a new one first: the ids stay"
Write-C "alpha`nsensors`nlogs"
$SC = Start-Srv "c"
try {
    Wait-Port 12401 $SC
    Expect "logs and sensors keep 1 and 2, alpha gets 3" (Tool "BakaShrotList.exe" @("topics", $KitchenC)) "\s1  logs\s+config.*\s2  sensors\s+config.*\s3  alpha\s+config"
    Expect "kitchen's message still under logs" (Tool "BakaShrotGetLatestMessage.exe" @("logs", "kitchen", $KitchenC)) "logs:kitchen#1 \(ids 1:3\)"
} finally { Stop-Srv $SC }

"--- Synchronous: C ran with NORMAL, D with the default FULL, OFF is refused"
$Ok = ((Get-Content (Join-Path $Dir "c.log") -Raw) -match "is ready \(synchronous NORMAL\)") -and ((Get-Content (Join-Path $Dir "d.log") -Raw) -match "is ready \(synchronous FULL\)")
if (-not $Ok) { $Fails++ }
"{0} C logged NORMAL, D FULL" -f $(if ($Ok) { "PASS" } else { "FAIL" })
Write-C "logs" "OFF"
$SO = Start-Srv "c"
$Exited = $SO.P.WaitForExit(10000)
if (-not $Exited) { Stop-Srv $SO }
$Log = Get-Content (Join-Path $Dir "c.log") -Raw
$Ok = $Exited -and $SO.P.ExitCode -ne 0 -and $Log -match "Synchronous = OFF isn't allowed"
if (-not $Ok) { $Fails++ }
"{0} Synchronous = OFF refused at start`n      -> {1}" -f $(if ($Ok) { "PASS" } else { "FAIL" }), (($Log -split "`n") | Select-String "Synchronous" | Select-Object -First 1)

"--- browse / browse_messages, as a database tool uses them (C stopped)"
$PythonExe = Get-Command python -ErrorAction SilentlyContinue
if ($PythonExe) {
    Set-Content (Join-Path $Dir "browse.py") -Encoding Ascii -Value @'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("PRAGMA foreign_keys = ON")  # like SQLiteStudio
print("rows", db.execute("SELECT COUNT(*) FROM browse").fetchone()[0])
db.execute("UPDATE browse SET topic = 'logs', node = NULL"); db.commit()
print("logs", db.execute("SELECT node, message_id, attachment_size FROM browse_messages").fetchall())
db.execute("UPDATE browse SET topic = 'LOGS', node = 'kitchen'"); db.commit()
print("kitchen", db.execute("SELECT node, message_id FROM browse_messages").fetchall())
try:
    db.execute("UPDATE browse SET topic = 'nope'"); db.commit(); print("bad accepted")
except sqlite3.IntegrityError:
    print("bad refused")
db.execute("UPDATE browse SET topic = 'sensors', node = NULL"); db.commit()
print("sensors", db.execute("SELECT COUNT(*) FROM browse_messages").fetchone()[0])
'@
    $Out = (& $PythonExe.Source -B (Join-Path $Dir "browse.py") (Join-Path $Dir "c.sqlite") 2>&1) -join " | "
    $Ok = $Out -eq "rows 1 | logs [('kitchen', 1, None)] | kitchen [('kitchen', 1)] | bad refused | sensors 0"
    if (-not $Ok) { $Fails++ }
    "{0} one row, a topic shows its messages, a node narrows them, an unknown topic is refused`n      -> {1}" -f $(if ($Ok) { "PASS" } else { "FAIL" }), $Out
} else {
    "SKIP browse: no python on the PATH"
}

""
if ($Fails -eq 0) { "ALL PASSED" } else { "$Fails FAILED"; exit 1 }
