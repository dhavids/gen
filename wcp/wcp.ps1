# wcp.ps1 — minimal upload wrapper with a compact roundtrip code, for Windows.
#
# USAGE:
#   wcp path\to\file.txt        # upload -> prints a short code, e.g. "aAbCd.txt"
#   wcp some words here         # not a file -> uploaded as text, prints a code
#   Get-Content file.txt | wcp  # no args -> reads stdin, prints a code
#   wcp aAbCd.txt                # retrieve: decodes backend + id from the code
#                                #   text  -> printed to stdout
#                                #   file  -> saved in the current folder with
#                                #            its original filename
#   wcp get <full-url> [-o file] # retrieve by a full URL instead of a code
#
# The first character of the printed code is the backend letter; everything
# after it is that backend's own ID for the upload:
#   a = 0x0          (default fetch host https://0x0.st)
#   b = transfer.sh  (default fetch host https://transfer.sh)
#   c = catbox       (default fetch host https://files.catbox.moe — note this
#                     differs from catbox's upload endpoint, catbox.moe)
#
# --backend / --host work for both directions: on upload they choose/override
# which service and endpoint is used; on retrieval, --host overrides the
# default fetch host for the decoded backend letter.
#
# Collision handling: a single word that happens to start with a known
# backend letter (e.g. `wcp aeroplane`) looks like a code. wcp tries
# retrieval first; if that 404s, it falls back to uploading the word as text.
#
# Requires curl.exe (bundled with Windows 10+ by default).

$ErrorActionPreference = "Stop"

$DefaultUploadHost0x0 = "https://0x0.st"
$DefaultUploadHostTransferSh = "https://transfer.sh"
$DefaultUploadHostCatbox = "https://catbox.moe/user/api.php"
$DefaultFetchHost0x0 = "https://0x0.st"
$DefaultFetchHostTransferSh = "https://transfer.sh"
$DefaultFetchHostCatbox = "https://files.catbox.moe"

function Get-LetterForBackend([string]$Backend) {
    switch ($Backend) {
        "0x0"         { return "a" }
        "transfer.sh" { return "b" }
        "catbox"      { return "c" }
    }
}

function Get-DefaultFetchHostForLetter([string]$Letter) {
    switch ($Letter) {
        "a" { return $DefaultFetchHost0x0 }
        "b" { return $DefaultFetchHostTransferSh }
        "c" { return $DefaultFetchHostCatbox }
        default { return $null }
    }
}

function Get-IdFromUrl([string]$Url) {
    $noScheme = $Url -replace '^https?://', ''
    $slashIndex = $noScheme.IndexOf('/')
    if ($slashIndex -lt 0) { return "" }
    return $noScheme.Substring($slashIndex + 1)
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
            Move-Item -Force $bodyFile "./$fname"
            Write-Output "Saved as $fname"
        }
        return $true
    } finally {
        Remove-Item $hdrFile -ErrorAction SilentlyContinue
        Remove-Item $bodyFile -ErrorAction SilentlyContinue
    }
}

# --- "get" subcommand: fetch back a URL directly ----------------------------
if ($args.Count -gt 0 -and $args[0] -eq "get") {
    $rest2 = $args[1..($args.Count - 1)]
    $OutFile = $null
    $Url = $null
    $j = 0
    while ($j -lt $rest2.Count) {
        if ($rest2[$j] -eq "-o" -or $rest2[$j] -eq "--output") {
            $OutFile = $rest2[$j + 1]; $j += 2
        } else {
            $Url = $rest2[$j]; $j += 1
        }
    }
    if ([string]::IsNullOrEmpty($Url)) {
        Write-Error "Usage: wcp get <url> [-o outputfile]"
        exit 1
    }
    if (-not (Invoke-Retrieve $Url $OutFile)) {
        Write-Error "Failed to fetch $Url"
        exit 1
    }
    exit 0
}

# --- parse flags once, for both upload and retrieval paths ------------------
$Backend = "0x0"
$UploadHost = ""
$DoCopy = $false
$rest = @()

