# End-to-end test of big messages: up to 16 MB once authenticated, 4 KB
# frames before that (Commons/Networking/Connections.pbi).
# Two linked servers: pushes of 100 KB, 1 MB and just under the cap, read
# back through the client DLL, replicated to the other server, small ones
# still batched, a push over the cap refused, and frames too big for the
# handshake cutting the connection right away.
# Needs Build\ (Build.ps1) and Build\Bench\BenchServer.exe (Bench-Replication.ps1,
# or compile Tests\Bench\BenchServer.pb into it). Uses ports 12403-12404.
# Usage: powershell -ExecutionPolicy Bypass -File Tests\BigMessages-Test.ps1
param([string]$Build = (Join-Path $PSScriptRoot "..\Build"))
$ErrorActionPreference = "Stop"
$Build = (Resolve-Path $Build).Path
$Dir = Join-Path $Build "_bigtest"
Remove-Item -Recurse -Force $Dir -ErrorAction SilentlyContinue
New-Item -ItemType Directory $Dir | Out-Null
$Server = Join-Path $Build "Bench\BenchServer.exe"
$Fails = 0

# Same as Packets.pbi.
$MaxPacketSize  = 16 * 1024 * 1024
$MaxMessageSize = $MaxPacketSize - 4096

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
function Expect([string]$What, $Result, [string]$Pattern, [int]$Code = 0) {
    $Out = $Result.Out
    if ($Out.Length -gt 300) { $Out = $Out.Substring(0, 300) + "... (" + $Result.Out.Length + " chars)" }
    Check $What (($Result.Code -eq $Code) -and ($Result.Out -match $Pattern)) ("[{0}] {1}" -f $Result.Code, $Out)
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
# Waits until Sql answers something matching Pattern, for up to Seconds.
function Wait-Query($Sql, $Ini, $Pattern, $Seconds = 30) {
    $D = (Get-Date).AddSeconds($Seconds)
    do {
        $R = Query $Sql $Ini
        if ($R.Code -eq 0 -and $R.Out -match $Pattern) { return $R }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $D)
    $R
}
# A JSON message of exactly Size bytes, in a file, as BakaShrotPushMessage's @File.
function New-Message($Name, [int]$Size) {
    $P = Join-Path $Dir "$Name.json"
    $Head = '{"n":"' + $Name + '","pad":"'
    $Tail = '"}'
    $Pad = $Size - $Head.Length - $Tail.Length
    $B = New-Object System.Text.StringBuilder ($Size)
    [void]$B.Append($Head)
    [void]$B.Append(("0123456789abcdef" * [math]::Ceiling($Pad / 16)).Substring(0, $Pad))
    [void]$B.Append($Tail)
    [IO.File]::WriteAllText($P, $B.ToString(), (New-Object System.Text.UTF8Encoding $false))
    "@$P"
}
# Connects, sends one frame header announcing Size bytes, then up to 64 KB of
# zeros, and tells whether the server closed (or reset) the connection
# within 3 s, rather than waiting for the rest.
function Test-RawFrame([int]$Port, [int]$Size) {
    $C = New-Object System.Net.Sockets.TcpClient
    $Start = Get-Date
    try {
        $C.Connect("127.0.0.1", $Port)
        $S = $C.GetStream()
        $S.ReadTimeout = 5000
        $S.Write([BitConverter]::GetBytes([int]$Size), 0, 4)
        try { $S.Write((New-Object byte[] ([math]::Min($Size, 65536))), 0, [math]::Min($Size, 65536)) } catch { }
        $Buffer = New-Object byte[] 16
        try { $Read = $S.Read($Buffer, 0, 16) } catch { $Read = -1 }
        ($Read -le 0) -and (((Get-Date) - $Start).TotalSeconds -lt 3)
    } catch { ((Get-Date) - $Start).TotalSeconds -lt 3 } finally { $C.Close() }
}

$A = New-KeyPair; $B = New-KeyPair; $K = New-KeyPair

# Same names on both, different ids.
Set-Content (Join-Path $Dir "a.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($A.Priv)
Node = serverA

[BakaShrot.Topics]
logs = 1

[BakaShrot.Nodes]
serverA = 10
serverB = 11
kitchen = 2

[BakaShrot.Server]
Host = 127.0.0.1
Port = 12403
ReplicatingTopics = logs
DatabasePath = $(Join-Path $Dir "a.sqlite")
PeerSyncInterval = 1
PeerRetryDelay = 1

[BakaShrot.Peer.b]
Host = 127.0.0.1
Port = 12404
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
ReadTopics = *
AllowQuery = 1
"@

Set-Content (Join-Path $Dir "b.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($B.Priv)
Node = serverB

[BakaShrot.Topics]
logs = 300

[BakaShrot.Nodes]
serverA = 1
serverB = 2
kitchen = 30

[BakaShrot.Server]
Host = 127.0.0.1
Port = 12404
ReplicatingTopics = logs
DatabasePath = $(Join-Path $Dir "b.sqlite")
PeerSyncInterval = 1
PeerRetryDelay = 1

[BakaShrot.Peer.a]
Host = 127.0.0.1
Port = 12403
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

$ServerKeys = @{ 12403 = $A.Pub; 12404 = $B.Pub }
function Client-Ini($Name, $Port) {
    $P = Join-Path $Dir "$Name.ini"
    Set-Content $P -Encoding Ascii -Value "[BakaShrot]`r`nPrivateKey = $($K.Priv)`r`nPublicKey = $($K.Pub)`r`nNode = kitchen`r`nServerHost = 127.0.0.1`r`nServerPort = $Port`r`nServerPublicKey = $($ServerKeys[$Port])"
    $P
}
$OnA = Client-Ini "kitchen-a" 12403
$OnB = Client-Ini "kitchen-b" 12404

$Sizes = [ordered]@{ "m100k" = 100 * 1024; "m1m" = 1024 * 1024; "mmax" = $MaxMessageSize }
$Files = @{}
foreach ($N in $Sizes.Keys) { $Files[$N] = New-Message $N $Sizes[$N] }
$Over  = New-Message "over" ($MaxMessageSize + 1)
# Not JSON: 1 MB of it cut short, and plain text. Stored anyway, is_json = 0.
$Broken = Join-Path $Dir "broken.json"
[IO.File]::WriteAllText($Broken, ([IO.File]::ReadAllText($Files["m1m"].Substring(1))).Substring(0, 1000000))
$Text = Join-Path $Dir "text.txt"
[IO.File]::WriteAllText($Text, "just some text, not JSON")
$Small = New-Message "small" 40

$SA = Start-Srv "a"; $SB = Start-Srv "b"
try {
    Wait-Port 12403 $SA; Wait-Port 12404 $SB

    "--- Before authenticating"
    Check "a frame over 4 KB is cut right away" (Test-RawFrame 12403 4097) "connection closed"
    Check "a 16 MB frame too" (Test-RawFrame 12403 $MaxPacketSize) "connection closed"
    Check "the server still serves after that" (Test-Port 12403) "listening"

    "--- Pushes"
    $Id = 0
    foreach ($N in $Sizes.Keys) {
        $Id++
        $T = Measure-Command { $R = Tool "BakaShrotPushMessage.exe" @($Files[$N], $OnA) }
        Expect ("push of {0:N0} bytes ({1:N0} ms)" -f $Sizes[$N], $T.TotalMilliseconds) $R "message #$Id"
    }
    Expect "a push 1 byte over the cap is refused" (Tool "BakaShrotPushMessage.exe" @($Over, $OnA)) "too big" 1
    $Id++
    Expect "a small push after them" (Tool "BakaShrotPushMessage.exe" @($Small, $OnA)) "message #$Id"

    "--- Read back"
    $T = Measure-Command { $O = & (Join-Path $Build "BakaShrotGetLatestMessage.exe") "logs" "kitchen" $OnA 2>&1 }
    $Code = $LASTEXITCODE
    Check "latest is the small one" ($Code -eq 0 -and ($O -join "") -match '"n":"small"') ($O -join " | ")
    $R = Query "SELECT message_id, length(message_data) FROM data WHERE node_id = 2 ORDER BY message_id" $OnA
    Expect "stored sizes on A" $R ('\[\["1","{0}"\],\["2","{1}"\],\["3","{2}"\],\["4","40"\]\]' -f $Sizes["m100k"], $Sizes["m1m"], $MaxMessageSize)

    "--- Replicated to B (same names, B's ids)"
    $R = Wait-Query "SELECT message_id, length(message_data), topic_id, node_id FROM messages WHERE topic = 'logs' AND node = 'kitchen' ORDER BY message_id" $OnB '"4","40"' 60
    Expect "every one on B, under logs=300 kitchen=30" $R ('\[\["1","{0}","300","30"\],\["2","{1}","300","30"\],\["3","{2}","300","30"\],\["4","40","300","30"\]\]' -f $Sizes["m100k"], $Sizes["m1m"], $MaxMessageSize)
    $R = Query "SELECT count(*) FROM data a WHERE node_id = 30 AND message_id = 3 AND substr(message_data, 1, 31) = '{`"n`":`"mmax`",`"pad`":`"0123456789ab' AND substr(message_data, -2) = '`"}' AND is_json = 1" $OnB
    Expect "the biggest one is intact on B" $R '\[\["1"\]\]'

    "--- Read back the biggest, from B"
    # Pushed after the small one, so it's the latest.
    $Id++
    Expect "push the biggest again" (Tool "BakaShrotPushMessage.exe" @($Files["mmax"], $OnA)) "message #$Id"
    $null = Wait-Query "SELECT max(message_id) FROM data WHERE node_id = 30" $OnB "`"$Id`"" 60
    $T = Measure-Command { $O = & (Join-Path $Build "BakaShrotGetLatestMessage.exe") "logs" "kitchen" $OnB 2>&1 }
    $Code = $LASTEXITCODE
    $Json = if ($O.Count -ge 2) { [string]$O[1] } else { "" }
    Check ("BakaShrotGetLatestMessage of {0:N0} bytes from B ({1:N0} ms)" -f $MaxMessageSize, $T.TotalMilliseconds) ($Code -eq 0 -and $Json.Length -eq $MaxMessageSize -and $Json -eq [IO.File]::ReadAllText($Files["mmax"].Substring(1))) ("[$Code] " + [string]$O[0] + ", " + $Json.Length + " chars")

    "--- Many small ones still go in batches"
    1..30 | ForEach-Object { $null = Tool "BakaShrotPushMessage.exe" @($Small, $OnA) }
    $R = Wait-Query "SELECT count(*) FROM data WHERE node_id = 30" $OnB '"35"' 30
    Expect "35 on B" $R '\[\["35"\]\]'

    "--- Not JSON: stored as is, flagged"
    Expect "1 MB of broken JSON is stored" (Tool "BakaShrotPushMessage.exe" @("@$Broken", $OnA)) "message #36"
    Expect "plain text is stored" (Tool "BakaShrotPushMessage.exe" @("@$Text", $OnA)) "message #37"
    Expect "flagged is_json = 0 on A, the rest 1" (Query "SELECT message_id, is_json, length(message_data) FROM data WHERE node_id = 2 AND message_id >= 35 ORDER BY message_id" $OnA) '\[\["35","1","40"\],\["36","0","1000000"\],\["37","0","24"\]\]'
    $R = Wait-Query "SELECT message_id, is_json, length(message_data) FROM data WHERE node_id = 30 AND message_id >= 35 ORDER BY message_id" $OnB '"37"' 30
    Expect "replicated and flagged the same on B" $R '\[\["35","1","40"\],\["36","0","1000000"\],\["37","0","24"\]\]'
    $O = & (Join-Path $Build "BakaShrotGetLatestMessage.exe") "logs" "kitchen" $OnB 2>&1
    Check "read back as is from B" ($LASTEXITCODE -eq 0 -and [string]$O[1] -eq "just some text, not JSON") ($O -join " | ")

    "--- is_json for the edge cases (SQLite's json_valid(), RFC 8259)"
    $Cases = @(
        @("42", 1), @('"a string"', 1), @("null", 1), @("[1,2]", 1), @('  {"a":1}  ', 1),
        @("{a:1}", 0), @('{"a":1} x', 0), @("{'a':1}", 0), @('{"a":1', 0), @("", 0))
    $Id = 37
    foreach ($C in $Cases) {
        $Id++
        $F = Join-Path $Dir "case$Id.txt"
        [IO.File]::WriteAllText($F, $C[0])
        $R = Tool "BakaShrotPushMessage.exe" @("@$F", $OnA)
        $Q = Query "SELECT is_json FROM data WHERE node_id = 2 AND message_id = $Id" $OnA
        Check ("'{0}' stored, is_json = {1}" -f $C[0], $C[1]) ($R.Out -match "message #$Id" -and $Q.Out -match ('"rows":\[\["{0}"\]\]' -f $C[1])) ($R.Out + " / " + $Q.Out)
    }

    "--- JSON queries over mixed rows"
    Expect "with is_json = 1, ->> works" (Query "SELECT COUNT(*) FROM data WHERE is_json = 1 AND message_data ->> '$.n' = 'small'" $OnA) '\[\["31"\]\]'
    Expect "in the select list too" (Query "SELECT COUNT(message_data ->> '$.n') FROM data WHERE is_json = 1" $OnA) '\[\["35"\]\]'
    # SQLite fails these with "malformed JSON" on the first non-JSON row.
    # PureBasic's NextDatabaseRow() can't tell that from the end of the rows,
    # RunReadOnlyQuery() asks SQLite: refused, never a partial or empty answer.
    Expect "without it, an aggregate is refused with SQLite's error, not answered with no rows" (Query "SELECT COUNT(*) FROM data WHERE message_data ->> '$.n' = 'small'" $OnA) 'Query failed: malformed JSON \(a row isn''t JSON: add is_json = 1 to the WHERE\)' 1
    Expect "rows read as they go are refused too, not cut short at the first non-JSON one" (Query "SELECT message_id, message_data ->> '$.n' FROM data WHERE node_id = 2 ORDER BY message_id" $OnA) 'Query failed: malformed JSON' 1
    Expect "non-JSON rows without JSON functions: every row" (Query "SELECT COUNT(*), SUM(is_json = 0) FROM data" $OnA) '\[\["\d+","\d+"\]\]'
    Expect "JSON functions guarded by CASE WHEN is_json: every row" (Query "SELECT COUNT(*), COUNT(CASE WHEN is_json THEN message_data ->> '$.n' END) FROM data" $OnA) '\[\["\d+","35"\]\]'
    Expect "a query with really no rows: still an empty answer" (Query "SELECT message_id FROM data WHERE message_id < 0" $OnA) '"rows":\[\]'
    Expect "and a query error still refused as before" (Query "SELECT nope FROM data" $OnA) 'Query failed: .*nope' 1
} finally {
    Stop-Srv $SA; Stop-Srv $SB
}

"--- Logs"
# Up to the last real activity: whichever stops first, the other loses its
# link to it.
function Read-Log($Name) {
    $L = @(Get-Content (Join-Path $Dir "$Name.log"))
    $End = [array]::IndexOf($L, "Stopping...")
    if ($End -lt 0) { $End = $L.Count }
    while ($End -gt 0 -and $L[$End - 1] -match "Lost the link|Dropping the link|Retrying|disconnected|aborted|didn't answer") { $End-- }
    ($L[0..([math]::Max($End - 1, 0))]) -join "`n"
}
$LogA = Read-Log "a"
$LogB = Read-Log "b"
# The raw frames are cut as an invalid frame, or as too much data when the
# zeros after the header filled the inbox before its size was checked:
# either way right away, which one is down to timing.
# Client ids get reused, so whether each one is authenticated is followed
# line by line, from its "connected".
$Authenticated = @{}; $Cut = 0; $CutAuthenticated = 0
foreach ($Line in ($LogA -split "`n")) {
    if ($Line -match "Client (\d+) connected") { $Authenticated[$Matches[1]] = $false }
    elseif ($Line -match "Client (\d+) authenticated") { $Authenticated[$Matches[1]] = $true }
    elseif ($Line -match "Client (\d+) sent (an invalid frame|too much data)") {
        $Cut++
        if ($Authenticated[$Matches[1]]) { $CutAuthenticated++ }
    }
}
Check "A cut both raw frames (invalid frame or too much data)" ($Cut -ge 2) "$Cut times"
Check "none of them from an authenticated client" ($CutAuthenticated -eq 0) "$CutAuthenticated"
# Without the refusals this test asks for ("Query failed: malformed JSON", ...).
$UnrefusedA = ($LogA -split "`n" | Where-Object { $_ -notmatch "Refused a request" }) -join "`n"
$UnrefusedB = ($LogB -split "`n" | Where-Object { $_ -notmatch "Refused a request" }) -join "`n"
foreach ($P in @("too big", "Lost the link", "Failed")) {
    Check "no '$P' in A's or B's log" (-not ($UnrefusedA -match [regex]::Escape($P)) -and -not ($UnrefusedB -match [regex]::Escape($P))) "checked"
}
Check "no 'sent too much data' in B's log" (-not ($LogB -match "sent too much data")) "checked"

""
if ($Fails) { "$Fails FAILED"; exit 1 } else { "All passed" }
