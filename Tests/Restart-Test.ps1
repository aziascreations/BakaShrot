# End-to-end test of a server killed mid-traffic and restarted (a crash,
# not a clean stop): what it acknowledged survives, its ids carry on where
# they stopped, and the two servers catch up with each other both ways.
#
# Two linked servers, A and B, each with its own client node pushing
# (kitchen on A, garage on B: one writer per topic/node pair) through
# Tests/restart_pusher.py, as fast as acknowledgements come back:
#   1. B killed while both push; A keeps pushing while B is down; B
#      restarted: every push it acknowledged is there, no gap, its next id
#      follows, and both servers end up with the same messages.
#   2. B killed again a fraction of a second into that catch-up, restarted:
#      still converges.
#   3. A killed while both push (the other direction), restarted: same.
# The servers are killed with Stop-Process -Force (TerminateProcess), like
# a crash. Synchronous is the default (FULL); a killed process loses
# nothing committed with NORMAL either, only a power loss would.
#
# Needs Build\ (Build.ps1), Build\Bench\BenchServer.exe, and Python 3 on the
# PATH (the pushers use Interactors/Python/bakashrot.py). Uses ports
# 12415-12416.
# Usage: powershell -ExecutionPolicy Bypass -File Tests\Restart-Test.ps1

param([string]$Build = (Join-Path $PSScriptRoot "..\Build"), [string]$Python = "python")

$ErrorActionPreference = "Stop"
$Build = (Resolve-Path $Build).Path
$Dir = Join-Path $Build "_restarttest"
Remove-Item -Recurse -Force $Dir -ErrorAction SilentlyContinue
New-Item -ItemType Directory $Dir | Out-Null
$Server = Join-Path $Build "Bench\BenchServer.exe"
$Dll = Join-Path $Build "BakaShrot_Client.dll"
$Pusher = Join-Path $PSScriptRoot "restart_pusher.py"
$Fails = 0

$PythonExe = (Get-Command $Python -ErrorAction SilentlyContinue)
if (-not $PythonExe) { "FAIL no Python ($Python), the pushers need it"; exit 1 }
$PythonExe = $PythonExe.Source

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
function Check([string]$What, [bool]$Ok, [string]$Detail) {
    if (-not $Ok) { $script:Fails++ }
    "{0} {1}`n      -> {2}" -f $(if ($Ok) { "PASS" } else { "FAIL" }), $What, $Detail
}
function Start-Srv($Name) {
    $Stop = Join-Path $Dir "$Name.stop"
    Remove-Item $Stop -ErrorAction SilentlyContinue
    # Each run its own log, the previous ones are kept for a look.
    $script:Runs[$Name] = 1 + [int]$script:Runs[$Name]
    $P = Start-Process -FilePath $Server -ArgumentList "`"$(Join-Path $Dir "$Name.ini")`"", "`"$Stop`"" -WorkingDirectory $Dir `
        -RedirectStandardOutput (Join-Path $Dir ("{0}.{1}.log" -f $Name, $script:Runs[$Name])) -WindowStyle Hidden -PassThru
    $null = $P.Handle
    @{ P = $P; Stop = $Stop; Name = $Name }
}
function Stop-Srv($S) {
    if ($S.P.HasExited) { return }
    Set-Content $S.Stop "x"
    if (-not $S.P.WaitForExit(15000)) { Stop-Process -Id $S.P.Id -Force }
}
function Kill-Srv($S) {
    Stop-Process -Id $S.P.Id -Force
    $null = $S.P.WaitForExit(10000)
}
function Wait-Port($Port, $S) {
    $D = (Get-Date).AddSeconds(15)
    while (-not (Test-Port $Port)) {
        if ($S.P.HasExited) { throw "$($S.Name) exited" }
        if ((Get-Date) -gt $D) { throw "$($S.Name) not listening" }
        Start-Sleep -Milliseconds 100
    }
}
function Query($Sql, $Ini) {
    $F = Join-Path $Dir ("q-" + [guid]::NewGuid().ToString("N") + ".sql"); Set-Content $F -Encoding Ascii -Value $Sql
    $R = Tool "BakaShrotQuery.exe" @("@$F", $Ini)
    Remove-Item $F
    $R
}

