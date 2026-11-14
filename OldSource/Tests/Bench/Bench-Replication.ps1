# ============================================================================
# BakaShrot replication benchmark
#
# Runs several servers linked as peers on localhost (by default 4 in a Y: one
# hub linked to 3 leaves), each with its own nodes pushing to it, and
# measures, stage by stage:
#   - the push path: achieved vs offered rate, latency, failures
#   - replication: lag on every server while pushing, whether it keeps up
#     (trough slope, see Bench_TroughSlope() in BenchClient.pb), and how long
#     it takes to drain once the pushes stop
#   - every server's CPU and RAM, and its database's size
#   - a query suite (queries.txt) after every stage, as the data grows
#
# Three parts:
#   1. Ramp: from an empty database, stages of -Ramp ("NodesxRate", Rate per
#      node in msg/s, 0 = as fast as the server answers), to find where the
#      push path and the replication saturate.
#   2. Scale: seeds every database up to each of -SeedTotals rows (identical
#      on every server, see BenchSeed.pb), then runs -SteadyStage and the
#      query suite at that size: how check-ins and queries hold up with
#      lots of data.
#   3. Mixed: -MixedStage with queries_load.txt running in a loop against
#      the hub meanwhile: reads under write load, and writes under reads.
#
# Results go into Build\Bench\runs\<timestamp>\: configs, per-stage samples
# (CSV, one row per sample), summaries (JSON), and report.md / results.json
# for the whole run.
# The databases and server logs go into -DataDir\<timestamp>\ instead, out of
# the repo: every push rewrites them, and file watchers on the repo (git
# caches, editors) otherwise burn a core or two reacting to it, skewing the
# CPU numbers. The databases are deleted at the end, unless -KeepData.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File Tests\Bench\Bench-Replication.ps1
#   ... -Ramp "5x20,10x50" -SeedTotals @() -PushSeconds 10     quick run
#   ... -Topology Mesh -PeerSyncInterval 1                     variations
#   ... -Synchronous NORMAL      the servers' Synchronous (FULL by default)
#   ... -Names Wildcard          each server only names its own nodes, and
#                                takes the others' by AcceptNodes = n*
#   ... -Parts Ramp                                            only part 1
# Keep -PushSeconds at 6+ times PeerSyncInterval for the trough slope to mean
# something.
#
#   ... -Compiler "C:\Program Files\PureBasic_640\Compilers\pbcompilerc.exe" `
#       -CompilerFlags "/OPTIMIZER"                            PB 6.40, C backend
#
# Needs: PureBasic 5.73 x64 (found by itself, or -Compiler), libsodium
# extracted in Libs\libsodium\x64 (see Build.ps1), and a sqlite3.dll with
# the JSON functions (3.38+): Libs\sqlite\x64\sqlite3.dll by default, or
# -SqliteDll.
# Everything runs on one machine: the load generator competes with the
# servers for the CPU, its own CPU use is in the report.
# ============================================================================

