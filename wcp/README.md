# wcp — upload a file, text, or stdin; get back a short code

`wcp` uploads something and prints a **short code**. Give that code back later to
retrieve it — text prints to stdout, files are saved into the current folder.

Uploads are encrypted client-side. Without a stored key the key rides in the code
(`CODE-KEY`, ~20 chars). Store a key with `--set-key` and codes drop to 7 characters,
because the key no longer has to travel.

```bash
wcp this is a note
# -> B68845i-arclfBzz13Wy

wcp B68845i-arclfBzz13Wy
# -> this is a note

wcp --set-key                  # generate and store a key on this machine
# -> NPBfB8bVtOQB18NHLfHS      # set the same one on your other machine, once

wcp this is a note
# -> Bes0x4x                   # same encryption, no key in the code

wcp notes.csv
# -> Bbf2r86

wcp Bbf2r86
# -> Saved as notes.csv        # the original filename survives
```
Run `wcp -h` for the full flag list.

## Dependencies

**Required:** `curl` (`curl.exe` on Windows), `openssl`, and either `bash` or
PowerShell 5.1+.

`curl.exe` and PowerShell 5.1 ship with Windows 10 (1803+) and Windows 11. `openssl`
does not — `winget install ShiningLight.OpenSSL.Light`, `choco install openssl`, or the
copy Git for Windows ships. On Linux and macOS use your package manager. `wcp` names
the right command if something is missing.

**Optional:** a clipboard tool — `pbcopy`/`pbpaste`, `xclip`, `xsel`, or
`wl-copy`/`wl-paste`. It must match the running display server: `wl-copy` needs
Wayland, `xclip` and `xsel` need X11. An SSH session has neither.

The code is copied automatically in a terminal, and not when output is redirected, so
`C=$(wcp file.txt)` leaves your clipboard alone. `-c` copies anyway, `-n` never does.

## Install

```bash
bash setup                                              # Linux, macOS, WSL
powershell -ExecutionPolicy Bypass -File setup.ps1      # Windows
```

Both install `wcp` and offer to put it on your `PATH`, printing what they changed and
how to undo it. `setup` writes to `/usr/local/bin`, or `~/.local/bin` when that is not
writable, and wraps any profile line in `# >>> wcp >>>` / `# <<< wcp <<<` markers:

```bash
sed -i '/^# >>> wcp >>>$/,/^# <<< wcp <<<$/d' ~/.bashrc
```

Run non-interactively, `setup` leaves your profile alone and prints the line to add.

To install by hand: `chmod +x wcp && sudo mv wcp /usr/local/bin/wcp`. On Windows, copy
`wcp.ps1` into a folder on your `PATH` alongside a `wcp.cmd` wrapper so plain `wcp`
works:

```
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wcp.ps1" %*
```

When editing the Windows `PATH` by hand, read the **User**-scoped value, not
`$env:Path` — that is the combined machine+user value, and writing it back duplicates
your whole system PATH into your user variable.

## How the code works

The first character encodes the backend and the extension together. Lowercase is
litterbox, uppercase catbox, and the letter's position gives the extension:

```
  a/A (none)   f/F .yaml   k/K .png
  b/B .txt     g/G .csv    l/L .jpg
  c/C .md      h/H .conf   m/M .pdf
  d/D .log     i/I .sh     n/N .zip
  e/E .json    j/J .py     o/O .gz

  0 / 1  extension not in the list (literal .ext follows the id)
```

So `b0ojyr4` is litterbox + `.txt`, `B96k8z8` is catbox + `.txt`.

**Nothing is overwritten.** A retrieval that would clobber an existing file inserts
`_1`, `_2` before the extension and prints the name it used. This applies to `-o` too.

**Code or text?** A candidate of 7 characters or fewer that looks like a code is tried
as a retrieval first, falling back to uploading it as text. Longer ones are only tried
if they contain a `.` or `-`. Use `wcp . <code>` to force retrieval.

## Backends

`-b` / `--backend` picks the service; `-b c` and `-b l` are accepted short forms.
`--host` overrides the endpoint, on upload and retrieval alike.

| Backend | Notes |
|---|---|
| `catbox` (default) | permanent |
| `litterbox` | expires: `-t` sets 1h, 12h, 24h or 72h, default 1h |

## Encryption

AES-256-CBC, client-side. The key is **never uploaded** — only ciphertext reaches the
server. Losing the key loses the data.

| | no stored key | key stored |
|---|---|---|
| `catbox` (default) | encrypted, key in the code | encrypted, **7-char code** |
| `litterbox` | plain | encrypted, **7-char code** |

`-e` forces encryption, `-p` forces it off, `-z` ignores the stored key for one run.

Files up to 1 MB are encrypted whatever their type; `-f` raises that to 100 MB. Beyond
the limit they upload as-is with a warning. Encrypted uploads keep the original
filename; plain ones keep only the extension.

### Sharing a key

The key never travels with a code, so every machine that reads your uploads needs the
same one:

```bash
# machine A, which already has it
wcp --get-key
# -> NPBfB8bVtOQB18NHLfHS

# machine B, once
wcp --set-key NPBfB8bVtOQB18NHLfHS
```

A machine without it gets a clear error rather than a garbled file:

```
wcp: this upload is encrypted, but no key is set on this machine
wcp: run --set-key with the key from the machine that sent it
```

Files stored under an old key can still be retrieved using:
`wcp . <code> <old_key>`

## Retrieval

`wcp . <code>` always retrieves: it never checks for a local file of that name, or
falls back to uploading. It also accepts a full URL. `-o <file>` saves under a name
you choose and implies explicit retrieval on its own.

`-l` prints the URL instead of the code. With `-le` and no stored key you get two
lines, URL then key; only the URL is copied to the clipboard.

## Accumulate buffer

`-a` appends to a local buffer, `-s` uploads it, `--clear` empties it. Text only.
Entries are separated by two blank lines.

```bash
echo "note one" | wcp -a         # append stdin
wcp -a "note two"                # append argument text
wcp -va                          # append the clipboard
wcp -a                           # print the buffer
wcp -s                           # upload and clear
```

The buffer survives between shells, and a failed `-s` leaves it intact. It is
encrypted on send under the usual rules.
On Linux a piped entry is labelled with the command that produced it.

Best effort: a stage that already exited is left out, and shell builtins such as
`echo` never appear because they run no process. Windows has no equivalent, since a
PowerShell pipeline passes objects inside one process.

## Notes

- Uploads take a three-way decision: a single existing file is uploaded as a file,
  stdin with no arguments is uploaded as stdin, anything else is joined with spaces
  and uploaded as text.
- A code uploaded with a custom `--host` needs the same `--host` to retrieve, or
  lookup falls back to the public default for that backend letter.

## Environment variables

- `WCP_BACKEND` — upload backend (default: `catbox`)
- `WCP_TIME` — litterbox expiry in whole hours (default: 1)
- `WCP_PLAIN` — set to `1` to disable encryption
- `WCP_KEY_LEN` — generated key length (default: 12)
- `WCP_NO_COPY` — set to `1` to never touch the clipboard
