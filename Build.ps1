# ============================================================================
# BakaShrot build & run script
#
# 0. Extracts libsodium's dynamic build from Libs/libsodium-*-msvc.zip, and
#    sqlite3.dll from the latest Libs/sqlite-dll-win-*.zip, if not done yet.
#    Delete Libs/libsodium/x64 or Libs/sqlite/x64 to extract them again.
# 1. Compiles KeyGen, the server, the client DLL, its example app and the
#    tools (PushMessage, GetLatestMessage, GetMessages, Query, Resolve,
#    ListNames) into ./Build, next to copies of
#    libsodium.dll and sqlite3.dll
# 2. Generates a keypair for two servers and one for a client
# 3. Writes the servers' configs and the client's keys. Topics and nodes
#    have names, and each server its own ids for them, to show names being
#    translated (logs is 1 on server, 200 on server2):
#      server.ini   logs:server1 on port 12345, registers the client, peer
#                   of server2, database ./server.sqlite
#      server2.ini  logs:server2 on port 12346, peer of server, database
#                   ./server2.sqlite
#      client.ini   logs:local through server, for the tools and the example
#                   app, may push to logs and sensors, read every topic, and
#                   run raw queries
#      client2.ini  logs:local2 through server2, same client key, may not query
#    Both servers replicate logs and sensors to each other, e.g.:
#      .\PushMessage.exe -t sensors @msg.json client.ini
#      .\GetLatestMessage.exe sensors local client2.ini
#      .\GetMessages.exe logs local --follow client2.ini
#      .\Resolve.exe topic sensors client2.ini     (201 there, 2 on server)
#      .\Query.exe "SELECT topic, node, message_id FROM messages" client.ini
# 4. Runs the first server, type "quit" or an empty line to stop it, or
#    "restart" / "vacuum" / "help". Run the second one in
#    another terminal to see them link: .\BakaShrot_Server.exe server2.ini
#
# Usage: powershell -ExecutionPolicy Bypass -File Build.ps1 [-Compiler <path>]
#
# Keys are regenerated on every run, ./Build is git-ignored since it holds
# private keys.
# ============================================================================

param(
    [string]$Compiler = "C:\Program Files\PureBasic_573\Compilers\pbcompiler.exe"
)

$ErrorActionPreference = "Stop"

$Root   = $PSScriptRoot
$Output = Join-Path $Root "Build"

# Where Commons/Cryptography/Libsodium.pbi imports it from, x64 since the
# compiler above is the x64 one.
$SodiumDir = Join-Path $Root "Libs\libsodium\x64"

# Where sqlite3.dll is extracted to, the server loads it instead of the
# SQLite bundled with PureBasic 5.73, which lacks the JSON functions.
$SqliteDir = Join-Path $Root "Libs\sqlite\x64"

$ServerHost      = "127.0.0.1"
$ServerPort      = 12345
$Server2Port     = 12346
$PeerRetryDelay  = 10
$PeerBatchSize   = 100

# The same names on both servers, different ids, see the top of this file.
# Same client, through server2 as its own node (local2), so no topic/node is
# ever written to on both servers.
$Topics  = @{ logs = 1; sensors = 2 }
$Nodes   = @{ server1 = 1; local = 2; server2 = 3; local2 = 4 }
$Topics2 = @{ logs = 200; sensors = 201 }
$Nodes2  = @{ server1 = 11; local = 12; server2 = 13; local2 = 14 }

function Format-Names($Names) {
    ($Names.GetEnumerator() | Sort-Object Value | ForEach-Object { "$($_.Key) = $($_.Value)" }) -join "`r`n"
}

function Expand-Libsodium {
    $Zip = Get-ChildItem (Join-Path $Root "Libs") -Filter "libsodium-*-msvc.zip" | Select-Object -First 1
    if (-not $Zip) {
        throw "Missing Libs\libsodium-*-msvc.zip, get it from https://download.libsodium.org/libsodium/releases/"
    }

    Write-Host "Extracting libsodium from $($Zip.Name)"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $Archive = [IO.Compression.ZipFile]::OpenRead($Zip.FullName)
    try {
        # Zip folder -> Libs\libsodium folder
        $Targets = @{ "x64" = "x64"; "Win32" = "x86" }
        foreach ($Arch in $Targets.Keys) {
            $Destination = Join-Path $Root "Libs\libsodium\$($Targets[$Arch])"
            New-Item -ItemType Directory -Force $Destination | Out-Null
            foreach ($Name in @("libsodium.dll", "libsodium.lib")) {
                $Entry = $Archive.GetEntry("libsodium/$Arch/Release/v143/dynamic/$Name")
                if (-not $Entry) {
                    throw "$($Zip.Name) has no $Arch dynamic $Name"
                }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, (Join-Path $Destination $Name), $true)
            }
        }
    }
    finally {
        $Archive.Dispose()
    }
}

