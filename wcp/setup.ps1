# setup.ps1 - installs wcp on Windows, no bash or WSL required.
#
# Installs wcp.ps1 and a wcp.cmd launcher (so plain 'wcp' works from cmd.exe
# or PowerShell) into %USERPROFILE%\bin, then offers to add that folder to
# your user PATH.
#
# USAGE:
#   powershell -ExecutionPolicy Bypass -File setup.ps1
#
# Keep this file pure ASCII: PowerShell 5.1 reads a BOM-less file as CP1252,
# where a stray UTF-8 byte becomes a quote and breaks parsing.

$ErrorActionPreference = 'Stop'

# Report a missing required tool and stop, unless the user insists.
function Confirm-Missing([string]$Tool, [string[]]$Advice) {
    Write-Output ($Tool + ' was not found, and wcp requires it.')
    foreach ($line in $Advice) { Write-Output $line }
    Write-Output 'Reopen your terminal afterwards so PATH picks it up.'
    Write-Output ''
    $reply = ''
    if ([Environment]::UserInteractive) {
        $reply = Read-Host 'Install wcp anyway? [y/N]'
    }
    if ($reply -notmatch '^[Yy]') {
        Write-Output ('Stopped. Install ' + $Tool + ', then rerun this script.')
        exit 1
    }
    Write-Output ''
}

$srcDir = $PSScriptRoot
if (-not $srcDir) {
    $srcDir = (Get-Location).Path
}
$binDir = Join-Path $env:USERPROFILE 'bin'

Write-Output 'Detected: windows (native PowerShell)'
Write-Output ''

# curl.exe drives every transfer.
$curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
if (-not $curlCmd) {
    Confirm-Missing 'curl.exe' @(
        'It ships with Windows 10 (1803+) and Windows 11, so a miss usually',
        'means an older Windows or a trimmed PATH. Either put',
        'C:\Windows\System32 back on PATH, or install curl with one of:',
        '  winget install cURL.cURL',
        '  choco install curl',
        'Git for Windows also ships one at:',
        '  C:\Program Files\Git\mingw64\bin\curl.exe'
    )
}

# openssl does all encryption, and encryption is not optional.
$sslPath = $null
$sslCmd = Get-Command openssl.exe -ErrorAction SilentlyContinue
if ($sslCmd) {
    $sslPath = $sslCmd.Source
} else {
    $sslGuesses = @(
        (Join-Path $env:ProgramFiles 'OpenSSL-Win64\bin\openssl.exe'),
        (Join-Path $env:ProgramFiles 'OpenSSL\bin\openssl.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'OpenSSL-Win32\bin\openssl.exe'),
        (Join-Path $env:ProgramFiles 'Git\usr\bin\openssl.exe')
    )
    foreach ($g in $sslGuesses) {
        if ($g -and (Test-Path -LiteralPath $g) -and -not $sslPath) { $sslPath = $g }
    }
}

if ($sslPath) {
    Write-Output 'Found openssl.'
    Write-Output ''
} else {
    Confirm-Missing 'openssl' @(
        'Install with one of:',
        '  winget install ShiningLight.OpenSSL.Light',
        '  choco install openssl',
        'Git for Windows also ships one at:',
        '  C:\Program Files\Git\usr\bin\openssl.exe'
    )
}

$srcPs1 = Join-Path $srcDir 'wcp.ps1'
if (-not (Test-Path -LiteralPath $srcPs1)) {
    Write-Output ('ERROR: no wcp.ps1 next to this script. Looked in: ' + $srcDir)
    exit 1
}

New-Item -ItemType Directory -Force -Path $binDir | Out-Null

$dstPs1 = Join-Path $binDir 'wcp.ps1'
Copy-Item -LiteralPath $srcPs1 -Destination $dstPs1 -Force
Write-Output ('Installed: ' + $dstPs1)

# Install tests.md alongside wcp.
$srcTests = Join-Path $srcDir 'tests.md'
if (Test-Path -LiteralPath $srcTests) {
    $dstTests = Join-Path $binDir 'tests.md'
    Copy-Item -LiteralPath $srcTests -Destination $dstTests -Force
    Write-Output ('Installed: ' + $dstTests)
}

# Launcher so 'wcp' works without typing .ps1.
$dstCmd = Join-Path $binDir 'wcp.cmd'
$cmdLines = @(
    '@echo off',
    'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wcp.ps1" %*'
)
Set-Content -LiteralPath $dstCmd -Value $cmdLines -Encoding ASCII
Write-Output ('Installed: ' + $dstCmd)
Write-Output ''

# Read the User-scoped PATH, not the combined $env:Path.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($null -eq $userPath) {
    $userPath = ''
}

$target = $binDir.TrimEnd('\')

$already = $false
foreach ($entry in $userPath.Split(';')) {
    if ($entry.TrimEnd('\') -ieq $target) {
        $already = $true
    }
}

# The persisted PATH and this session's PATH are independent.
$inSession = $false
$sessionPath = $env:Path
if ($null -eq $sessionPath) {
    $sessionPath = ''
}
foreach ($entry in $sessionPath.Split(';')) {
    if ($entry.TrimEnd('\') -ieq $target) {
        $inSession = $true
    }
}

$getUser = '[Environment]::GetEnvironmentVariable(''Path'',''User'')'
$getMach = '[Environment]::GetEnvironmentVariable(''Path'',''Machine'')'

# Line the user pastes to refresh PATH in the current session.
$refresh = '  $env:Path = ' + $getMach + ' + '';'' + ' + $getUser

$undo1 = '  $p = ' + $getUser
$undoFilter = '  $p = ($p.Split('';'') | Where-Object { $_ -ne '''
$undo2 = $undoFilter + $binDir + ''' }) -join '';'''
$undo3 = '  [Environment]::SetEnvironmentVariable(''Path'', $p, ''User'')'

if ($already) {
    if (-not $inSession) {
        Write-Output 'This terminal has not picked up the PATH change. Either paste:'
        Write-Output $refresh
        Write-Output 'or open a new terminal.'
        Write-Output ''
    }
} else {
    Write-Output ('NOTE: ' + $binDir + ' is not in your user PATH.')

    $reply = ''
    if ([Environment]::UserInteractive) {
        $reply = Read-Host 'Add it to your user PATH automatically? [y/N]'
    } else {
        Write-Output 'Not running interactively, so PATH was not modified.'
    }

    if ($reply -match '^[Yy]') {
        $newPath = $binDir
        if ($userPath -ne '') {
            $newPath = $userPath + ';' + $binDir
        }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Output 'Added to your user PATH.'
        Write-Output ''
        # Refresh this process; it cannot reach the parent shell.
        $machPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $usrPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:Path = $machPath + ';' + $usrPath
        Write-Output 'To use wcp in THIS terminal without reopening it, paste:'
        Write-Output $refresh
        Write-Output ''
        Write-Output '(Or just open a new terminal. Running this script as'
        Write-Output ' . .\setup.ps1  would have refreshed the session directly.)'
        Write-Output ''
        Write-Output 'To undo that later:'
        Write-Output $undo1
        Write-Output $undo2
        Write-Output $undo3
    } else {
        Write-Output 'Skipped. Add it yourself when you want it:'
        Write-Output $undo1
        $addHint = '  [Environment]::SetEnvironmentVariable(''Path'', $p + '';'
        Write-Output ($addHint + $binDir + ''', ''User'')')
        Write-Output ''
        Write-Output ('Or run wcp by full path: ' + $dstCmd)
    }
}

Write-Output ''
Write-Output 'Done. Test with:'
Write-Output '  wcp hello world'