$i = 0
while ($i -lt $args.Count) {
    $a = $args[$i]
    if ($a -eq "--backend") {
        $Backend = $args[$i + 1]; $i += 2
    } elseif ($a -like "--backend=*") {
        $Backend = $a.Substring(10); $i += 1
    } elseif ($a -eq "--host") {
        $UploadHost = $args[$i + 1]; $i += 2
    } elseif ($a -like "--host=*") {
        $UploadHost = $a.Substring(7); $i += 1
    } elseif ($a -eq "--copy") {
        $DoCopy = $true; $i += 1
    } else {
        $rest += $a; $i += 1
    }
}

# --- short-code retrieval: single token starting with a known backend ------
# letter, at least 2 characters, and not an existing local file.
if ($rest.Count -eq 1 -and -not (Test-Path -LiteralPath $rest[0] -PathType Leaf)) {
    $Candidate = $rest[0]
    $Letter = $Candidate.Substring(0, 1)
    $Id = $Candidate.Substring(1)
    if ($Id.Length -gt 0) {
        if ($UploadHost) {
            $FetchHost = $UploadHost
            $ValidLetter = $true
        } else {
            $FetchHost = Get-DefaultFetchHostForLetter $Letter
            $ValidLetter = -not [string]::IsNullOrEmpty($FetchHost)
        }
        if ($ValidLetter) {
            $fetchUrl = "$($FetchHost.TrimEnd('/'))/$Id"
            if (Invoke-Retrieve $fetchUrl $null) {
                exit 0
            }
            # else: fall through to normal upload handling below, treating
            # $Candidate as text to upload.
        }
    }
}

switch ($Backend) {
    "0x0"         { $DefaultHost = $DefaultUploadHost0x0 }
    "transfer.sh" { $DefaultHost = $DefaultUploadHostTransferSh }
    "catbox"      { $DefaultHost = $DefaultUploadHostCatbox }
    default {
        Write-Error "Unknown backend: $Backend (expected: 0x0, transfer.sh, catbox)"
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

function Upload-0x0([string]$Kind, [string]$Arg) {
    switch ($Kind) {
        "file"  { return & curl.exe -sS -F "file=@$Arg" $UploadHost }
        "text"  {
            $tmp = Write-TempFile $Arg
            try { return & curl.exe -sS -F "file=@$tmp" $UploadHost }
            finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
        "stdin" {
            $content = [Console]::In.ReadToEnd()
            $tmp = Write-TempFile $content
            try { return & curl.exe -sS -F "file=@$tmp" $UploadHost }
            finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
    }
}

function Upload-TransferSh([string]$Kind, [string]$Arg) {
    switch ($Kind) {
        "file"  {
            $name = Split-Path -Leaf $Arg
            return & curl.exe -sS -T $Arg "$UploadHost/$name"
        }
        "text"  {
            $tmp = Write-TempFile $Arg
            try { return & curl.exe -sS -T $tmp "$UploadHost/paste.txt" }
            finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
        "stdin" {
            $content = [Console]::In.ReadToEnd()
            $tmp = Write-TempFile $content
            try { return & curl.exe -sS -T $tmp "$UploadHost/paste.txt" }
            finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        }
    }
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

function Dispatch([string]$Kind, [string]$Arg) {
    switch ($Backend) {
        "0x0"         { return Upload-0x0 $Kind $Arg }
        "transfer.sh" { return Upload-TransferSh $Kind $Arg }
        "catbox"      { return Upload-Catbox $Kind $Arg }
    }
}

if ($rest.Count -eq 0 -or ($rest.Count -eq 1 -and $rest[0] -eq "-")) {
    $result = Dispatch "stdin" ""
} elseif ($rest.Count -eq 1 -and (Test-Path -LiteralPath $rest[0] -PathType Leaf)) {
    $result = Dispatch "file" $rest[0]
} else {
    $text = $rest -join ' '
    $result = Dispatch "text" $text
}

$letter = Get-LetterForBackend $Backend
$id = Get-IdFromUrl $result
$code = "$letter$id"

Write-Output $code

if ($DoCopy) {
    $code | Set-Clipboard
}