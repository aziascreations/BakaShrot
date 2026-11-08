# End-to-end test of reading runs of messages: the GetMessages request
# (Commons/Networking/Packets/GetMessagesPacket.pbi), through the client DLL
# and Tools\GetMessages: from the start, after an id, after the latest one,
# with a limit, answers split at ~1 MB, data that isn't JSON or spans lines,
# refusals, and --follow picking up new pushes.
# Needs Build\ (Build.ps1) and Build\Bench\BenchServer.exe (Bench-Replication.ps1,
# or compile Tests\Bench\BenchServer.pb into it). Uses port 12405.
# Usage: powershell -ExecutionPolicy Bypass -File Tests\GetMessages-Test.ps1
param([string]$Build = (Join-Path $PSScriptRoot "..\Build"))
$ErrorActionPreference = "Stop"
$Build = (Resolve-Path $Build).Path
$Dir = Join-Path $Build "_getmessagestest"
Remove-Item -Recurse -Force $Dir -ErrorAction SilentlyContinue
New-Item -ItemType Directory $Dir | Out-Null
$Server = Join-Path $Build "Bench\BenchServer.exe"
$Port = 12405
$Fails = 0

function New-KeyPair {
    $L = & (Join-Path $Build "KeyGen.exe")
    @{ Priv = $L[0] -replace "^PrivateKey = ", ""; Pub = $L[1] -replace "^PublicKey = ", "" }
}
function Test-Port($P) {
    $C = New-Object System.Net.Sockets.TcpClient
    try { $A = $C.BeginConnect("127.0.0.1", $P, $null, $null); $A.AsyncWaitHandle.WaitOne(200) -and $C.Connected } catch { $false } finally { $C.Close() }
}
# Runs a tool, its output as lines (Lines) and joined (Out).
function Tool([string]$Name, [string[]]$A) {
    $O = @(& (Join-Path $Build $Name) @A 2>&1 | ForEach-Object { "$_" })
    @{ Code = $LASTEXITCODE; Lines = $O; Out = ($O -join " | ") }
}
function Check([string]$What, [bool]$Ok, [string]$Detail) {
    if (-not $Ok) { $script:Fails++ }
    if ($Detail.Length -gt 300) { $Detail = $Detail.Substring(0, 300) + "... (" + $Detail.Length + " chars)" }
    "{0} {1}`n      -> {2}" -f $(if ($Ok) { "PASS" } else { "FAIL" }), $What, $Detail
}
function Expect([string]$What, $Result, [string]$Pattern, [int]$Code = 0) {
    Check $What (($Result.Code -eq $Code) -and ($Result.Out -match $Pattern)) ("[{0}] {1}" -f $Result.Code, $Result.Out)
}
# The ids GetMessages printed, in order.
function Ids($Result) {
    @($Result.Lines | Where-Object { $_ -match "^\d+`t" } | ForEach-Object { [long]($_ -split "`t", 2)[0] })
}
# Whether Ids are exactly From..To.
function Is-Run($Ids, [long]$From, [long]$To) {
    $Want = if ($To -ge $From) { @($From..$To) } else { @() }
    ($Ids -join ",") -eq ($Want -join ",")
}
function Push($Data, $Ini, [string]$Topic = "") {
    $F = Join-Path $Dir "push.txt"
    [IO.File]::WriteAllText($F, $Data, (New-Object System.Text.UTF8Encoding $false))
    $A = @()
    if ($Topic) { $A += @("-t", $Topic) }
    Tool "PushMessage.exe" ($A + @("@$F", $Ini))
}

$S = New-KeyPair; $K = New-KeyPair; $L = New-KeyPair

