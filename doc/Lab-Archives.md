# LSP-Claw Lab Archives

LSP-Claw can move a complete lab to or from a user's file system without
placing ZIP bytes in MCP JSON or AI context. The same format can be used as a
snapshot when transferring a lab between LSP-Claw servers.

## User workflows

The authenticated browser setup page lists labs and provides **Download ZIP**
and **Upload and import ZIP** controls. The browser transfers the file directly
between the user's file system and LSP-Claw.

AI agents use two MCP tools:

- `prepareLabExport` accepts the optional selected-lab override `labName` and
  returns a short-lived, one-time `downloadUrl`.
- `prepareLabImport` requires a destination `labName` and a `conflictAction` of
  `createNew` or `replace`. Replacement also requires `confirmed=true` and a
  stopped destination. It returns a short-lived, one-time `uploadUrl` for a
  raw `application/zip` POST.

Tickets expire after five minutes by default and are consumed by the first
matching request. Preparing a new ticket is required after expiration, use, or
a failed upload. Archive endpoints use the same configured browser login or
MCP bearer-token boundary as the rest of LSP-Claw.

## Archive format

LSP-Claw-generated ZIPs use ZIP32 method 0: entries are stored without
compression. This avoids compression work on embedded systems and permits
chunked BAS IO output without buffering the archive in Lua memory. Imports use
ZipIo and accept both stored and compressed ZIP entries.

Every archive contains `.lsp-claw-lab.json`:

```json
{
  "format": "lsp-claw-lab",
  "version": 1,
  "exportedLabName": "router-demo",
  "createdAt": 1784044800,
  "fileCount": 12,
  "uncompressedBytes": 48291,
  "emptyDirectories": ["cache/empty"]
}
```

`fileCount` and `uncompressedBytes` describe lab files only; the manifest is
not installed in the lab. `emptyDirectories` is required because BAS ZipIo
intentionally ignores directory-only ZIP entries. LSP-Claw still writes normal
directory entries for other ZIP readers, then recreates empty directories from
the validated manifest during import.

The archive includes files, binary contents, dotfiles, and significant empty
directories. It excludes backups, staging directories, process state, trace
buffers, tokens, and LSP-Claw configuration because those are outside the lab
IO.

## Import validation and replacement

The default independent limits are:

| Limit | Default |
|---|---:|
| Uploaded/stored archive | 64 MiB |
| Expanded lab contents | 64 MiB |
| One expanded file | 64 MiB |
| Entries | 4,096 |
| Path depth | 32 |
| Expansion ratio | 100:1 |
| Manifest | 256 KiB |

Import writes the bounded HTTP body to a temporary BAS IO file, opens that
file with `ba.mkio(baseIo, zipPath)`, validates and copies the ZipIo tree into a
separate staging directory, closes ZipIo explicitly, and only then changes the
destination. Absolute, drive, UNC, dot-segment, duplicate case-insensitive, and
conflicting paths are rejected. Counts, expanded bytes, format, and version
must match the manifest.

ZipIo exposes directories and readable resources rather than host filesystem
special-file semantics. LSP-Claw creates only BAS IO directories and ordinary
files from that view; it never creates a symlink, device, or other special
entry from archive metadata.

`createNew` fails if the destination exists. `replace` never merges: the
destination must be stopped and explicitly confirmed. The prepared staging
directory and old lab directory are renamed at the commit point. If installing
the new directory fails, the old directory is renamed back. A failed create or
validation removes both staging data and any newly registered empty lab.

Exports return the archive size and SHA-256 digest. Imports return the uploaded
digest, file count, expanded byte count, source manifest name, and final lab
identity. These values make local automation verifiable without transferring
the archive through MCP text.
