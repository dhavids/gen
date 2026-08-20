# wcp.ps1 — minimal upload wrapper with a compact roundtrip code, for Windows.
#
# USAGE:
#   wcp path\to\file.txt        # upload -> prints a short code, e.g. "brbkswy"
#   wcp some words here         # not a file -> uploaded as text, prints a code
#   Get-Content file.txt | wcp  # no args -> reads stdin, prints a code
#   wcp brbkswy                 # retrieve (implicit): may fall back to uploading
#   wcp . brbkswy               # retrieve (explicit): errors instead of falling back
#   wcp get brbkswy             # retrieve (explicit): same as above
#   wcp get <full-url> [-o file] # retrieve by a full URL instead of a code
#
# Retrieved text prints to stdout; retrieved files are saved into the current
# folder. Existing files are never overwritten — _1, _2 are appended and the
# name actually used is printed.
#
# The first character of the printed code encodes BOTH the backend and the
# file extension. Lowercase a-o = litterbox, uppercase A-O = catbox.
# Digits 0/1 mean the extension is not in the built-in table (the literal
# .ext follows the prefix). A typical code is 7 characters long.
# Letters p-z, P-Z and digits 2-9 are reserved for a future third backend.
#
# Old-format codes with a literal extension (e.g. aAbCd.txt, c96k8z8.txt)
# still resolve correctly for backward compatibility.
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
# old-format codes carry a dot, encrypted codes a dash), so an ordinary long
# word is uploaded straight away with no wasted request.
#
# Encryption is NOT implemented in this PowerShell version. litterbox (the
# default backend) is plain, so normal use works. Targeting catbox, passing -e,
# or retrieving a code containing a - all error out; use --plain / -p for
# catbox. Short aliases: -b backend, -c copy, -p plain, -t time.
#
# Requires curl.exe (bundled with Windows 10+ by default).

$ErrorActionPreference = "Stop"

$DefaultUploadHostCatbox = "https://catbox.moe/user/api.php"
$DefaultFetchHostCatbox = "https://files.catbox.moe"
$DefaultUploadHostLitterbox = "https://litterbox.catbox.moe/resources/internals/api.php"
$DefaultFetchHostLitterbox = "https://litter.catbox.moe"
$DefaultLitterboxTime = "1h"

# Extension table: index 0 = no extension, 1..14 = common extensions.
$ExtTable = @("", "txt", "md", "log", "json", "yaml", "csv", "conf", "sh", "py", "png", "jpg", "pdf", "zip", "gz")

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

    # Backward compatibility: old-format codes with a literal dot
    if (($letter -eq "a" -or $letter -eq "c") -and $rest.Contains(".")) {
        $script:DecodeBackend = if ($letter -eq "a") { "litterbox" } else { "catbox" }
        $script:DecodeId = $rest
        $script:DecodeFetchHost = ""
        return $true
    }

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

# --- retrieval: given a full URL, print (text) or save (file) --------------

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
            Move-Item -Force $bodyFile $OverrideOut
            Write-Output "Saved to $OverrideOut"
        } elseif ($ctype -like "text/*") {
            Get-Content -Raw $bodyFile
        } else {
            $fname = Split-Path -Leaf ($Url -replace '\?.*$', '')
            if ([string]::IsNullOrEmpty($fname)) { $fname = "downloaded_file" }
            $target = Get-UniqueSaveName "./$fname"
            Move-Item -Force $bodyFile $target
            Write-Output "Saved as $(Split-Path -Leaf $target)"
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
  wcp get <code|url> [-o file]   retrieve explicitly

Options:
  -b, --backend <name>   litterbox (default) or catbox; -b l / -b c also work
      --host <url>       override the backend endpoint, or the fetch host
  -t, --time <hours>     litterbox expiry, rounds up to 1/12/24/72 (default 1)
  -p, --plain            upload without encryption
  -c, --copy             copy the resulting code to the clipboard
  -v, --paste            upload the clipboard contents (takes no arguments)
  -h, --help             show this help

Encryption is NOT implemented in this PowerShell version. litterbox (the
default) is plain, so normal use works. Targeting catbox, passing -e, or
retrieving a code containing a - all error out; use --plain for catbox.

Env: WCP_BACKEND, WCP_TIME (whole hours), WCP_PLAIN=1
"@
}