function Expand-Sqlite {
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    foreach ($Arch in @("x64", "x86")) {
        # The version in the name is zero-padded, so the last one by name is the latest.
        $Zip = Get-ChildItem (Join-Path $Root "Libs") -Filter "sqlite-dll-win-$Arch-*.zip" | Sort-Object Name | Select-Object -Last 1
        if (-not $Zip) {
            throw "Missing Libs\sqlite-dll-win-$Arch-*.zip, get it from https://www.sqlite.org/download.html"
        }

        Write-Host "Extracting SQLite from $($Zip.Name)"
        $Destination = Join-Path $Root "Libs\sqlite\$Arch"
        New-Item -ItemType Directory -Force $Destination | Out-Null

        $Archive = [IO.Compression.ZipFile]::OpenRead($Zip.FullName)
        try {
            $Entry = $Archive.GetEntry("sqlite3.dll")
            if (-not $Entry) {
                throw "$($Zip.Name) has no sqlite3.dll"
            }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, (Join-Path $Destination "sqlite3.dll"), $true)
        }
        finally {
            $Archive.Dispose()
        }
    }
}

function Invoke-Compiler($Source, $Executable, $Flags) {
    Write-Host "Compiling $Source"
    & $Compiler (Join-Path $Root $Source) @Flags /QUIET /EXE (Join-Path $Output $Executable)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to compile $Source"
    }
}

function New-KeyPair {
    # KeyGen prints "PrivateKey = ..." then "PublicKey = ...".
    $Lines = & (Join-Path $Output "KeyGen.exe")
    if ($LASTEXITCODE -ne 0) {
        throw "KeyGen failed: $Lines"
    }
    return @{
        PrivateKey = $Lines[0] -replace "^PrivateKey = ", ""
        PublicKey  = $Lines[1] -replace "^PublicKey = ", ""
    }
}