param(
    [ValidateSet("Y", "Chain", "Mesh")]
    [string]$Topology = "Y",
    [ValidateSet("Declared", "Wildcard")]
    [string]$Names = "Declared",
    [int]$ServerCount = 4,
    [int]$MaxNodesPerServer = 10,
    [int]$MessageSize = 200,
    [int]$PushSeconds = 30,
    [int]$PeerSyncInterval = 5,
    [int]$PeerBatchSize = 100,
    # The servers' [BakaShrot.Server] Synchronous: FULL like their default,
    # NORMAL to compare with the runs from before 2026-11-09.
    [ValidateSet("FULL", "NORMAL")]
    [string]$Synchronous = "FULL",
    [int]$PortBase = 13001,
    [string]$Ramp = "5x5,5x20,5x50,5x100,5x0,10x20,10x50,10x100,10x0",
    [int[]]$SeedTotals = @(250000, 1000000),
    [string]$SteadyStage = "10x10",
    [string]$MixedStage = "10x10",

    [string]$Parts = "Ramp,Scale,Mixed",
    [int]$QueryRepeats = 3,
    [int]$DrainTimeout = 180,
    [string]$Compiler = "",
    [string]$CompilerFlags = "",
    [string]$SqliteDll = "",
    [string]$DataDir = (Join-Path ([IO.Path]::GetTempPath()) "BakaShrot-Bench"),
    [switch]$KeepData,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

# "Ramp,Scale" or "Ramp", "Scale", from -File or -Command alike.
$PartList = @($Parts -split "[, ]" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($Part in $PartList) { if ($Part -notin @("Ramp", "Scale", "Mixed")) { throw "Unknown part $Part, use Ramp, Scale and/or Mixed" } }

$Stamp    = Get-Date -Format "yyyyMMdd-HHmmss"
$Root     = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$BenchDir = $PSScriptRoot
$OutDir   = Join-Path $Root "Build\Bench"
$RunDir   = Join-Path $OutDir "runs\$Stamp"
$RunData  = Join-Path $DataDir $Stamp
$LogDir   = Join-Path $RunData "logs"
$TopicId  = 1


# --- Build ------------------------------------------------------------------

function Find-Compiler {
    if ($Compiler) { return $Compiler }
    foreach ($Candidate in @("C:\Program Files\PureBasic_573\Compilers\pbcompiler.exe",
                             "C:\Program Files\PureBasic573\Compilers\pbcompiler.exe")) {
        if (Test-Path $Candidate) { return $Candidate }
    }
    throw "PureBasic 5.73 x64 not found, pass -Compiler"
}

function Copy-Dlls {
    New-Item -ItemType Directory -Force $OutDir | Out-Null

    $Sodium = Join-Path $Root "Libs\libsodium\x64\libsodium.dll"
    if (-not (Test-Path $Sodium)) { throw "Missing $Sodium, run Build.ps1 once to extract it" }
    Copy-Item $Sodium $OutDir -Force

    $Sqlite = $SqliteDll
    if (-not $Sqlite) { $Sqlite = Join-Path $Root "Libs\sqlite\x64\sqlite3.dll" }
    if (-not (Test-Path $Sqlite)) { throw "Missing $Sqlite, run Build.ps1 once to extract it, or pass -SqliteDll" }
    Copy-Item $Sqlite (Join-Path $OutDir "sqlite3.dll") -Force
    Write-Host "Using SQLite $((Get-Item $Sqlite).VersionInfo.ProductVersion) from $Sqlite"
}

$script:CompilerName = "(not rebuilt, -SkipBuild)"

function Invoke-Build {
    $Pb = Find-Compiler
    New-Item -ItemType Directory -Force $OutDir | Out-Null

    # "PureBasic 6.40 - C Backend (Windows - x64) - (c) ...", 5.73 takes /EXE,
    # 6.x /OUTPUT.
    $script:CompilerName = ((& $Pb /VERSION) | Select-Object -First 1) -replace " - \(c\).*$", ""
    $OutputFlag = if ($script:CompilerName -match "PureBasic 5\.") { "/EXE" } else { "/OUTPUT" }
    $Extra = @($CompilerFlags -split " " | Where-Object { $_ })
    if ($Extra.Count -gt 0) { $script:CompilerName += " " + ($Extra -join " ") }
    Write-Host "Compiler: $($script:CompilerName)"

    foreach ($Item in @(
            @("Tests\Bench\BenchServer.pb", "BenchServer.exe", @("/CONSOLE", "/THREAD")),
            @("Tests\Bench\BenchClient.pb", "BenchClient.exe", @("/CONSOLE", "/THREAD")),
            @("Tests\Bench\BenchSeed.pb",   "BenchSeed.exe",   @("/CONSOLE")),
            @("Tools\BakaShrotGenerateKeyPairs\BakaShrotGenerateKeyPairs.pb",     "BakaShrotGenerateKeyPairs.exe",      @("/CONSOLE")))) {
        Write-Host "Compiling $($Item[0])"
        $Flags = $Item[2] + $Extra
        & $Pb (Join-Path $Root $Item[0]) @Flags /QUIET $OutputFlag (Join-Path $OutDir $Item[1])
        if ($LASTEXITCODE -ne 0) { throw "Failed to compile $($Item[0])" }
    }
}

function New-KeyPair {
    $Lines = & (Join-Path $OutDir "BakaShrotGenerateKeyPairs.exe")
    if ($LASTEXITCODE -ne 0) { throw "BakaShrotGenerateKeyPairs failed: $Lines" }
    return @{
        PrivateKey = $Lines[0] -replace "^PrivateKey = ", ""
        PublicKey  = $Lines[1] -replace "^PublicKey = ", ""
    }
}


# --- Topology and configs -----------------------------------------------------

function Get-Edges {
    $Edges = @()
    switch ($Topology) {
        "Y"     { for ($i = 1; $i -lt $ServerCount; $i++) { $Edges += , @(0, $i) } }
        "Chain" { for ($i = 0; $i -lt $ServerCount - 1; $i++) { $Edges += , @($i, ($i + 1)) } }
        "Mesh"  { for ($i = 0; $i -lt $ServerCount; $i++) { for ($j = $i + 1; $j -lt $ServerCount; $j++) { $Edges += , @($i, $j) } } }
    }
    return , $Edges
}

function New-Servers {
    $Servers = @()
    for ($i = 0; $i -lt $ServerCount; $i++) {
        if ($Topology -eq "Y") {
            if ($i -eq 0) { $Name = "hub" } else { $Name = "leaf$i" }
        } else {
            $Name = "s$($i + 1)"
        }
        $Keys = New-KeyPair
        $Servers += [pscustomobject]@{
            Index        = $i
            Name         = $Name
            NodeId       = $i + 1
            Port         = $PortBase + $i
            PrivateKey   = $Keys.PrivateKey
            PublicKey    = $Keys.PublicKey
            DatabasePath = Join-Path $RunData "$Name.sqlite"
            ConfigPath   = Join-Path $RunDir "$Name.ini"
            StopFile     = Join-Path $RunData "$Name.stop"
            FirstNode    = ($i + 1) * 100 + 1
            MonitorNode  = 900 + $i + 1
            QueryNode    = 950 + $i + 1
            Peers        = @()
            Process      = $null
        }
    }
    foreach ($Edge in (Get-Edges)) {
        $Servers[$Edge[0]].Peers += $Edge[1]
        $Servers[$Edge[1]].Peers += $Edge[0]
    }
    return $Servers
}

function Write-ServerConfig($Server, $Servers, $ClientKeys) {
    $LastNode   = $Server.FirstNode + $MaxNodesPerServer - 1
    # The bench's one key writes as every node: a client section per node.
    $ClientSections = (@($Server.FirstNode..$LastNode) + @($Server.MonitorNode, $Server.QueryNode) | ForEach-Object { @"
[BakaShrot.Client.bench$_]
PublicKeys = $($ClientKeys.PublicKey)
Node = $_
DefaultTopic = $TopicId
AllowRead = 1
AllowWrite = 1
AllowQuery = 1

"@ }) -join "`r`n"

    # Only named topics and nodes replicate, and they must be named on both
    # ends (Declared): every server names every node of every server, with
    # the same ids. Wildcard: each server only names its own, the peers take
    # them by AcceptNodes = n*, and give them ids of their own. The servers'
    # own nodes are named everywhere either way: a peer authenticates by
    # name, the others must know it.
    $NodeNames = @()
    foreach ($Other in $Servers) {
        $NodeNames += "n$($Other.NodeId) = $($Other.NodeId)"
        if ($Names -eq "Wildcard" -and $Other -ne $Server) { continue }
        $OtherLast = $Other.FirstNode + $MaxNodesPerServer - 1
        foreach ($Id in (@($Other.FirstNode..$OtherLast) + @($Other.MonitorNode, $Other.QueryNode))) {
            $NodeNames += "n$Id = $Id"
        }
    }

    $Text = @"
[BakaShrot]
PrivateKey = $($Server.PrivateKey)
Node = $($Server.NodeId)

[BakaShrot.Topics]
bench = $TopicId

[BakaShrot.Nodes]
$($NodeNames -join "`r`n")

[BakaShrot.Server]
Host = 127.0.0.1
Port = $($Server.Port)
ReplicatingTopics = $TopicId
DatabasePath = $($Server.DatabasePath)
PeerRetryDelay = 2
PeerSyncInterval = $PeerSyncInterval
PeerBatchSize = $PeerBatchSize
Synchronous = $Synchronous

$ClientSections
"@
    foreach ($PeerIndex in $Server.Peers) {
        $Peer = $Servers[$PeerIndex]
        $Text += @"
[BakaShrot.Peer.$($Peer.Name)]
Host = 127.0.0.1
Port = $($Peer.Port)
Node = $($Peer.NodeId)
PublicKey = $($Peer.PublicKey)
$(if ($Names -eq "Wildcard") { "AcceptNodes = n*" })

[BakaShrot.Client.$($Peer.Name)]
PublicKeys = $($Peer.PublicKey)
Node = $($Peer.NodeId)
AllowRead = 0
AllowWrite = 0
AllowQuery = 0

"@
    }
    Set-Content -Path $Server.ConfigPath -Value $Text -Encoding Ascii
}


# --- Servers ----------------------------------------------------------------

$script:StartCount = 0

function Test-Port($Port) {
    $Client = New-Object System.Net.Sockets.TcpClient
    try {
        $Async = $Client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if ($Async.AsyncWaitHandle.WaitOne(200) -and $Client.Connected) { return $true }
        return $false
    } catch {
        return $false
    } finally {
        $Client.Close()
    }
}

function Start-Servers($Servers) {
    $script:StartCount++
    foreach ($Server in $Servers) {
        Remove-Item $Server.StopFile -ErrorAction SilentlyContinue
        $Log = Join-Path $LogDir "$($Server.Name)-$($script:StartCount).log"
        $Server.Process = Start-Process -FilePath (Join-Path $OutDir "BenchServer.exe") `
            -ArgumentList "`"$($Server.ConfigPath)`"", "`"$($Server.StopFile)`"" `
            -WorkingDirectory $OutDir -NoNewWindow -PassThru `
            -RedirectStandardOutput $Log -RedirectStandardError "$Log.err"
    }
    foreach ($Server in $Servers) {
        $Deadline = (Get-Date).AddSeconds(15)
        while (-not (Test-Port $Server.Port)) {
            if ($Server.Process.HasExited) { throw "$($Server.Name) exited, see its log in $LogDir" }
            if ((Get-Date) -gt $Deadline) { throw "$($Server.Name) isn't listening on $($Server.Port)" }
            Start-Sleep -Milliseconds 100
        }
    }
    # Let the peers link (they retry every 2 s) and run their first check-in.
    Start-Sleep -Seconds 4
    Write-Host "Servers up: $(($Servers | ForEach-Object { "$($_.Name)=pid $($_.Process.Id)" }) -join ', ')"
}

function Stop-Servers($Servers) {
    foreach ($Server in $Servers) {
        if ($Server.Process -and -not $Server.Process.HasExited) {
            Set-Content -Path $Server.StopFile -Value "stop"
        }
    }
    foreach ($Server in $Servers) {
        if ($Server.Process) {
            if (-not $Server.Process.WaitForExit(30000)) {
                Write-Warning "$($Server.Name) didn't stop, killing it"
                $Server.Process.Kill()
            }
            $Server.Process = $null
        }
    }
}


# --- Stages -----------------------------------------------------------------

function ConvertTo-Stage($Spec) {
    $Fields = $Spec.Trim().ToLower().Split("x")
    return [pscustomobject]@{ Nodes = [int]$Fields[0]; Rate = [double]$Fields[1] }
}

function Write-Plan($Path, $Servers, $ClientKeys, $Stage, $Name, $QueryFile, $QueryLoad) {
    $Text = @"
[Bench]
PrivateKey = $($ClientKeys.PrivateKey)
PublicKey = $($ClientKeys.PublicKey)
TopicId = $TopicId
ServerCount = $($Servers.Count)
PushSeconds = $PushSeconds
Rate = $($Stage.Rate)
MessageSize = $MessageSize
SampleMs = 1000
DrainSampleMs = 250
DrainTimeout = $DrainTimeout
PeerSyncInterval = $PeerSyncInterval
SamplesCsv = $(Join-Path $RunDir "$Name.samples.csv")
SummaryOut = $(Join-Path $RunDir "$Name.summary.json")
QueryFile = $QueryFile
QueryRepeats = $QueryRepeats
QueryOut = $(Join-Path $RunDir "$Name.queries.json")

"@
    foreach ($Server in $Servers) {
        $ProcId = 0
        if ($Server.Process) { $ProcId = $Server.Process.Id }
        # The query suite runs on the hub and the first leaf, the query load
        # only on the hub.
        $Text += @"
[Server$($Server.Index + 1)]
Name = $($Server.Name)
Host = 127.0.0.1
Port = $($Server.Port)
PublicKey = $($Server.PublicKey)
Pid = $ProcId
DatabasePath = $($Server.DatabasePath)
FirstNode = $($Server.FirstNode)
MaxNodes = $MaxNodesPerServer
NodeCount = $($Stage.Nodes)
MonitorNode = $($Server.MonitorNode)
QueryNode = $($Server.QueryNode)
QueryLoad = $([int]($QueryLoad -and $Server.Index -eq 0))
Query = $([int]($Server.Index -le 1))

"@
    }
    Set-Content -Path $Path -Value $Text -Encoding Ascii
}

function Invoke-BenchClient($Mode, $Plan) {
    & (Join-Path $OutDir "BenchClient.exe") $Mode $Plan | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "BenchClient $Mode failed" }
}

$script:Results = @()
$script:QueryResults = @()

function Invoke-Stage($Part, $Name, $Stage, $Servers, $ClientKeys, [switch]$QueryLoad) {
    $Plan = Join-Path $RunDir "$Name.plan.ini"
    $LoadFile = ""
    if ($QueryLoad) { $LoadFile = Join-Path $BenchDir "queries_load.txt" }
    Write-Plan $Plan $Servers $ClientKeys $Stage $Name $LoadFile $QueryLoad

    $RateText = if ($Stage.Rate -gt 0) { "$($Stage.Rate) msg/s" } else { "max" }
    Write-Host ""
    Write-Host "=== $Name : $($Stage.Nodes) nodes/server x $RateText, $PushSeconds s ===" -ForegroundColor Cyan
    # Other processes busy meanwhile (antivirus scanning the databases...),
    # tick-based, only good enough to spot the big ones.
    $Before = @{}
    Get-Process | ForEach-Object { $Before[$_.Id] = $_.CPU }
    $StartTime = Get-Date
    Invoke-BenchClient "run" $Plan
    $Seconds = ((Get-Date) - $StartTime).TotalSeconds
    $Others = Get-Process | Where-Object { $_.Name -notin @("BenchServer", "BenchClient", "Idle") -and $null -ne $_.CPU } | ForEach-Object {
        $Previous = 0
        if ($Before.ContainsKey($_.Id)) { $Previous = $Before[$_.Id] }
        [pscustomobject]@{ Name = $_.Name; Percent = 100 * ($_.CPU - $Previous) / $Seconds }
    } | Sort-Object Percent -Descending | Select-Object -First 3
    $Summary = Get-Content (Join-Path $RunDir "$Name.summary.json") -Raw | ConvertFrom-Json
    $Summary | Add-Member -NotePropertyName OtherProcesses -NotePropertyValue (($Others | Where-Object Percent -ge 5 | ForEach-Object { "$($_.Name) $(Format-Num $_.Percent)" }) -join ", ")
    $Summary | Add-Member -NotePropertyName Stage -NotePropertyValue $Name
    $Summary | Add-Member -NotePropertyName Part -NotePropertyValue $Part
    $Summary | Add-Member -NotePropertyName NodesPerServer -NotePropertyValue $Stage.Nodes
    $script:Results += $Summary

    # The query suite, on the idle servers.
    Write-Plan $Plan $Servers $ClientKeys $Stage $Name (Join-Path $BenchDir "queries.txt") $false
    Invoke-BenchClient "query" $Plan
    $Rows = ($Summary.Servers | Measure-Object -Property Rows -Maximum).Maximum
    foreach ($Query in (Get-Content (Join-Path $RunDir "$Name.queries.json") -Raw | ConvertFrom-Json)) {
        $Query | Add-Member -NotePropertyName Stage -NotePropertyValue $Name
        $Query | Add-Member -NotePropertyName DataRows -NotePropertyValue $Rows
        $script:QueryResults += $Query
    }
    return $Summary
}

function Invoke-Seed($Servers, $TargetRows, $CurrentRows) {
    $Nodes = $Servers.Count * $MaxNodesPerServer
    $PerNode = [math]::Ceiling(($TargetRows - $CurrentRows) / $Nodes)
    if ($PerNode -le 0) { return }
    $Spec = ($Servers | ForEach-Object { "$($_.FirstNode)-$($_.FirstNode + $MaxNodesPerServer - 1)" }) -join ","
    Write-Host ""
    Write-Host "=== Seeding to ~$TargetRows rows per server ($PerNode more per node, in every database) ===" -ForegroundColor Cyan
    Stop-Servers $Servers
    $Dbs = $Servers | ForEach-Object { $_.DatabasePath }
    & (Join-Path $OutDir "BenchSeed.exe") $TopicId $Spec $PerNode $MessageSize @Dbs | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "BenchSeed failed" }
    Start-Servers $Servers
}


# --- Report -----------------------------------------------------------------

function Format-Num($Value, $Decimals = 0) {
    return ([double]$Value).ToString("N$Decimals", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-Verdict($Summary) {
    $Notes = @()
    if ($Summary.Rate -gt 0 -and $Summary.PushRate -lt 0.9 * $Summary.OfferedRate) { $Notes += "push saturated" }
    if ($Summary.Failed -gt 0) { $Notes += "$($Summary.Failed) failed pushes" }
    # The trough slope is too noisy for a verdict (check-ins drift against the
    # windows), the lag in seconds of pushes isn't: keeping up means about
    # two check-ins' worth at most, through the hub.
    $MaxLagSeconds = ($Summary.Servers | Measure-Object -Property LagMaxSeconds -Maximum).Maximum
    if ($MaxLagSeconds -gt 2 * $PeerSyncInterval + 2) { $Notes += "replication lagging" }
    if (-not $Summary.Drained) { $Notes += "NOT drained" }
    elseif ($Summary.DrainSeconds -gt 2 * $PeerSyncInterval + 5) { $Notes += "slow drain" }
    if ($Notes.Count -eq 0) { return "ok" }
    return $Notes -join ", "
}

function Get-LogIssues($Servers) {
    $Issues = @()
    foreach ($Server in $Servers) {
        $Logs = Get-ChildItem $LogDir -Filter "$($Server.Name)-*.log"
        $Counts = [ordered]@{}
        foreach ($Pattern in @("Refused", "Failed", "locked", "timed out", "Dropping", "Lost the link", "too big")) {
            $Counts[$Pattern] = @($Logs | Select-String -SimpleMatch $Pattern).Count
        }
        $Sent = @($Logs | Select-String -Pattern "\[Peer\] Sent (\d+) messages .* in (\d+) ms")
        $Messages = 0; $Ms = 0
        foreach ($Match in $Sent) {
            $Messages += [int]$Match.Matches[0].Groups[1].Value
            $Ms += [int]$Match.Matches[0].Groups[2].Value
        }
        $Issues += [pscustomobject]@{
            Server = $Server.Name; Counts = $Counts
            ReplicatedOut = $Messages; ReplicateMs = $Ms; CatchUps = $Sent.Count
        }
    }
    return $Issues
}

function Write-Report($Servers) {
    $Lines = @()
    $Lines += "# BakaShrot replication benchmark, $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $Lines += ""
    $Cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
    $Ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $Lines += "- Machine: $Cpu, $Ram GB RAM, everything on localhost"
    $Lines += "- Topology: $Topology, $ServerCount servers ($(($Servers | ForEach-Object { "$($_.Name) <-> " + (($_.Peers | ForEach-Object { $Servers[$_].Name }) -join '/') }) -join '; '))"
    $Lines += "- Names: $Names ($(if ($Names -eq 'Wildcard') { 'each server names its own nodes, peers take them by AcceptNodes = n*' } else { 'every node named on every server' }))"
    $Lines += "- Messages: ~$MessageSize bytes of JSON, PeerSyncInterval $PeerSyncInterval s, PeerBatchSize $PeerBatchSize, $PushSeconds s per stage"
    $Lines += "- Built with: $($script:CompilerName), SQLite $((Get-Item (Join-Path $OutDir 'sqlite3.dll')).VersionInfo.ProductVersion)"
    $Lines += "- CPU in % of one core (100 = one core busy), System = whole machine in %, Bench = the load generator itself (% of one core)"
    $Lines += ""

    $Lines += "## Stages"
    $Lines += ""
    $Lines += "- Max lag: most messages a server was missing while pushing. Trough: the lowest lag of the last check-in window, slope: how fast those troughs rise (~0 = keeps up)."
    $Lines += ""
    $Lines += "| Stage | Nodes | Offered msg/s | Pushed msg/s | Push p50 / p99 / max ms | Failed | Max lag msgs (s of pushes) | Last trough | Trough slope msg/s | Drain s | Verdict |"
    $Lines += "|---|---|---|---|---|---|---|---|---|---|---|"
    foreach ($R in $script:Results) {
        $Offered = if ($R.Rate -gt 0) { Format-Num $R.OfferedRate } else { "max" }
        $Lag = ($R.Servers | Measure-Object -Property LagMaxPush -Maximum).Maximum
        $LagSeconds = ($R.Servers | Measure-Object -Property LagMaxSeconds -Maximum).Maximum
        $Trough = ($R.Servers | Measure-Object -Property LagTroughLast -Maximum).Maximum
        $Slope = ($R.Servers | Measure-Object -Property LagSlope -Maximum).Maximum
        $Drain = if ($R.Drained) { Format-Num $R.DrainSeconds 1 } else { "> $DrainTimeout" }
        $Lines += "| $($R.Stage) | $($R.NodesPerServer) x $ServerCount | $Offered | $(Format-Num $R.PushRate) | $(Format-Num $R.PushP50Ms 1) / $(Format-Num $R.PushP99Ms 1) / $(Format-Num $R.PushMaxMs 0) | $($R.Failed) | $(Format-Num $Lag) ($(Format-Num $LagSeconds 1)) | $(Format-Num $Trough) | $(Format-Num $Slope 1) | $Drain | $(Get-Verdict $R) |"
    }
    $Lines += ""

    $Lines += "## Resources while pushing"
    $Lines += ""
    $Header = "| Stage | System CPU avg / max | Bench CPU |"
    $Sep = "|---|---|---|"
    foreach ($Server in $Servers) { $Header += " $($Server.Name) CPU avg / max | $($Server.Name) RAM WS / private MB |"; $Sep += "---|---|" }
    $Header += " Other busy processes (% core) |"; $Sep += "---|"
    $Lines += $Header
    $Lines += $Sep
    foreach ($R in $script:Results) {
        $Row = "| $($R.Stage) | $(Format-Num $R.SystemCpuAvg) % / $(Format-Num $R.SystemCpuMax) % | $(Format-Num $R.BenchCpuAvg) |"
        foreach ($S in $R.Servers) { $Row += " $(Format-Num $S.CpuAvgPush) / $(Format-Num $S.CpuMaxPush) | $(Format-Num $S.WorkingSetMaxMb 1) / $(Format-Num $S.PrivateMaxMb 1) |" }
        $Row += " $($R.OtherProcesses) |"
        $Lines += $Row
    }
    $Lines += ""

    $Lines += "## Per server, end of stage"
    $Lines += ""
    $Header = "| Stage |"
    $Sep = "|---|"
    foreach ($Server in $Servers) { $Header += " $($Server.Name) rows | DB MB | max lag | monitor query avg / max ms |"; $Sep += "---|---|---|---|" }
    $Lines += $Header
    $Lines += $Sep
    foreach ($R in $script:Results) {
        $Row = "| $($R.Stage) |"
        foreach ($S in $R.Servers) { $Row += " $(Format-Num $S.Rows) | $(Format-Num $S.DbMb 1) | $(Format-Num $S.LagMaxPush) | $(Format-Num $S.MonitorAvgMs 1) / $(Format-Num $S.MonitorMaxMs 1) |" }
        $Lines += $Row
    }
    $Lines += ""

    $Lines += "## Queries, idle, median ms (on $($Servers[0].Name))"
    $Lines += ""
    $Stages = $script:QueryResults | Where-Object Server -eq $Servers[0].Name | Select-Object -ExpandProperty Stage -Unique
    $Names = $script:QueryResults | Select-Object -ExpandProperty Name -Unique
    $Header = "| Query |"
    $Sep = "|---|"
    foreach ($Stage in $Stages) {
        $Rows = ($script:QueryResults | Where-Object { $_.Stage -eq $Stage } | Select-Object -First 1).DataRows
        $Header += " $Stage ($(Format-Num $Rows) rows) |"; $Sep += "---|"
    }
    $Lines += $Header
    $Lines += $Sep
    foreach ($Name in $Names) {
        $Row = "| $Name |"
        foreach ($Stage in $Stages) {
            $Q = $script:QueryResults | Where-Object { $_.Stage -eq $Stage -and $_.Name -eq $Name -and $_.Server -eq $Servers[0].Name } | Select-Object -First 1
            if (-not $Q) { $Row += " |" }
            elseif ($Q.Count -eq 0) { $Row += " FAIL: $($Q.LastError) |" }
            else { $Row += " $(Format-Num $Q.P50Ms 1) |" }
        }
        $Lines += $Row
    }
    $Lines += ""

    $Mixed = $script:Results | Where-Object { $_.QueriesUnderLoad.Count -gt 0 }
    foreach ($R in $Mixed) {
        $Lines += "## Queries under load ($($R.Stage), on $($Servers[0].Name), while pushing $(Format-Num $R.PushRate) msg/s)"
        $Lines += ""
        $Lines += "| Query | Runs | p50 ms | p90 ms | max ms | Failures |"
        $Lines += "|---|---|---|---|---|---|"
        foreach ($Q in $R.QueriesUnderLoad) {
            $Lines += "| $($Q.Name) | $($Q.Count) | $(Format-Num $Q.P50Ms 1) | $(Format-Num $Q.P90Ms 1) | $(Format-Num $Q.MaxMs 1) | $($Q.Failures) $($Q.LastError) |"
        }
        $Lines += ""
    }

    $Lines += "## Server logs"
    $Lines += ""
    $Lines += "| Server | Catch-ups sent | Messages replicated out | ms spent sending | Refused | Failed | locked | timed out | Dropping | Lost the link | too big |"
    $Lines += "|---|---|---|---|---|---|---|---|---|---|---|"
    foreach ($I in (Get-LogIssues $Servers)) {
        $Lines += "| $($I.Server) | $($I.CatchUps) | $(Format-Num $I.ReplicatedOut) | $(Format-Num $I.ReplicateMs) | $(($I.Counts.Values) -join ' | ') |"
    }
    $Lines += ""

    $Report = Join-Path $RunDir "report.md"
    Set-Content -Path $Report -Value ($Lines -join "`r`n") -Encoding UTF8
    @{ Results = $script:Results; Queries = $script:QueryResults } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $RunDir "results.json") -Encoding UTF8
    return $Report
}


# --- Main -------------------------------------------------------------------

if (-not $SkipBuild) { Invoke-Build }
Copy-Dlls
New-Item -ItemType Directory -Force $RunDir, $LogDir | Out-Null
Write-Host "Run folder: $RunDir"

$ClientKeys = New-KeyPair
$Servers = @(New-Servers)
foreach ($Server in $Servers) { Write-ServerConfig $Server $Servers $ClientKeys }

try {
    Start-Servers $Servers
    $Last = $null

    if ($PartList -contains "Ramp") {
        $i = 0
        foreach ($Spec in $Ramp.Split(",")) {
            $i++
            $Stage = ConvertTo-Stage $Spec
            $Last = Invoke-Stage "Ramp" ("ramp{0:D2}-{1}" -f $i, $Spec.Trim()) $Stage $Servers $ClientKeys
        }
    }

    if ($PartList -contains "Scale") {
        foreach ($Target in $SeedTotals) {
            $Current = 0
            if ($Last) { $Current = ($Last.Servers | Measure-Object -Property Rows -Minimum).Minimum }
            Invoke-Seed $Servers $Target $Current
            $Last = Invoke-Stage "Scale" ("scale-{0}k" -f [math]::Round($Target / 1000)) (ConvertTo-Stage $SteadyStage) $Servers $ClientKeys
        }
    }

    if ($PartList -contains "Mixed") {
        $Last = Invoke-Stage "Mixed" "mixed" (ConvertTo-Stage $MixedStage) $Servers $ClientKeys -QueryLoad
    }
}
finally {
    Stop-Servers $Servers
    if ($script:Results.Count -gt 0) {
        $Report = Write-Report $Servers
        Write-Host ""
        Write-Host "Report: $Report"
    }
    Write-Host "Server logs: $LogDir"
    if (-not $KeepData) {
        Get-ChildItem $RunData -Filter "*.sqlite*" | Remove-Item -Force
    } else {
        Write-Host "Databases kept in $RunData"
    }
}
