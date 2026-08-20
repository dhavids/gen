# wcp.ps1 - minimal upload wrapper with a compact roundtrip code, for Windows.
#
# USAGE:
#   wcp path\to\file.txt        # upload -> prints a short code, e.g. "brbkswy"
#   wcp some words here         # not a file -> uploaded as text, prints a code
#   Get-Content file.txt | wcp  # no args -> reads stdin, prints a code
#   wcp brbkswy                 # retrieve (implicit): may fall back to uploading
#   wcp . brbkswy               # retrieve (explicit): errors instead of falling back
#   wcp . <full-url>            # retrieve by URL instead of a code
#   wcp brbkswy -o out.txt      # ...saved under a name you choose
#
# Retrieved text prints to stdout; retrieved files are saved into the current
# folder. Existing files are never overwritten - _1, _2 are appended and the
# name actually used is printed.
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
# Env vars: $env:WCP_BACKEND (default: litterbox), $env:WCP_TIME (whole hours, default 1)
#
# Collision handling: a candidate of 7 chars or fewer that looks like a code is
# tried as a retrieval first; if that 404s it falls back to uploading it as
# text. Longer candidates are only tried if they contain a . or a - (escape and
# escape-path codes carry a dot, encrypted codes a dash), so an ordinary long
# word is uploaded straight away with no wasted request.
#
# Encryption is NOT implemented in this PowerShell version. Uploads require
# --plain / -p (or WCP_PLAIN=1) since encryption is on by default. Retrieving
# a code containing a - errors out. Short aliases: -b backend, -c copy, -p plain, -t time.
#
# Requires curl.exe (bundled with Windows 10+ by default).

$ErrorActionPreference = "Stop"