Push-Location $Root
try {
    New-Item -ItemType Directory -Force $Output | Out-Null

    # 0. libsodium
    if (-not (Test-Path (Join-Path $SodiumDir "libsodium.lib"))) {
        Expand-Libsodium
    }
    Copy-Item (Join-Path $SodiumDir "libsodium.dll") $Output -Force

    # 0. SQLite
    if (-not (Test-Path (Join-Path $SqliteDir "sqlite3.dll"))) {
        Expand-Sqlite
    }
    Copy-Item (Join-Path $SqliteDir "sqlite3.dll") $Output -Force

    # 1. Compile
    Invoke-Compiler "Tools\KeyGen\KeyGen.pb"        "KeyGen.exe"            @("/CONSOLE")
    Invoke-Compiler "Server\BakaShrot_Server.pb"    "BakaShrot_Server.exe"  @("/CONSOLE", "/THREAD")
    Invoke-Compiler "Client\BakaShrot_Client.pbi"   "BakaShrot_Client.dll"  @("/DLL", "/THREAD")
    # Example app using the DLL, run it from ./Build while the server runs.
    Invoke-Compiler "Client\BakaShrot_Client_Prototypes.pbi" "ClientExample.exe" @("/CONSOLE")
    # Tools using the DLL, same as the example:
    #   PushMessage [-t <Topic>] [-a <File>] <Json|@JsonFile> [ClientIni]
    #   GetLatestMessage <Topic> <Node> [ClientIni]
    Invoke-Compiler "Tools\PushMessage\PushMessage.pb"           "PushMessage.exe"       @("/CONSOLE")
    Invoke-Compiler "Tools\GetLatestMessage\GetLatestMessage.pb" "GetLatestMessage.exe"  @("/CONSOLE")
    #   GetMessages <Topic> <Node> [--after <Id|latest>] [--limit <N>] [--follow] [ClientIni]
    Invoke-Compiler "Tools\GetMessages\GetMessages.pb"           "GetMessages.exe"       @("/CONSOLE")
    #   GetAttachment <Topic> <Node> <MessageId> <OutFile> [ClientIni]
    Invoke-Compiler "Tools\GetAttachment\GetAttachment.pb"       "GetAttachment.exe"     @("/CONSOLE")
    #   Query <Sql|@SqlFile> [ClientIni]
    Invoke-Compiler "Tools\Query\Query.pb"                       "Query.exe"             @("/CONSOLE")
    #   Resolve <topic|node> <NameOrId> [ClientIni]
    Invoke-Compiler "Tools\Resolve\Resolve.pb"                   "Resolve.exe"           @("/CONSOLE")
    #   ListNames [topics|nodes|all] [ClientIni] [--json]
    Invoke-Compiler "Tools\ListNames\ListNames.pb"               "ListNames.exe"         @("/CONSOLE")

    # 2. Keys
    Write-Host "Generating keys"
    $ServerKeys  = New-KeyPair
    $Server2Keys = New-KeyPair
    $ClientKeys  = New-KeyPair

    # 3. Configs
    # Both servers are each other's peer, and register each other as a client
    # so the links can authenticate.
    $ServerConfig = @"
[BakaShrot]
PrivateKey = $($ServerKeys.PrivateKey)
Topic = logs
Node = server1

; This server's ids for the names every server shares.
[BakaShrot.Topics]
$(Format-Names $Topics)

[BakaShrot.Nodes]
$(Format-Names $Nodes)

[BakaShrot.Server]
Host = $ServerHost
Port = $ServerPort
ReplicatingTopics = logs;sensors
NetThreadPoolSize = 4
DatabasePath = ./server.sqlite
PeerRetryDelay = $PeerRetryDelay
PeerBatchSize = $PeerBatchSize

[BakaShrot.Peer.server2]
Host = $ServerHost
Port = $Server2Port
Topic = logs
Node = server2
PublicKey = $($Server2Keys.PublicKey)

[BakaShrot.Client.local]
PublicKeys = $($ClientKeys.PublicKey)
Identities = logs:local
PushTopics = logs;sensors
ReadTopics = *
AllowRead = 1
AllowWrite = 1
AllowQuery = 1

; The peer only replicates, it has no business reading or writing as a client.
[BakaShrot.Client.server2]
PublicKeys = $($Server2Keys.PublicKey)
Identities = logs:server2
AllowRead = 0
AllowWrite = 0
AllowQuery = 0
"@
    Set-Content -Path (Join-Path $Output "server.ini") -Value $ServerConfig -Encoding Ascii

    $Server2Config = @"
[BakaShrot]
PrivateKey = $($Server2Keys.PrivateKey)
Topic = logs
Node = server2

; Other ids than server's, same names: replication goes by name.
[BakaShrot.Topics]
$(Format-Names $Topics2)

[BakaShrot.Nodes]
$(Format-Names $Nodes2)

[BakaShrot.Server]
Host = $ServerHost
Port = $Server2Port
ReplicatingTopics = logs;sensors
NetThreadPoolSize = 4
DatabasePath = ./server2.sqlite
PeerRetryDelay = $PeerRetryDelay
PeerBatchSize = $PeerBatchSize

[BakaShrot.Peer.server]
Host = $ServerHost
Port = $ServerPort
Topic = logs
Node = server1
PublicKey = $($ServerKeys.PublicKey)

; The peer only replicates, it has no business reading or writing as a client.
[BakaShrot.Client.server]
PublicKeys = $($ServerKeys.PublicKey)
Identities = logs:server1
AllowRead = 0
AllowWrite = 0
AllowQuery = 0

; No raw queries through this server.
[BakaShrot.Client.local]
PublicKeys = $($ClientKeys.PublicKey)
Identities = logs:local2
PushTopics = logs;sensors
ReadTopics = *
AllowRead = 1
AllowWrite = 1
AllowQuery = 0
"@
    Set-Content -Path (Join-Path $Output "server2.ini") -Value $Server2Config -Encoding Ascii

    $Client2Config = @"
[BakaShrot]
PrivateKey = $($ClientKeys.PrivateKey)
PublicKey = $($ClientKeys.PublicKey)
Topic = logs
Node = local2
ServerHost = $ServerHost
ServerPort = $Server2Port
ServerPublicKey = $($Server2Keys.PublicKey)
"@
    Set-Content -Path (Join-Path $Output "client2.ini") -Value $Client2Config -Encoding Ascii

    # Read by ClientExample.exe.
    $ClientConfig = @"
[BakaShrot]
PrivateKey = $($ClientKeys.PrivateKey)
PublicKey = $($ClientKeys.PublicKey)
Topic = logs
Node = local
ServerHost = $ServerHost
ServerPort = $ServerPort
ServerPublicKey = $($ServerKeys.PublicKey)
"@
    Set-Content -Path (Join-Path $Output "client.ini") -Value $ClientConfig -Encoding Ascii

    Write-Host "Wrote Build\server.ini, Build\server2.ini, Build\client.ini and Build\client2.ini"

    # 4. Run, from ./Build so ./test.sqlite ends up there too.
    Write-Host "Start the second server in another terminal to see them link:"
    Write-Host "  cd Build; .\BakaShrot_Server.exe server2.ini"
    Push-Location $Output
    try {
        & ".\BakaShrot_Server.exe" "server.ini"
    }
    finally {
        Pop-Location
    }
}
finally {
    Pop-Location
}
