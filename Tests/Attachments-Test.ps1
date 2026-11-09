# End-to-end test of attachments (Design/Attachments.md), through the tools
# (BakaShrotPushMessage -a, BakaShrotGetAttachment, BakaShrotGetLatestMessage):
#   - pushed with a message, read back identical (100 KB, 5 MB + a bit,
#     exactly 2 MB: one part, several, a whole number of them);
#   - a message without one: refused when asked for it;
#   - replicated after their messages, identical on the other server;
#   - bigger than the other server's MaxAttachmentSize: its message comes,
#     the attachment is refused there as not kept;
#   - too big to push: refused, and the message isn't stored;
#   - deleted with their message by the retention, parts included.
# Two linked servers, A (port 12410, MaxAttachmentSize 64M) and B (12411, 3M).
# Needs Build\ (Build.ps1) and Build\Bench\BenchServer.exe.
# Usage: powershell -ExecutionPolicy Bypass -File Tests\Attachments-Test.ps1
param([string]$Build = (Join-Path $PSScriptRoot "..\Build"))
$ErrorActionPreference = "Stop"
$Build = (Resolve-Path $Build).Path
$Dir = Join-Path $Build "_attachtest"
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
function Wait-Query($Sql, $Ini, $Pattern, $Seconds = 20) {
    $D = (Get-Date).AddSeconds($Seconds)
    do {
        $R = Query $Sql $Ini
        if ($R.Code -eq 0 -and $R.Out -match $Pattern) { return $R }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $D)
    $R
}
function Push($Data, $Ini, [string]$Topic = "", [string]$Attach = "") {
    $F = Join-Path $Dir "push.txt"
    [IO.File]::WriteAllText($F, $Data, (New-Object System.Text.UTF8Encoding $false))
    $A = @()
    if ($Topic) { $A += @("-t", $Topic) }
    if ($Attach) { $A += @("-a", $Attach) }
    Tool "BakaShrotPushMessage.exe" ($A + @("@$F", $Ini))
}
# A file of Size random bytes.
function New-File($Name, [int]$Size, [int]$Seed) {
    $P = Join-Path $Dir $Name
    $B = New-Object byte[] $Size
    (New-Object System.Random $Seed).NextBytes($B)
    [IO.File]::WriteAllBytes($P, $B)
    $P
}
function Hash($Path) { if (Test-Path $Path) { (Get-FileHash $Path -Algorithm SHA256).Hash } else { "no file" } }
# Saves an attachment and compares it with the original.
function Expect-Same([string]$What, $Topic, $Node, $Id, $Original, $Ini) {
    $Out = Join-Path $Dir ("got-" + [guid]::NewGuid().ToString("N") + ".bin")
    $R = Tool "BakaShrotGetAttachment.exe" @($Topic, $Node, "$Id", $Out, $Ini)
    $Same = ($R.Code -eq 0) -and ((Hash $Out) -eq (Hash $Original))
    Check $What $Same ("[{0}] {1}" -f $R.Code, $R.Out)
}
# Retries BakaShrotGetAttachment until it works: replicated ones come after their message.
function Wait-Same([string]$What, $Topic, $Node, $Id, $Original, $Ini, $Seconds = 20) {
    $Out = Join-Path $Dir ("got-" + [guid]::NewGuid().ToString("N") + ".bin")
    $D = (Get-Date).AddSeconds($Seconds)
    do {
        $R = Tool "BakaShrotGetAttachment.exe" @($Topic, $Node, "$Id", $Out, $Ini)
        if ($R.Code -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $D)
    Check $What (($R.Code -eq 0) -and ((Hash $Out) -eq (Hash $Original))) ("[{0}] {1}" -f $R.Code, $R.Out)
}

$A = New-KeyPair; $B = New-KeyPair; $K = New-KeyPair

Set-Content (Join-Path $Dir "a.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($A.Priv)
Node = serverA

[BakaShrot.Topics]
logs = 1
short = 2
photos = 3

[BakaShrot.Nodes]
serverA = 10
serverB = 11
kitchen = 2
garage = 3

[BakaShrot.Retention]
short = 4s

[BakaShrot.Server]
Host = 127.0.0.1
Port = 12410
ReplicatingTopics = logs;short;photos
DatabasePath = $(Join-Path $Dir "a.sqlite")
PeerSyncInterval = 1
PeerRetryDelay = 1
RetentionInterval = 1
MaxAttachmentSize = 64M

[BakaShrot.Peer.b]
Host = 127.0.0.1
Port = 12411
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
PushTopics = logs;short
ReadTopics = *
AllowQuery = 1
"@

Set-Content (Join-Path $Dir "b.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($B.Priv)
Node = serverB

[BakaShrot.Topics]
logs = 300
short = 301
photos = 302

[BakaShrot.Nodes]
serverA = 1
serverB = 2
kitchen = 30
garage = 31

[BakaShrot.Server]
Host = 127.0.0.1
Port = 12411
ReplicatingTopics = logs;short;photos
DatabasePath = $(Join-Path $Dir "b.sqlite")
PeerSyncInterval = 1
PeerRetryDelay = 1
RetentionInterval = 1
MaxAttachmentSize = 3M

[BakaShrot.Peer.a]
Host = 127.0.0.1
Port = 12410
Node = serverA
PublicKey = $($A.Pub)

[BakaShrot.Client.a]
PublicKeys = $($A.Pub)
Node = serverA
DefaultTopic = logs

[BakaShrot.Client.garage]
PublicKeys = $($K.Pub)
Node = garage
DefaultTopic = photos
PushTopics = photos
ReadTopics = *
AllowQuery = 1
"@

$ServerKeys = @{ 12410 = $A.Pub; 12411 = $B.Pub }
function Client-Ini($Name, $Topic, $Node, $Port) {
    $P = Join-Path $Dir "$Name.ini"
    Set-Content $P -Encoding Ascii -Value "[BakaShrot]`r`nPrivateKey = $($K.Priv)`r`nPublicKey = $($K.Pub)`r`nNode = $Node`r`nServerHost = 127.0.0.1`r`nServerPort = $Port`r`nServerPublicKey = $($ServerKeys[$Port])"
    $P
}
$OnA = Client-Ini "kitchen-a" "logs" "kitchen" 12410
$OnB = Client-Ini "garage-b" "photos" "garage" 12411

$Small = New-File "small.bin" (100 * 1024) 1
$Mid   = New-File "mid.bin" (5 * 1024 * 1024 + 123) 2
$Exact = New-File "exact.bin" (2 * 1024 * 1024) 3
$Tiny  = New-File "tiny.bin" 1 4

foreach ($Port in 12410, 12411) { if (Test-Port $Port) { throw "Port $Port is already in use" } }
$SA = Start-Srv "a"; $SB = Start-Srv "b"
try {
    Wait-Port 12410 $SA; Wait-Port 12411 $SB
    Start-Sleep -Seconds 1

    "--- Pushed with their message, read back"
    Expect "push #1 with 100 KB" (Push '{"n":1}' $OnA "" $Small) "message #1, with an attachment of 102400 bytes"
    $Started = Get-Date
    Expect "push #2 with 5 MB + 123 bytes (6 parts)" (Push '{"n":2}' $OnA "" $Mid) "message #2, with an attachment of 5243003 bytes"
    $UploadMs = ((Get-Date) - $Started).TotalMilliseconds
    Expect "push #3 with exactly 2 MB (2 parts)" (Push '{"n":3}' $OnA "" $Exact) "message #3, with an attachment of 2097152 bytes"
    Expect "push #4 with 1 byte" (Push '{"n":4}' $OnA "" $Tiny) "message #4"
    Expect "push #5 without" (Push '{"n":5}' $OnA) "message #5$"
    Expect-Same "#1 read back identical" "logs" "kitchen" 1 $Small $OnA
    $Started = Get-Date
    Expect-Same "#2 read back identical" "logs" "kitchen" 2 $Mid $OnA
    $DownloadMs = ((Get-Date) - $Started).TotalMilliseconds
    Check "5 MB up and down, tool start included" $true ("{0:N0} ms up, {1:N0} ms down" -f $UploadMs, $DownloadMs)
    Expect-Same "#3 read back identical" "logs" "kitchen" 3 $Exact $OnA
    Expect-Same "#4 read back identical" "logs" "kitchen" 4 $Tiny $OnA
    Expect "#5 has none: refused" (Tool "BakaShrotGetAttachment.exe" @("logs", "kitchen", "5", (Join-Path $Dir "none.bin"), $OnA)) "No attachment for logs:kitchen#5" 1
    Check "a refused one leaves no file" (-not (Test-Path (Join-Path $Dir "none.bin"))) "checked"
    Expect "a message that doesn't exist: refused" (Tool "BakaShrotGetAttachment.exe" @("logs", "kitchen", "99", (Join-Path $Dir "none.bin"), $OnA)) "No attachment" 1
    Expect "BakaShrotGetLatestMessage: #5, no attachment line" (Tool "BakaShrotGetLatestMessage.exe" @("logs", "kitchen", $OnA)) "#5 \(ids 1:2\), pushed [^|]+\| \{`"n`":5\}$"
    $R = Query "SELECT message_id, size, state FROM attachments WHERE topic_id = 1 AND node_id = 2 ORDER BY message_id" $OnA
    Check "A's attachments: 4, all ready (2)" ($R.Out -match '\[\["1","102400","2"\],\["2","5243003","2"\],\["3","2097152","2"\],\["4","1","2"\]\]') $R.Out
    Expect "A stores 6 + 2 + 1 + 1 parts" (Query "SELECT COUNT(*) FROM blob_chunks" $OnA) '\[\["10"\]\]'

    "--- Replicated after their messages (B takes up to 3M)"
    $R = Wait-Query "SELECT COUNT(*) FROM messages WHERE topic = 'logs' AND node = 'kitchen'" $OnB '\[\["5"\]\]'
    Check "B got the 5 messages" ($R.Out -match '\[\["5"\]\]') $R.Out
    Wait-Same "B: #1 identical" "logs" "kitchen" 1 $Small $OnB
    Wait-Same "B: #3 identical (2 MB)" "logs" "kitchen" 3 $Exact $OnB
    Wait-Same "B: #4 identical (1 byte)" "logs" "kitchen" 4 $Tiny $OnB
    Expect "B: #2 isn't kept (5 MB > 3M)" (Tool "BakaShrotGetAttachment.exe" @("logs", "kitchen", "2", (Join-Path $Dir "none.bin"), $OnB)) "isn't kept here" 1
    $R = Query "SELECT a.message_id, a.state FROM attachments a JOIN topics t ON t.topic_id = a.topic_id WHERE t.name = 'logs' ORDER BY a.message_id" $OnB
    Check "B's attachments: ready, not kept (3), ready, ready" ($R.Out -match '\[\["1","2"\],\["2","3"\],\["3","2"\],\["4","2"\]\]') $R.Out
    Expect "B: BakaShrotGetLatestMessage logs:kitchen, #5 has none" (Tool "BakaShrotGetLatestMessage.exe" @("logs", "kitchen", $OnB)) "#5 \(ids 300:30\), pushed [^|]+\| \{`"n`":5\}"

    "--- Pushed on B, too big there, then replicated to A"
    Expect "B refuses 5 MB (more than 3M)" (Push '{"photo":0}' $OnB "" $Mid) "too big: 5243003 bytes, at most 3145728" 1
    Expect "the message wasn't stored: the next is #1" (Push '{"photo":1}' $OnB "" $Small) "message #1, with an attachment"
    Wait-Same "A got B's photos:garage#1 identical" "photos" "garage" 1 $Small $OnA
    Expect "A: the latest of photos:garage" (Tool "BakaShrotGetLatestMessage.exe" @("photos", "garage", $OnA)) "Attachment: 102400 bytes \| \{`"photo`":1\}"

    "--- Deleted with their message (A: short = 4s)"
    $Before = (Query "SELECT COUNT(*) FROM blob_chunks" $OnA).Out
    Expect "push short #1 with 2 MB" (Push '{"s":1}' $OnA "short" $Exact) "message #1, with an attachment"
    Expect "A has 2 more parts" (Query "SELECT COUNT(*) FROM blob_chunks" $OnA) '\[\["13"\]\]'
    $R = Wait-Query "SELECT COUNT(*) FROM messages WHERE topic = 'short'" $OnA '\[\["0"\]\]' 15
    Check "the message is deleted past 4 s" ($R.Out -match '\[\["0"\]\]') $R.Out
    $R = Wait-Query "SELECT COUNT(*) FROM blob_chunks" $OnA '\[\["11"\]\]' 10
    Check "and its 2 parts" ($R.Out -match '\[\["11"\]\]') "before $Before, now $($R.Out)"
    Expect "and its attachments row" (Query "SELECT COUNT(*) FROM attachments WHERE topic_id = 2" $OnA) '\[\["0"\]\]'
    Expect "and its blob" (Query "SELECT COUNT(*) FROM blobs WHERE state = 3" $OnA) '\[\["0"\]\]'
    Wait-Same "B kept short#1 (no max age there)" "short" "kitchen" 1 $Exact $OnB
}
finally {
    Stop-Srv $SA; Stop-Srv $SB
}

"--- Logs"
$LogA = Get-Content (Join-Path $Dir "a.log") -Raw
$LogB = Get-Content (Join-Path $Dir "b.log") -Raw
Check "A sent B the attachments it takes" ($LogA -match "Sent the attachment of logs:kitchen#1 to 'b'" -and $LogA -match "Sent the attachment of logs:kitchen#3 to 'b'") "checked"
Check "A never sent #2 (not kept by B)" (-not ($LogA -match "Sent the attachment of logs:kitchen#2")) "checked"
Check "B sent A its photo" ($LogB -match "Sent the attachment of photos:garage#1 to 'a'") "checked"
Check "A logged deleting the parts" ($LogA -match "deleted 2 attachment parts") "checked"
$Other = ($LogA + "`n" + $LogB) -split "`r?`n" | Where-Object { $_ -match "Failed|invalid|unexpected|doesn't decrypt|SHA-256" -and $_ -notmatch "Refused a request" }
Check "no failure in A's or B's log" ($Other.Count -eq 0) ($Other -join " / ")

""
if ($Fails) { "$Fails FAILED"; exit 1 } else { "All passed" }
