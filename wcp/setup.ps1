# setup.ps1 - installs wcp on Windows, no bash or WSL required.
#
# Installs wcp.ps1 and a wcp.cmd launcher (so plain 'wcp' works from cmd.exe
# or PowerShell) into %USERPROFILE%\bin, then offers to add that folder to
# your user PATH.
#
# USAGE:
#   powershell -ExecutionPolicy Bypass -File setup.ps1
#
# Deliberately plain style: no assignment-from-if, no backtick escapes, and
# literal text in single quotes. Those constructs parse differently across
# PowerShell versions and this script has to run on whatever is installed.

$ErrorActionPreference = 'Stop'

$srcDir = $PSScriptRoot
if (-not $srcDir) {
    $srcDir = (Get-Location).Path
}
$binDir = Join-Path $env:USERPROFILE 'bin'

Write-Output 'Detected: windows (native PowerShell)'
Write-Output ''

# curl.exe ships with Windows 10 1803+ and Windows 11. wcp cannot work without it.
$curlCmd = Get-Command curl.exe -ErrorAction SilentlyContinue
if (-not $curlCmd) {
    Write-Output 'WARNING: curl.exe was not found on PATH.'
    Write-Output '         wcp needs it. It ships with Windows 10 (1803+) and Windows 11.'
    Write-Output ''
}

# Encryption needs openssl; without it wcp still works for plain uploads.
$sslCmd = Get-Command openssl.exe -ErrorAction SilentlyContinue
if (-not $sslCmd) {
    Write-Output 'NOTE: openssl.exe was not found on PATH.'
    Write-Output '      wcp works without it, but -e and catbox uploads need it.'
    Write-Output '      Install with one of:'
    Write-Output '        winget install ShiningLight.OpenSSL.Light'
    Write-Output '        choco install openssl'
    Write-Output '      Git for Windows also ships one in C:\Program Files\Git\usr\bin.'
    Write-Output ''
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

# Launcher so 'wcp' works without typing .ps1.
$dstCmd = Join-Path $binDir 'wcp.cmd'
$cmdLines = @(
    '@echo off',
    'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wcp.ps1" %*'
)
Set-Content -LiteralPath $dstCmd -Value $cmdLines -Encoding ASCII
Write-Output ('Installed: ' + $dstCmd + '  (lets you just type wcp)')
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
    Write-Output ($binDir + ' is already in your user PATH.')
    if ($inSession) {
        Write-Output 'You can run wcp directly.'
    } else {
        Write-Output 'This terminal has not picked it up yet. Either paste:'
        Write-Output $refresh
        Write-Output 'or open a new terminal.'
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
Write-Output ''
Write-Output 'Encryption uses openssl and is interchangeable with the bash build.'
