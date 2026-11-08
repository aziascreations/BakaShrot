# ============================================================================
# BakaShrot release build
#
# Builds everything with PureBasic 6.40's C backend and its optimizer into
# Release\<version>\, ready to copy to a server or hand to a client:
#   BakaShrot_Server.exe                the server
#   BakaShrot_Client.dll                the client DLL, with
#   BakaShrot_Client_Prototypes.pbi     its PureBasic prototypes
#   PushMessage.exe, GetLatestMessage.exe, GetMessages.exe, GetAttachment.exe,
#   Query.exe, Resolve.exe, ListNames.exe, KeyGen.exe   the tools
#   libsodium.dll, sqlite3.dll          what they need next to them
#   vcruntime140.dll                    what libsodium.dll needs (Libs\redist)
#   python\bakashrot.py, example.py     the Python client, over the DLL
#   config.example.ini                  the server's config, documented
#   VERSION.txt                         commit, date, compiler, libraries
# and Release\BakaShrot-<version>.zip of it, unless -NoZip.
#
# No keys and no configs with keys in it: generate them with KeyGen.exe.
#
# Then checks the build works, unless -SkipTest: generates keys, runs the
# server from the release folder on a spare port with a throwaway database,
# pushes two messages, reads them back by name (the latest, then both),
# resolves a name and queries it through the "messages" view with the
# tools, reads them with the Python client if Python is on the PATH, then
# stops the server and deletes all of it.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File Release.ps1
#   ... -Version 1.2.0           instead of <date>-<commit>
#   ... -Force                   replaces Release\<version>\ if it exists
#   ... -Compiler <path> -NoOptimizer -SqliteDll <path> -SkipTest -NoZip
#
# Needs libsodium in Libs\libsodium\x64 and sqlite3.dll (3.38+, for the JSON
# functions) in Libs\sqlite\x64, Build.ps1 extracts both from Libs\*.zip.
# ============================================================================

param(
    [string]$Version = "",
    [string]$Compiler = "C:\Program Files\PureBasic_640\Compilers\pbcompilerc.exe",
    [switch]$NoOptimizer,
    [string]$SqliteDll = "",
    [string]$OutRoot = "",
    [switch]$Force,
    [switch]$SkipTest,
    [switch]$NoZip,
    [int]$TestPort = 12399
)

$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot
if (-not $OutRoot) { $OutRoot = Join-Path $Root "Release" }


# --- Checks -----------------------------------------------------------------

if (-not (Test-Path $Compiler)) { throw "Compiler not found: $Compiler, pass -Compiler" }
$CompilerName = ((& $Compiler /VERSION) | Select-Object -First 1) -replace " - \(c\).*$", ""
if ($CompilerName -notmatch "PureBasic 6\.") { throw "Expected PureBasic 6.x, got '$CompilerName'" }
if ($CompilerName -notmatch "C Backend") { Write-Warning "Not the C backend: $CompilerName" }

$Sodium = Join-Path $Root "Libs\libsodium\x64\libsodium.dll"
if (-not (Test-Path $Sodium) -or -not (Test-Path (Join-Path $Root "Libs\libsodium\x64\libsodium.lib"))) {
    throw "Missing Libs\libsodium\x64\libsodium.dll/.lib, run Build.ps1 once to extract them"
}
if (-not $SqliteDll) { $SqliteDll = Join-Path $Root "Libs\sqlite\x64\sqlite3.dll" }
if (-not (Test-Path $SqliteDll)) { throw "Missing $SqliteDll, run Build.ps1 once to extract it, or pass -SqliteDll" }
$SqliteVersion = (Get-Item $SqliteDll).VersionInfo.ProductVersion
if ([version]$SqliteVersion -lt [version]"3.38") { throw "SQLite $SqliteVersion is too old, the JSON functions need 3.38+" }
$SodiumVersion = (Get-Item $Sodium).VersionInfo.ProductVersion
# The runtime DLLs Windows may not have, see Libs\redist\README.md.
$Redist = @(Get-ChildItem (Join-Path $Root "Libs\redist\x64") -Filter "*.dll" -ErrorAction SilentlyContinue)
if (-not ($Redist | Where-Object { $_.Name -eq "vcruntime140.dll" })) {
    throw "Missing Libs\redist\x64\vcruntime140.dll, libsodium.dll needs it, see Libs\redist\README.md"
}
$RedistVersion = ($Redist | Where-Object { $_.Name -eq "vcruntime140.dll" }).VersionInfo.FileVersion

