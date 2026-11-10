# End-to-end test of pushed_at and [BakaShrot.Retention]:
#   - a database from before pushed_at gets it (the time of the upgrade), and
#     its ids go on;
#   - a push is stamped with the time it arrived (UTC), BakaShrotGetMessages
#     --time and BakaShrotGetLatestMessage show it, replication carries it as is;
#   - each server deletes a topic's messages past its own max age (by name,
#     by pattern, "*"), only its own: the peer keeps its copies;
#   - after deleting, ids go on, and the peer doesn't send them again;
#   - what a peer replicates already past the max age isn't stored, but
#     counts as received: not sent again;
#   - an age without a unit is refused at start.
# Two linked servers, A (port 12408) and B (12409).
# Needs Build\ (Build.ps1), Build\Bench\BenchServer.exe (or compile
# Tests\Bench\BenchServer.pb into it), and Python 3 for the old database
# (skipped without it).
# Usage: powershell -ExecutionPolicy Bypass -File Tests\Retention-Test.ps1 [-Python <python.exe>]
param(
    [string]$Build = (Join-Path $PSScriptRoot "..\Build"),
    [string]$Python = "python"
)
$ErrorActionPreference = "Stop"
$Build = (Resolve-Path $Build).Path
$Dir = Join-Path $Build "_retentiontest"
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
    @{ Code = $LASTEXITCODE; Out = ($O -join " | "); Lines = @($O | Where-Object { "$_" -ne "" }) }
}
function Check([string]$What, [bool]$Ok, [string]$Detail) {
    if (-not $Ok) { $script:Fails++ }
    "{0} {1}`n      -> {2}" -f $(if ($Ok) { "PASS" } else { "FAIL" }), $What, $Detail
}
function Expect([string]$What, $Result, [string]$Pattern, [int]$Code = 0) {
    Check $What (($Result.Code -eq $Code) -and ($Result.Out -match $Pattern)) ("[{0}] {1}" -f $Result.Code, $Result.Out)
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
    if ($S.P.HasExited) { return }
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
# Waits until Sql answers something matching Pattern, for up to Seconds.
function Wait-Query($Sql, $Ini, $Pattern, $Seconds = 20) {
    $D = (Get-Date).AddSeconds($Seconds)
    do {
        $R = Query $Sql $Ini
        if ($R.Code -eq 0 -and $R.Out -match $Pattern) { return $R }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $D)
    $R
}
function Count($Topic, $Where = "") {
    "SELECT COUNT(*) AS n FROM messages WHERE topic = '$Topic' AND node = 'kitchen' $Where"
}
function NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
# Pushes Data from a file (PowerShell 5 strips the quotes of an argument).
function Push($Data, $Ini, [string]$Topic = "") {
    $F = Join-Path $Dir "push.txt"
    [IO.File]::WriteAllText($F, $Data, (New-Object System.Text.UTF8Encoding $false))
    $A = @()
    if ($Topic) { $A += @("-t", $Topic) }
    Tool "BakaShrotPushMessage.exe" ($A + @("@$F", $Ini))
}

$A = New-KeyPair; $B = New-KeyPair; $K = New-KeyPair

# A: short is kept 3 s here, everything else forever. Checked every second.
Set-Content (Join-Path $Dir "a.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($A.Priv)
Node = serverA

[BakaShrot.Topics]
logs = 1
short = 2
keep = 3
late = 4

[BakaShrot.Nodes]
serverA = 10
serverB = 11
kitchen = 2

[BakaShrot.Retention]
short = 3s

[BakaShrot.Server]
Host = 127.0.0.1
Port = 12408
ReplicatingTopics = logs;short;keep;late
DatabasePath = $(Join-Path $Dir "a.sqlite")
PeerSyncInterval = 1
PeerRetryDelay = 1
RetentionInterval = 1

[BakaShrot.Peer.b]
Host = 127.0.0.1
Port = 12409
Node = serverB
PublicKey = $($B.Pub)

[BakaShrot.Client.b]
PublicKeys = $($B.Pub)
Node = serverB
DefaultTopic = logs

[BakaShrot.Client.kitchen]
PublicKeys = $($K.Pub)
Node = kitchen
DefaultTopic = logs
PushTopics = logs;short;keep;late
ReadTopics = *
AllowQuery = 1
"@

# B: other ids. short forever, keep by a pattern (4 s), the rest 1 h.
Set-Content (Join-Path $Dir "b.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($B.Priv)
Node = serverB

[BakaShrot.Topics]
logs = 300
short = 301
keep = 302
late = 303

[BakaShrot.Nodes]
serverA = 1
serverB = 2
kitchen = 30

[BakaShrot.Retention]
short = forever
ke* = 4s
late = 3s
* = 1h

[BakaShrot.Server]
Host = 127.0.0.1
Port = 12409
ReplicatingTopics = logs;short;keep;late
DatabasePath = $(Join-Path $Dir "b.sqlite")
PeerSyncInterval = 1
PeerRetryDelay = 1
RetentionInterval = 1

[BakaShrot.Peer.a]
Host = 127.0.0.1
Port = 12408
Node = serverA
PublicKey = $($A.Pub)

[BakaShrot.Client.a]
PublicKeys = $($A.Pub)
Node = serverA
DefaultTopic = logs

[BakaShrot.Client.kitchen]
PublicKeys = $($K.Pub)
Node = kitchen
DefaultTopic = logs
ReadTopics = *
AllowQuery = 1
"@

$ServerKeys = @{ 12408 = $A.Pub; 12409 = $B.Pub }
function Client-Ini($Name, $Port) {
    $P = Join-Path $Dir "$Name.ini"
    Set-Content $P -Encoding Ascii -Value "[BakaShrot]`r`nPrivateKey = $($K.Priv)`r`nPublicKey = $($K.Pub)`r`nNode = kitchen`r`nServerHost = 127.0.0.1`r`nServerPort = $Port`r`nServerPublicKey = $($ServerKeys[$Port])"
    $P
}
$OnA = Client-Ini "kitchen-a" 12408
$OnB = Client-Ini "kitchen-b" 12409

# A database from before pushed_at, for A: one message, logs:kitchen #1.
$HasOld = $false
$Seed = @"
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE data (topic_id INTEGER NOT NULL, node_id INTEGER NOT NULL, message_id INTEGER NOT NULL, message_data TEXT NOT NULL, is_json INTEGER NOT NULL GENERATED ALWAYS AS (json_valid(message_data)) STORED, UNIQUE (topic_id, node_id, message_id))")
db.execute("INSERT INTO data (topic_id, node_id, message_id, message_data) VALUES (1, 2, 1, '{\"old\":1}')")
db.commit()
"@
Set-Content (Join-Path $Dir "seed.py") -Encoding Ascii -Value $Seed
try {
    & $Python -B (Join-Path $Dir "seed.py") (Join-Path $Dir "a.sqlite") 2>&1 | Out-Null
    $HasOld = ($LASTEXITCODE -eq 0)
} catch { $HasOld = $false }
if (-not $HasOld) { "SKIP the old database: no Python ($Python)" ; Remove-Item (Join-Path $Dir "a.sqlite") -ErrorAction SilentlyContinue }

foreach ($Port in 12408, 12409) { if (Test-Port $Port) { throw "Port $Port is already in use" } }
$Before = NowMs
$SA = Start-Srv "a"; $SB = $null
try {
    Wait-Port 12408 $SA
    "--- Before B starts: late #1-#2 on A, past B's 3 s once B gets them"
    foreach ($i in 1..2) { Expect "push late #$i" (Push "{`"late`":$i}" $OnA "late") "message #$i" }
    Start-Sleep -Seconds 5
    $SB = Start-Srv "b"
    Wait-Port 12409 $SB
    Start-Sleep -Seconds 2

    "--- The old database"
    if ($HasOld) {
        $R = Query "SELECT message_id, pushed_at FROM data WHERE topic_id = 1 AND node_id = 2" $OnA
        $Stamp = 0; if ($R.Out -match '\[\["1","(\d+)"\]\]') { $Stamp = [int64]$Matches[1] }
        Check "the old message got pushed_at: the time of the upgrade" ($Stamp -ge $Before - 1000 -and $Stamp -le (NowMs)) $R.Out
        Expect "its ids go on: the next push is #2" (Push '{"n":"after upgrade"}' $OnA) "message #2"
    } else {
        Expect "first push" (Push '{"n":"first"}' $OnA) "message #1"
        Expect "second push" (Push '{"n":"after upgrade"}' $OnA) "message #2"
    }

    "--- pushed_at"
    $PushedFrom = NowMs
    Expect "push logs #3" (Push '{"n":"stamped"}' $OnA) "message #3"
    $PushedTo = NowMs
    $R = Query "SELECT pushed_at, pushed_utc FROM messages WHERE topic = 'logs' AND node = 'kitchen' AND message_id = 3" $OnA
    $Stamp = 0; if ($R.Out -match '\[\["(\d+)","([^"]+)"\]\]') { $Stamp = [int64]$Matches[1]; $Utc = $Matches[2] }
    Check "stamped with the time it arrived, in UTC ms" ($Stamp -ge $PushedFrom - 50 -and $Stamp -le $PushedTo + 50) "$Stamp in [$PushedFrom, $PushedTo]"
    $Expected = [DateTimeOffset]::FromUnixTimeMilliseconds($Stamp).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    Check "the view's pushed_utc is the same, as text" ($Utc -eq $Expected) "$Utc, expected $Expected"

    $R = Tool "BakaShrotGetMessages.exe" @("logs", "kitchen", "--after", "2", "--time", $OnA)
    Check "BakaShrotGetMessages --time: id, time, data" ($R.Code -eq 0 -and $R.Lines.Count -eq 1 -and $R.Lines[0] -eq "3`t$Expected`t{`"n`":`"stamped`"}") $R.Out
    $R = Tool "BakaShrotGetMessages.exe" @("logs", "kitchen", "--after", "2", $OnA)
    Check "BakaShrotGetMessages without --time: as before" ($R.Code -eq 0 -and $R.Lines.Count -eq 1 -and $R.Lines[0] -eq "3`t{`"n`":`"stamped`"}") $R.Out
    Expect "BakaShrotGetLatestMessage shows it" (Tool "BakaShrotGetLatestMessage.exe" @("logs", "kitchen", $OnA)) ("#3 \(ids 1:2\), pushed " + [regex]::Escape($Expected))

    $Sql = "SELECT message_id, pushed_at FROM messages WHERE topic = 'logs' AND node = 'kitchen' ORDER BY message_id"
    $OnAStamps = (Query $Sql $OnA).Out
    $R = Wait-Query $Sql $OnB '"3","\d+"'
    Check "replicated with the same pushed_at, every one" ($R.Out -eq $OnAStamps) "A $OnAStamps | B $($R.Out)"
    Expect "BakaShrotGetLatestMessage on B: the same time" (Tool "BakaShrotGetLatestMessage.exe" @("logs", "kitchen", $OnB)) ("#3 \(ids 300:30\), pushed " + [regex]::Escape($Expected))

    "--- Retention on A (short = 3s), not on B (short = forever)"
    foreach ($i in 1..3) { Expect "push short #$i" (Push "{`"short`":$i}" $OnA "short") "message #$i" }
    $R = Wait-Query (Count "short") $OnB '\[\["3"\]\]' 10
    Check "B got the 3 short ones" ($R.Out -match '\[\["3"\]\]') $R.Out
    $R = Wait-Query (Count "short") $OnA '\[\["0"\]\]' 10
    Check "A deleted them past 3 s" ($R.Out -match '\[\["0"\]\]') $R.Out
    Expect "A kept logs (no max age)" (Query (Count "logs") $OnA) '\[\["3"\]\]'
    Expect "B kept them (its own rules)" (Query (Count "short") $OnB) '\[\["3"\]\]'
    Expect "A: no message left in short" (Tool "BakaShrotGetLatestMessage.exe" @("short", "kitchen", $OnA)) "No message" 1
    Expect "A's ids go on after deleting: #4" (Push '{"short":4}' $OnA "short") "message #4"
    $R = Wait-Query (Count "short") $OnB '\[\["4"\]\]' 10
    Check "B got #4" ($R.Out -match '\[\["4"\]\]') $R.Out
    Start-Sleep -Seconds 3
    Expect "B didn't send A back what A deleted" (Query (Count "short" "AND message_id <= 3") $OnA) '\[\["0"\]\]'

    "--- Retention on B by pattern (ke* = 4s), not on A"
    foreach ($i in 1..2) { Expect "push keep #$i" (Push "{`"keep`":$i}" $OnA "keep") "message #$i" }
    $R = Wait-Query (Count "keep") $OnB '\[\["2"\]\]' 10
    Check "B got the 2 keep ones" ($R.Out -match '\[\["2"\]\]') $R.Out
    $R = Wait-Query (Count "keep") $OnB '\[\["0"\]\]' 10
    Check "B deleted them past 4 s" ($R.Out -match '\[\["0"\]\]') $R.Out
    Expect "A kept them" (Query (Count "keep") $OnA) '\[\["2"\]\]'
    Expect "push keep #3" (Push '{"keep":3}' $OnA "keep") "message #3"
    $R = Wait-Query (Count "keep") $OnB '\[\["1"\]\]' 10
    Check "B only got #3, not #1 and #2 again" ($R.Out -match '\[\["1"\]\]') $R.Out
    Expect "B: it's #3" (Tool "BakaShrotGetLatestMessage.exe" @("keep", "kitchen", $OnB)) "keep:kitchen#3"
    Expect "B's * = 1h keeps logs" (Query (Count "logs") $OnB) '\[\["3"\]\]'

    "--- Replicated already past the max age (B: late = 3s)"
    $Head = "SELECT h.max_message_id FROM node_heads h JOIN topics t ON t.topic_id = h.topic_id WHERE t.name = 'late'"
    $R = Wait-Query $Head $OnB '\[\["2"\]\]' 10
    Check "B counts late #1-#2 as received (its head is 2)" ($R.Out -match '\[\["2"\]\]') $R.Out
    Expect "but didn't store them" (Query (Count "late") $OnB) '\[\["0"\]\]'
    Expect "A has them" (Query (Count "late") $OnA) '\[\["2"\]\]'
    Expect "push late #3, fresh" (Push '{"late":3}' $OnA "late") "message #3"
    $R = Wait-Query $Head $OnB '\[\["3"\]\]' 10
    Check "B got #3" ($R.Out -match '\[\["3"\]\]') $R.Out
    # Stored, then deleted 3 s later by the pass, alone: #1-#2 never were.
    $D = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $D -and -not ((Get-Content (Join-Path $Dir "b.log") -Raw) -match "deleted 1 messages of topic 'late'")) { Start-Sleep -Milliseconds 250 }
    Check "B stored #3, and deleted it alone past 3 s" ((Get-Content (Join-Path $Dir "b.log") -Raw) -match "deleted 1 messages of topic 'late'") "checked"
    Start-Sleep -Seconds 2
}
finally {
    Stop-Srv $SA; if ($SB) { Stop-Srv $SB }
}

"--- Logs"
$LogA = Get-Content (Join-Path $Dir "a.log") -Raw
$LogB = Get-Content (Join-Path $Dir "b.log") -Raw
# How many messages of Topic a log says were deleted. Pushed a few ms apart,
# they can fall on both sides of a retention check (every 1 s), and be
# deleted over two of them.
function Count-Deleted($Log, $Topic) {
    $N = 0
    foreach ($M in [regex]::Matches($Log, "Retention: deleted (\d+) messages of topic '$Topic' pushed before \d{4}-")) { $N += [int]$M.Groups[1].Value }
    $N
}
Check "A logged its rule" ($LogA -match "Retention: short = 3s") "checked"
$N = Count-Deleted $LogA "short"
Check "A logged what it deleted: short #1-#3, maybe #4 since" ($N -ge 3) "$N deleted"
Check "B logged its rules" ($LogB -match "Retention: ke\* = 4s" -and $LogB -match "Retention: \* = 1h") "checked"
$N = Count-Deleted $LogB "keep"
Check "B deleted keep: #1-#2, maybe #3 since" ($N -ge 2) "$N deleted"
Check "B never sent A short messages (A is ahead, deleted or not)" (-not ($LogB -match "Sent \d+ messages of short")) "checked"
Check "A sent B late once each: #1-#2, then #3 alone" (([regex]::Matches($LogA, "Sent 2 messages of late:kitchen")).Count -eq 1 -and ([regex]::Matches($LogA, "Sent 1 messages of late:kitchen")).Count -eq 1) "checked"
Check "B never stored late #1-#2" (-not ($LogB -match "deleted [23] messages of topic 'late'")) "checked"
Check "A sent B keep twice: #1-#2, then #3 alone" ($LogA -match "Sent 2 messages of keep:kitchen" -and $LogA -match "Sent 1 messages of keep:kitchen" -and -not ($LogA -match "Sent 3 messages of keep")) "checked"
# A tries to link to B in the 5 s before B starts: those are expected.
$LinkTries = @([regex]::Matches($LogA, "Failed to link to 'b'")).Count
Check "A only failed to link to B before B started" ($LinkTries -le 8) "$LinkTries tries"
$LogAOther = ($LogA -split "`r?`n" | Where-Object { $_ -notmatch "Failed to link to 'b'|Retrying 'b'" }) -join "`n"
foreach ($P in @("Failed", "invalid", "unexpected", "doesn't decrypt")) {
    Check "no '$P' in A's or B's log" (-not ($LogAOther -match [regex]::Escape($P)) -and -not ($LogB -match [regex]::Escape($P))) "checked"
}

"--- An age without a unit"
(Get-Content (Join-Path $Dir "a.ini") -Raw) -replace "short = 3s", "short = 30" | Set-Content (Join-Path $Dir "bad.ini") -Encoding Ascii
$SBad = Start-Srv "bad"
$Exited = $SBad.P.WaitForExit(10000)
if (-not $Exited) { Stop-Srv $SBad }
$LogBad = Get-Content (Join-Path $Dir "bad.log") -Raw
Check "refused at start" ($Exited -and $SBad.P.ExitCode -ne 0 -and $LogBad -match "short = '30' isn't an age") $LogBad.Trim()

""
if ($Fails) { "$Fails FAILED"; exit 1 } else { "All passed" }
