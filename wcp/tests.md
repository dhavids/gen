# wcp test sheet

Every ```bash and ```powershell block below is executable. `wcp` runs the blocks for
its own shell and skips the others, so both builds are checked against one sheet.
Run the lot with:

```
wcp --run-tests
```

or paste any block into a terminal by hand.

The runner sandboxes itself first: it points `XDG_CONFIG_HOME` and `XDG_CACHE_HOME`
at a temp directory and works in another, so **your own stored key and buffer are
never touched**. The sheet then sets its own fake key, so nothing here depends on
yours.

Tests upload real data to catbox, so they need network and leave a few small public
files behind.

## How a block is read

- A line that is not a comment is a command, run in a shell that persists across
  the whole sheet, so `CODE=$(...)` in one block is still set in the next.
- `# -> text` asserts the previous command's output contains `text`.
- `# ~> regex` asserts it matches `regex`.
- Any other `#` line is a note and is ignored.

## Setup

```bash
wcp --set-key wcpTESTkey0000000001
# -> key stored
```

```powershell
wcp --set-key wcpTESTkey0000000001
# -> key stored
```

## Dependencies

```bash
command -v curl >/dev/null && command -v openssl >/dev/null && echo BOTH
# -> BOTH
```

## Key store

```bash
wcp --get-key
# -> wcpTESTkey0000000001

wcp --set-key abc
# -> a stored key needs at least 20 characters

wcp --set-key 'has spaces in it here'
# -> may only contain letters and digits

wcp --set-key --clear-key
# -> separate actions

wcp --get-key hello
# -> a key action takes no other arguments
```

```powershell
wcp --get-key
# -> wcpTESTkey0000000001

wcp --set-key abc
# -> a stored key needs at least 20 characters

wcp --set-key --clear-key
# -> separate actions

wcp --get-key hello
# -> a key action takes no other arguments
```

## Upload and retrieve with the stored key

The key never travels, so the code stays 7 characters.

```bash
CODE=$(wcp -n stored roundtrip)
echo "$CODE"
# ~> ^[A-Za-z0-9]{7}$

wcp "$CODE"
# -> stored roundtrip
```

```powershell
$CODE = (wcp -n stored roundtrip).Trim()
$CODE
# ~> ^[A-Za-z0-9]{7}$

wcp $CODE
# -> stored roundtrip
```

## Without the stored key

`-z` ignores it, so the key rides in the code instead.

```bash
ZCODE=$(wcp -zn plain roundtrip)
echo "$ZCODE"
# ~> ^[A-Za-z0-9]{7}-[A-Za-z0-9]{12}$

wcp "$ZCODE"
# -> plain roundtrip

wcp . "${ZCODE%%-*}" "${ZCODE#*-}"
# -> plain roundtrip

wcp . "${ZCODE%%-*}" AAAAAAAAAAAA
# -> could not decrypt

wcp . "${ZCODE%%-*}" short
# -> does not look like a key
```

```powershell
$ZCODE = (wcp -zn plain roundtrip).Trim()
$ZCODE
# ~> ^[A-Za-z0-9]{7}-[A-Za-z0-9]{12}$

wcp $ZCODE
# -> plain roundtrip

$PARTS = $ZCODE.Split('-')
wcp . $PARTS[0] $PARTS[1]
# -> plain roundtrip

wcp . $PARTS[0] AAAAAAAAAAAA
# -> could not decrypt

wcp . $PARTS[0] short
# -> does not look like a key
```

## Link output

```bash
wcp -ln link test | wc -l
# -> 1

wcp -ln link test
# ~> ^https://

wcp -lezn link and key test | wc -l
# -> 2
```

```powershell
(wcp -ln link test | Measure-Object -Line).Lines
# -> 1

wcp -ln link test
# ~> ^https://

(wcp -lezn link and key test | Measure-Object -Line).Lines
# -> 2
```

Only the URL reaches the clipboard, never the key.

## Large files and -f

```bash
head -c 2097152 /dev/urandom > big.bin

wcp -zn big.bin
# -> over the 1 MB limit, uploading as-is
# -> pass -f to encrypt it anyway

BIGCODE=$(wcp -zfn big.bin)
echo "$BIGCODE"
# ~> ^[A-Za-z0-9]{7}-[A-Za-z0-9]{12}$

mkdir -p out && cd out && wcp "$BIGCODE" && cd ..
# -> Saved as big.bin

cmp big.bin out/big.bin && echo IDENTICAL
# -> IDENTICAL
```

## Accumulate buffer

```bash
wcp --clear
# -> buffer cleared (0 entries, 0 B)

printf 'one\n' | wcp -a
printf 'two\n' | wcp -a

wcp -a
# -> one
# -> two
# -> 2 entries, 10 B

head -c 64 /dev/urandom | wcp -a
# -> only text can be accumulated

SENT=$(wcp -sn)
echo "$SENT"
# ~> ^[A-Za-z0-9]{7}$

wcp -s
# -> buffer is empty - nothing to send
```

```powershell
wcp --clear
# -> buffer cleared

"one" | wcp -a
"two" | wcp -a

wcp -a
# -> one
# -> two
# -> 2 entries

$SENT = (wcp -sn).Trim()
$SENT
# ~> ^[A-Za-z0-9]{7}$

wcp -s
# -> buffer is empty - nothing to send
```

Entries are separated by two blank lines, which is why two 4-byte entries total
10 bytes.

## Buffer trimming

```bash
wcp --clear && seq 1 40 | wcp -a

wcp -a | wc -l
# -> 40

wcp -a --full | wc -l
# -> 40
```

Redirected output is never trimmed. On a terminal and without `--full`, `wcp -a`
shows the first five lines, a `... 30 lines hidden ...` marker, then the last five.

## A failed send keeps the buffer

The important one: a network failure must not lose what you accumulated.

```bash
wcp --clear && printf 'keepme\n' | wcp -a

wcp -s --host https://127.0.0.1:1/
# -> upload failed on backend

wcp -a
# -> keepme

wcp --clear
```

```powershell
wcp --clear
"keepme" | wcp -a

wcp -s --host https://127.0.0.1:1/
# -> upload failed on backend

wcp -a
# -> keepme

wcp --clear
```

## Pipeline labelling (Linux only)

```bash
wcp --clear && seq 1 100000 | tr -d x | wcp -a

wcp -a --full | head -1
# this should print: $ seq 1 100000 | tr -d x
```

Not asserted, and it will not match under `--run-tests`. The label is read from the
parent shell's list of children, so a runner sitting between the pipeline and `wcp`
changes what there is to find. Check it by pasting the block into a terminal.

Best effort in any case: a stage that already exited is left out, and builtins such
as `echo` never appear because they run no process. Windows has no equivalent.

## Flag parsing

```bash
wcp -vb
# -> cannot be bundled

LITERAL=$(wcp -zn -- -vb)
wcp "$LITERAL"
# -> -vb
```

## Retrieval never overwrites

```bash
printf 'first version\n' > note.txt
NOTECODE=$(wcp -zn note.txt)

wcp "$NOTECODE"
# -> Saved as note_1.txt

cat note.txt
# -> first version
```

## Teardown

```bash
wcp --clear-key
# -> key cleared
```

```powershell
wcp --clear-key
# -> key cleared
```

The runner deletes its sandbox on exit. Nothing above touched your real key or
buffer.
