# The attachment cases the regular clients never produce (Design/Attachments.md):
#   1. Through a raw client (Tests/AttachmentEdgeClient.pb): a wrong SHA-256,
#      parts out of order / of the wrong size / repeated, someone else's
#      upload, the wrong topic, an upload attached twice, too big, a part
#      out of range.
#   2. Uploads left behind: kept within UploadTimeout, deleted past it, then
#      refused.
#   3. Replication resuming: the receiving server killed in the middle of a
#      400 MB attachment, restarted, the sender goes on from where it stopped.
#   4. A corrupted attachment (bytes flipped in the sender's database): the
#      client refuses it, the peer drops it and doesn't keep it.
# Two servers, A (port 12413) and B (12414). Needs Build\ (Build.ps1),
# Build\Bench\BenchServer.exe, Build\AttachmentEdgeClient.exe (compile
# Tests\AttachmentEdgeClient.pb, thread-safe console), and Python 3 for 4.
# Usage: powershell -ExecutionPolicy Bypass -File Tests\AttachmentEdges-Test.ps1 [-Python <python.exe>]
param(
    [string]$Build = (Join-Path $PSScriptRoot "..\Build"),
    [string]$Python = "python"
)
$ErrorActionPreference = "Stop"
$Build = (Resolve-Path $Build).Path
$Dir = Join-Path $Build "_attachedges"
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
    @{ Code = $LASTEXITCODE; Out = ($O -join " | "); Lines = @($O) }
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
    # Each run its own log: a restart doesn't overwrite the last one's.
    $script:Runs[$Name]++
    $Log = Join-Path $Dir "$Name.$($script:Runs[$Name]).log"
    $P = Start-Process -FilePath $Server -ArgumentList "`"$(Join-Path $Dir "$Name.ini")`"", "`"$Stop`"" -WorkingDirectory $Dir `
        -RedirectStandardOutput $Log -WindowStyle Hidden -PassThru
    $null = $P.Handle
    @{ P = $P; Stop = $Stop; Name = $Name; Log = $Log }
}
$Runs = @{ a = 0; b = 0 }
function Stop-Srv($S) {
    if (-not $S -or $S.P.HasExited) { return }
    Set-Content $S.Stop "x"
    if (-not $S.P.WaitForExit(30000)) { Stop-Process -Id $S.P.Id -Force }
}
function Wait-Port($Port, $S) {
    $D = (Get-Date).AddSeconds(15)
    while (-not (Test-Port $Port)) {
        if ($S.P.HasExited) { throw "$($S.Name) exited: $(Get-Content $S.Log -Raw)" }
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
function Push($Data, $Ini, [string]$Attach = "") {
    $F = Join-Path $Dir "push.txt"
    [IO.File]::WriteAllText($F, $Data, (New-Object System.Text.UTF8Encoding $false))
    $A = @()
    if ($Attach) { $A += @("-a", $Attach) }
    Tool "BakaShrotPushMessage.exe" ($A + @("@$F", $Ini))
}
function New-File($Name, [int64]$Size, [int]$Seed) {
    $P = Join-Path $Dir $Name
    $R = New-Object System.Random $Seed
    $Buf = New-Object byte[] ([math]::Min($Size, 16MB))
    $F = [IO.File]::OpenWrite($P)
    $Left = $Size
    while ($Left -gt 0) { $R.NextBytes($Buf); $N = [math]::Min($Left, $Buf.Length); $F.Write($Buf, 0, $N); $Left -= $N }
    $F.Close()
    $P
}
function Hash($Path) { if (Test-Path $Path) { (Get-FileHash $Path -Algorithm SHA256).Hash } else { "no file" } }
function Num($Out) { if ($Out -match '\[\["(\d+)"\]\]') { [int64]$Matches[1] } else { -1 } }

$A = New-KeyPair; $B = New-KeyPair; $K = New-KeyPair; $G = New-KeyPair

foreach ($Name in "a", "b") {
    $Me = @{ a = $A; b = $B }[$Name]; $Peer = @{ a = $B; b = $A }[$Name]
    $PeerName = @{ a = "b"; b = "a" }[$Name]
    $Port = @{ a = 12413; b = 12414 }[$Name]; $PeerPort = @{ a = 12414; b = 12413 }[$Name]
    $Base = @{ a = 1; b = 100 }[$Name]
    Set-Content (Join-Path $Dir "$Name.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($Me.Priv)
Node = server$Name

[BakaShrot.Topics]
logs = $Base
other = $($Base + 1)
secret = $($Base + 2)

[BakaShrot.Nodes]
servera = $($Base + 10)
serverb = $($Base + 11)
kitchen = $($Base + 2)
garage = $($Base + 3)

[BakaShrot.Server]
Host = 127.0.0.1
Port = $Port
ReplicatingTopics = logs
DatabasePath = $(Join-Path $Dir "$Name.sqlite")
PeerSyncInterval = 1
PeerRetryDelay = 1
RetentionInterval = 1
MaxAttachmentSize = 512M
UploadTimeout = 10

[BakaShrot.Peer.$PeerName]
Host = 127.0.0.1
Port = $PeerPort
Node = server$PeerName
PublicKey = $($Peer.Pub)

[BakaShrot.Client.$PeerName]
PublicKeys = $($Peer.Pub)
Node = server$PeerName
DefaultTopic = logs

[BakaShrot.Client.kitchen]
PublicKeys = $($K.Pub)
Node = kitchen
DefaultTopic = logs
PushTopics = logs;other;secret
ReadTopics = *
AllowQuery = 1

[BakaShrot.Client.garage]
PublicKeys = $($G.Pub)
Node = garage
DefaultTopic = logs
PushTopics = logs
ReadTopics = logs
"@
}
$ServerKeys = @{ 12413 = $A.Pub; 12414 = $B.Pub }
function Client-Ini($Name, $Keys, $Node, $Port) {
    $P = Join-Path $Dir "$Name.ini"
    Set-Content $P -Encoding Ascii -Value "[BakaShrot]`r`nPrivateKey = $($Keys.Priv)`r`nPublicKey = $($Keys.Pub)`r`nNode = $Node`r`nServerHost = 127.0.0.1`r`nServerPort = $Port`r`nServerPublicKey = $($ServerKeys[$Port])"
    $P
}
$KitchenA = Client-Ini "kitchen-a" $K "kitchen" 12413
$GarageA  = Client-Ini "garage-a" $G "garage" 12413
$KitchenB = Client-Ini "kitchen-b" $K "kitchen" 12414

foreach ($Port in 12413, 12414) { if (Test-Port $Port) { throw "Port $Port is already in use" } }
$SA = Start-Srv "a"; $SB = $null
try {
    Wait-Port 12413 $SA

    "--- 1. Through the raw client"
    $R = Tool "AttachmentEdgeClient.exe" @("edge", $KitchenA, $GarageA)
    $R.Lines | Where-Object { $_ -match "^(PASS|FAIL|      ->)" }
    $Script:Fails += @($R.Lines | Where-Object { $_ -match "^FAIL" }).Count
    Check "the raw client ran to the end" ($R.Code -ne $null -and ($R.Out -match "LEFT (\d+) (\d+)")) $R.Lines[-1]
    $Partial = $Matches[1]; $Complete = $Matches[2]
    $LeftAt = Get-Date

    "--- 2. Uploads left behind (UploadTimeout = 10)"
    $Sql = "SELECT blob_id, state, received FROM blobs WHERE blob_id IN ($Partial, $Complete) ORDER BY blob_id"
    $R = Query $Sql $KitchenA
    Check "within UploadTimeout: both kept, receiving (0) and complete (1)" ($R.Out -match "\[\[`"$Partial`",`"0`",`"1048576`"\],\[`"$Complete`",`"1`",`"5000`"\]\]") $R.Out
    $R = Wait-Query "SELECT COUNT(*) FROM blobs WHERE blob_id IN ($Partial, $Complete)" $KitchenA '\[\["0"\]\]' 25
    $After = ((Get-Date) - $LeftAt).TotalSeconds
    Check "past it: both deleted" ($R.Out -match '\[\["0"\]\]') ("{0:N1} s after they were left" -f $After)
    Check "  not before 10 s" ($After -ge 8) ("{0:N1} s" -f $After)
    Expect "  their parts too" (Query "SELECT COUNT(*) FROM blob_chunks WHERE blob_id IN ($Partial, $Complete)" $KitchenA) '\[\["0"\]\]'
    Expect "  and the one with the wrong SHA-256 (dropped at once)" (Query "SELECT COUNT(*) FROM blobs WHERE state <> 2" $KitchenA) '\[\["0"\]\]'
    Expect "  the attached one is kept" (Query "SELECT COUNT(*) FROM blobs WHERE state = 2" $KitchenA) '\[\["1"\]\]'
    $R = Tool "AttachmentEdgeClient.exe" @("late", $KitchenA, $Partial, $Complete)
    $R.Lines | Where-Object { $_ -match "^(PASS|FAIL|      ->)" }
    $Script:Fails += @($R.Lines | Where-Object { $_ -match "^FAIL" }).Count

    "--- 3. Replication resuming (B killed in the middle of 400 MB)"
    $Big = New-File "big.bin" 400MB 9
    $R = Push '{"big":1}' $KitchenA $Big
    Check "push 400 MB to A" ($R.Code -eq 0 -and $R.Out -match "message #(\d+), with an attachment") $R.Out
    $BigId = $Matches[1]
    $SB = Start-Srv "b"
    Wait-Port 12414 $SB
    $Received = "SELECT COALESCE(MAX(b.received), 0) FROM attachments a JOIN topics t ON t.topic_id = a.topic_id LEFT JOIN blobs b ON b.blob_id = a.blob_id WHERE t.name = 'logs' AND a.message_id = $BigId"
    $KilledAt = -1
    $D = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $D) {
        $N = Num (Query $Received $KitchenB).Out
        if ($N -ge 40MB) { Stop-Process -Id $SB.P.Id -Force; $SB.P.WaitForExit(10000) | Out-Null; $KilledAt = $N; break }
        Start-Sleep -Milliseconds 50
    }
    Check "B killed in the middle" ($KilledAt -gt 0 -and $KilledAt -lt 400MB) ("{0:N0} MB of 400 received" -f ($KilledAt / 1MB))
    $SB = Start-Srv "b"
    Wait-Port 12414 $SB
    $AfterRestart = Num (Query $Received $KitchenB).Out
    Check "after the restart, what it had is still there" ($AfterRestart -ge $KilledAt) ("{0:N0} MB" -f ($AfterRestart / 1MB))
    $Copy = Join-Path $Dir "big-from-b.bin"
    $D = (Get-Date).AddSeconds(90)
    do {
        $R = Tool "BakaShrotGetAttachment.exe" @("logs", "kitchen", $BigId, $Copy, $KitchenB)
        if ($R.Code -eq 0) { break }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $D)
    Check "B ends up with all of it, identical" ($R.Code -eq 0 -and (Hash $Copy) -eq (Hash $Big)) $R.Out
    $LogA = (Get-ChildItem $Dir -Filter "a.*.log" | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
    $Resumed = [regex]::Matches($LogA, "Sent the attachment of logs:kitchen#$BigId to 'b' in \d+ ms, from part (\d+)")
    $From = if ($Resumed.Count) { [int]$Resumed[$Resumed.Count - 1].Groups[1].Value } else { -1 }
    Check "A went on from where B stopped, not from 0" ($From -gt 0 -and $From * 1MB -le $AfterRestart) ("from part $From, B had {0:N0} MB" -f ($AfterRestart / 1MB))
    Remove-Item $Copy, $Big -ErrorAction SilentlyContinue

    "--- 4. A corrupted attachment"
    $HasPython = $false
    try { & $Python -c "import sqlite3" 2>&1 | Out-Null; $HasPython = ($LASTEXITCODE -eq 0) } catch { }
    if (-not $HasPython) {
        "SKIP no Python ($Python)"
    } else {
        Stop-Srv $SB; $SB = $null
        $Small = New-File "small.bin" (3MB + 99) 10
        $R = Push '{"corrupt":1}' $KitchenA $Small
        Check "push 3 MB to A, B stopped" ($R.Code -eq 0 -and $R.Out -match "message #(\d+), with an attachment") $R.Out
        $BadId = $Matches[1]
        Stop-Srv $SA
        $Flip = @"
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
row = db.execute("SELECT c.rowid, c.chunk_data FROM blob_chunks c JOIN attachments a ON a.blob_id = c.blob_id WHERE a.message_id = ? AND a.topic_id = 1 AND c.chunk_index = 1", (int(sys.argv[2]),)).fetchone()
data = bytearray(row[1]); data[1000] ^= 0xFF
db.execute("UPDATE blob_chunks SET chunk_data = ? WHERE rowid = ?", (bytes(data), row[0]))
db.commit(); print("flipped")
"@
        Set-Content (Join-Path $Dir "flip.py") -Encoding Ascii -Value $Flip
        $Out = & $Python -B (Join-Path $Dir "flip.py") (Join-Path $Dir "a.sqlite") $BadId 2>&1
        Check "a byte flipped in A's database, part 1" ("$Out" -eq "flipped") "$Out"
        $SA = Start-Srv "a"
        Wait-Port 12413 $SA
        $Copy = Join-Path $Dir "bad-from-a.bin"
        Expect "reading it from A: the client refuses it" (Tool "BakaShrotGetAttachment.exe" @("logs", "kitchen", $BadId, $Copy, $KitchenA)) "doesn't match its SHA-256" 1
        Check "  and leaves no file" (-not (Test-Path $Copy)) "checked"
        $SB = Start-Srv "b"
        Wait-Port 12414 $SB
        Start-Sleep -Seconds 6
        $LogB = Get-Content $SB.Log -Raw
        $Drops = [regex]::Matches($LogB, "attachment of logs:kitchen#$BadId from peer 'a' doesn't match its SHA-256, dropped").Count
        Check "B drops it: doesn't match" ($Drops -ge 1) "$Drops times in 6 s"
        Expect "B doesn't serve it" (Tool "BakaShrotGetAttachment.exe" @("logs", "kitchen", $BadId, $Copy, $KitchenB)) "isn't here yet" 1
        # A sends it again at every check-in, so B can be receiving (1) it
        # again when asked: back to missing once that copy is dropped too.
        $R = Wait-Query "SELECT a.state, COALESCE(a.blob_id, 0) FROM attachments a JOIN topics t ON t.topic_id = a.topic_id WHERE t.name = 'logs' AND a.message_id = $BadId" $KitchenB '\[\["0","0"\]\]' 5
        Check "B's attachment is back to missing (0), no blob" ($R.Out -match '\[\["0","0"\]\]') $R.Out
        Expect "B: no blob left behind, once cleaned" (Wait-Query "SELECT COUNT(*) FROM blobs WHERE state <> 2" $KitchenB '\[\["0"\]\]' 5) '\[\["0"\]\]'
        "INFO A sends it again at every check-in: $Drops times in 6 s (PeerSyncInterval 1)"
    }
}
finally {
    Stop-Srv $SA; Stop-Srv $SB
}

"--- Logs"
# Refusals are what this test asks for, their codes' names (InvalidRequest)
# aren't bad packets.
$All = (Get-ChildItem $Dir -Filter "*.log" | ForEach-Object { Get-Content $_.FullName }) | Where-Object { $_ -notmatch "Refused a request" -and $_ -match "invalid|unexpected|doesn't decrypt" }
Check "no invalid or unexpected packets in any log" ($All.Count -eq 0) ($All -join " / ")

""
if ($Fails) { "$Fails FAILED"; exit 1 } else { "All passed" }
