# wcp — minimal upload wrapper (multi-backend, roundtrip codes)

`wcp` uploads a file, some text, or stdin, and prints back a **short code**. Give that same code back to `wcp` later to retrieve it — text is printed to stdout, files are saved in the current folder under their original filename.

```bash
wcp report.pdf
# -> aXyZ123.pdf

wcp aXyZ123.pdf
# -> Saved as report.pdf
```

**Files in this folder:**
- `setup` — run this first; detects your OS and installs `wcp` to the right place
- `wcp` — the Linux/macOS/WSL script
- `wcp.ps1` — the Windows PowerShell script
- `README.md` — this file

## How the code works

The code is `<backend-letter><id>`, with no separator — just the letter directly followed by whatever ID the backend itself assigned:

| Letter | Backend | Default fetch host |
|---|---|---|
| `a` | `0x0` (default) | `https://0x0.st` |
| `b` | `transfer.sh` | `https://transfer.sh` |
| `c` | `catbox` | `https://files.catbox.moe` (note: different from catbox's *upload* endpoint, `catbox.moe`) |

On retrieval, `wcp` reads the first character to pick the backend, prepends the matching fetch host to the rest of the code, and fetches that URL. It decides text-vs-file by checking the response's `Content-Type` header (`text/*` → print; anything else → save as a file).

**Collision handling:** a single word that happens to start with a known letter (e.g. `wcp aeroplane`) looks like a code. `wcp` tries retrieval first; if that 404s, it falls back to uploading the word as text instead of just erroring — so this is safe to use even if your text happens to start with `a`, `b`, or `c`.

## Backends (for uploading)

`--backend` selects which service's API to use for uploads (default: `0x0`). `--host` overrides that backend's endpoint — and on retrieval, overrides the fetch host used to decode a code (useful if you uploaded via a self-hosted instance and need to fetch from that same instance rather than the public default).

| Backend | Default upload host | Notes |
|---|---|---|
| `0x0` (default) | `https://0x0.st` | Also works against `https://envs.sh` and `https://ttm.sh` via `--host` — both run the actual 0x0 software, confirmed protocol-compatible. |
| `transfer.sh` | `https://transfer.sh` | PUT-based upload. |
| `catbox` | `https://catbox.moe/user/api.php` | Multipart POST with `reqtype=fileupload`. |

Other similarly-named "file drop" services (`pixeldrain`, `bashupload.com`, `file.io`) aren't implemented here — they'd each need their own backend function, similar to how `transfer.sh`/`catbox` were added.

## Usage

```bash
wcp path/to/file.txt                       # single existing file -> uploaded as-is, prints a code
wcp some words here                        # not a file -> joined with spaces, uploaded as text, prints a code
echo "text" | wcp                          # no args -> reads stdin, prints a code
wcp aXyZ123.pdf                            # retrieve by code -> saves or prints depending on type
wcp --backend transfer.sh path/to/file.txt # use a different backend for upload
wcp --backend catbox some text
wcp --host https://envs.sh hello           # override the endpoint (0x0 backend)
wcp --copy some text                       # also copy the resulting code to clipboard
wcp get https://0x0.st/AbCd.txt            # retrieve by a full URL instead of a code
wcp get https://0x0.st/AbCd.txt -o out.txt # ...and save it under a specific name
```

## Install

Run `setup` once — it detects your OS and installs `wcp` to the right place automatically:

```bash
bash setup
```

- **Linux / macOS / WSL:** installs the bash `wcp` script to `/usr/local/bin/wcp` (or `~/.local/bin/wcp` as a fallback if that's not writable), makes it executable, and tells you if that folder needs adding to `PATH`.
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

- All three scripts (bash, PowerShell) do the same three-way decision for uploads: **single existing file** → upload as file; **stdin with no args** → upload stdin; **anything else (including multiple words)** → joined with a space and uploaded as text.
- The full upload → code → retrieve roundtrip (both text and file, both print-to-stdout and save-as-file paths, and the collision fallback) was tested end-to-end against local mock servers matching each protocol's shape — this sandbox can't reach the real internet, so a real smoke test against the live services is still worth doing once installed.
- `transfer.sh` codes contain a `/` (its URLs have two path segments — a random ID and a filename), so they look like `b<id>/paste.txt` rather than a single flat token. This is expected and handled correctly, since the code format doesn't require the ID portion to be simple.
- If you uploaded with a custom `--host` (a self-hosted instance), retrieving that code later also needs the same `--host` — without it, retrieval falls back to the public default for that backend letter and won't find your self-hosted copy.
- This does **not** work against the custom `cp-site` built earlier in this project — that one uses a different API shape (`/up` endpoint, split `/down` + `/f` flow, and already does its own text-vs-file distinction server-side rather than via `Content-Type` sniffing). Adding a `cp-site` backend here would be straightforward if wanted (same pattern as `transfer.sh`/`catbox`).