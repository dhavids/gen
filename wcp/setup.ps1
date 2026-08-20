# setup.ps1 — installs wcp on Windows, no bash or WSL required.
#
# Installs wcp.ps1 and a wcp.cmd launcher (so plain `wcp` works from cmd.exe,
# PowerShell, or anywhere else) into %USERPROFILE%\bin, then offers to add
# that folder to your user PATH.
#
# USAGE:
#   powershell -ExecutionPolicy Bypass -File setup.ps1
#
# To uninstall: delete %USERPROFILE%\bin\wcp.ps1 and wcp.cmd, and remove that
# folder from your user PATH (see the command printed at the end).

$ErrorActionPreference = "Stop"

$srcDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$binDir = Join-Path $env:USERPROFILE "bin"

Write-Output "Detected: windows (native PowerShell)"
Write-Output ""

# curl.exe ships with Windows 10 1803+ and 11. wcp cannot work without it.
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Write-Output "WARNING: curl.exe was not found on PATH."
    Write-Output "         wcp needs it. It ships with Windows 10 (1803+) and Windows 11."
    Write-Output ""
}

$srcPs1 = Join-Path $srcDir "wcp.ps1"
if (-not (Test-Path -LiteralPath $srcPs1)) {
    Write-Error "wcp: cannot find wcp.ps1 next to this script (looked in $srcDir)"
    exit 1
}

New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Copy-Item -LiteralPath $srcPs1 -Destination (Join-Path $binDir "wcp.ps1") -Force
Write-Output "Installed: $(Join-Path $binDir 'wcp.ps1')"

# Thin launcher so `wcp` works without typing .ps1, and without needing the
# execution policy relaxed — -ExecutionPolicy Bypass applies per invocation.
$cmdBody = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wcp.ps1" %*
'@
Set-Content -LiteralPath (Join-Path $binDir "wcp.cmd") -Value $cmdBody -Encoding ASCII
Write-Output "Installed: $(Join-Path $binDir 'wcp.cmd')  (lets you just type 'wcp')"
Write-Output ""

# Read the USER-scoped PATH only. Using $env:Path here would be a bug: that is
# the combined machine+user value, and writing it back into the user scope
# duplicates the whole system PATH into your user variable permanently.
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($null -eq $userPath) { $userPath = "" }

$already = $userPath.Split(';') | Where-Object { $_.TrimEnd('\') -ieq $binDir.TrimEnd('\') }

if ($already) {
    Write-Output "$binDir is already in your user PATH — you can run 'wcp' directly."
} else {
    Write-Output "NOTE: $binDir is not in your user PATH."

    $reply = ""
    if ([Environment]::UserInteractive) {
        $reply = Read-Host "Add it to your user PATH automatically? [y/N]"
    } else {
        Write-Output "Not running interactively, so PATH was not modified."
    }

    if ($reply -match '^[Yy]') {
        $newPath = if ($userPath -eq "") { $binDir } else { "$userPath;$binDir" }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Output "Added to your user PATH. Open a new terminal for it to take effect."
        Write-Output ""
        Write-Output "To undo that later:"
        Write-Output "  `$p = [Environment]::GetEnvironmentVariable('Path','User')"
        Write-Output "  `$p = (`$p.Split(';') | Where-Object { `$_ -ne '$binDir' }) -join ';'"
        Write-Output "  [Environment]::SetEnvironmentVariable('Path', `$p, 'User')"
    } else {
        Write-Output "Skipped. Add it yourself when you want it:"
        Write-Output "  `$p = [Environment]::GetEnvironmentVariable('Path','User')"
        Write-Output "  [Environment]::SetEnvironmentVariable('Path', `"`$p;$binDir`", 'User')"
        Write-Output ""
        Write-Output "Or run wcp by full path: $(Join-Path $binDir 'wcp.cmd')"
    }
}

Write-Output ""
Write-Output "Done. Test with:"
Write-Output "  wcp hello world"
Write-Output ""
Write-Output "Note: this PowerShell build does not implement encryption."
Write-Output "litterbox (the default backend) is plain, so normal use works."
Write-Output "For catbox, pass --plain. Encrypted codes cannot be retrieved here."
