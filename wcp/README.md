# wcp — minimal upload wrapper (multi-backend, roundtrip codes)

`wcp` uploads a file, some text, or stdin, and prints back a **short code**. Give that same code back to `wcp` later to retrieve it — text is printed to stdout, files are saved into the current folder under the server-generated name.

```bash
wcp report.pdf
# -> QXyZ123

wcp QXyZ123
# -> Saved as report.pdf
```

**Files in this folder:**
- `setup` — run this first; detects your OS and installs `wcp` to the right place
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

**Backward compatibility:** old-format codes with a literal extension (e.g. `aAbCd.txt`, `c96k8z8.txt`) still resolve correctly. These are detected by the presence of a dot after an `a` or `c` prefix.

On retrieval, `wcp` decodes the first character to pick the backend and extension, prepends the matching fetch host to the reconstructed id, and fetches that URL. It decides text-vs-file by checking the response's `Content-Type` header (`text/*` → print; anything else → save as a file).

When text is printed **to a terminal**, `wcp` adds a trailing newline if the content lacks one, so your prompt starts on its own line. When the output is **redirected or piped** it emits the stored bytes untouched, so `wcp [code] > file` reproduces the original exactly.

**Never overwrites:** when a retrieval saves a file and that name is already taken, `wcp` inserts `_1`, `_2` and so on before the extension (`report.md` → `report_1.md`) and prints the name it actually used. `wcp get [url] -o [file]` is exempt — an explicit `-o` means you named the file yourself, so it overwrites.

**Collision handling:** a candidate of **7 characters or fewer** that looks like a code (valid prefix, alphanumeric remainder) is tried as a retrieval first; if that 404s it falls back to uploading it as text. **Longer** candidates are only tried as codes if they contain a `.` or a `-`, so an ordinary long word is uploaded immediately with no wasted request. (A `.` appears in escape-path and old-format codes, a `-` in encrypted ones.) If a local file shares the name of a code you want, use `wcp . [code]` to force retrieval — the explicit form never checks for local files.

## Backends (for uploading)

`--backend` (or `-b`) selects which service's API to use for uploads (default: `litterbox`). `--host` overrides that backend's endpoint — and on retrieval, overrides the fetch host used to decode a code. `-t [hours]` sets the litterbox expiry in whole hours, rounding UP to the nearest of 1h/12h/24h/72h (default 1h, max 72h). Catbox ignores `-t` because catbox never expires.

| Backend | Default upload host | Notes |
|---|---|---|
| `catbox` | `https://catbox.moe/user/api.php` | Multipart POST with `reqtype=fileupload`. Permanent storage. |
| `litterbox` (default) | `https://litterbox.catbox.moe/resources/internals/api.php` | Multipart POST with `reqtype=fileupload` + `time`. Codes expire after the chosen window (1h/12h/24h/72h, default 1h, max 72h). |

## Usage

```bash
wcp path/to/file.txt                       # single existing file -> uploaded as-is, prints a code
wcp some words here                        # not a file -> joined with spaces, uploaded as text, prints a code
echo "text" | wcp                          # no args -> reads stdin, prints a code
wcp brbkswy                                # retrieve by code (implicit) -> saves or prints depending on type
wcp . brbkswy                              # retrieve by code (explicit) -> always retrieves, never falls back to upload
wcp get brbkswy                            # retrieve by code (explicit) -> same as above
wcp get https://files.catbox.moe/AbCd.txt  # retrieve by a full URL instead of a code
wcp get https://files.catbox.moe/AbCd.txt -o out.txt # ...and save it under a specific name
wcp --backend catbox path/to/file.txt      # use catbox for permanent storage
wcp -b c path/to/file.txt                  # same, using short alias
wcp -b l some text                         # litterbox with short alias
wcp -t 24 some text                        # litterbox with 24-hour expiry (rounds up to 24h)
WCP_BACKEND=catbox wcp hello               # env var to pick backend
WCP_TIME=24 wcp hello                      # env var to pick litterbox expiry (whole hours, default 1)
wcp --copy some text                       # also copy the resulting code to clipboard
wcp -c some text                           # same, using short alias
wcp -e hello world                         # force encryption -> prints CODE-KEY
wcp -b c some text                         # catbox: encrypted by default
wcp -p -b c some text                      # catbox without encryption
WCP_PLAIN=1 wcp -b c hello                 # env var to disable encryption
wcp B68845i-arclfBzz13Wy                   # retrieve encrypted code -> decrypts and prints/saves
```

### Encryption

Encryption is client-side: AES-256-CBC with a random 12-character key. The key is **never uploaded** — only ciphertext reaches the server, so the host stores data it cannot read. An encrypted code is `CODE-KEY` (e.g. `B68845i-arclfBzz13Wy`), about 20 characters instead of 7. That is ~71 bits of key, against ciphertext an attacker must first obtain by enumerating the host.

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
- Files: encrypted only if (a) the file is text (detected via `file -b --mime-type`), and (b) the file is at most 100 KB (102400 bytes)
- If a file fails either condition, it uploads unencrypted with a clear warning to stderr (e.g. `wcp: not encrypting report.pdf — not a text file, uploading as-is`)

**Filename preservation:** When encrypting a file, wcp prepends a `wcp-name:filename` header so the original name can be recovered on decryption. Text/stdin uploads do not get this header.

**Losing the key loses the data permanently.** There is no recovery.

**What `-e` protects against:**
- Someone enumerating the host's id space
- Anyone who sees the storage URL without the code (host operator, CDN or server logs)