# The commit, marked "dirty" if anything isn't committed.
$Commit = "nogit"
$Dirty = $false
Push-Location $Root
try {
    $Commit = (git rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $Commit) { $Commit = "nogit" }
    else { $Dirty = [bool](git status --porcelain 2>$null) }
} catch { $Commit = "nogit" }
finally { Pop-Location }

if (-not $Version) {
    $Version = (Get-Date -Format "yyyyMMdd") + "-" + $Commit
    if ($Dirty) { $Version += "-dirty" }
}

$OutDir = Join-Path $OutRoot $Version
if (Test-Path $OutDir) {
    if (-not $Force) { throw "$OutDir already exists, pass -Force to replace it" }
    Remove-Item -Recurse -Force $OutDir
}
New-Item -ItemType Directory -Force $OutDir | Out-Null

Write-Host "Release $Version -> $OutDir"
Write-Host "Compiler: $CompilerName$(if (-not $NoOptimizer) { ' /OPTIMIZER' })"
Write-Host "SQLite $SqliteVersion, libsodium $SodiumVersion"
if ($Dirty) { Write-Warning "Uncommitted changes, the version is marked dirty" }


# --- Build ------------------------------------------------------------------

$Common = @("/QUIET")
if (-not $NoOptimizer) { $Common += "/OPTIMIZER" }

$Targets = @(
    @("Server\BakaShrot_Server.pb",           "BakaShrot_Server.exe", @("/CONSOLE", "/THREAD")),
    @("Client\BakaShrot_Client.pbi",          "BakaShrot_Client.dll", @("/DLL", "/THREAD")),
    @("Tools\PushMessage\PushMessage.pb",     "PushMessage.exe",      @("/CONSOLE")),
    @("Tools\GetLatestMessage\GetLatestMessage.pb", "GetLatestMessage.exe", @("/CONSOLE")),
    @("Tools\GetMessages\GetMessages.pb",     "GetMessages.exe",      @("/CONSOLE")),
    @("Tools\GetAttachment\GetAttachment.pb", "GetAttachment.exe",    @("/CONSOLE")),
    @("Tools\Query\Query.pb",                 "Query.exe",            @("/CONSOLE")),
    @("Tools\Resolve\Resolve.pb",             "Resolve.exe",          @("/CONSOLE")),
    @("Tools\ListNames\ListNames.pb",         "ListNames.exe",        @("/CONSOLE")),
    @("Tools\KeyGen\KeyGen.pb",               "KeyGen.exe",           @("/CONSOLE"))
)

Push-Location $Root
try {
    foreach ($Target in $Targets) {
        Write-Host "Compiling $($Target[0])"
        $Flags = $Target[2] + $Common
        & $Compiler (Join-Path $Root $Target[0]) @Flags /OUTPUT (Join-Path $OutDir $Target[1])
        if ($LASTEXITCODE -ne 0) { throw "Failed to compile $($Target[0])" }
    }
}
finally {
    Pop-Location
}

# The DLL's import library and exports aren't needed to use it.
Get-ChildItem $OutDir -Include "*.lib", "*.exp" -Recurse | Remove-Item -Force

