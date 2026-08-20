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

$srcPs1 = Join-Path $srcDir 'wcp.ps1'
if (-not (Test-Path -LiteralPath $srcPs1)) {
    Write-Output ('ERROR: cannot find wcp.ps1 next to this script (looked in ' + $srcDir + ')')
    exit 1
}

New-Item -ItemType Directory -Force -Path $binDir | Out-Null

$dstPs1 = Join-Path $binDir 'wcp.ps1'
Copy-Item -LiteralPath $srcPs1 -Destination $dstPs1 -Force
Write-Output ('Installed: ' + $dstPs1)

# Thin launcher so 'wcp' works without typing .ps1, and without relaxing the
# execution policy globally - Bypass applies only to that invocation.
$dstCmd = Join-Path $binDir 'wcp.cmd'
$cmdLines = @(
    '@echo off',
    'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wcp.ps1" %*'
)
Set-Content -LiteralPath $dstCmd -Value $cmdLines -Encoding ASCII
Write-Output ('Installed: ' + $dstCmd + '  (lets you just type wcp)')
Write-Output ''

# Read the USER-scoped PATH only. Using $env:Path here would be a bug: that is
# the combined machine+user value, and writing it back into the user scope
# permanently duplicates the whole system PATH into your user variable.
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

$undo1 = '  $p = [Environment]::GetEnvironmentVariable(''Path'',''User'')'
$undo2 = '  $p = ($p.Split('';'') | Where-Object { $_ -ne ''' + $binDir + ''' }) -join '';'''
$undo3 = '  [Environment]::SetEnvironmentVariable(''Path'', $p, ''User'')'

if ($already) {
    Write-Output ($binDir + ' is already in your user PATH - you can run wcp directly.')
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
        Write-Output 'Added to your user PATH. Open a new terminal for it to take effect.'
        Write-Output ''
        Write-Output 'To undo that later:'
        Write-Output $undo1
        Write-Output $undo2
        Write-Output $undo3
    } else {
        Write-Output 'Skipped. Add it yourself when you want it:'
        Write-Output $undo1
        Write-Output ('  [Environment]::SetEnvironmentVariable(''Path'', $p + '';' + $binDir + ''', ''User'')')
        Write-Output ''
        Write-Output ('Or run wcp by full path: ' + $dstCmd)
    }
}

Write-Output ''
Write-Output 'Done. Test with:'
Write-Output '  wcp hello world'
Write-Output ''
Write-Output 'Note: this PowerShell build does not implement encryption.'
Write-Output 'litterbox (the default backend) is plain, so normal use works.'
Write-Output 'For catbox, pass --plain. Encrypted codes cannot be retrieved here.'