**What `-e` does NOT protect against:**
- The code itself leaking — the key is part of the code, so anyone holding the full `CODE-KEY` string can read the content

**Requirements:** `openssl` must be installed. If missing, wcp exits with an error.

**Note:** `-e` is not yet supported in `wcp.ps1` (PowerShell/Windows).

### Explicit retrieval: `wcp . [code]` and `wcp get [code]`

These two forms always retrieve — they never check for a local file of that name, and they never fall back to uploading on failure. If the code is wrong or expired, you get a clear error instead of silently uploading the code string as text and getting a fresh code back. This is the safe way to retrieve when you know you have a code.

`wcp get [url]` with a full URL (starting with `http://` or `https://`) still works as before. Anything without a scheme is treated as a code.

The implicit form (`wcp [code]`) is unchanged — it still falls back to uploading on 404. Use the explicit forms when you want a hard error on a bad code instead of a silent upload.

### Backend aliases

`-b` is a short form of `--backend`. It accepts full backend names or one-letter aliases that match the **first letter of the backend name**:

| Alias | Backend |
|---|---|
| `c` | catbox |
| `l` | litterbox |

Note: these aliases follow the **backend name**, not the code prefix letters. Code prefixes encode both backend and extension, so they are a different concept.

## Install

Run `setup` once — it detects your OS and installs `wcp` to the right place automatically:

```bash
bash setup
```

- **Linux / macOS / WSL:** installs the bash `wcp` script to `/usr/local/bin/wcp` (or `~/.local/bin/wcp` as a fallback if that's not writable) and makes it executable. If that folder isn't on your `PATH`, it asks whether to add it and, if you agree, appends the line to the profile your login shell actually reads (`~/.zshrc` for zsh, `~/.bashrc` for bash, `~/.profile` otherwise).

  Anything written to a profile is wrapped in markers so it can be removed cleanly later:

  ```bash
  # >>> wcp >>>
  # Added by the wcp setup script. To remove, delete this line
  # through the matching '<<< wcp <<<' line below.
  export PATH="$PATH:/home/you/.local/bin"
  # <<< wcp <<<
  ```

  To undo it by hand, or from a future uninstall script:

  ```bash
  sed -i '/^# >>> wcp >>>$/,/^# <<< wcp <<<$/d' ~/.bashrc
  ```

  Re-running `setup` never adds a second block — it detects the existing markers and leaves the file alone. If `setup` is run non-interactively (piped, or from CI) it never touches your profile; it prints the line for you to add yourself.
- **Windows (via Git Bash, MSYS2, or similar):** installs `wcp.ps1` and a `wcp.cmd` launcher (so plain `wcp` works from cmd.exe, PowerShell, or Git Bash) into `%USERPROFILE%\bin`, and adds that folder to your user `PATH` automatically if `powershell.exe` is reachable.

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
Requires `curl` (already on virtually every system). `--copy` uses `pbcopy` (macOS), `xclip`, or `wl-copy` (Wayland) — whichever is found first; harmless if none are installed, it just won't copy.

**Windows (PowerShell), no bash available at all:**
```powershell
mkdir $env:USERPROFILE\bin -Force
Copy-Item wcp.ps1 $env:USERPROFILE\bin\wcp.ps1
[Environment]::SetEnvironmentVariable("Path", "$env:Path;$env:USERPROFILE\bin", "User")
```
Requires `curl.exe`, which ships with Windows 10 (1803+) and Windows 11 by default — no separate install needed.

**Making `wcp` callable without typing `.ps1`:** PowerShell requires an explicit extension for scripts by default. Either call it as `wcp.ps1 <args>`, or create the same thin `wcp.cmd` wrapper that `setup` would have created for you:
```
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wcp.ps1" %*
```

**Note on PowerShell execution policy:** if running the `.ps1` directly (not via the `.cmd` wrapper above) hits a script-execution-disabled error, either use the `.cmd` wrapper (which bypasses it per-invocation) or run once as admin: `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`.

## Notes

- All scripts (bash, PowerShell) do the same three-way decision for uploads: **single existing file** → upload as file; **stdin with no args** → upload stdin; **anything else (including multiple words)** → joined with a space and uploaded as text.
- The full upload → code → retrieve roundtrip (both text and file, both print-to-stdout and save-as-file paths, and the collision fallback) was tested end-to-end against local mock servers matching each protocol's shape — this sandbox can't reach the real internet, so a real smoke test against the live services is still worth doing once installed.
- If you uploaded with a custom `--host` (a self-hosted instance), retrieving that code later also needs the same `--host` — without it, retrieval falls back to the public default for that backend letter and won't find your self-hosted copy.
- This does **not** work against the custom `cp-site` built earlier in this project — that one uses a different API shape (`/up` endpoint, split `/down` + `/f` flow, and already does its own text-vs-file distinction server-side rather than via `Content-Type` sniffing). Adding a `cp-site` backend here would be straightforward if wanted (same pattern as `catbox`/`litterbox`).

## Removed backends

On 2026-08-20, the following backends were dropped:
- `0x0` — HTTP 503, uploads disabled upstream.
- `transfer.sh` — service shut down, connection refused.

## Caveat

Litterbox codes stop resolving after the expiry window. Use `--backend catbox` or set `WCP_BACKEND=catbox` for permanent storage. wcp does NOT switch automatically — catbox is the manual fallback.

## Environment variables

- `WCP_BACKEND` — selects the upload backend (default: `litterbox`). Set to `catbox` for permanent storage.
- `WCP_TIME` — whole number of hours for litterbox expiry (default: 1). Rounds UP to the nearest of 1h/12h/24h/72h. Ignored by catbox.