Copy-Item $Sodium $OutDir
foreach ($File in $Redist) { Copy-Item $File.FullName $OutDir }
Copy-Item $SqliteDll (Join-Path $OutDir "sqlite3.dll")
Copy-Item (Join-Path $Root "Client\BakaShrot_Client_Prototypes.pbi") $OutDir
New-Item -ItemType Directory -Force (Join-Path $OutDir "python") | Out-Null
foreach ($File in @("bakashrot.py", "example.py")) {
    Copy-Item (Join-Path $Root "Interactors\Python\$File") (Join-Path $OutDir "python")
}
Copy-Item (Join-Path $Root "Server\Config\schema.ini") (Join-Path $OutDir "config.example.ini")

$VersionText = @"
BakaShrot $Version
Built:     $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Commit:    $Commit$(if ($Dirty) { " (with uncommitted changes)" })
Compiler:  $CompilerName$(if (-not $NoOptimizer) { " /OPTIMIZER" })
SQLite:    $SqliteVersion
libsodium: $SodiumVersion
VC++ runtime: $RedistVersion (vcruntime140.dll, for libsodium.dll)

Needs Windows 10 or later, 64-bit. Keep the DLLs next to the exes.

Run the server:  BakaShrot_Server.exe config.ini
  Its config: config.example.ini. Keys: KeyGen.exe, the private key goes in
  [BakaShrot] PrivateKey, the public key in the configs that trust it, and
  in its clients' client.ini as ServerPublicKey (it logs it when it starts).
  Every connection is encrypted, and only reaches the server holding the
  private key of the ServerPublicKey (or peer PublicKey) it was given.
  It reads commands from its console (quit, restart, vacuum, help), so it
  needs one: it stops right away without console input.
  Topics and nodes go by name ([BakaShrot.Topics], [BakaShrot.Nodes]) or id,
  each server has its own ids for the same names.
Tools, next to BakaShrot_Client.dll, with a client.ini:
  PushMessage [-t <Topic>] [-a <File>] <Json|@JsonFile> [ClientIni]
  GetLatestMessage <Topic> <Node> [ClientIni]
  GetMessages <Topic> <Node> [--after <Id|latest>] [--limit <N>] [--follow] [--interval <Ms>] [--time] [ClientIni]
  GetAttachment <Topic> <Node> <MessageId> <OutFile> [ClientIni]
  Resolve <topic|node> <NameOrId> [ClientIni]
  ListNames [topics|nodes|all] [ClientIni] [--json]
  Query <Sql|@SqlFile> [ClientIni]     e.g. SELECT * FROM messages WHERE topic = 'logs'
  client.ini: [BakaShrot] PrivateKey, PublicKey, Topic, Node (names or
  ids), ServerHost, ServerPort, ServerPublicKey.
Python (3.8+, 64-bit): python\bakashrot.py, no dependencies, uses
  BakaShrot_Client.dll (set BAKASHROT_DLL, or pass dll_path). See its
  docstring, and python\example.py <ClientIni> <Topic> <Node>.
"@
Set-Content -Path (Join-Path $OutDir "VERSION.txt") -Value $VersionText -Encoding UTF8


# --- Test -------------------------------------------------------------------

function New-KeyPair {
    $Lines = & (Join-Path $OutDir "KeyGen.exe")
    if ($LASTEXITCODE -ne 0) { throw "KeyGen failed: $Lines" }
    return @{
        PrivateKey = $Lines[0] -replace "^PrivateKey = ", ""
        PublicKey  = $Lines[1] -replace "^PublicKey = ", ""
    }
}

function Test-Port($Port) {
    $Client = New-Object System.Net.Sockets.TcpClient
    try {
        $Async = $Client.BeginConnect("127.0.0.1", $Port, $null, $null)
        return ($Async.AsyncWaitHandle.WaitOne(200) -and $Client.Connected)
    } catch { return $false }
    finally { $Client.Close() }
}

function Invoke-Tool($Name, [string[]]$Arguments) {
    $Output = & (Join-Path $OutDir $Name) @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$Name failed: $Output" }
    return ($Output -join "`n")
}

