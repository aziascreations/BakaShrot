# ============================================================================
# Compares runs of Bench-Replication.ps1 side by side, as a markdown table.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File Tests\Bench\Compare-Runs.ps1 `
#       -Runs "Build\Bench\runs\20261107-123413,Build\Bench\runs\20261107-125334" `
#       -Labels "Before,WAL + wake-ups" [-Out comparison.md]
#
# Picks the key numbers of each run's results.json: the push ceilings, the
# latencies, replication lag and drain, CPU and RAM, the queries at the
# biggest data size, and the mixed stage. Stages missing from a run show "-".
# ============================================================================

param(
    [Parameter(Mandatory = $true)] [string[]]$Runs,
    [string[]]$Labels = @(),
    [string]$Out = ""
)

$ErrorActionPreference = "Stop"

# "powershell -File" passes "a,b" as one string.
$Runs   = @($Runs | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Labels = @($Labels | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$Culture = [Globalization.CultureInfo]::InvariantCulture

function Format-Num($Value, $Decimals = 0) {
    if ($null -eq $Value) { return "-" }
    return ([double]$Value).ToString("N$Decimals", $Culture)
}

$Data = @()
for ($i = 0; $i -lt $Runs.Count; $i++) {
    $Json = Get-Content (Join-Path $Runs[$i] "results.json") -Raw | ConvertFrom-Json
    $Label = if ($i -lt $Labels.Count) { $Labels[$i] } else { Split-Path $Runs[$i] -Leaf }
    $Data += [pscustomobject]@{ Label = $Label; Results = @($Json.Results); Queries = @($Json.Queries) }
}

# A stage by the end of its name ("5x0" matches "ramp05-5x0").
function Get-Stage($Run, $Suffix) {
    return $Run.Results | Where-Object { $_.Stage -like "*$Suffix" } | Select-Object -First 1
}

function Get-Max($Stage, $Property) {
    if (-not $Stage) { return $null }
    return ($Stage.Servers | Measure-Object -Property $Property -Maximum).Maximum
}

function Get-Avg($Stage, $Property) {
    if (-not $Stage) { return $null }
    return ($Stage.Servers | Measure-Object -Property $Property -Average).Average
}

# Median of a query on the first server, in the last stage that ran it.
function Get-Query($Run, $Name) {
    $Q = $Run.Queries | Where-Object { $_.Name -eq $Name -and $_.Server -eq $Run.Results[0].Servers[0].Name } | Select-Object -Last 1
    if (-not $Q -or $Q.Count -eq 0) { return $null }
    return $Q.P50Ms
}

function Get-LoadQuery($Run, $Name) {
    $Mixed = Get-Stage $Run "mixed"
    if (-not $Mixed) { return $null }
    $Q = $Mixed.QueriesUnderLoad | Where-Object Name -eq $Name | Select-Object -First 1
    if (-not $Q) { return $null }
    return $Q.P50Ms
}

$Rows = @(
    @("**Push ceiling**, msg/s, 5 nodes/server", { param($R) Format-Num (Get-Stage $R "5x0").PushRate }),
    @("**Push ceiling**, msg/s, 10 nodes/server", { param($R) Format-Num (Get-Stage $R "10x0").PushRate }),
    @("Pushed of 2,000 offered (10 x 50)", { param($R) Format-Num (Get-Stage $R "10x50").PushRate }),
    @("Pushed of 4,000 offered (10 x 100)", { param($R) Format-Num (Get-Stage $R "10x100").PushRate }),
    @("Push p50 / p99 ms, 10 x 50", { param($R) $S = Get-Stage $R "10x50"; if ($S) { "$(Format-Num $S.PushP50Ms 1) / $(Format-Num $S.PushP99Ms 1)" } else { "-" } }),
    @("Push p50 / p99 / max ms, flat out (10 nodes)", { param($R) $S = Get-Stage $R "10x0"; if ($S) { "$(Format-Num $S.PushP50Ms 1) / $(Format-Num $S.PushP99Ms 1) / $(Format-Num $S.PushMaxMs)" } else { "-" } }),
    @("Replication lag, s of pushes, flat out", { param($R) Format-Num (Get-Max (Get-Stage $R "10x0") "LagMaxSeconds") 1 }),
    @("Drain after the push, s, flat out", { param($R) Format-Num (Get-Stage $R "10x0").DrainSeconds 1 }),
    @("Server CPU, % of a core, flat out (avg of the 4)", { param($R) Format-Num (Get-Avg (Get-Stage $R "10x0") "CpuAvgPush") }),
    @("Machine CPU %, flat out", { param($R) Format-Num (Get-Stage $R "10x0").SystemCpuAvg }),
    @("Hub RAM, working set MB, max", { param($R) Format-Num (($R.Results | ForEach-Object { $_.Servers[0].WorkingSetMaxMb } | Measure-Object -Maximum).Maximum) 1 }),
    @("Rows per server at the end", { param($R) Format-Num $R.Results[-1].Servers[0].Rows }),
    @("Query: latest message, ms (1M rows)", { param($R) Format-Num (Get-Query $R "latest_message") 1 }),
    @("Query: last 50 of a node, ms", { param($R) Format-Num (Get-Query $R "last_50_of_node") 1 }),
    @("Query: sync state (GROUP BY all), ms", { param($R) Format-Num (Get-Query $R "sync_state") 1 }),
    @("Query: sync state from node_heads (what check-ins use now), ms", { param($R) Format-Num (Get-Query $R "sync_state_heads") 1 }),
    @("Query: JSON count over all rows, ms", { param($R) Format-Num (Get-Query $R "json_count_all") 1 }),
    @("Query: JSON aggregate over all rows, ms", { param($R) Format-Num (Get-Query $R "json_agg_all") 1 }),
    @("**Mixed:** pushed of 400 msg/s with a query loop", { param($R) Format-Num (Get-Stage $R "mixed").PushRate }),
    @("Mixed: push p99 / max ms", { param($R) $S = Get-Stage $R "mixed"; if ($S) { "$(Format-Num $S.PushP99Ms 1) / $(Format-Num $S.PushMaxMs)" } else { "-" } }),
    @("Mixed: failed pushes", { param($R) $S = Get-Stage $R "mixed"; if ($S) { $S.Failed } else { "-" } }),
    @("Mixed: JSON count over all rows, ms, under load", { param($R) Format-Num (Get-LoadQuery $R "json_count_all") 1 }),
    @("Mixed: latest message, ms, under load", { param($R) Format-Num (Get-LoadQuery $R "latest_message") 1 })
)

$Lines = @()
$Lines += "| | " + (($Data | ForEach-Object { $_.Label }) -join " | ") + " |"
$Lines += "|---|" + (($Data | ForEach-Object { "---" }) -join "|") + "|"
foreach ($Row in $Rows) {
    $Cells = foreach ($Run in $Data) { & $Row[1] $Run }
    $Lines += "| $($Row[0]) | " + ($Cells -join " | ") + " |"
}

$Text = $Lines -join "`r`n"
if ($Out) { Set-Content -Path $Out -Value $Text -Encoding UTF8 }
$Text