# A pusher in the background: Name's out file gets "<id> <seq>" per
# acknowledged push, then STOPPED or ERR.
function Start-Pusher($Name, $Ini) {
    $Out = Join-Path $Dir "$Name.out"; $Stop = Join-Path $Dir "$Name.stop"
    Remove-Item $Out, $Stop -ErrorAction SilentlyContinue
    $P = Start-Process -FilePath $PythonExe -ArgumentList "-B", "`"$Pusher`"", "`"$Dll`"", "`"$Ini`"", "`"$Stop`"", "`"$Out`"", $Name `
        -WorkingDirectory $Build -WindowStyle Hidden -PassThru
    $null = $P.Handle
    @{ P = $P; Out = $Out; Stop = $Stop; Name = $Name }
}
function Stop-Pusher($Pu) {
    Set-Content $Pu.Stop "x"
    if (-not $Pu.P.WaitForExit(15000)) { Stop-Process -Id $Pu.P.Id -Force }
}
# What a pusher saw: how many acknowledged, the last id and seq, how it ended.
function Read-Pusher($Pu) {
    $Lines = @(Get-Content $Pu.Out -ErrorAction SilentlyContinue)
    $Acked = @($Lines | Where-Object { $_ -match "^\d+ \d+$" })
    $Last = if ($Acked.Count) { $Acked[-1] -split " " } else { @("0", "0") }
    @{ Count = $Acked.Count; LastId = [int64]$Last[0]; LastSeq = [int]$Last[1]; End = [string]($Lines | Select-Object -Last 1) }
}

# Every node of logs on a server: count, first and last id, and sums over
# the data and the push times, to compare two servers.
$StatsSql = "SELECT node, COUNT(*), MIN(message_id), MAX(message_id), SUM(length(message_data)), SUM(pushed_at % 1000003), SUM(message_id * length(message_data)) FROM messages WHERE topic = 'logs' GROUP BY node ORDER BY node"
function Stats($Ini) {
    $R = Query $StatsSql $Ini
    if ($R.Code -ne 0) { return "query failed: " + $R.Out }
    ($R.Out -replace '^.*"rows":', '')
}
# The highest id and the count of a node on a server.
function Head($Node, $Ini) {
    $R = Query "SELECT COUNT(*), COALESCE(MAX(message_id), 0) FROM messages WHERE topic = 'logs' AND node = '$Node'" $Ini
    if ($R.Out -match '\[\["(\d+)","(\d+)"\]\]') { @{ Count = [int64]$Matches[1]; Max = [int64]$Matches[2] } } else { @{ Count = -1; Max = -1; Out = $R.Out } }
}
# Waits until A and B have the same messages, and at least Kitchen and
# Garage messages of each node. Returns the stats, and whether they matched.
function Wait-Converged($Kitchen, $Garage, $Seconds = 60) {
    $D = (Get-Date).AddSeconds($Seconds)
    do {
        $SA = Stats $OnA; $SB = Stats $OnB
        $HK = Head "kitchen" $OnB; $HG = Head "garage" $OnA
        if ($SA -eq $SB -and $HK.Count -ge $Kitchen -and $HG.Count -ge $Garage) { return @{ Ok = $true; A = $SA; B = $SB } }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $D)
    @{ Ok = $false; A = $SA; B = $SB }
}
# What a restarted server must show for the node its pusher wrote to: every
# acknowledged push there (ids 1..max without a gap, max at least the last
# acknowledged one, its data the one acknowledged), and at most one more
# (committed, the answer lost with the kill). Leaves the node's head in
# $Survived: a function's return value would take its PASS/FAIL lines too.
function Check-Survived($What, $Node, $Pu, $Ini) {
    $Seen = Read-Pusher $Pu
    $H = Head $Node $Ini
    Check "$What`: every acknowledged push survived, ids without a gap" `
        ($Seen.LastId -gt 0 -and $H.Count -eq $H.Max -and $H.Max -ge $Seen.LastId -and $H.Max -le $Seen.LastId + 1) `
        ("{0} acknowledged, last #{1}; stored {2}, last #{3}; pusher: {4}" -f $Seen.Count, $Seen.LastId, $H.Count, $H.Max, $Seen.End)
    $R = Query "SELECT message_data FROM messages WHERE topic = 'logs' AND node = '$Node' AND message_id = $($Seen.LastId)" $Ini
    Check "$What`: the last acknowledged one is the one pushed" ($R.Out -match ('\\"seq\\":' + $Seen.LastSeq + '[,}]')) $R.Out
    $script:Survived = $H
}