# --- parse flags once, for both upload and retrieval paths ------------------

$Backend = if ($env:WCP_BACKEND) { $env:WCP_BACKEND } else { "litterbox" }
$LbHours = if ($env:WCP_TIME) { $env:WCP_TIME } else { 1 }
$UploadHost = ""
$DoCopy = $false
$Plain = $false
$DoPaste = $false
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
    } elseif ($a -eq "-h" -or $a -eq "--help") {
        Show-Usage
        exit 0
    } elseif ($a -eq "-p" -or $a -eq "--plain") {
        $Plain = $true; $i += 1
    } elseif ($a -eq "-e" -or $a -eq "--encrypt") {
        Write-Error "wcp: -e is not yet supported in the PowerShell version"
        exit 1
    } else {
        $rest += $a; $i += 1
    }
}

if ($env:WCP_PLAIN -eq "1") { $Plain = $true }

$LbTime = Convert-LitterboxTimeBucket $LbHours

function Do-ExplicitRetrieve([string]$Code) {
    if ($Code -cmatch '^[a-oA-O01][0-9a-zA-Z]{6}-[0-9a-zA-Z]+$') {
        Write-Error "wcp: encrypted codes are not yet supported in the PowerShell version"
        exit 1
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
    $fetchHost = if ($UploadHost) { $UploadHost } elseif ($backendName -eq "catbox") { $DefaultFetchHostCatbox } else { $DefaultFetchHostLitterbox }

    # Decode the code to get the ID
    if (-not (Decode-Code $Code)) {
        Write-Error "wcp: '$Code' is not a valid code (unknown prefix '$letter')"
        return $false
    }

    $fetchUrl = "$($fetchHost.TrimEnd('/'))/$DecodeId"
    if (-not (Invoke-Retrieve $fetchUrl $null)) {
        Write-Error "wcp: no such code '$Code' ($backendName, $extStr)"
        Write-Error "wcp: $backendName codes expire — the default window is 1h"
        return $false
    }
    return $true
}

# --- explicit retrieval: wcp . [code] or wcp get [code/url] ----------------

# Check for encrypted code (contains '-')
if ($rest.Count -gt 1 -and $rest[1].Contains("-")) {
    Write-Error "wcp: encrypted codes are not yet supported in the PowerShell version"
    exit 1
}

if ($rest.Count -gt 0 -and $rest[0] -eq ".") {
    if ($rest.Count -lt 2) {
        Write-Error "wcp: . needs a code, e.g. wcp . b0ojyr4"
        exit 1
    }
    if (-not (Do-ExplicitRetrieve $rest[1])) {
        exit 1
    }
    exit 0
}

if ($rest.Count -gt 0 -and $rest[0] -eq "get") {
    # Check for encrypted code in get form
    for ($j = 1; $j -lt $rest.Count; $j++) {
        if ($rest[$j] -ne "-o" -and $rest[$j] -ne "--output" -and $rest[$j].Contains("-")) {
            Write-Error "wcp: encrypted codes are not yet supported in the PowerShell version"
            exit 1
        }
    }
    $OutFile = $null
    $Url = $null
    $j = 1
    while ($j -lt $rest.Count) {
        if ($rest[$j] -eq "-o" -or $rest[$j] -eq "--output") {
            $OutFile = $rest[$j + 1]; $j += 2
        } else {
            $Url = $rest[$j]; $j += 1
        }
    }
    if ([string]::IsNullOrEmpty($Url)) {
        Write-Error "Usage: wcp get <url|code> [-o outputfile]"
        exit 1
    }
    # Distinguish URL from code by scheme
    if ($Url -match '^https?://') {
        if (-not (Invoke-Retrieve $Url $OutFile)) {
            Write-Error "wcp: failed to fetch $Url"
            exit 1
        }
    } else {
        if (-not (Do-ExplicitRetrieve $Url)) {
            exit 1
        }
    }
    exit 0
}

# --- short-code retrieval: single token, not an existing local file --------

if ($rest.Count -eq 1 -and -not (Test-Path -LiteralPath $rest[0] -PathType Leaf)) {
    if ($rest[0].Contains("-")) {
        Write-Error "wcp: encrypted codes are not yet supported in the PowerShell version"
        exit 1
    }
    $Candidate = $rest[0]
    $Letter = $Candidate.Substring(0, 1)
    $RestPart = $Candidate.Substring(1)

    if ($Candidate -cmatch '^[a-oA-O01][0-9a-zA-Z]{6}-[0-9a-zA-Z]+$') {
        Write-Error "wcp: encrypted codes are not yet supported in the PowerShell version"
        exit 1
    }

    if (Decode-Code $Candidate) {
        # Short candidates may be codes; longer ones only if they carry a dot.
        if ($Candidate.Length -le 7 -and $RestPart -cmatch '^[0-9a-zA-Z]+$') {
            $FetchHost = if ($UploadHost) { $UploadHost } elseif ($DecodeBackend -eq "catbox") { $DefaultFetchHostCatbox } else { $DefaultFetchHostLitterbox }
            $fetchUrl = "$($FetchHost.TrimEnd('/'))/$DecodeId"
            if (Invoke-Retrieve $fetchUrl $null) {
                exit 0
            }
        } elseif ($Candidate.Contains(".")) {
            # Backward-compat old-format code
            $FetchHost = if ($UploadHost) { $UploadHost } elseif ($DecodeBackend -eq "catbox") { $DefaultFetchHostCatbox } else { $DefaultFetchHostLitterbox }
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
    $tmp = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
    return $tmp
}

function Upload-Catbox([string]$Kind, [string]$Arg) {
    switch ($Kind) {
        "file"  {
            return & curl.exe -sS -F "reqtype=fileupload" -F "fileToUpload=@$Arg" $UploadHost
        }
        "text"  {
            $tmp = Write-TempFile $Arg
            try { return & curl.exe -sS -F "reqtype=fileupload" -F "fileToUpload=@$tmp" $UploadHost }
            finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
        "stdin" {
            $content = [Console]::In.ReadToEnd()
            $tmp = Write-TempFile $content
            try { return & curl.exe -sS -F "reqtype=fileupload" -F "fileToUpload=@$tmp" $UploadHost }
            finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
    }
}

function Upload-Litterbox([string]$Kind, [string]$Arg) {
    switch ($Kind) {
        "file"  {
            return & curl.exe -sS -F "reqtype=fileupload" -F "time=$LbTime" -F "fileToUpload=@$Arg" $UploadHost
        }
        "text"  {
            $tmp = Write-TempFile $Arg
            try { return & curl.exe -sS -F "reqtype=fileupload" -F "time=$LbTime" -F "fileToUpload=@$tmp" $UploadHost }
            finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
        "stdin" {
            $content = [Console]::In.ReadToEnd()
            $tmp = Write-TempFile $content
            try { return & curl.exe -sS -F "reqtype=fileupload" -F "time=$LbTime" -F "fileToUpload=@$tmp" $UploadHost }
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
        Write-Error "wcp: clipboard is empty — nothing to upload"
        exit 1
    }
    $PasteContent = $clip
}

if (-not $Plain -and $Backend -ne "litterbox") {
    Write-Error "wcp: $Backend uploads are encrypted by default, which is not yet supported in the PowerShell version"
    Write-Error "wcp: use --plain (-p) to upload without encryption"
    exit 1
}

if ($DoPaste) {
    $result = Dispatch "text" $PasteContent
} elseif ($rest.Count -eq 0 -or ($rest.Count -eq 1 -and $rest[0] -eq "-")) {
    $result = Dispatch "stdin" ""
} elseif ($rest.Count -eq 1 -and (Test-Path -LiteralPath $rest[0] -PathType Leaf)) {
    $result = Dispatch "file" $rest[0]
} else {
    $text = $rest -join ' '
    $result = Dispatch "text" $text
}

if ($result -notmatch '^https?://\S+$') {
    Write-Error "wcp: upload failed on backend '$Backend' ($UploadHost)"
    Write-Error "wcp: backend replied: $(if ($result) { $result } else { '<empty response>' })"
    exit 1
}

$idFull = Get-IdFromUrl $result
$code = Encode-Id $idFull $Backend

Write-Output $code

if ($DoCopy) {
    $code | Set-Clipboard
}