Set-Content (Join-Path $Dir "server.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($S.Priv)
Topic = logs
Node = server

[BakaShrot.Topics]
logs = 1
secret = 2

[BakaShrot.Nodes]
server = 1
kitchen = 5
lounge = 6
empty = 7

[BakaShrot.Server]
Host = 127.0.0.1
Port = $Port
DatabasePath = $(Join-Path $Dir "server.sqlite")

[BakaShrot.Client.kitchen]
PublicKeys = $($K.Pub)
Identities = logs:kitchen
PushTopics = logs;secret
ReadTopics = *
AllowQuery = 1

[BakaShrot.Client.lounge]
PublicKeys = $($L.Pub)
Identities = logs:lounge
ReadTopics = logs
"@

function Client-Ini($Name, $Keys) {
    $P = Join-Path $Dir "$Name.ini"
    Set-Content $P -Encoding Ascii -Value "[BakaShrot]`r`nPrivateKey = $($Keys.Priv)`r`nPublicKey = $($Keys.Pub)`r`nTopic = logs`r`nNode = $Name`r`nServerHost = 127.0.0.1`r`nServerPort = $Port`r`nServerPublicKey = $($S.Pub)"
    $P
}
$Kitchen = Client-Ini "kitchen" $K
$Lounge  = Client-Ini "lounge" $L

if (Test-Port $Port) { throw "Port $Port is already in use" }
$Stop = Join-Path $Dir "server.stop"
$P = Start-Process -FilePath $Server -ArgumentList "`"$(Join-Path $Dir "server.ini")`"", "`"$Stop`"" -WorkingDirectory $Dir `
    -RedirectStandardOutput (Join-Path $Dir "server.log") -WindowStyle Hidden -PassThru
$null = $P.Handle
$Follower = $null
try {
    $D = (Get-Date).AddSeconds(15)
    while (-not (Test-Port $Port)) {
        if ($P.HasExited) { throw "The server exited: $(Get-Content (Join-Path $Dir "server.log") -Raw)" }
        if ((Get-Date) -gt $D) { throw "The server isn't listening" }
        Start-Sleep -Milliseconds 100
    }

    # --- Nothing yet ----------------------------------------------------------

    $R = Tool "GetMessages.exe" @("logs", "kitchen", $Kitchen)
    Check "No messages yet: nothing printed, not a failure" ($R.Code -eq 0 -and $R.Lines.Count -eq 0) ("[{0}] {1}" -f $R.Code, $R.Out)

    $R = Tool "GetMessages.exe" @("logs", "kitchen", "--after", "latest", $Kitchen)
    Check "--after latest with no messages yet: nothing, not a failure" ($R.Code -eq 0 -and $R.Lines.Count -eq 0) ("[{0}] {1}" -f $R.Code, $R.Out)

    # --- 120 small ones -------------------------------------------------------

    $Started = Get-Date
    $Pushed = 0
    for ($i = 1; $i -le 120; $i++) {
        $R = Push ('{"i":' + $i + '}') $Kitchen
        if ($R.Code -eq 0) { $Pushed++ }
    }
    Check "120 pushes" ($Pushed -eq 120) ("{0} pushed in {1:N1} s" -f $Pushed, ((Get-Date) - $Started).TotalSeconds)

    $R = Tool "GetMessages.exe" @("logs", "kitchen", $Kitchen)
    $Ids = Ids $R
    Check "Default: the first 100, in order" ($R.Code -eq 0 -and (Is-Run $Ids 1 100)) ("[{0}] {1} ids, {2}..{3}" -f $R.Code, $Ids.Count, $Ids[0], $Ids[-1])
    Check "Each line is the id, a tab and the data as stored" ($R.Lines[0] -eq "1`t{`"i`":1}" -and $R.Lines[99] -eq "100`t{`"i`":100}") ("'{0}' / '{1}'" -f $R.Lines[0], $R.Lines[99])

    $R = Tool "GetMessages.exe" @("logs", "kitchen", "--limit", "0", $Kitchen)
    Check "--limit 0: all 120" ($R.Code -eq 0 -and (Is-Run (Ids $R) 1 120)) ("[{0}] {1} lines" -f $R.Code, $R.Lines.Count)

    $R = Tool "GetMessages.exe" @("logs", "kitchen", "--after", "115", $Kitchen)
    Check "--after 115: 116-120" ($R.Code -eq 0 -and (Is-Run (Ids $R) 116 120)) ("[{0}] {1}" -f $R.Code, $R.Out)

    $R = Tool "GetMessages.exe" @("logs", "kitchen", "--after", "10", "--limit", "7", $Kitchen)
    Check "--after 10 --limit 7: 11-17" ($R.Code -eq 0 -and (Is-Run (Ids $R) 11 17)) ("[{0}] {1}" -f $R.Code, $R.Out)

    $R = Tool "GetMessages.exe" @("logs", "kitchen", "--after", "120", $Kitchen)
    Check "--after the last one: nothing, not a failure" ($R.Code -eq 0 -and $R.Lines.Count -eq 0) ("[{0}] {1}" -f $R.Code, $R.Out)

    $R = Tool "GetMessages.exe" @("logs", "kitchen", "--after", "latest", $Kitchen)
    Check "--after latest: nothing" ($R.Code -eq 0 -and $R.Lines.Count -eq 0) ("[{0}] {1}" -f $R.Code, $R.Out)

    $R = Tool "GetMessages.exe" @("1", "5", "--after", "118", $Kitchen)
    Check "By ids (1, 5): 119-120" ($R.Code -eq 0 -and (Is-Run (Ids $R) 119 120)) ("[{0}] {1}" -f $R.Code, $R.Out)

    $R = Tool "GetMessages.exe" @("logs", "kitchen", "--after", "100", $Lounge)
    Check "Another client allowed to read logs: 101-120" ($R.Code -eq 0 -and (Is-Run (Ids $R) 101 120)) ("[{0}] {1} lines" -f $R.Code, $R.Lines.Count)

    # --- Refusals -------------------------------------------------------------

    $null = Push '{"s":1}' $Kitchen "secret"
    $R = Tool "GetMessages.exe" @("secret", "kitchen", $Kitchen)
    Check "A topic in ReadTopics (*): read" ($R.Code -eq 0 -and (Is-Run (Ids $R) 1 1)) ("[{0}] {1}" -f $R.Code, $R.Out)
    Expect "A topic not in ReadTopics: refused" (Tool "GetMessages.exe" @("secret", "kitchen", $Lounge)) "Not allowed to read topic 'secret'" 1
    Expect "Unknown node: refused" (Tool "GetMessages.exe" @("logs", "nobody", $Kitchen)) "Unknown node 'nobody'" 1
    Expect "Unknown topic: refused" (Tool "GetMessages.exe" @("nothing", "kitchen", $Kitchen)) "Unknown topic 'nothing'" 1
    $R = Tool "GetMessages.exe" @("logs", "empty", $Kitchen)
    Check "A known node with no messages: nothing, not a failure" ($R.Code -eq 0 -and $R.Lines.Count -eq 0) ("[{0}] {1}" -f $R.Code, $R.Out)
    Expect "Bad --after: refused by the tool" (Tool "GetMessages.exe" @("logs", "kitchen", "--after", "-3", $Kitchen)) "Invalid --after" 1
    Expect "Unknown option: refused by the tool" (Tool "GetMessages.exe" @("logs", "kitchen", "--nope", $Kitchen)) "Unknown option" 1

    # --- Data that isn't one line of JSON -------------------------------------

    $null = Push "plain text, not JSON" $Kitchen
    $null = Push "two`nlines" $Kitchen
    $R = Tool "GetMessages.exe" @("logs", "kitchen", "--after", "120", $Kitchen)
    Check "Non-JSON data printed as stored, a line break spans lines" (
        $R.Code -eq 0 -and $R.Lines.Count -eq 3 -and $R.Lines[0] -eq "121`tplain text, not JSON" -and $R.Lines[1] -eq "122`ttwo" -and $R.Lines[2] -eq "lines"
    ) ($R.Lines -join " / ")

    # --- Answers split at ~1 MB -----------------------------------------------

    # 5 of 600 KB and one of 3 MB: one per answer, the big one alone.
    $Sizes = @(600KB, 600KB, 600KB, 3MB, 600KB, 600KB)
    $BigOk = 0
    foreach ($Size in $Sizes) {
        $Data = '{"pad":"' + ("x" * ($Size - 10)) + '"}'
        if ((Push $Data $Kitchen).Code -eq 0) { $BigOk++ }
    }
    Check "6 big pushes (5 x 600 KB, 3 MB)" ($BigOk -eq 6) "$BigOk pushed"

    $R = Tool "GetMessages.exe" @("logs", "kitchen", "--after", "122", $Kitchen)
    $Ids = Ids $R
    $Lengths = @($R.Lines | ForEach-Object { (($_ -split "`t", 2)[1]).Length })
    $WantLengths = @($Sizes | ForEach-Object { $_ })
    Check "All 6 read back whole, over several answers" (
        $R.Code -eq 0 -and (Is-Run $Ids 123 128) -and (($Lengths -join ",") -eq ($WantLengths -join ","))
    ) ("[{0}] ids {1}, lengths {2}" -f $R.Code, ($Ids -join ","), ($Lengths -join ","))

    $R = Tool "GetMessages.exe" @("logs", "kitchen", "--after", "122", "--limit", "2", $Kitchen)
    Check "--limit 2 over big ones: 123-124" ($R.Code -eq 0 -and (Is-Run (Ids $R) 123 124)) ("[{0}] {1} lines" -f $R.Code, $R.Lines.Count)

    # --- --follow ---------------------------------------------------------------

    $FollowOut = Join-Path $Dir "follow.out"
    $Follower = Start-Process -FilePath (Join-Path $Build "GetMessages.exe") `
        -ArgumentList "logs", "kitchen", "--after", "latest", "--follow", "--interval", "100", "`"$Kitchen`"" `
        -WorkingDirectory $Build -RedirectStandardOutput $FollowOut -WindowStyle Hidden -PassThru
    $null = $Follower.Handle
    Start-Sleep -Milliseconds 1500
    Check "--follow keeps running once caught up" (-not $Follower.HasExited) $(if ($Follower.HasExited) { "exited with $($Follower.ExitCode)" } else { "running" })

    $null = Push '{"f":1}' $Kitchen
    $null = Push '{"f":2}' $Kitchen
    $null = Push '{"f":3}' $Kitchen
    $D = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 200
        $Lines = @()
        try {
            $Fs = [IO.File]::Open($FollowOut, "Open", "Read", "ReadWrite")
            $Text = (New-Object IO.StreamReader($Fs)).ReadToEnd(); $Fs.Close()
            $Lines = @($Text -split "`r?`n" | Where-Object { $_ -ne "" })
        } catch { }
    } while ($Lines.Count -lt 3 -and (Get-Date) -lt $D)
    Check "--follow --after latest: only the 3 new ones" (
        $Lines.Count -eq 3 -and $Lines[0] -eq "129`t{`"f`":1}" -and $Lines[2] -eq "131`t{`"f`":3}"
    ) ($Lines -join " / ")

    # The server going away ends it with a failure.
    Set-Content $Stop "x"
    if (-not $P.WaitForExit(15000)) { Stop-Process -Id $P.Id -Force }
    $Ended = $Follower.WaitForExit(15000)
    Check "--follow fails once the server is gone" ($Ended -and $Follower.ExitCode -eq 1) $(if ($Ended) { "exit code $($Follower.ExitCode)" } else { "still running" })

    $Log = Get-Content (Join-Path $Dir "server.log") -Raw
    $Bad = @($Log -split "`r?`n" | Where-Object { $_ -match "invalid|unexpected|Failed" })
    Check "Server log: no invalid or unexpected packets" ($Bad.Count -eq 0) $(if ($Bad.Count) { $Bad -join " / " } else { "clean" })
}
finally {
    if ($Follower -and -not $Follower.HasExited) { Stop-Process -Id $Follower.Id -Force }
    if (-not $P.HasExited) {
        Set-Content $Stop "x"
        if (-not $P.WaitForExit(15000)) { Stop-Process -Id $P.Id -Force }
    }
}

""
if ($Fails -eq 0) { "All checks passed" } else { "$Fails check(s) failed" }
exit $(if ($Fails -eq 0) { 0 } else { 1 })