$A = New-KeyPair; $B = New-KeyPair; $K = New-KeyPair; $G = New-KeyPair
$Runs = @{}

# Topics listed by name, nodes from the sections: a restart must give every
# name its id back, by the database.
function Write-Config($Name, $Keys, $Port, $Node, $PeerName, $PeerPort, $PeerNode, $PeerKey, $ClientNode, $ClientKey) {
    Set-Content (Join-Path $Dir "$Name.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($Keys.Priv)
Node = $Node

[BakaShrot.Topics]
logs

[BakaShrot.Server]
Host = 127.0.0.1
Port = $Port
ReplicatingTopics = logs
DatabasePath = $(Join-Path $Dir "$Name.sqlite")
PeerSyncInterval = 1
PeerRetryDelay = 1
PeerBatchSize = 10

[BakaShrot.Peer.$PeerName]
Host = 127.0.0.1
Port = $PeerPort
Node = $PeerNode
PublicKey = $PeerKey

[BakaShrot.Client.$PeerName]
PublicKeys = $PeerKey
Node = $PeerNode
AllowWrite = 0

[BakaShrot.Client.$ClientNode]
PublicKeys = $ClientKey
Node = $ClientNode
DefaultTopic = logs
ReadTopics = *
AllowQuery = 1
"@
}
Write-Config "a" $A 12415 "serverA" "b" 12416 "serverB" $B.Pub "kitchen" $K.Pub
Write-Config "b" $B 12416 "serverB" "a" 12415 "serverA" $A.Pub "garage" $G.Pub
Set-Content (Join-Path $Dir "kitchen.ini") -Encoding Ascii -Value "[BakaShrot]`r`nPrivateKey = $($K.Priv)`r`nPublicKey = $($K.Pub)`r`nNode = kitchen`r`nServerHost = 127.0.0.1`r`nServerPort = 12415`r`nServerPublicKey = $($A.Pub)"
Set-Content (Join-Path $Dir "garage.ini") -Encoding Ascii -Value "[BakaShrot]`r`nPrivateKey = $($G.Priv)`r`nPublicKey = $($G.Pub)`r`nNode = garage`r`nServerHost = 127.0.0.1`r`nServerPort = 12416`r`nServerPublicKey = $($B.Pub)"
$OnA = Join-Path $Dir "kitchen.ini"; $OnB = Join-Path $Dir "garage.ini"
Set-Content (Join-Path $Dir "next.json") -Encoding Ascii -Value '{"after":"restart"}'
$Next = "@" + (Join-Path $Dir "next.json")

$SA = Start-Srv "a"; $SB = Start-Srv "b"
$Pushers = @()
try {
    Wait-Port 12415 $SA; Wait-Port 12416 $SB

    "--- 1. B killed while both push, A keeps pushing, B restarted"
    $PK = Start-Pusher "kitchen-1" $OnA; $PG = Start-Pusher "garage-1" $OnB; $Pushers += $PK, $PG
    Start-Sleep -Seconds 3
    Kill-Srv $SB
    $null = $PG.P.WaitForExit(15000)
    Start-Sleep -Seconds 3                                   # A goes on alone
    Stop-Pusher $PK
    $KSeen = Read-Pusher $PK
    Check "the garage pusher noticed B was gone: ConnectionLostError, code 104" ($PG.P.HasExited -and (Read-Pusher $PG).End -like "ERR 104 ConnectionLostError*") (Read-Pusher $PG).End
    Check "kitchen kept pushing on A meanwhile" ($KSeen.Count -gt 100 -and $KSeen.End -eq "STOPPED") ("{0} acknowledged" -f $KSeen.Count)

    $SB = Start-Srv "b"; Wait-Port 12416 $SB
    Check-Survived "B" "garage" $PG $OnB
    $HG = $Survived
    $R = Tool "BakaShrotPushMessage.exe" @($Next, $OnB)
    Check "B: the next push carries on from the last id" ($R.Out -match "message #$($HG.Max + 1)\b") ("after #{0}: {1}" -f $HG.Max, $R.Out)
    $C = Wait-Converged $KSeen.LastId ($HG.Max + 1)
    Check "A and B converged (B caught up on kitchen, A on garage)" $C.Ok ("A {0}`n         B {1}" -f $C.A, $C.B)

    "--- 2. B killed again in the middle of its catch-up"
    $Before = (Head "kitchen" $OnB).Count
    $PK = Start-Pusher "kitchen-2" $OnA; $Pushers += $PK
    Start-Sleep -Seconds 1
    Kill-Srv $SB
    Start-Sleep -Seconds 6                                   # a backlog for B
    Stop-Pusher $PK
    $Total = (Head "kitchen" $OnA).Max
    $SB = Start-Srv "b"; Wait-Port 12416 $SB
    # Killed as soon as some of the backlog is in, not all of it.
    $D = (Get-Date).AddSeconds(30)
    do {
        $Mid = Head "kitchen" $OnB
        if ($Mid.Count -gt $Before -and $Mid.Count -lt $Total) { Kill-Srv $SB; break }
        Start-Sleep -Milliseconds 20
    } while ($Mid.Count -lt $Total -and (Get-Date) -lt $D)
    Check "B killed partway through its catch-up" ($Mid.Count -gt $Before -and $Mid.Count -lt $Total) `
        ("B had {0} kitchen messages before, {1} when killed, A {2}" -f $Before, $Mid.Count, $Total)
    if (-not $SB.P.HasExited) { Kill-Srv $SB }
    $SB = Start-Srv "b"; Wait-Port 12416 $SB
    $C = Wait-Converged $Total 0
    Check "B restarted, still converged" $C.Ok ("A {0}`n         B {1}" -f $C.A, $C.B)
    $H = Head "kitchen" $OnB
    Check "B's copy of kitchen has no gap" ($H.Count -eq $H.Max -and $H.Max -eq $Total) ("{0} stored, last #{1}, A's last #{2}" -f $H.Count, $H.Max, $Total)

    "--- 3. A killed while both push, B keeps pushing, A restarted"
    $PK = Start-Pusher "kitchen-3" $OnA; $PG = Start-Pusher "garage-3" $OnB; $Pushers += $PK, $PG
    Start-Sleep -Seconds 3
    Kill-Srv $SA
    $null = $PK.P.WaitForExit(15000)
    Start-Sleep -Seconds 3                                   # B goes on alone
    Stop-Pusher $PG
    $GSeen = Read-Pusher $PG
    Check "the kitchen pusher noticed A was gone: ConnectionLostError, code 104" ($PK.P.HasExited -and (Read-Pusher $PK).End -like "ERR 104 ConnectionLostError*") (Read-Pusher $PK).End

    $SA = Start-Srv "a"; Wait-Port 12415 $SA
    Check-Survived "A" "kitchen" $PK $OnA
    $HK = $Survived
    $R = Tool "BakaShrotPushMessage.exe" @($Next, $OnA)
    Check "A: the next push carries on from the last id" ($R.Out -match "message #$($HK.Max + 1)\b") ("after #{0}: {1}" -f $HK.Max, $R.Out)
    $C = Wait-Converged ($HK.Max + 1) $GSeen.LastId
    Check "A and B converged again" $C.Ok ("A {0}`n         B {1}" -f $C.A, $C.B)

    "--- Logs"
    $Bad = @(Get-ChildItem $Dir -Filter "*.log" | Select-String "Failed|refused|corrupt|malformed" | Where-Object { $_.Line -notmatch "Failed to connect|Lost the link|link to .* failed" })
    Check "no failure in either server's logs, other than the links lost to the kills" ($Bad.Count -eq 0) $(if ($Bad.Count) { ($Bad | Select-Object -First 5 | ForEach-Object { "$($_.Filename): $($_.Line)" }) -join " | " } else { "none" })
} finally {
    foreach ($Pu in $Pushers) { if (-not $Pu.P.HasExited) { Stop-Process -Id $Pu.P.Id -Force } }
    Stop-Srv $SA; Stop-Srv $SB
}

""
if ($Fails) { "$Fails FAILED"; exit 1 } else { "All passed" }
