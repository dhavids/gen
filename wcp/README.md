# wcp — minimal upload wrapper (multi-backend, roundtrip codes)

`wcp` uploads a file, some text, or stdin, and prints back a **short code**. Give that same code back to `wcp` later to retrieve it — text is printed to stdout, files are saved into the current folder under the server-generated name.

**To keep the original filename, upload with `-e`** (any file up to 1 MB). A plain upload only keeps the extension, because the host names the file. See [Encryption](#encryption).

```bash
wcp this is a note
# -> bes0x4x

wcp bes0x4x
# -> this is a note

wcp report.pdf
# -> mnh9s3s

wcp mnh9s3s
# -> Saved as nh9s3s.pdf

wcp mnh9s3s -o report.pdf
# -> Saved to report.pdf

wcp -e notes.csv
# -> bbf2r86-QHq1DLMGnKFm

wcp bbf2r86-QHq1DLMGnKFm
# -> Saved as notes.csv
```

**Files in this folder:**
- `setup` — run this first on Linux/macOS/WSL; detects your OS and installs `wcp`
- `setup.ps1` — native Windows installer, for PowerShell with no bash or WSL
- `wcp` — the Linux/macOS/WSL script
- `wcp.ps1` — the Windows PowerShell script
- `README.md` — this file

## How the code works

The prefix character encodes the backend and the file extension together. Lowercase means litterbox, uppercase means catbox, and the letter's position in the alphabet is the index into this list:

```
  a/A (none)   f/F .yaml   k/K .png
  b/B .txt     g/G .csv    l/L .jpg
  c/C .md      h/H .conf   m/M .pdf
  d/D .log     i/I .sh     n/N .zip
  e/E .json    j/J .py     o/O .gz

  0 / 1  extension not in the list (literal .ext follows the id)
```

Extensions that use the escape path (longer codes with literal `.ext`):
js, ts, html, css, toml, xml, gif, webp, mp4, tar, pcap

So `b0ojyr4` is litterbox + `.txt`, and `B96k8z8` is catbox + `.txt`.

On retrieval, `wcp` decodes the first character to pick the backend and extension, prepends the matching fetch host to the reconstructed id, and fetches that URL. It decides text-vs-file by checking the response's `Content-Type` header (`text/*` → print; anything else → save as a file).

When text is printed **to a terminal**, `wcp` adds a trailing newline if the content lacks one, so your prompt starts on its own line. When the output is **redirected or piped** it emits the stored bytes untouched, so `wcp [code] > file` reproduces the original exactly.

**Never overwrites:** when a retrieval saves a file and that name is already taken, `wcp` inserts `_1`, `_2` and so on before the extension (`nh9s3s.pdf` → `nh9s3s_1.pdf`) and prints the name it actually used. This applies to `-o [file]` too, so a retrieval can never destroy an existing file.

**Collision handling:** a candidate of **7 characters or fewer** that looks like a code (valid prefix, alphanumeric remainder) is tried as a retrieval first; if that 404s it falls back to uploading it as text. **Longer** candidates are only tried as codes if they contain a `.` or a `-`, so an ordinary long word is uploaded immediately with no wasted request. (A `.` appears in escape-path codes, a `-` in encrypted ones.) If a local file shares the name of a code you want, use `wcp . [code]` to force retrieval — the explicit form never checks for local files.

## Backends (for uploading)

`--backend` (or `-b`) selects which service's API to use for uploads (default: `litterbox`). `--host` overrides that backend's endpoint — and on retrieval, overrides the fetch host used to decode a code. `-t [hours]` sets the litterbox expiry in whole hours. Catbox ignores it, having no expiry.

| Backend | Default upload host | Notes |
|---|---|---|
| `catbox` | `https://catbox.moe/user/api.php` | Multipart POST with `reqtype=fileupload`. Permanent storage. |
| `litterbox` (default) | `https://litterbox.catbox.moe/resources/internals/api.php` | Multipart POST with `reqtype=fileupload` + `time`. Codes expire after the chosen window (1h/12h/24h/72h, default 1h, max 72h). |

## Usage

`wcp -h` prints the full list of forms and flags. It is generated from the script
itself, so it is always current — the canonical source is the `usage()` block in
[`wcp`](wcp), and [`wcp.ps1`](wcp.ps1) for the PowerShell build.

```bash
wcp -h                                     # full usage
wcp                                        # bare: reads stdin, for multi-line text
wcp . brbkswy                              # retrieve; error on a miss instead of uploading
wcp -b c path/to/file.txt                  # catbox (permanent, encrypted by default)
wcp -t 24 some text                        # litterbox expiry in hours
wcp -e -k 32 secret.txt                    # longer encryption key
wcp -n some text                           # do not copy the code to the clipboard
wcp -v                                     # upload the clipboard contents
```

The sections below cover the parts that need more than a one-line description.

### Encryption

Encryption is client-side: AES-256-CBC with a random 12-character key. The key is **never uploaded** — only ciphertext reaches the server, so the host stores data it cannot read. An encrypted code is `CODE-KEY` (e.g. `B68845i-arclfBzz13Wy`), about 20 characters instead of 7.

**Whether it happens by default depends on the backend:**

| Situation | Result |
|---|---|
| `litterbox` (the default backend) | **plain** — it expires, so the exposure window is short |
| `catbox`, or any other backend | **encrypted** |
| `-e` / `--encrypt` | forces encryption on any backend |
| `--plain` / `-p`, or `WCP_PLAIN=1` | forces it off |

If `openssl` is missing, an explicit `-e` is a hard error, while the implicit default for a non-litterbox backend degrades to a plain upload with a warning on stderr naming the backend. Asking for encryption never silently gives you plaintext; missing a default you did not ask for only warns.

**What gets encrypted:**
- Text and stdin: always encrypted
- Files: encrypted if at most 1 MB (1048576 bytes), whatever the file type
- Larger files upload unencrypted with a warning to stderr (e.g. `wcp: not encrypting big2m.bin - 2 MB over the 1 MB limit, uploading as-is`)

**Filename preservation — the reason to use `-e` on files.** A plain upload loses the original name: the host generates the id and keeps only the extension, so `quarterly-report.csv` comes back as `fdjzla.csv`. Encrypting puts a `wcp-name:` header inside the ciphertext, so the name survives:

```bash
wcp quarterly-report.csv       # -> gfdjzla
wcp gfdjzla                    # -> Saved as fdjzla.csv

wcp -e quarterly-report.csv    # -> bbf2r86-QHq1DLMGnKFm
wcp bbf2r86-QHq1DLMGnKFm       # -> Saved as quarterly-report.csv
```

Text and stdin uploads get no header — there is no filename to keep. The trade-off is that an encrypted upload is no longer a directly shareable link: the bytes at the URL are ciphertext, not your file.

**Key length** defaults to 12 characters (~71 bits). Adjust it with `-k [n]`, `--key-len [n]`, or `WCP_KEY_LEN` — anything from 12 to 64:

| `-k` | Entropy | Code length |
|---|---|---|
| 12 (default) | ~71 bits | 20 |
| 16 | ~95 bits | 24 |
| 22 | ~131 bits | 30 |
| 32 | ~190 bits | 40 |

Values below 12 or above 64 are rejected rather than silently accepted — 8 characters is only ~48 bits, which is brute-forceable against ciphertext someone already holds.

Retrieval never needs `-k`: the key travels inside the code, so `wcp` uses whatever length is there.

**Losing the key loses the data permanently.** There is no recovery.


### Explicit retrieval: `wcp . [code|url]`

This form always retrieves — it never checks for a local file of that name, and it never falls back to uploading on failure. If the code is wrong or expired you get a clear error, instead of the code string being silently uploaded as text and handing you a fresh code.

It accepts a full URL as well as a code: anything starting with `http://` or `https://` is fetched directly.

`-o [file]` saves the result under a name you choose, and implies an explicit retrieval on its own — `wcp [code] -o [file]` needs no leading dot.

### Backend aliases

`-b` is a short form of `--backend`. It accepts full backend names or one-letter aliases that match the **first letter of the backend name**:

| Alias | Backend |
|---|---|
| `c` | catbox |
| `l` | litterbox |

Note: these aliases follow the **backend name**, not the code prefix letters. Code prefixes encode both backend and extension, so they are a different concept.

## Dependencies

**Required**

| | Used for |
|---|---|
| `curl` (`curl.exe` on Windows) | every upload and retrieval |
| `bash`, or PowerShell 5.1+ on Windows | running the scripts |

`curl.exe` and PowerShell 5.1 both ship with Windows 10 (1803+) and Windows 11.

**Optional**

| | Used for | Without it |
|---|---|---|
| `openssl` | encryption | `-e` errors; a non-litterbox default warns and uploads plain |
| `pbcopy`, `xclip`, or `wl-copy` | copying the code to the clipboard | nothing is copied |
| `pbpaste`, `xclip`, or `wl-paste` | `-v` uploads the clipboard | `-v` errors |

Clipboard tools are tried in that order, and must match the running display server — `wl-copy` needs Wayland, `xclip` and `xsel` need X11. An SSH session has neither; use `wcp` -> `<your text>` -> Ctrl+D there.

The code is copied automatically when `wcp` runs in a terminal, and not when its output is redirected or captured, so `C=$(wcp file.txt)` leaves your clipboard alone. `-c` copies anyway, `-n` or `WCP_NO_COPY=1` never does. With no usable tool the automatic copy is skipped silently; `-c` names the package to install.

## Install

Run the installer once. Pick the one that matches your shell — both install `wcp` and offer to put it on your `PATH`.

**Linux, macOS, WSL, or Windows with Git Bash / MSYS2:**

```bash
bash setup
```

**Windows PowerShell with no bash or WSL:**

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

- **Linux / macOS / WSL:** installs `wcp` to `/usr/local/bin/wcp` (or `~/.local/bin/wcp` if that isn't writable) and makes it executable. If that folder isn't on your `PATH`, it asks before adding a line to your shell profile — `~/.zshrc` for zsh, `~/.bashrc` for bash (or `~/.bash_profile` if you have no `~/.bashrc`), `~/.profile` otherwise. It is idempotent and prints the file it used.

  The line it adds is wrapped in `# >>> wcp >>>` / `# <<< wcp <<<` markers. To remove it:

  ```bash
  sed -i '/^# >>> wcp >>>$/,/^# <<< wcp <<<$/d' ~/.bashrc
  ```

  When run non-interactively, it leaves your profile alone and prints the line for you to add yourself.
- **Windows (via Git Bash, MSYS2, or similar):** `bash setup` installs `wcp.ps1` and a `wcp.cmd` launcher (so plain `wcp` works from cmd.exe, PowerShell, or Git Bash) into `%USERPROFILE%\bin`, and adds that folder to your user `PATH` automatically if `powershell.exe` is reachable.
- **Windows PowerShell, no bash or WSL:** `setup.ps1` does the same natively — installs `wcp.ps1` and `wcp.cmd` into `%USERPROFILE%\bin`, and asks before adding that folder to your user `PATH`. It prints the command to undo that.

  A new terminal picks up the `PATH` change. To use it in the one you are already in:

  ```powershell
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
  ```

After running it, test with:
```bash
wcp hello world
```

### Manual install (if you don't have bash to run `setup`, or want to install by hand)

**Linux / macOS:**
```bash
chmod +x wcp
sudo mv wcp /usr/local/bin/wcp
```

**Windows (PowerShell):**
```powershell
mkdir $env:USERPROFILE\bin -Force
Copy-Item wcp.ps1 $env:USERPROFILE\bin\wcp.ps1
$p = [Environment]::GetEnvironmentVariable("Path", "User")
[Environment]::SetEnvironmentVariable("Path", "$p;$env:USERPROFILE\bin", "User")
```
Read the **User**-scoped PATH, not `$env:Path` — that is the combined machine+user value, and writing it back duplicates your whole system PATH into your user variable.

**Making `wcp` callable without typing `.ps1`:** PowerShell requires an explicit extension for scripts by default. Either call it as `wcp.ps1 <args>`, or create the same thin `wcp.cmd` wrapper that `setup` would have created for you:
```
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wcp.ps1" %*
```

**Note on PowerShell execution policy:** if running the `.ps1` directly (not via the `.cmd` wrapper above) hits a script-execution-disabled error, either use the `.cmd` wrapper (which bypasses it per-invocation) or run once as admin: `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`.

## Notes

- All scripts (bash, PowerShell) do the same three-way decision for uploads: **single existing file** → upload as file; **stdin with no args** → upload stdin; **anything else (including multiple words)** → joined with a space and uploaded as text.
- If you uploaded with a custom `--host` (a self-hosted instance), retrieving that code later also needs the same `--host` — without it, retrieval falls back to the public default for that backend letter and won't find your self-hosted copy.

## Environment variables

- `WCP_BACKEND` — upload backend (default: `litterbox`)
- `WCP_TIME` — litterbox expiry in whole hours (default: 1)
- `WCP_PLAIN` — set to `1` to disable encryption
- `WCP_KEY_LEN` — encryption key length (default: 12)