# Sync .NET's cwd with PowerShell's for relative paths discovery
[System.IO.Directory]::SetCurrentDirectory($PWD.Path)

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
        Write-Error "wcp: -t takes a whole number of hours, 1 to 72"
        exit 1
    }
    $h = [int]$h
    if    ($h -le 1)  { return "1h" }
    elseif ($h -le 12) { return "12h" }
    elseif ($h -le 24) { return "24h" }
    elseif ($h -le 72) { return "72h" }
    else {
        Write-Error "wcp: -t max is 72 hours (litterbox allows 1, 12, 24, 72)"
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

function Assert-OpenSsl {
    if ($OpenSslPath) { return }
    Write-Error "wcp: encryption needs openssl, which was not found on PATH."
    Write-Error "wcp: install it with one of:"
    Write-Error "wcp:   winget install ShiningLight.OpenSSL.Light"
    Write-Error "wcp:   choco install openssl"
    Write-Error "wcp: Git for Windows also ships one at C:\Program Files\Git\usr\bin."
    Write-Error "wcp: or use --plain (-p) to upload without encryption."
    exit 1
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
    $inFile = New-TempPath
    $outFile = New-TempPath
    try {
        [System.IO.File]::WriteAllBytes($inFile, $Plain)
        & $OpenSslPath enc -aes-256-cbc -pbkdf2 -iter 10000 -salt `
            -pass "pass:$Key" -in $inFile -out $outFile 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "wcp: encryption failed"
            exit 1
        }
        return [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($outFile))
    } finally {
        Remove-Item $inFile -ErrorAction SilentlyContinue
        Remove-Item $outFile -ErrorAction SilentlyContinue
    }
}

function Unprotect-Bytes([string]$B64, [string]$Key) {
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
    $bodyFile = New-TempPath
    try {
        $status = & curl.exe -sSL -o $bodyFile -w '%{http_code}' $Url
        if ([int]$status -ge 400) { return $false }
        $plain = Unprotect-Bytes ([System.IO.File]::ReadAllText($bodyFile)) $Key
        if ($null -eq $plain) {
            Write-Error "wcp: could not decrypt - wrong key or corrupted upload"
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
    $hdrFile = [System.IO.Path]::GetTempFileName()
    $bodyFile = [System.IO.Path]::GetTempFileName()
    try {
        $httpCode = & curl.exe -sSL -D $hdrFile -o $bodyFile -w '%{http_code}' $Url
        if ([int]$httpCode -ge 400) {
            return $false
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
  -b, --backend <name>   litterbox (default) or catbox; -b l / -b c also work
      --host <url>       override the backend endpoint, or the fetch host
  -t, --time <hours>     litterbox expiry, rounds up to 1/12/24/72 (default 1)
  -p, --plain            upload without encryption
  -c, --copy             copy the resulting code to the clipboard
  -v, --paste            upload the clipboard contents (takes no arguments)
  -h, --help             show this help

Encryption is NOT implemented in this PowerShell version. All uploads require
--plain (-p) or WCP_PLAIN=1 since encryption is on by default.

Env: WCP_BACKEND, WCP_TIME (whole hours), WCP_PLAIN=1
"@
}


# Flag Parsing

$Backend = if ($env:WCP_BACKEND) { $env:WCP_BACKEND } else { "litterbox" }
$LbHours = if ($env:WCP_TIME) { $env:WCP_TIME } else { 1 }
$UploadHost = ""
$DoCopy = $false
$Plain = $false
$DoPaste = $false
$OutFile = $null
$KeyLen = 12
$ForceEncrypt = $false
if ($env:WCP_KEY_LEN) { $KeyLen = [int]$env:WCP_KEY_LEN }
$rest = @()

$i = 0
while ($i -lt $args.Count) {
    $a = $args[$i]
    if ($a -eq "-b" -or $a -eq "--backend") {
        $val = $args[$i + 1]
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
        $UploadHost = $args[$i + 1]; $i += 2
    } elseif ($a -like "--host=*") {
        $UploadHost = $a.Substring(7); $i += 1
    } elseif ($a -eq "-t") {
        $LbHours = $args[$i + 1]; $i += 2
    } elseif ($a -like "-t=*") {
        $LbHours = $a.Substring(3); $i += 1
    } elseif ($a -eq "--time") {
        $LbHours = $args[$i + 1]; $i += 2
    } elseif ($a -like "--time=*") {
        $LbHours = $a.Substring(7); $i += 1
    } elseif ($a -eq "--copy" -or $a -eq "-c") {
        $DoCopy = $true; $i += 1
    } elseif ($a -eq "-v" -or $a -eq "--paste") {
        $DoPaste = $true; $i += 1
    } elseif ($a -eq "-k" -or $a -eq "--key-len") {
        $KeyLen = [int]$args[$i + 1]; $i += 2
    } elseif ($a -eq "-o" -or $a -eq "--output") {
        $OutFile = $args[$i + 1]; $i += 2
    } elseif ($a -eq "-h" -or $a -eq "--help") {
        Show-Usage
        exit 0
    } elseif ($a -eq "-p" -or $a -eq "--plain") {
        $Plain = $true; $i += 1
    } elseif ($a -eq "-e" -or $a -eq "--encrypt") {
        $ForceEncrypt = $true; $i += 1
    } else {
        $rest += $a; $i += 1
    }
}

if ($env:WCP_PLAIN -eq "1") { $Plain = $true }

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
        Write-Error "wcp: '$Code' is not a valid code (unknown prefix '$letter')"
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
        Write-Error "wcp: '$Code' is not a valid code (unknown prefix '$letter')"
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
        Write-Error "wcp: no such code '$Code' ($backendName, $extStr)"
        if ($backendName -eq "litterbox") {
            Write-Error "wcp: litterbox codes expire - the default window is 1h"
        }
        return $false
    }
    return $true
}


# Explicit Retrieval

# A leading dot, or -o on its own, both mean an explicit retrieval.
$target = $null
if ($rest.Count -gt 0 -and $rest[0] -eq ".") {
    if ($rest.Count -lt 2) {
        Write-Error "wcp: . needs a code or URL, e.g. wcp . b0ojyr4"
        exit 1
    }
    $target = $rest[1]
} elseif ($OutFile -and $rest.Count -eq 1) {
    $target = $rest[0]
}

if ($target) {
    if ($target -match '^https?://') {
        if (-not (Invoke-Retrieve $target $OutFile)) {
            Write-Error ("wcp: failed to fetch " + $target)
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
        Write-Error "wcp: unknown backend: $Backend (expected: catbox, litterbox)"
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
            $content = [Console]::In.ReadToEnd()
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
            $content = [Console]::In.ReadToEnd()
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
        Write-Error "wcp: -v/--paste takes no arguments (it uploads the clipboard)"
        exit 1
    }
    $clip = Get-Clipboard -Raw
    if ([string]::IsNullOrEmpty($clip)) {
        Write-Error "wcp: clipboard is empty - nothing to upload"
        exit 1
    }
    $PasteContent = $clip
}

if ($KeyLen -lt 12 -or $KeyLen -gt 64) {
    Write-Error "wcp: --key-len must be a whole number from 12 to 64 (default 12)"
    exit 1
}

# Select the encryption mode for this upload.
$MaxEncSize = 1048576
$Encrypt = $false
if ($Plain) {
    $Encrypt = $false
} elseif ($ForceEncrypt) {
    Write-Error "wcp: encryption is on by default and is not yet supported in the PowerShell version — use --plain"
    exit 1
} else {
    Write-Error "wcp: encryption is on by default and is not yet supported in the PowerShell version — use --plain"
    exit 1
}

$key = $null
$result = $null

if ($Encrypt) {
    $plain = $null
    if ($DoPaste) {
        $plain = [System.Text.Encoding]::UTF8.GetBytes($PasteContent)
    } elseif ($rest.Count -eq 0 -or ($rest.Count -eq 1 -and $rest[0] -eq "-")) {
        $plain = [System.Text.Encoding]::UTF8.GetBytes([Console]::In.ReadToEnd())
    } elseif ($rest.Count -eq 1 -and (Test-Path -LiteralPath $rest[0] -PathType Leaf)) {
        $fp = $rest[0]
        $bn = Split-Path -Leaf $fp
        if ((Get-Item -LiteralPath $fp).Length -gt $MaxEncSize) {
            $msg = " - over the 1 MB limit, uploading as-is"
            Write-Error ("wcp: not encrypting " + $bn + $msg)
            $Encrypt = $false
        } else {
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
        $key = New-WcpKey $KeyLen
        $result = Dispatch "text" (Protect-Bytes $plain $key)
    }
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
    Write-Error "wcp: upload failed on backend '$Backend' ($UploadHost)"
    $reply = $result
    if (-not $reply) {
        $reply = "<empty response>"
    }
    Write-Error "wcp: backend replied: $reply"
    exit 1
}

$idFull = Get-IdFromUrl $result
$code = Encode-Id $idFull $Backend
if ($key) {
    $code = $code + "-" + $key
}

Write-Output $code

if ($DoCopy) {
    $code | Set-Clipboard
}
