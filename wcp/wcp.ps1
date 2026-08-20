# wcp.ps1 - minimal upload wrapper with a compact roundtrip code, for Windows.
#
# USAGE:
#   wcp path\to\file.txt        # upload -> prints a short code, e.g. "brbkswy"
#   wcp some words here         # not a file -> uploaded as text, prints a code
#   Get-Content file.txt | wcp  # no args -> reads stdin, prints a code
#   wcp brbkswy                 # retrieve (implicit): may fall back to uploading
#   wcp . brbkswy               # retrieve (explicit): errors instead of falling back
#   wcp . <full-url>            # retrieve by URL instead of a code
#   wcp . brbkswy -o out.txt    # ...saved under a name you choose
#
# Retrieved text prints to stdout; retrieved files are saved into the current
# folder. Existing files are never overwritten - _1, _2 are appended and the
# name actually used is printed. Encrypted files restore their original name.
#
# The first character of the printed code encodes BOTH the backend and the
# file extension. Lowercase a-o = litterbox, uppercase A-O = catbox.
# Digits 0/1 mean the extension is not in the built-in table (the literal
# .ext follows the prefix). A typical code is 7 characters long.
# Letters p-z, P-Z and digits 2-9 are reserved for a future third backend.
#
# -b / --backend and --host work for both directions: on upload they choose
# which service and endpoint is used; on retrieval, --host overrides the
# default fetch host for the decoded backend.
#
# -t [hours] takes a whole number of hours and rounds UP to the nearest of
# 1h, 12h, 24h, 72h (litterbox only; catbox never expires). Max 72h.
#
# Env vars: $env:WCP_BACKEND (default: catbox), $env:WCP_TIME (whole hours, default 1)
#
# Collision handling: a candidate of 7 chars or fewer that looks like a code is
# tried as a retrieval first; if that 404s it falls back to uploading it as
# text. Longer candidates are only tried if they contain a . or a - (escape and
# escape-path codes carry a dot, encrypted codes a dash), so an ordinary long
# word is uploaded straight away with no wasted request.
#
# With a key stored (--set-key), every upload is encrypted with it and the
# code stays 7 characters, because the key never travels; -z opts out.
# With no stored key: catbox is encrypted with a random per-upload key that
# rides in the code, litterbox is plain because it expires within hours.
# -e / --encrypt forces it on; --plain / -p and WCP_PLAIN=1 force it off.
# Encrypted codes use a 12-char alphanumeric key: CODE-KEY (~20 chars total).
# The KEY is NEVER uploaded - only the ciphertext goes to the server.
# Losing the KEY loses the data permanently.
#   wcp -b c hello world -> B0ojyr4-AbCdEfGhIjKl
# curl.exe and openssl are both required.
# Files up to 1 MB are encrypted, any type; -f raises that to 100 MB.
#
# -l prints the full URL instead of the code; with -e the key follows on a
# second line and only the URL is copied. Retrieve with: wcp . <url> <key>
#
# -a appends stdin, argument text or the clipboard to a local buffer, -s
# uploads it, --clear empties it. Entries are separated by two blank lines.
# A piped entry gets no command label: a PowerShell pipeline passes objects
# inside one process, so there is no writer process to name.
#
# Short aliases: -b backend, -c copy, -e encrypt, -f force, -l link,
# -p plain, -t time.
#
# Keep this file pure ASCII: PowerShell 5.1 reads a BOM-less file as CP1252,
# where a stray UTF-8 byte becomes a quote and breaks parsing.

$ErrorActionPreference = "Stop"

# Capture pipeline input now; $input is only live at script entry.
$PipelineInput = @($input)

# Sync .NET's cwd with PowerShell's for relative paths discovery
[System.IO.Directory]::SetCurrentDirectory($PWD.Path)

# A piped-to .ps1 gets objects in $input; a piped-to .cmd gets real stdin.
function Read-PipedInput {
    if ($PipelineInput.Count -gt 0) {
        return ($PipelineInput -join [Environment]::NewLine)
    }
    return [Console]::In.ReadToEnd()
}