if (-not $SkipTest) {
    Write-Host "Testing the build"

    # Inside the release folder: exes run from temp folders get blocked by
    # the antivirus here, and the tools look for the DLL next to themselves.
    $TestDir = Join-Path $OutDir "_test"
    New-Item -ItemType Directory -Force $TestDir | Out-Null
    $Server = $null
    try {
        if (Test-Port $TestPort) { throw "Port $TestPort is already in use, pass -TestPort" }

        $ServerKeys = New-KeyPair
        $ClientKeys = New-KeyPair

        Set-Content -Path (Join-Path $TestDir "server.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($ServerKeys.PrivateKey)
Topic = releasetest
Node = server

[BakaShrot.Topics]
releasetest = 7

[BakaShrot.Nodes]
server = 1
tester = 2

[BakaShrot.Server]
Host = 127.0.0.1
Port = $TestPort
ReplicatingTopics = releasetest
DatabasePath = $(Join-Path $TestDir "test.sqlite")

[BakaShrot.Client.test]
PublicKeys = $($ClientKeys.PublicKey)
Identities = releasetest:tester
AllowRead = 1
AllowWrite = 1
AllowQuery = 1
"@
        Set-Content -Path (Join-Path $TestDir "client.ini") -Encoding Ascii -Value @"
[BakaShrot]
PrivateKey = $($ClientKeys.PrivateKey)
PublicKey = $($ClientKeys.PublicKey)
Topic = releasetest
Node = tester
ServerHost = 127.0.0.1
ServerPort = $TestPort
ServerPublicKey = $($ServerKeys.PublicKey)
"@
        Set-Content -Path (Join-Path $TestDir "message.json") -Encoding Ascii -Value '{"release":"test","value":42}'

        # Its own (hidden) console: without console input, the server stops
        # right away.
        $Server = Start-Process -FilePath (Join-Path $OutDir "BakaShrot_Server.exe") -ArgumentList "`"$(Join-Path $TestDir 'server.ini')`"" `
            -WorkingDirectory $TestDir -WindowStyle Hidden -PassThru
        $Deadline = (Get-Date).AddSeconds(15)
        while (-not (Test-Port $TestPort)) {
            if ($Server.HasExited) { throw "The server exited with code $($Server.ExitCode)" }
            if ((Get-Date) -gt $Deadline) { throw "The server isn't listening on $TestPort" }
            Start-Sleep -Milliseconds 100
        }

        $ClientIni = Join-Path $TestDir "client.ini"
        $Pushed = Invoke-Tool "PushMessage.exe" @("@$(Join-Path $TestDir 'message.json')", $ClientIni)
        if ($Pushed -notmatch "message #1") { throw "Unexpected push answer: $Pushed" }

        $Latest = Invoke-Tool "GetLatestMessage.exe" @("releasetest", "tester", $ClientIni)
        if ($Latest -notmatch '"release"\s*:\s*"test"' -or $Latest -notmatch '\(ids 7:2\)') { throw "Unexpected latest message: $Latest" }

        $Pushed = Invoke-Tool "PushMessage.exe" @("@$(Join-Path $TestDir 'message.json')", $ClientIni)
        if ($Pushed -notmatch "message #2") { throw "Unexpected second push answer: $Pushed" }
        # message.json ends with a line break, kept in the data: one empty line after each.
        $Messages = @(& (Join-Path $OutDir "GetMessages.exe") "releasetest" "tester" $ClientIni | Where-Object { $_ -ne "" })
        if ($LASTEXITCODE -ne 0 -or $Messages.Count -ne 2 -or $Messages[0] -notmatch '^1\t\{"release"' -or $Messages[1] -notmatch '^2\t') {
            throw "Unexpected messages: $($Messages -join ' | ')"
        }

        $Resolved = Invoke-Tool "Resolve.exe" @("topic", "releasetest", $ClientIni)
        if ($Resolved -notmatch "topic releasetest = 7") { throw "Unexpected resolved topic: $Resolved" }

        $Sql = Join-Path $TestDir "query.sql"
        Set-Content -Path $Sql -Encoding Ascii -Value "SELECT message_data ->> '$.value', is_json, topic_id FROM messages WHERE topic = 'releasetest' AND node = 'tester' AND is_json = 1"
        $Queried = Invoke-Tool "Query.exe" @("@$Sql", $ClientIni)
        if ($Queried -notmatch '\[\["42","1","7"\],\["42","1","7"\]\]') { throw "Unexpected query result: $Queried" }

        Write-Host "  Pushed, read back by name, resolved and queried messages: OK"

        $PythonExe = Get-Command python -ErrorAction SilentlyContinue
        if ($PythonExe) {
            $Script = "import sys; sys.path.insert(0, sys.argv[1]); from bakashrot import Client; " +
                      "c = Client.from_ini(sys.argv[2], sys.argv[3]); c.connect(); " +
                      "p = c.get_messages('releasetest', 'tester'); print(len(p), p.messages[0].json()['value'], c.push({'py': 1})); c.close()"
            $PyOut = & $PythonExe.Source -B -c $Script (Join-Path $OutDir "python") $ClientIni (Join-Path $OutDir "BakaShrot_Client.dll") 2>&1
            if ($LASTEXITCODE -ne 0 -or "$PyOut" -ne "2 42 3") { throw "Unexpected Python client output: $PyOut" }
            Write-Host "  Read and pushed with the Python client: OK"
        }
        else {
            Write-Host "  No python on the PATH, the Python client wasn't checked"
        }

        # An attachment of 3 parts and a bit, up and back.
        $Attach = Join-Path $TestDir "attach.bin"
        $Bytes = New-Object byte[] (3 * 1024 * 1024 + 17)
        (New-Object System.Random 5).NextBytes($Bytes)
        [IO.File]::WriteAllBytes($Attach, $Bytes)
        $Pushed = Invoke-Tool "PushMessage.exe" @("-a", $Attach, "@$(Join-Path $TestDir 'message.json')", $ClientIni)
        if ($Pushed -notmatch "message #(\d+), with an attachment of 3145745 bytes") { throw "Unexpected push with an attachment: $Pushed" }
        $AttachedId = $Matches[1]
        $Copy = Join-Path $TestDir "attach-copy.bin"
        $Saved = Invoke-Tool "GetAttachment.exe" @("releasetest", "tester", $AttachedId, $Copy, $ClientIni)
        if ($Saved -notmatch "Saved 3145745 bytes" -or (Get-FileHash $Attach).Hash -ne (Get-FileHash $Copy).Hash) { throw "Unexpected attachment read back: $Saved" }
        Write-Host "  Pushed and read back an attachment: OK"
    }
    finally {
        if ($Server -and -not $Server.HasExited) {
            Stop-Process -Id $Server.Id -Force
            $Server.WaitForExit(5000) | Out-Null
        }
        Remove-Item -Recurse -Force $TestDir -ErrorAction SilentlyContinue
    }
}


# --- Package ----------------------------------------------------------------

if (-not $NoZip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Zip = Join-Path $OutRoot "BakaShrot-$Version.zip"
    if (Test-Path $Zip) { Remove-Item -Force $Zip }
    [IO.Compression.ZipFile]::CreateFromDirectory($OutDir, $Zip, [IO.Compression.CompressionLevel]::Optimal, $true)
    Write-Host "Zip: $Zip"
}

Write-Host ""
Write-Host "Done: $OutDir"
Get-ChildItem $OutDir | Select-Object Name, @{ n = "KB"; e = { [math]::Round($_.Length / 1KB) } } | Format-Table -AutoSize | Out-String | Write-Host
