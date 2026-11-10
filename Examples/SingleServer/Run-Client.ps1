# ============================================================================
# BakaShrot example: what a client does, with the tools and client.ini.
#
# Start the server first (Start-Server.ps1). Each step prints the command
# it runs, then its output: run from this folder, the commands can be
# pasted as they are. Every run pushes 3 more messages, the ids go on from
# the last run's (Start-Server.ps1 -Reset starts over).
#
# Usage: powershell -ExecutionPolicy Bypass -File Run-Client.ps1 [-BinDir <dir>]
#   -BinDir  Where the tools are, with BakaShrot_Client.dll next to them:
#            Build\ by default (Build.ps1), or a Release\<v>\.
# ============================================================================

param(
    [string]$BinDir = (Join-Path $PSScriptRoot "..\..\Build")
)

$ErrorActionPreference = "Stop"

$Port = 12360

function Test-Port($Port) {
    $Client = New-Object System.Net.Sockets.TcpClient
    try {
        $Async = $Client.BeginConnect("127.0.0.1", $Port, $null, $null)
        return ($Async.AsyncWaitHandle.WaitOne(200) -and $Client.Connected)
    } catch { return $false }
    finally { $Client.Close() }
}

function Write-Step($Text) {
    Write-Host ""
    Write-Host "== $Text" -ForegroundColor Cyan
}

# Runs a tool, shows the command and what it printed, stops if it failed.
# client.ini is always the last argument.
function Invoke-Tool($Name, [string[]]$Arguments) {
    $Arguments += "client.ini"
    $Shown = $Arguments | ForEach-Object { if ($_ -match " ") { "`"$_`"" } else { $_ } }
    Write-Host ("> " + (Join-Path $Bin "$Name.exe") + " " + ($Shown -join " ")) -ForegroundColor DarkGray
    $Output = & (Join-Path $Bin "$Name.exe") @Arguments 2>&1
    $Code = $LASTEXITCODE
    $Output | ForEach-Object { Write-Host "  $_" }
    if ($Code -ne 0) { throw "$Name failed with code $Code" }
    return ($Output -join "`n")
}

if (-not (Test-Path (Join-Path $BinDir "BakaShrot_Client.dll"))) {
    throw "No BakaShrot_Client.dll in ${BinDir}: build it first (Build.ps1), or pass -BinDir"
}
if (-not (Test-Port $Port)) {
    throw "Nothing listens on port ${Port}: start the server first (Start-Server.ps1)"
}

# From this folder, so every path is short: client.ini, messages\...
Push-Location $PSScriptRoot
try {
    $Bin = Resolve-Path -Relative $BinDir
    New-Item -ItemType Directory -Force "out" | Out-Null

    Write-Step "Push a message to the client's default topic (logs, the server's DefaultTopic for it), as node demo"
    # JSON goes in a file (@file): PowerShell drops the double quotes of an argument.
    $null = Invoke-Tool "BakaShrotPushMessage" @("@messages\hello.json")

    Write-Step "Push one to another topic it may push to (sensors)"
    $null = Invoke-Tool "BakaShrotPushMessage" @("-t", "sensors", "@messages\reading.json")

    Write-Step "Push one with a file attached"
    $Pushed = Invoke-Tool "BakaShrotPushMessage" @("-a", "messages\report.txt", "@messages\report.json")
    if ($Pushed -notmatch "message #(\d+)") { throw "Unexpected answer: $Pushed" }
    $ReportId = $Matches[1]

    Write-Step "Read the latest message of logs:demo (topic:node, by name)"
    $null = Invoke-Tool "BakaShrotGetLatestMessage" @("logs", "demo")

    Write-Step "Read the attachment back"
    $null = Invoke-Tool "BakaShrotGetAttachment" @("logs", "demo", $ReportId, "out\report-copy.txt")
    if ((Get-FileHash "out\report-copy.txt").Hash -ne (Get-FileHash "messages\report.txt").Hash) { throw "The attachment came back different" }
    Write-Host "  Same bytes as messages\report.txt"

    Write-Step "Read every message of logs:demo, with when they were pushed (UTC)"
    $null = Invoke-Tool "BakaShrotGetMessages" @("logs", "demo", "--time")

    Write-Step "Read the sensors one"
    $null = Invoke-Tool "BakaShrotGetLatestMessage" @("sensors", "demo")

    Write-Step "What the server calls the names: their ids there"
    $null = Invoke-Tool "BakaShrotResolveIds" @("topic", "sensors")
    $null = Invoke-Tool "BakaShrotList" @()

    Write-Step "A raw SQL query (needs AllowQuery = 1), from messages\query.sql"
    $null = Invoke-Tool "BakaShrotQuery" @("@messages\query.sql")

    Write-Host ""
    Write-Host "Done. To follow new messages as they come, from this folder:" -ForegroundColor Green
    Write-Host "  $(Join-Path $Bin 'BakaShrotGetMessages.exe') logs demo --after latest --follow client.ini"
}
finally {
    Pop-Location
}