# Write to stderr without Write-Error's error record or its throw.
function Warn([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

$DefaultUploadHostCatbox = "https://catbox.moe/user/api.php"
$DefaultFetchHostCatbox = "https://files.catbox.moe"
$DefaultUploadHostLitterbox = "https://litterbox.catbox.moe/resources/internals/api.php"
$DefaultFetchHostLitterbox = "https://litter.catbox.moe"
$DefaultLitterboxTime = "1h"

# Extension table: index 0 = no extension, 1..14 = common extensions.
$ExtTable = @("", "txt", "md", "log", "json", "yaml", "csv", "conf",
              "sh", "py", "png", "jpg", "pdf", "zip", "gz")

function Get-ExtIndex([string]$Ext) {
    for ($i = 0; $i -lt $ExtTable.Count; $i++) {
        if ($ExtTable[$i] -eq $Ext) { return $i }
    }
    return -1
}

function Encode-Id([string]$IdFull, [string]$Backend) {
    if ($IdFull -match '\.') {
        $dotIdx = $IdFull.LastIndexOf('.')
        $ext = $IdFull.Substring($dotIdx + 1)
        $idBase = $IdFull.Substring(0, $dotIdx)
    } else {
        $ext = ""
        $idBase = $IdFull
    }

    $idx = Get-ExtIndex $ext
    if ($idx -ge 0) {
        if ($Backend -eq "catbox") {
            $prefix = [char](65 + $idx)
        } else {
            $prefix = [char](97 + $idx)
        }
        return "${prefix}${idBase}"
    } else {
        if ($Backend -eq "catbox") {
            return "1${idBase}.${ext}"
        } else {
            return "0${idBase}.${ext}"
        }
    }
}

function Decode-Code([string]$Candidate) {
    $letter = $Candidate.Substring(0, 1)
    $rest = $Candidate.Substring(1)

    # Digit prefix: unlisted extension
    if ($letter -eq "0" -or $letter -eq "1") {
        $script:DecodeBackend = if ($letter -eq "0") { "litterbox" } else { "catbox" }
        $script:DecodeId = $rest
        $script:DecodeFetchHost = ""
        return $true
    }

    # Alphabetic prefix
    if ($letter -cmatch '^[a-z]$') {
        $script:DecodeBackend = "litterbox"
        $idx = [int][char]$letter - 97
    } elseif ($letter -cmatch '^[A-Z]$') {
        $script:DecodeBackend = "catbox"
        $idx = [int][char]$letter - 65
    } else {
        return $false
    }

    if ($idx -lt 0 -or $idx -ge $ExtTable.Count) { return $false }

    $ext = $ExtTable[$idx]
    if ([string]::IsNullOrEmpty($ext)) {
        $script:DecodeId = $rest
    } else {
        $script:DecodeId = "${rest}.${ext}"
    }
    $script:DecodeFetchHost = ""
    return $true
}

function Convert-LitterboxTimeBucket([string]$Hours) {
    $h = $Hours -replace 'h$', ''
    if ($h -notmatch '^\d+$' -or [int]$h -lt 1) {
        Warn "wcp: -t takes a whole number of hours, 1 to 72"
        exit 1
    }
    $h = [int]$h
    if    ($h -le 1)  { return "1h" }
    elseif ($h -le 12) { return "12h" }
    elseif ($h -le 24) { return "24h" }
    elseif ($h -le 72) { return "72h" }
    else {
        Warn "wcp: -t max is 72 hours (litterbox allows 1, 12, 24, 72)"
        exit 1
    }
}

function Get-IdFromUrl([string]$Url) {
    $noScheme = $Url -replace '^https?://', ''
    $slashIndex = $noScheme.IndexOf('/')
    if ($slashIndex -lt 0) { return "" }
    return $noScheme.Substring($slashIndex + 1)
}

# Pick a name that does not already exist, inserting _1, _2 before the extension.
function Get-UniqueSaveName([string]$Name) {
    if (-not (Test-Path -LiteralPath $Name)) { return $Name }
    $dir = Split-Path -Parent $Name
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $ext = [System.IO.Path]::GetExtension($Name)
    $n = 1
    while ($true) {
        $leaf = "$base" + "_" + "$n" + "$ext"
        $cand = if ($dir) { Join-Path $dir $leaf } else { $leaf }
        if (-not (Test-Path -LiteralPath $cand)) { return $cand }
        $n += 1
    }
}

function HumanSize([long]$Bytes) {
    if ($Bytes -ge 1048576) { return "$($Bytes / 1048576) MB" }
    if ($Bytes -ge 1024) { return "$(([math]::Round(($Bytes + 512) / 1024))) KB" }
    return "$Bytes B"
}

function Read-StoredKey {
    if (-not (Test-Path -LiteralPath $KeyPath)) { return "" }
    $k = Get-Content -LiteralPath $KeyPath -TotalCount 1
    if ($null -eq $k) { return "" }
    return $k.Trim()
}

function Write-StoredKey([string]$Key) {
    if ($Key.Length -lt $MinStoredKey) {
        Warn "wcp: a stored key needs at least $MinStoredKey characters"
        Warn "wcp: run --set-key with no value to generate one"
        return $false
    }
    if ($Key -notmatch '^[A-Za-z0-9]+$') {
        Warn "wcp: a stored key may only contain letters and digits"
        return $false
    }
    $dir = Split-Path -Parent $KeyPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $enc = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($KeyPath, $Key, $enc)
    # Windows has no chmod, so drop inherited rights and grant only this user.
    $acl = Get-Acl -LiteralPath $KeyPath
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($r in @($acl.Access)) { $acl.RemoveAccessRule($r) | Out-Null }
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $me, "FullControl", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $KeyPath -AclObject $acl
    return $true
}

# True when a body is base64 ciphertext we produced.
function Test-Encrypted([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 10) { return $false }
    $head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 10)
    if ($head -ne "U2FsdGVkX1") { return $false }
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    return ($text -match '^[A-Za-z0-9+/=\r\n]*$')
}

# Set key to encrypt with, and EmitKey to the key the code should carry.
function Select-Key {
    if ($StoredKey) {
        $script:key = $StoredKey
        $script:EmitKey = ""
    } else {
        $script:key = New-WcpKey $KeyLen
        $script:EmitKey = $script:key
    }
}

function Describe-Reply([string]$Reply) {
    # A blocked request answers with a whole HTML page, not a message.
    if ([string]::IsNullOrEmpty($Reply)) {
        return "<empty response>"
    }
    if ($Reply -match '(?i)<html|<!doctype') {
        $out = "HTML error page"
        $m = [regex]::Match($Reply, '(?i)<title>([^<]*)')
        if ($m.Success) {
            $out += " - " + $m.Groups[1].Value.Trim()
        }
        $r = [regex]::Match($Reply, 'Request ID: <code>([^<]*)')
        if ($r.Success) {
            $out += " (request id " + $r.Groups[1].Value.Trim() + ")"
        }
        return $out
    }
    if ($Reply.Length -gt 200) {
        return $Reply.Substring(0, 200) + "... [" + $Reply.Length + " bytes total]"
    }
    return $Reply
}

# Run the powershell blocks in tests.md, in a sandbox of their own.
function Invoke-TestSheet([string]$Sheet) {
    if (-not $Sheet) {
        $here = Split-Path -Parent $PSCommandPath
        $beside = Join-Path $here 'tests.md'
        $here2 = Join-Path $PWD.Path 'tests.md'
        if (Test-Path -LiteralPath $beside) {
            $Sheet = $beside
        } elseif (Test-Path -LiteralPath $here2) {
            $Sheet = $here2
        } else {
            Warn "wcp: no tests.md beside wcp or in this directory"
            Warn "wcp: pass one explicitly: wcp --run-tests <file.md>"
            return 1
        }
    }
    if (-not (Test-Path -LiteralPath $Sheet)) {
        Warn "wcp: cannot read $Sheet"
        return 1
    }

    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("wcp-tests-" + $stamp)
    $work = Join-Path $sandbox 'work'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    # The key and the buffer both hang off LOCALAPPDATA, so moving it moves both
    # and the real ones are never touched.
    $oldLocal = $env:LOCALAPPDATA
    $oldCache = $env:XDG_CACHE_HOME
    $oldNoCopy = $env:WCP_NO_COPY
    $oldPwd = $PWD.Path
    $env:LOCALAPPDATA = $sandbox
    $env:XDG_CACHE_HOME = $sandbox
    $env:WCP_NO_COPY = '1'
    Set-Location -LiteralPath $work

    # Errors go to [Console]::Error, which no in-process call can capture, so
    # each command runs wcp as a child and merges its streams.
    $script:WcpBin = $PSCommandPath
    $script:WcpCmd = Join-Path (Split-Path -Parent $PSCommandPath) 'wcp.cmd'
    $pass = 0
    $fail = 0
    $out = ''
    $inFence = $false

    [Console]::Out.WriteLine("wcp: running $Sheet")
    foreach ($line in (Get-Content -LiteralPath $Sheet)) {
        if ($line -match '^```powershell\s*$') { $inFence = $true; continue }
        if ($line -match '^```') { $inFence = $false; continue }
        if (-not $inFence) { continue }
        if ($line.Trim() -eq '') { continue }

        if ($line -match '^#\s*->\s?(.*)$') {
            $want = $matches[1]
            if ($out -like ('*' + $want + '*')) {
                $pass += 1
            } else {
                $fail += 1
                $seen = $out -replace "`r?`n", ' '
                if ($seen.Length -gt 70) { $seen = $seen.Substring(0, 70) }
                [Console]::Out.WriteLine("  FAIL $want")
                [Console]::Out.WriteLine("       got: $seen")
            }
            continue
        }
        if ($line -match '^#\s*~>\s?(.*)$') {
            $want = $matches[1]
            if ($out -match $want) {
                $pass += 1
            } else {
                $fail += 1
                $seen = $out -replace "`r?`n", ' '
                if ($seen.Length -gt 70) { $seen = $seen.Substring(0, 70) }
                [Console]::Out.WriteLine("  FAIL $want")
                [Console]::Out.WriteLine("       got: $seen")
            }
            continue
        }
        if ($line -match '^#') { continue }

        try {
            $out = (Invoke-Expression $line 2>&1 | Out-String).Trim()
        } catch {
            $out = $_.Exception.Message
        }
    }

    Set-Location -LiteralPath $oldPwd
    $env:LOCALAPPDATA = $oldLocal
    $env:XDG_CACHE_HOME = $oldCache
    $env:WCP_NO_COPY = $oldNoCopy
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue

    [Console]::Out.WriteLine("")
    [Console]::Out.WriteLine("$pass passed, $fail failed")
    if ($fail -eq 0) { return 0 }
    return 1
}

# Spawn wcp as a child so its stderr is a real stream the sheet can capture.
function wcp {
    $ErrorActionPreference = 'Continue'
    $stdin = @($input)
    $quoted = ($args | ForEach-Object { '"' + $_ + '"' }) -join ' '
    if ($stdin.Count -eq 0) {
        return (& cmd /c "`"$script:WcpCmd`" $quoted" 2>&1)
    }
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $tmp -Value $stdin -Encoding Ascii
        & cmd /c "`"$script:WcpCmd`" $quoted < `"$tmp`"" 2>&1
    } finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

# Show the buffer: head and tail only on a terminal, unless --full.
function Show-Buffer {
    if (-not (Test-Path -LiteralPath $BufferPath)) {
        Warn "wcp: buffer is empty - nothing to show"
        return
    }
    $lines = @(Get-Content -LiteralPath $BufferPath)
    if ($lines.Count -eq 0) {
        Warn "wcp: buffer is empty - nothing to show"
        return
    }
    if ($Full -or [Console]::IsOutputRedirected -or $lines.Count -le 10) {
        foreach ($l in $lines) { [Console]::Out.WriteLine($l) }
    } else {
        foreach ($l in $lines[0..4]) { [Console]::Out.WriteLine($l) }
        $hidden = $lines.Count - 10
        [Console]::Out.WriteLine(
            "... $hidden lines hidden, --full shows everything ...")
        foreach ($l in $lines[-5..-1]) { [Console]::Out.WriteLine($l) }
    }
    $entries = CountEntries $BufferPath
    $sz = HumanSize (Get-Item $BufferPath).Length
    Warn "wcp: $(Format-Entries $entries), $sz"
}

function Format-Entries([int]$N) {
    if ($N -eq 1) { return "1 entry" }
    return "$N entries"
}

function CountEntries([string]$Path) {
    $n = 1; $b = 0
    foreach ($line in Get-Content $Path) {
        if ($line -eq '') { $b++; continue }
        if ($b -ge 2) { $n++; $b = 0 }
        $b = 0
    }
    if ($b -ge 2) { $n++ }
    return $n
}

function EmitResult([string]$IdFull, [string]$Backend, [string]$Key) {
    $fetchHost = $DefaultFetchHostLitterbox
    if ($UploadHost) {
        $fetchHost = $UploadHost
    } elseif ($Backend -eq "catbox") {
        $fetchHost = $DefaultFetchHostCatbox
    }
    $code = Encode-Id $IdFull $Backend
    if ($Link) {
        $url = "$($fetchHost.TrimEnd('/'))/$IdFull"
        [Console]::Out.WriteLine($url)
        # clipboard gets link only, never the key
        if (-not $NoCopy -and ($DoCopy -or
            (-not [Console]::IsOutputRedirected))) {
            try { $url | Set-Clipboard } catch {}
        }
        if ($Key) { [Console]::Out.WriteLine($Key) }
    } elseif ($Key) {
        $full = "$code-$Key"
        [Console]::Out.WriteLine($full)
        if (-not $NoCopy -and ($DoCopy -or
            (-not [Console]::IsOutputRedirected))) {
            try { $full | Set-Clipboard } catch {}
        }
    } else {
        [Console]::Out.WriteLine($code)
        if (-not $NoCopy -and ($DoCopy -or
            (-not [Console]::IsOutputRedirected))) {
            try { $code | Set-Clipboard } catch {}
        }
    }
}


# Encryption

# Locate openssl once; the same invocation as the bash build.
function Find-OpenSsl {
    foreach ($n in @("openssl.exe", "openssl")) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    # Common installers do not add themselves to PATH, so look where they land.
    $guesses = @(
        (Join-Path $env:ProgramFiles 'OpenSSL-Win64\bin\openssl.exe'),
        (Join-Path $env:ProgramFiles 'OpenSSL\bin\openssl.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'OpenSSL-Win32\bin\openssl.exe'),
        (Join-Path $env:ProgramFiles 'Git\usr\bin\openssl.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\usr\bin\openssl.exe')
    )
    foreach ($g in $guesses) {
        if ($g -and (Test-Path -LiteralPath $g)) { return $g }
    }
    return $null
}

$OpenSslPath = Find-OpenSsl

# Fail early when curl.exe or openssl is missing.
function Require-Tools {
    $missing = @()
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        $missing += "curl.exe"
    }
    if (-not $OpenSslPath) { $missing += "openssl" }
    if ($missing.Count -eq 0) { return }
    Warn ("wcp: missing required tool(s): " + ($missing -join ", "))
    if ($missing -contains "curl.exe") {
        Warn "wcp: curl.exe ships with Windows 10 (1803+) and Windows 11, so"
        Warn "wcp: check C:\Windows\System32 is on PATH, or install it with:"
        Warn "wcp:   winget install cURL.cURL"
        Warn "wcp:   choco install curl"
    }
    if ($missing -contains "openssl") {
        Warn "wcp: install openssl with one of:"
        Warn "wcp:   winget install ShiningLight.OpenSSL.Light"
        Warn "wcp:   choco install openssl"
        Warn "wcp: Git for Windows also ships one at"
        Warn "wcp:   C:\Program Files\Git\usr\bin\openssl.exe"
        Warn "wcp: then reopen your terminal so PATH picks it up."
    }
    exit 1
}

function Assert-OpenSsl {
    Require-Tools
}

function New-TempPath {
    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    return (Join-Path ([System.IO.Path]::GetTempPath()) ('wcp-' + $stamp + '.bin'))
}

# Draw from [A-Za-z0-9] with rejection sampling so the alphabet stays uniform.
function New-WcpKey([int]$Len) {
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] 1
    $out = ''
    while ($out.Length -lt $Len) {
        $rng.GetBytes($buf)
        if ($buf[0] -lt 248) { $out += $chars[$buf[0] % 62] }
    }
    return $out
}

function Protect-Bytes([byte[]]$Plain, [string]$Key) {
    # Keep curl and openssl stderr non-fatal.
    $ErrorActionPreference = 'Continue'
    $inFile = New-TempPath
    $outFile = New-TempPath
    try {
        [System.IO.File]::WriteAllBytes($inFile, $Plain)
        & $OpenSslPath enc -aes-256-cbc -pbkdf2 -iter 10000 -salt `
            -pass "pass:$Key" -in $inFile -out $outFile 2>$null
        if ($LASTEXITCODE -ne 0) {
            Warn "wcp: encryption failed"
            exit 1
        }
        return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($outFile))
    } finally {
        Remove-Item $inFile -ErrorAction SilentlyContinue
        Remove-Item $outFile -ErrorAction SilentlyContinue
    }
}

function Unprotect-Bytes([string]$B64, [string]$Key) {
    # Keep curl and openssl stderr non-fatal.
    $ErrorActionPreference = 'Continue'
    $inFile = New-TempPath
    $outFile = New-TempPath
    try {
        [System.IO.File]::WriteAllBytes($inFile, [Convert]::FromBase64String($B64.Trim()))
        & $OpenSslPath enc -d -aes-256-cbc -pbkdf2 -iter 10000 `
            -pass "pass:$Key" -in $inFile -out $outFile 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return [System.IO.File]::ReadAllBytes($outFile)
    } finally {
        Remove-Item $inFile -ErrorAction SilentlyContinue
        Remove-Item $outFile -ErrorAction SilentlyContinue
    }
}


# Retrieval

# Fetch ciphertext, decrypt, then save under its wcp-name header or print it.
function Invoke-EncryptedRetrieve([string]$Url, [string]$Key, [string]$OutFile) {
    # Keep curl and openssl stderr non-fatal.
    $ErrorActionPreference = 'Continue'
    $bodyFile = New-TempPath
    try {
        $status = & curl.exe -sSL -o $bodyFile -w '%{http_code}' $Url
        if ([int]$status -ge 400) { return $false }
        $plain = Unprotect-Bytes ([System.IO.File]::ReadAllText($bodyFile)) $Key
        if ($null -eq $plain) {
            Warn "wcp: could not decrypt - wrong key or corrupted upload"
            exit 1
        }
        $nl = [Array]::IndexOf($plain, [byte]10)
        $hdr = ""
        if ($nl -gt 0) {
            $hdr = [System.Text.Encoding]::UTF8.GetString($plain, 0, $nl)
        }
        if ($hdr.StartsWith("wcp-name:")) {
            $target = $OutFile
            if (-not $target) { $target = "./" + $hdr.Substring(9) }
            $target = Get-UniqueSaveName $target
            $rest = New-Object byte[] ($plain.Length - $nl - 1)
            [Array]::Copy($plain, $nl + 1, $rest, 0, $rest.Length)
            [System.IO.File]::WriteAllBytes($target, $rest)
            [Console]::Out.WriteLine("Saved as " + (Split-Path -Leaf $target))
        } elseif ($OutFile) {
            $target = Get-UniqueSaveName $OutFile
            [System.IO.File]::WriteAllBytes($target, $plain)
            [Console]::Out.WriteLine("Saved to " + $target)
        } else {
            [Console]::Out.Write([System.Text.Encoding]::UTF8.GetString($plain))
        }
        return $true
    } finally {
        Remove-Item $bodyFile -ErrorAction SilentlyContinue
    }
}

function Invoke-Retrieve([string]$Url, [string]$OverrideOut) {
    # Keep curl and openssl stderr non-fatal.
    $ErrorActionPreference = 'Continue'
    $hdrFile = [System.IO.Path]::GetTempFileName()
    $bodyFile = [System.IO.Path]::GetTempFileName()
    try {
        $httpCode = & curl.exe -sSL -D $hdrFile -o $bodyFile -w '%{http_code}' $Url
        if ([int]$httpCode -ge 400) {
            return $false
        }

        # A stored-key upload has no key in its code, so detect it by shape.
        if (Test-Encrypted $bodyFile) {
            if (-not $StoredKey) {
                Warn "wcp: this upload is encrypted, but no key is set here"
                Warn "wcp: run --set-key with the key from the sending machine"
                return $false
            }
            return (Invoke-EncryptedRetrieve $Url $StoredKey $OverrideOut)
        }

        $ctype = ""
        Get-Content $hdrFile | ForEach-Object {
            if ($_ -match '^[Cc]ontent-[Tt]ype:\s*(.+?)\s*$') {
                $ctype = $matches[1]
            }
        }

        if ($OverrideOut) {
            $outName = Get-UniqueSaveName $OverrideOut
            Move-Item -Force $bodyFile $outName
            [Console]::Out.WriteLine("Saved to " + $outName)
        } elseif ($ctype -like "text/*") {
            [Console]::Out.Write([System.IO.File]::ReadAllText($bodyFile))
        } else {
            $fname = Split-Path -Leaf ($Url -replace '\?.*$', '')
            if ([string]::IsNullOrEmpty($fname)) { $fname = "downloaded_file" }
            $target = Get-UniqueSaveName "./$fname"
            Move-Item -Force $bodyFile $target
            [Console]::Out.WriteLine("Saved as " + (Split-Path -Leaf $target))
        }
        return $true
    } finally {
        Remove-Item $hdrFile -ErrorAction SilentlyContinue
        Remove-Item $bodyFile -ErrorAction SilentlyContinue
    }
}

function Show-Usage {
    @"
wcp - upload a file, some text, or stdin; get back a short code.

Usage:
  wcp <file>                     upload a file
  wcp some words here            upload text
  Get-Content file | wcp         upload stdin
  wcp <code>                     retrieve; falls back to uploading on a miss
  wcp . <code>                   retrieve; errors on a miss
  wcp . <code|url>               retrieve; errors on a miss
  wcp <code|url> -o <file>       retrieve and save under a chosen name

Options:
  -b, --backend <name>   catbox (default) or litterbox; -b c / -b l also work
      --host <url>       override the backend endpoint, or the fetch host
  -t, --time <hours>     litterbox expiry, rounds up to 1/12/24/72 (default 1)
  -p, --plain            upload without encryption
  -c, --copy             copy the code even when output is redirected
  -n, --no-copy          do not copy the code to the clipboard
  -l, --link             print the full URL instead of the short code
  -f, --force            encrypt a file of any type, up to 100 MB
  -a, --accumulate       append stdin, text or the clipboard to the buffer
                         with nothing to append, shows the buffer instead
  -s, --send             upload the accumulated buffer and clear it
      --clear            empty the buffer without uploading
      --full             with -a, show the whole buffer, not head and tail
      --run-tests [file] run the blocks in tests.md and report pass/fail
  -v, --paste            upload the clipboard contents (takes no arguments)
  -h, --help             show this help

Key store:
      --set-key [key]    store a key (20+ chars); with no value, generate one
      --get-key          print the stored key
      --clear-key        forget the stored key
  -z, --no-stored-key    ignore the stored key for this run

With a key stored, every upload is encrypted with it and the code stays 7
characters, because the key never travels. Both machines need the same key.

Env: WCP_BACKEND, WCP_TIME (whole hours), WCP_PLAIN=1, WCP_NO_COPY=1
"@
}


# Flag Parsing

$Backend = if ($env:WCP_BACKEND) { $env:WCP_BACKEND } else { "catbox" }
$LbHours = if ($env:WCP_TIME) { $env:WCP_TIME } else { 1 }
$UploadHost = ""
$DoCopy = $false
$NoCopy = $false
if ($env:WCP_NO_COPY -eq '1') { $NoCopy = $true }
$Plain = $false
$DoPaste = $false
$OutFile = $null
$KeyLen = 12
$ForceEncrypt = $false
$Link = $false
$Force = $false
$Accum = $false
$Send = $false
$Clear = $false
$Full = $false
$RunTests = $false
$TestSheet = ""
$NoKey = $false
$DoSetKey = $false
$SetKeyValue = ""
$DoGetKey = $false
$DoClearKey = $false
$MinStoredKey = 20
$KeyPath = Join-Path (Join-Path $env:LOCALAPPDATA 'wcp') 'key'
$CacheRoot = $env:XDG_CACHE_HOME
if (-not $CacheRoot) { $CacheRoot = $env:LOCALAPPDATA }
$BufferPath = Join-Path (Join-Path $CacheRoot 'wcp') 'buffer'
if ($env:WCP_KEY_LEN) { $KeyLen = [int]$env:WCP_KEY_LEN }
$rest = @()

# Expand bundled boolean flags, so -abc becomes -a -b -c.
$ShortFlags = "cenpvhlfasz"
$ValueFlags = "btko"
$Argv = @()
$sawDoubleDash = $false
foreach ($a in $args) {
    if ($sawDoubleDash) { $Argv += $a; continue }
    if ($a -eq "--") { $sawDoubleDash = $true; $Argv += $a; continue }
    if ($a -cmatch '^-[a-zA-Z]{2,}$') {
        $chars = $a.Substring(1).ToCharArray()
        $allShort = $true
        $anyValue = $false
        foreach ($c in $chars) {
            if ($ShortFlags.IndexOf($c) -lt 0) { $allShort = $false }
            if ($ValueFlags.IndexOf($c) -ge 0) { $anyValue = $true }
        }
        if ($anyValue) {
            Warn "wcp: -b, -t, -k and -o take a value and cannot be bundled (got '$a')"
            exit 1
        }
        if ($allShort) {
            foreach ($c in $chars) { $Argv += "-$c" }
            continue
        }
    }
    $Argv += $a
}

$i = 0
while ($i -lt $Argv.Count) {
    $a = $Argv[$i]
    if ($a -eq "-b" -or $a -eq "--backend") {
        $val = $Argv[$i + 1]
        switch ($val) {
            "c" { $Backend = "catbox" }
            "catbox" { $Backend = "catbox" }
            "l" { $Backend = "litterbox" }
            "litterbox" { $Backend = "litterbox" }
            default { $Backend = $val }
        }
        $i += 2
    } elseif ($a -like "--backend=*") {
        $val = $a.Substring(10)
        switch ($val) {
            "c" { $Backend = "catbox" }
            "catbox" { $Backend = "catbox" }
            "l" { $Backend = "litterbox" }
            "litterbox" { $Backend = "litterbox" }
            default { $Backend = $val }
        }
        $i += 1
    } elseif ($a -eq "--host") {
        $UploadHost = $Argv[$i + 1]; $i += 2
    } elseif ($a -like "--host=*") {
        $UploadHost = $a.Substring(7); $i += 1
    } elseif ($a -eq "-t") {
        $LbHours = $Argv[$i + 1]; $i += 2
    } elseif ($a -like "-t=*") {
        $LbHours = $a.Substring(3); $i += 1
    } elseif ($a -eq "--time") {
        $LbHours = $Argv[$i + 1]; $i += 2
    } elseif ($a -like "--time=*") {
        $LbHours = $a.Substring(7); $i += 1
    } elseif ($a -eq "--copy" -or $a -eq "-c") {
        $DoCopy = $true; $i += 1
    } elseif ($a -eq "--no-copy" -or $a -eq "-n") {
        $NoCopy = $true; $i += 1
    } elseif ($a -eq "-v" -or $a -eq "--paste") {
        $DoPaste = $true; $i += 1
    } elseif ($a -eq "-k" -or $a -eq "--key-len") {
        $KeyLen = [int]$Argv[$i + 1]; $i += 2
    } elseif ($a -eq "-o" -or $a -eq "--output") {
        $OutFile = $Argv[$i + 1]; $i += 2
    } elseif ($a -eq "-h" -or $a -eq "--help") {
        Show-Usage
        exit 0
    } elseif ($a -eq "-p" -or $a -eq "--plain") {
        $Plain = $true; $i += 1
    } elseif ($a -eq "-e" -or $a -eq "--encrypt") {
        $ForceEncrypt = $true; $i += 1
    } elseif ($a -eq "-l" -or $a -eq "--link") {
        $Link = $true; $i += 1
    } elseif ($a -eq "-f" -or $a -eq "--force") {
        $Force = $true; $i += 1
    } elseif ($a -eq "-a" -or $a -eq "--accumulate") {
        $Accum = $true; $i += 1
    } elseif ($a -eq "-s" -or $a -eq "--send") {
        $Send = $true; $i += 1
    } elseif ($a -eq "--clear") {
        $Clear = $true; $i += 1
    } elseif ($a -eq "--full") {
        $Full = $true; $i += 1
    } elseif ($a -eq "--run-tests") {
        $RunTests = $true; $i += 1
        if ($i -lt $Argv.Count -and -not $Argv[$i].StartsWith("-")) {
            $TestSheet = $Argv[$i]; $i += 1
        }
    } elseif ($a -eq "-z" -or $a -eq "--no-stored-key") {
        $NoKey = $true; $i += 1
    } elseif ($a -eq "--set-key") {
        $DoSetKey = $true; $i += 1
        # Optional value: only take a token that is not itself a flag.
        if ($i -lt $Argv.Count -and -not $Argv[$i].StartsWith("-")) {
            $SetKeyValue = $Argv[$i]; $i += 1
        }
    } elseif ($a -like "--set-key=*") {
        $DoSetKey = $true
        $SetKeyValue = $a.Substring(10); $i += 1
    } elseif ($a -eq "--get-key") {
        $DoGetKey = $true; $i += 1
    } elseif ($a -eq "--clear-key") {
        $DoClearKey = $true; $i += 1
    } elseif ($a -eq "--") {
        $i += 1
        while ($i -lt $Argv.Count) { $rest += $Argv[$i]; $i += 1 }
    } else {
        $rest += $a; $i += 1
    }
}

if ($env:WCP_PLAIN -eq "1") { $Plain = $true }

if ($Accum -and $Send) {
    Warn "wcp: -a and -s do opposite things"
    exit 1
}

# Checked after parsing, so --help still works on a bare machine.
Require-Tools

if ($RunTests) {
    exit (Invoke-TestSheet $TestSheet)
}

# Key-store actions stand alone: they never combine with an upload.
$keyActions = 0
if ($DoSetKey) { $keyActions += 1 }
if ($DoGetKey) { $keyActions += 1 }
if ($DoClearKey) { $keyActions += 1 }
if ($keyActions -gt 1) {
    Warn "wcp: --set-key, --get-key and --clear-key are separate actions"
    exit 1
}
if ($keyActions -eq 1) {
    if ($rest.Count -gt 0) {
        Warn "wcp: a key action takes no other arguments"
        exit 1
    }
    if ($DoSetKey) {
        if (-not $SetKeyValue) {
            $SetKeyValue = New-WcpKey $MinStoredKey
            if (-not (Write-StoredKey $SetKeyValue)) { exit 1 }
            Warn "wcp: generated a new key and stored it"
            [Console]::Out.WriteLine($SetKeyValue)
        } else {
            if (-not (Write-StoredKey $SetKeyValue)) { exit 1 }
            Warn "wcp: key stored"
        }
        exit 0
    }
    if ($DoGetKey) {
        $storedNow = Read-StoredKey
        if (-not $storedNow) {
            Warn "wcp: no key is set on this machine"
            exit 1
        }
        [Console]::Out.WriteLine($storedNow)
        exit 0
    }
    if (Test-Path -LiteralPath $KeyPath) {
        Remove-Item -LiteralPath $KeyPath -Force
        Warn "wcp: key cleared"
    } else {
        Warn "wcp: no key was set"
    }
    exit 0
}

# -z opts out of the stored key, restoring the per-backend default.
$StoredKey = ""
if (-not $NoKey) { $StoredKey = Read-StoredKey }

$LbTime = Convert-LitterboxTimeBucket $LbHours

function Do-ExplicitRetrieve([string]$Code, [string]$OutFile) {
    # An encrypted code is CODE-KEY; split on the first dash.
    $encKey = $null
    if ($Code -cmatch '^[a-oA-O01][0-9a-zA-Z]+-[0-9a-zA-Z]+$') {
        Assert-OpenSsl
        $dash = $Code.IndexOf("-")
        $encKey = $Code.Substring($dash + 1)
        $Code = $Code.Substring(0, $dash)
    }
    $letter = $Code.Substring(0, 1)

    # Validate prefix letter
    $backendName = $null
    if ($letter -cmatch '^[a-o]$') { $backendName = "litterbox" }
    elseif ($letter -cmatch '^[A-O]$') { $backendName = "catbox" }
    elseif ($letter -eq '0') { $backendName = "litterbox" }
    elseif ($letter -eq '1') { $backendName = "catbox" }
    else {
        Warn "wcp: '$Code' is not a valid code (unknown prefix '$letter')"
        return $false
    }

    # Determine extension for error message
    $extStr = ".txt"
    if ($letter -cmatch '^[a-z]$') {
        $idx = [int][char]$letter - 97
        if ($idx -ge 0 -and $idx -lt $ExtTable.Count -and $ExtTable[$idx]) {
            $extStr = "." + $ExtTable[$idx]
        }
    }
    elseif ($letter -cmatch '^[A-Z]$') {
        $idx = [int][char]$letter - 65
        if ($idx -ge 0 -and $idx -lt $ExtTable.Count -and $ExtTable[$idx]) {
            $extStr = "." + $ExtTable[$idx]
        }
    }

    # Resolve fetch host
    $fetchHost = $DefaultFetchHostLitterbox
    if ($UploadHost) {
        $fetchHost = $UploadHost
    } elseif ($backendName -eq "catbox") {
        $fetchHost = $DefaultFetchHostCatbox
    }

    # Decode the code to get the ID
    if (-not (Decode-Code $Code)) {
        Warn "wcp: '$Code' is not a valid code (unknown prefix '$letter')"
        return $false
    }

    $fetchUrl = "$($fetchHost.TrimEnd('/'))/$DecodeId"
    $ok = $false
    if ($encKey) {
        $ok = Invoke-EncryptedRetrieve $fetchUrl $encKey $OutFile
    } else {
        $ok = Invoke-Retrieve $fetchUrl $OutFile
    }
    if (-not $ok) {
        Warn "wcp: no such code '$Code' ($backendName, $extStr)"
        if ($backendName -eq "litterbox") {
            Warn "wcp: litterbox codes expire - the default window is 1h"
        }
        return $false
    }
    return $true
}


# Explicit Retrieval

# A leading dot, or -o on its own, both mean an explicit retrieval.
$target = $null
$retrievalKey = ""
if ($rest.Count -gt 0 -and $rest[0] -eq ".") {
    if ($rest.Count -lt 2) {
        Warn "wcp: . needs a code or URL, e.g. wcp . b0ojyr4"
        exit 1
    }
    $target = $rest[1]
    if ($rest.Count -gt 2) { $retrievalKey = $rest[2] }
} elseif ($OutFile -and $rest.Count -eq 1) {
    $target = $rest[0]
}

# A key may also arrive in a URL fragment: accepted, never emitted.
if ($target -and $target.Contains('#')) {
    $bits = $target.Split('#')
    $target = $bits[0]
    if (-not $retrievalKey) { $retrievalKey = $bits[1] }
}

if ($retrievalKey -and $retrievalKey -notmatch '^[A-Za-z0-9]{12,64}$') {
    Warn "wcp: that does not look like a key (expected 12-64 letters and digits)"
    exit 1
}

if ($target) {
    if ($target -match '^https?://') {
        if ($retrievalKey) {
            if (-not (Invoke-EncryptedRetrieve $target $retrievalKey $OutFile)) {
                exit 1
            }
        } elseif (-not (Invoke-Retrieve $target $OutFile)) {
            Warn ("wcp: failed to fetch " + $target)
            exit 1
        }
    } elseif ($retrievalKey) {
        # A bare code plus a key is the same thing as CODE-KEY.
        if ($target.Contains('-')) {
            Warn "wcp: '$target' already carries a key, so a second one is ambiguous"
            exit 1
        }
        if (-not (Do-ExplicitRetrieve ($target + '-' + $retrievalKey) $OutFile)) {
            exit 1
        }
    } else {
        if (-not (Do-ExplicitRetrieve $target $OutFile)) {
            exit 1
        }
    }
    exit 0
}


# Short Code Retrieval

if ($rest.Count -eq 1 -and -not (Test-Path -LiteralPath $rest[0] -PathType Leaf)) {
    $Candidate = $rest[0]
    $Letter = $Candidate.Substring(0, 1)
    $RestPart = $Candidate.Substring(1)

    if ($Candidate -cmatch '^[a-oA-O01][0-9a-zA-Z]+-[0-9a-zA-Z]+$') {
        if (Do-ExplicitRetrieve $Candidate $OutFile) { exit 0 }
        exit 1
    }

    if (Decode-Code $Candidate) {
        # Short candidates may be codes; longer ones only if they carry a dot.
        if ($Candidate.Length -le 7 -and $RestPart -cmatch '^[0-9a-zA-Z]+$') {
            $FetchHost = $DefaultFetchHostLitterbox
            if ($UploadHost) {
                $FetchHost = $UploadHost
            } elseif ($DecodeBackend -eq "catbox") {
                $FetchHost = $DefaultFetchHostCatbox
            }
            $fetchUrl = "$($FetchHost.TrimEnd('/'))/$DecodeId"
            if (Invoke-Retrieve $fetchUrl $null) {
                exit 0
            }
        } elseif ($Candidate.Contains(".")) {
            # Code carrying a literal extension after an a/c prefix.
            $FetchHost = $DefaultFetchHostLitterbox
            if ($UploadHost) {
                $FetchHost = $UploadHost
            } elseif ($DecodeBackend -eq "catbox") {
                $FetchHost = $DefaultFetchHostCatbox
            }
            $fetchUrl = "$($FetchHost.TrimEnd('/'))/$DecodeId"
            if (Invoke-Retrieve $fetchUrl $null) {
                exit 0
            }
        }
    }
}

switch ($Backend) {
    "catbox"      { $DefaultHost = $DefaultUploadHostCatbox }
    "litterbox"   { $DefaultHost = $DefaultUploadHostLitterbox }
    default {
        Warn "wcp: unknown backend: $Backend (expected: catbox, litterbox)"
        exit 1
    }
}
if ([string]::IsNullOrEmpty($UploadHost)) { $UploadHost = $DefaultHost }
$UploadHost = $UploadHost.TrimEnd('/')

function Write-TempFile([string]$Content) {
    # Name it .txt so the backend serves it as text, not binary.
    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wcp-' + $stamp + '.txt')
    $enc = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tmp, $Content, $enc)
    return $tmp
}

function Upload-Catbox([string]$Kind, [string]$Arg) {
    # Keep curl and openssl stderr non-fatal.
    $ErrorActionPreference = 'Continue'
    switch ($Kind) {
        "file"  {
            return & curl.exe -sS -F "reqtype=fileupload" `
                -F "fileToUpload=@$Arg" $UploadHost
        }
        "text"  {
            $tmp = Write-TempFile $Arg
            try {
                return & curl.exe -sS -F "reqtype=fileupload" `
                    -F "fileToUpload=@$tmp" $UploadHost
            }
            finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
        "stdin" {
            $content = Read-PipedInput
            $tmp = Write-TempFile $content
            try {
                return & curl.exe -sS -F "reqtype=fileupload" `
                    -F "fileToUpload=@$tmp" $UploadHost
            }
            finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
    }
}

function Upload-Litterbox([string]$Kind, [string]$Arg) {
    # Keep curl and openssl stderr non-fatal.
    $ErrorActionPreference = 'Continue'
    switch ($Kind) {
        "file"  {
            return & curl.exe -sS -F "reqtype=fileupload" -F "time=$LbTime" `
                -F "fileToUpload=@$Arg" $UploadHost
        }
        "text"  {
            $tmp = Write-TempFile $Arg
            try {
                return & curl.exe -sS -F "reqtype=fileupload" -F "time=$LbTime" `
                    -F "fileToUpload=@$tmp" $UploadHost
            }
            finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
        "stdin" {
            $content = Read-PipedInput
            $tmp = Write-TempFile $content
            try {
                return & curl.exe -sS -F "reqtype=fileupload" -F "time=$LbTime" `
                    -F "fileToUpload=@$tmp" $UploadHost
            }
            finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
    }
}

function Dispatch([string]$Kind, [string]$Arg) {
    switch ($Backend) {
        "catbox"      { return Upload-Catbox $Kind $Arg }
        "litterbox"   { return Upload-Litterbox $Kind $Arg }
    }
}

if ($DoPaste) {
    if ($rest.Count -gt 0) {
        Warn "wcp: -v/--paste takes no arguments (it uploads the clipboard)"
        exit 1
    }
    $clip = Get-Clipboard -Raw
    if ([string]::IsNullOrEmpty($clip)) {
        Warn "wcp: clipboard is empty - nothing to upload"
        exit 1
    }
    $PasteContent = $clip
}

if ($KeyLen -lt 12 -or $KeyLen -gt 64) {
    Warn "wcp: --key-len must be a whole number from 12 to 64 (default 12)"
    exit 1
}

# Select the encryption mode for this upload.
$MaxEncSize = 1048576
$MaxForceSize = 104857600    # 100 MB, -f ceiling
$Encrypt = $false
if ($Plain) {
    $Encrypt = $false
} elseif ($ForceEncrypt) {
    $Encrypt = $true
} elseif ($StoredKey) {
    $Encrypt = $true
} elseif ($Backend -eq "litterbox") {
    $Encrypt = $false
} else {
    $Encrypt = $true
}

$key = $null
$result = $null

# Buffer modes encrypt inside their own block, not from $rest.
if ($Encrypt -and -not $Send -and -not $Accum -and -not $Clear) {
    $plain = $null
    if ($DoPaste) {
        $plain = [System.Text.Encoding]::UTF8.GetBytes($PasteContent)
    } elseif ($rest.Count -eq 0 -or ($rest.Count -eq 1 -and $rest[0] -eq "-")) {
        $plain = [System.Text.Encoding]::UTF8.GetBytes((Read-PipedInput))
    } elseif ($rest.Count -eq 1 -and (Test-Path -LiteralPath $rest[0] -PathType Leaf)) {
        $fp = $rest[0]
        $bn = Split-Path -Leaf $fp
        $fsize = (Get-Item -LiteralPath $fp).Length
        if ($fsize -le $MaxEncSize) {
            # encrypt normally
        } elseif ($Force -and $fsize -le $MaxForceSize) {
            $hsize = HumanSize $fsize
            $upSize = HumanSize ($fsize * 4 / 3)
            Warn ("wcp: encrypting $hsize" +
                " - the upload will be about $upSize and may take a while")
        } elseif ($Force) {
            $hsize = HumanSize $fsize
            $flimit = HumanSize $MaxForceSize
            Warn ("wcp: -f cannot encrypt $bn" +
                " - $hsize over the $flimit encrypted limit")
            Warn "wcp: upload it without -f to send it unencrypted"
            exit 1
        } else {
            $hsize = HumanSize $fsize
            $limit = HumanSize $MaxEncSize
            Warn ("wcp: not encrypting $bn" +
                " - $hsize over the $limit limit, uploading as-is")
            Warn "wcp: pass -f to encrypt it anyway"
            $Encrypt = $false
        }
        if ($Encrypt) {
            $hdr = [System.Text.Encoding]::UTF8.GetBytes("wcp-name:$bn`n")
            $body = [System.IO.File]::ReadAllBytes($fp)
            $plain = New-Object byte[] ($hdr.Length + $body.Length)
            [Array]::Copy($hdr, 0, $plain, 0, $hdr.Length)
            [Array]::Copy($body, 0, $plain, $hdr.Length, $body.Length)
        }
    } else {
        $plain = [System.Text.Encoding]::UTF8.GetBytes(($rest -join ' '))
    }

    if ($Encrypt) {
        Select-Key
        $result = Dispatch "text" (Protect-Bytes $plain $key)
    }
}

# Accumulate / Send / Clear
if ($Clear) {
    if (Test-Path -LiteralPath $BufferPath) {
        $entries = CountEntries $BufferPath
        $sz = HumanSize (Get-Item $BufferPath).Length
        Remove-Item $BufferPath -Force
        [Console]::Out.WriteLine("wcp: buffer cleared ($(Format-Entries $entries), $sz)")
    } else {
        [Console]::Out.WriteLine("wcp: buffer cleared (0 entries, 0 B)")
    }
    exit 0
}

if ($Accum) {
    if ($rest.Count -gt 0) {
        # Argument text
        $text = $rest -join ' '
        $sep = if (Test-Path -LiteralPath $BufferPath) { "`n`n" } else { "" }
        if (-not (Test-Path $BufferPath)) {
            New-Item -ItemType Directory -Path (Split-Path $BufferPath) -Force | Out-Null
        }
        Add-Content -Path $BufferPath -Value ($sep + $text) -NoNewline:$false
    } elseif ($DoPaste) {
        # Clipboard
        if (-not (Test-Path $BufferPath)) {
            New-Item -ItemType Directory -Path (Split-Path $BufferPath) -Force | Out-Null
        }
        $sep = if (Test-Path -LiteralPath $BufferPath) { "`n`n" } else { "" }
        Add-Content -Path $BufferPath -Value ($sep + $PasteContent) -NoNewline:$false
    } elseif (-not [Console]::IsInputRedirected) {
        Show-Buffer
    } else {
        # Stdin
        $content = Read-PipedInput
        if ([string]::IsNullOrEmpty($content)) {
            Warn "wcp: nothing on stdin - nothing to accumulate"
            exit 1
        }
        # There is no file(1) here, so a NUL byte is the only binary signal.
        if ($content.Contains([char]0)) {
            Warn "wcp: only text can be accumulated"
            exit 1
        }
        if (-not (Test-Path $BufferPath)) {
            New-Item -ItemType Directory -Path (Split-Path $BufferPath) -Force | Out-Null
        }
        $sep = if (Test-Path -LiteralPath $BufferPath) { "`n`n" } else { "" }
        Add-Content -Path $BufferPath -Value ($sep + $content) -NoNewline:$false
    }
    exit 0
}

if ($Send) {
    if (-not (Test-Path -LiteralPath $BufferPath)) {
        Warn "wcp: buffer is empty - nothing to send"
        exit 1
    }
    $bufferContent = Get-Content -Raw $BufferPath
    if ([string]::IsNullOrWhiteSpace($bufferContent)) {
        Warn "wcp: buffer is empty - nothing to send"
        exit 1
    }
    $key = $null
    if ($Encrypt) {
        Select-Key
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($bufferContent)
        $result = Dispatch "text" (Protect-Bytes $plainBytes $key)
    } else {
        $result = Dispatch "text" $bufferContent
    }
    if ($result -match '^https?://\S+$') {
        $idFull = Get-IdFromUrl $result
        EmitResult $idFull $Backend $EmitKey
        Remove-Item $BufferPath -Force
    } else {
        Warn "wcp: upload failed on backend '$Backend' ($UploadHost)"
        $reply = Describe-Reply $result
        Warn "wcp: backend replied: $reply"
        exit 1
    }
    exit 0
}

if (-not $result) {
    if ($DoPaste) {
        $result = Dispatch "text" $PasteContent
    } elseif ($rest.Count -eq 0 -or ($rest.Count -eq 1 -and $rest[0] -eq "-")) {
        $result = Dispatch "stdin" ""
    } elseif ($rest.Count -eq 1 -and (Test-Path -LiteralPath $rest[0] -PathType Leaf)) {
        $result = Dispatch "file" $rest[0]
    } else {
        $result = Dispatch "text" ($rest -join ' ')
    }
}

if ($result -notmatch '^https?://\S+$') {
    Warn "wcp: upload failed on backend '$Backend' ($UploadHost)"
    $reply = Describe-Reply $result
    Warn "wcp: backend replied: $reply"
    exit 1
}

$idFull = Get-IdFromUrl $result
EmitResult $idFull $Backend $EmitKey
