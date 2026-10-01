# vault

One encrypted 7z file you can edit in place.

```sh
vault              # list contents
vault add SRC...   # add files or directories
vault edit FILE    # open in nvim, re-encrypt on save (creates the file if new)
vault cat FILE     # print one file
vault get FILE DST # extract one file
vault rm FILE      # delete from the vault
vault sh           # shell with everything unpacked in RAM, re-encrypts on exit
```

Paths come from `$VAULT_ARCHIVE` (default `~/vault.7z`) and the editor from
`$VAULT_EDITOR`, falling back to `$VISUAL`, `$EDITOR`, then `nvim`.

There is no unlocked state. Plaintext exists only while a command is running,
only under `/dev/shm` (tmpfs, RAM-backed), and is wiped when the command exits —
including on ctrl-C. Nothing unencrypted is written to disk at any point.

That is the whole design goal. A folder you unlock and re-lock leaves plaintext
sitting on disk for as long as you forget to lock it, readable by anything
running as you; scoping the decryption to a single command makes the exposure
window the length of one edit instead of one afternoon.

## Why it exists

safe-agent covers agents you put in a jail. It does nothing about agents running
*unsandboxed* on the host as your own user — and those can read every file you
can. There is no permission bit that keeps a process out of files owned by the
uid it runs as.

So the gate has to be something the process does not have: a passphrase that
exists only in your head. At rest the contents are AES-256 ciphertext that no
process can read without you typing it.

The two halves compose. Agent jails get a tmpfs `$HOME`, so `~/vault.7z` is not
visible inside one at all — you would have to pass `-d` deliberately.

## Header encryption is not optional

The archive is built with `-mhe=on`, which encrypts the archive *headers* as
well as the file data. Without it:

```sh
$ 7z l vault.7z          # no password prompt at all
2026-08-18 14:31  ....A  1834  aws-prod.pem
2026-08-18 14:31  ....A   412  bank-recovery-codes.txt
```

Filenames leak the shape of your secrets even when their contents are safe.
`-mhe=on` makes listing require the passphrase too.

## Two 7z traps this wraps

**`-p` means opposite things.** With no value attached, `-p` prompts for a
password on `a` and `u`, but means *the empty password* on `l` and `x`. A read
command with a trailing `-p` fails with `Cannot open encrypted archive. Wrong
password?` even when you know the password — because it never asked.

**Creating asks twice, opening asks once.** Adding to an existing encrypted
archive prompts once to open it and again to encrypt the new data. Anything
feeding the password on stdin has to supply enough copies or 7z dies with
`Break signaled` partway through.

`vault` reads the password once and replays it with bash's builtin `printf`.
That matters for more than convenience: `-p<password>` on the command line, or
`yes <password> |`, both put the passphrase in a process's argv, where any
process running as you can read it out of `ps` — exactly the threat the vault
exists to stop.

## Creating asks twice

The first command that creates the archive asks for the passphrase twice.
Creating *sets* the password rather than checking one, so a typo would encrypt
everything under a string nobody knows. 7z would normally ask for confirmation
itself, but since `vault` answers every prompt with the same string to get past
the trap above, that safety net is bypassed and the confirmation happens in the
script instead.

Later commands ask once — a wrong password there simply fails to open the
archive, which is harmless.

Every write (`add`, `edit`, `rm`, `sh`) recreates the archive, and 7z creates it
0644. Each one re-applies 0600 afterwards; world-readable ciphertext is not a
break, but there is no reason to hand anyone a copy to attack offline.

## The shell is marked

`vault sh` sets a distinct prompt so `exit` is unambiguous:

```
[vault] alex@host:/dev/shm/vault.tdAD4rOq$
```

`$VAULT_SH=1` is exported too, for scripts or a custom prompt to key off. The
rcfile that applies the prompt is created outside the scratch directory on
purpose — anything left inside it is swept into the archive on exit.

## Two ways `sh` used to destroy the vault

Both are guarded now, and both are in the tests.

**An empty scratch dir.** `sh` re-adds its whole directory on exit. If you had
deleted everything in there, `7z a` replaced the archive with a 32-byte stub —
and since there was nothing to encrypt, 7z dropped the encryption too. The vault
became an empty, unencrypted file. `sh` now refuses to write an empty scratch
dir and leaves the archive alone; `vault rm` is how you delete things.

**Two sessions at once.** Each one unpacks the same archive and re-adds its own
copy on exit, so whoever exits last wins and the other's work is gone silently.
Writers now take an exclusive `flock` on `$ARCHIVE.lock` for their whole run,
held on fd 9 so the kernel releases it even if the process is killed. Readers
(`ls`, `cat`, `get`) do not take it — they cannot lose anyone's work.

## Limits

* **Plaintext is readable while a command runs.** During `vault edit`, the file
  sits in `/dev/shm` owned by you, so anything running as you could read it for
  as long as the editor is open. Short window, not zero.
* **No authentication.** 7z's AES-256 protects confidentiality but does not
  reliably detect deliberate tampering. Fine for a file you control; weaker if
  you re-download it from somewhere you do not trust.
* **KDF.** 7z derives the key with iterated SHA-256, weaker than a modern
  password hash. Use a long passphrase.
* **Nothing is shredded.** Scratch files are unlinked from tmpfs rather than
  overwritten. That is RAM, so nothing survives a reboot, but a live memory dump
  is out of scope.

Uploading the archive is the point of the design — one self-contained file, and
without the passphrase it reveals neither contents nor filenames.
