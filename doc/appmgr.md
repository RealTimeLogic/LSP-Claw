# `appmgr` API Reference

## Overview

The `appmgr` module manages persistent **LSP-Claw lab apps**. Each lab is a
named object with its own storage, backup storage, staging paths, running state,
and Mako or Xedge application handle.

Known labs are recorded in:

```text
LSP-Claw-Labs.json
```

Lab files are not stored in the registry. Each lab remains a top-level BAS IO
directory. For example:

```text
lsplab/
lsplab-backup/
router-demo/
router-demo-backup/
```

The module-level compatibility API continues to address the legacy lab:

```text
lsplab
```

The module-level API remains available for older callers that explicitly use
`lsplab`. Current LSP-Claw MCP tools resolve named lab objects and do not depend
on that compatibility singleton.

The module provides APIs for:

- Creating named lab and backup storage areas.
- Persisting lab metadata and migrating an existing `lsplab` installation.
- Reading and writing the lab through BAS IO objects.
- Detecting whether the runtime is Mako or Xedge.
- Starting and stopping the lab app.
- Recursively iterating IO trees.
- Copying examples from another IO, such as `GitHubIo`, into the lab.
- Backing up, moving, or clearing lab files.

Load the module with:

```lua
local appmgr = require "appmgr"
```

## Registry and migration

The version 1 registry contains a sorted `labs` array. Each entry has:

```lua
{
   name = "router-demo",
   basePath = "router-demo",
   basePathExplicit = false,
   createdAt = 178...,
   updatedAt = 178...,
   running = false
}
```

On first use, if `lsplab` exists and the registry does not, `appmgr` registers
that directory with `basePath = ""`. It does not move or modify the lab or its
`lsplab-backup` sibling. The registry includes an unverified migration record
that preserves the legacy names and states that no contents were moved.

Persisted `running` values are reset when the registry is loaded because an
application from a previous process cannot still be managed by the new process.
Stale `<lab>-stage-*` directories are removed when that lab is initialized.

## Runtime Behavior

The behavior depends on the runtime environment.

| Runtime | Lab app support | `.preload` support | `.xlua` auto execution |
|---|---:|---:|---:|
| Mako Server | yes | yes | no |
| Xedge | yes | yes | yes |
| Xedge running as a Mako app | yes | yes | yes |

When running under Xedge, `appmgr.getLabIo()` and `lab:getLabIo()` return a second IO object,
`executeIo`. This IO maps to Xedge's live execution IO and can auto-execute
`.xlua` files when the lab app is running.

When running under Mako, `executeIo` is not available. `.xlua` files may still
be stored in the lab as normal files, but Mako does not auto-execute them.

## appmgr.create()

Creates and initializes the legacy `lsplab` and `lsplab-backup` storage areas.
This is the compatibility entry point for older single-lab callers.

```lua
local ok, err = appmgr.create()
```

On success, returns a truthy value. The current implementation may return
`true` when creating the lab or the lab IO object when it has already been
initialized.

On failure:

```lua
nil, err
```

Call this before using APIs that require the lab IO, such as:

- `appmgr.getLabIo`
- `appmgr.start`
- `appmgr.backup`
- `appmgr.rmlab`
- `appmgr.copy2lab`

Recommended pattern:

```lua
local ok, err = appmgr.create()
if not ok then
   return nil, err
end
```

## appmgr.name()

Returns the compatibility API's stable storage name. This is always:

```lua
"lsplab"
```

Callers should use this accessor in user-facing errors instead of duplicating
the literal name. Named lab objects return their own identity from `lab:name()`.

## Named-lab manager API

### appmgr.validateLabName(name)

Validates a portable lab storage name. Names contain 1 to 64 characters, start
with a letter or digit, and then contain only letters, digits, hyphen, and
underscore. Names using the reserved `-backup` suffix or `-stage-` namespace
are rejected.

```lua
local name, err = appmgr.validateLabName("router-demo")
```

### appmgr.registryFile()

Returns the registry filename:

```lua
assert(appmgr.registryFile() == "LSP-Claw-Labs.json")
```

### appmgr.listLabs()

Returns sorted copies of the registered lab metadata records:

```lua
local labs, err = appmgr.listLabs()
```

Changing a returned table does not change the registry. Runtime `running`
values reflect the current process.

### appmgr.createLab(name, basePath)

Creates and registers a named lab and its sibling backup directory:

```lua
local lab, err, code = appmgr.createLab("router-demo")
```

When `basePath` is omitted for the first registered lab, it defaults to the
root path `""`; for a later lab, it defaults to the lab name. Pass `""`
explicitly to request the root URL. The registry records whether the route was
explicitly selected so a later routing workflow never silently changes a user
choice. A nonempty base path must be one URL-safe segment using the same
character set as a lab name.

When a second lab is created by any caller, `appmgr.createLab` changes an
existing automatically assigned root route to that existing lab's name before
creating the new lab. A running existing lab blocks this transition. An
explicitly configured root route is never changed automatically. The fourth
return value describes a performed route transition.

Lab names are compared case-insensitively so the registry is portable across
case-sensitive and case-insensitive filesystems. Duplicate names return
`labAlreadyExists`; invalid names return `invalidLabName`. Base paths are also
case-insensitively unique. A route collision returns
`labBasePathAlreadyExists`.

### appmgr.getLab(name)

Returns an existing lab object without creating a new registry entry:

```lua
local lab, err, code = appmgr.getLab("router-demo")
```

Lookup is case-insensitive. An absent name returns `unknownLab`.

### Lab object methods

A named lab object owns the same operations that the compatibility module API
performs on `lsplab`:

| Method | Purpose |
|---|---|
| `lab:name()` | Return the stable lab name. |
| `lab:metadata()` | Return a copy of the lab metadata. |
| `lab:create()` | Initialize lab and backup IOs and recover stale staging directories. |
| `lab:getLabIo()` | Return storage IO and optional Xedge execution IO. |
| `lab:start()` / `lab:stop()` | Start or stop this lab at its registered base path. |
| `lab:isRunning()` | Return current-process running state. |
| `lab:basePath()` | Return the direct registered URL base path. |
| `lab:backup(name, copy)` | Back up this lab under `<lab>-backup`. |
| `lab:listBackups()` | List only this lab's backups. |
| `lab:restore(name)` | Restore this lab from one of its backups. |
| `lab:copy2lab(io, path)` | Stage and replace this lab from another BAS IO. |
| `lab:createStageIo()` / `lab:removeStage(io, name)` | Create or discard sibling staging storage for an internal operation. |
| `lab:replaceWithStage(io, name)` | Commit an already validated sibling stage by directory rename with rollback. The caller must hold the lab lock. |
| `lab:rmlab()` | Remove all files from this lab. |

Mutating lab methods are exclusive. If another mutation is active, they return
`nil, err, "labBusy"`. `lab:busy()` reports the active operation. The manager's
route-change, rename, and delete functions share the same per-lab lock.

### appmgr.setLabBasePath(name, basePath)

Changes a stopped lab's unique direct URL base path. An empty path means the
server root. MCP callers require explicit user confirmation before invoking
this operation.

### appmgr.renameLab(name, newName)

Renames a stopped lab, its top-level storage directory, and its sibling backup
directory. An automatically assigned name-based route follows the new name;
an explicitly selected route is preserved.

### appmgr.deleteLab(name)

Deletes a stopped lab, all lab files, all backups, and its registry entry.
This is irreversible and MCP callers require explicit user confirmation.
When this leaves one stopped lab whose name-based route was assigned
automatically, that remaining lab returns to the root route without changing
`basePathExplicit` to true. An explicit route is never changed.

MCP session selection is handled by `lspclaw.lua`; it stores only the active
lab name and resolves the corresponding object with `appmgr.getLab()`.

## appmgr.getLabIo()

Returns the legacy `lsplab` storage IO and, when available, its Xedge execution IO.

```lua
local labIo, executeIo = appmgr.getLabIo()
```

Returns:

| Value | Runtime | Description |
|---|---|---|
| `labIo` | Mako and Xedge | Normal BAS IO rooted at `lsplab`. Use this for standard storage operations. |
| `executeIo` | Xedge only | IO rooted at the Xedge live app path. Saving `.xlua` files through this IO can auto-execute them when the lab is running. |

`labIo` is initialized by `appmgr.create()` or `appmgr.start()`. If neither has
been called, it may be `nil`.

Example:

```lua
local ok, err = appmgr.create()
if not ok then return nil, err end

local labIo, executeIo = appmgr.getLabIo()

if executeIo then
   trace("Powered by Xedge")
else
   trace("Powered by Mako")
end
```

## appmgr.start()

Starts the lab app.

```lua
local ok, err = appmgr.start()
```

Behavior:

- Calls `appmgr.create()` internally if needed.
- Fails with `nil, "already running"` if the lab is already running.
- Under Mako, starts the lab with `mako.createapp`.
- Under Xedge, starts the lab with `xedge.auxapp`.

On success:

```lua
true
```

On failure:

```lua
nil, err
```

When the app starts:

- Mako executes `.preload`.
- Xedge executes `.preload` and loads `.xlua` files.

## appmgr.running()

Returns whether the lab app is currently running.

```lua
local running = appmgr.running()
```

Returns:

| Value | Meaning |
|---|---|
| `true` | The lab app is running. |
| `false` | The lab app is stopped. |

Example:

```lua
if not appmgr.running() then
   local ok, err = appmgr.start()
   if not ok then return nil, err end
end
```

## appmgr.stop()

Stops the lab app.

```lua
local ok, err = appmgr.stop()
```

Behavior:

- Under Mako, calls `mako.stopapp` and `mako.removeapp`.
- Under Xedge, calls `xedge.auxapp` with `{ running = false }`.
- If the lab is not running, returns `nil, "not running"`.

On success:

```lua
true
```

On failure:

```lua
nil, err
```

Shutdown handlers such as `onunload()` may run as part of the underlying Mako
or Xedge shutdown behavior.

## appmgr.filePath(path, file)

Combines a directory path and file name into a slash-separated relative path.

```lua
local fullPath = appmgr.filePath(path, file)
```

Behavior:

```lua
appmgr.filePath("", "index.lsp")        -- "index.lsp"
appmgr.filePath("AJAX", "index.lsp")    -- "AJAX/index.lsp"
appmgr.filePath("a/b", "file.lua")      -- "a/b/file.lua"
```

This helper is useful with `appmgr.recDirIter`, which returns the directory
path and file name separately.

## appmgr.recDirIter(io, curPath, ldir)

Returns a recursive iterator over a BAS IO tree.

```lua
for path, name in appmgr.recDirIter(io, curPath, ldir) do
   ...
end
```

Parameters:

| Parameter | Type | Description |
|---|---:|---|
| `io` | BAS IO | IO object to iterate, such as `ghio` or `labIo`. |
| `curPath` | string | Directory path to start from. Use `""` for the IO root. |
| `ldir` | boolean/nil | When true, the iterator also yields directory entries. |

For file entries:

```lua
path = "directory/path"
name = "fileName.ext"
```

For directory entries when `ldir == true`:

```lua
path = "directory/path"
name = nil
```

The root directory `""` is not yielded as a directory entry.

When the iterator is exhausted, it returns:

```lua
nil, nil
```

Example: list all files in the GitHub IO's `AJAX` example directory:

```lua
for path, name in appmgr.recDirIter(ghio, "AJAX") do
   trace(appmgr.filePath(path, name))
end
```

Example: list all files in the lab:

```lua
local labIo = appmgr.getLabIo()

for path, name in appmgr.recDirIter(labIo, "") do
   trace(appmgr.filePath(path, name))
end
```

Example: include directory entries:

```lua
for path, name in appmgr.recDirIter(labIo, "", true) do
   if name then
      trace("file", appmgr.filePath(path, name))
   else
      trace("dir", path)
   end
end
```

## appmgr.copy2lab(io, path)

Copies a directory tree from another BAS IO into the lab.

```lua
local ok, err = appmgr.copy2lab(io, path)
```

Parameters:

| Parameter | Type | Description |
|---|---:|---|
| `io` | BAS IO | Source IO. Typically the `GitHubIo` instance for `RealTimeLogic/LSP-Examples`. |
| `path` | string | Source directory to copy. |

The lab must already be created:

```lua
local ok, err = appmgr.create()
if not ok then return nil, err end
```

The source path must be a directory.

Example: copy the `AJAX` example from GitHub into the lab:

```lua
local ok, err = appmgr.copy2lab(ghio, "AJAX")
if not ok then
   trace("copy failed", err)
end
```

The selected source directory name is stripped when copying. Copying `AJAX`
creates lab entries such as:

```text
README.md
www/...
```

The selected source directory is copied into a temporary staging directory
first. Only after staging succeeds does `copy2lab` clear and replace the lab.
If a source read fails, such as a GitHub rate-limit or authorization error, the
current lab is left unchanged and the staging directory is removed.

The function copies file contents through `rwfile.file` and creates directories
as needed.

Returns:

```lua
true
```

or:

```lua
nil, err
```

## appmgr.backup(name, copy)

Backs up the compatibility lab contents into a subdirectory of `lsplab-backup`.

```lua
local ok, err = appmgr.backup(name, copy)
```

Parameters:

| Parameter | Type | Description |
|---|---:|---|
| `name` | string | Backup directory name under `lsplab-backup`. |
| `copy` | boolean/nil | When true, copy lab files into the backup and leave the lab unchanged. When false or nil, move lab files into the backup and then clear remaining lab directories. |

The lab must already be created. `appmgr.create()` also initializes the backup
base IO.

The backup name must not already exist. `appmgr.backup` never overwrites or
merges an existing backup directory. A collision returns:

```lua
nil, "backup <name> already exists", "backupAlreadyExists"
```

Examples:

Copy the lab into a backup and keep the lab intact:

```lua
local ok, err = appmgr.backup("before-edit", true)
```

Move the lab into a backup, leaving the lab empty:

```lua
local ok, err = appmgr.backup("old-project", false)
```

or:

```lua
local ok, err = appmgr.backup("old-project")
```

Returns:

```lua
true
```

or:

```lua
nil, err
```

Use this before copying a new example when the user chooses to preserve existing
lab files.

## appmgr.listBackups()

Lists backup directories under `lsplab-backup`.

```lua
local backups, err = appmgr.listBackups()
```

The lab must already be created so the backup storage IO is initialized.

On success, returns a sorted array of backup directory names:

```lua
{
   "before-edit",
   "old-project"
}
```

On failure:

```lua
nil, err
```

MCP tools should present these names as numbered choices when asking a user
which backup to restore.

## appmgr.restore(name)

Restores a named backup into the lab.

```lua
local ok, err = appmgr.restore(name)
```

Parameters:

| Parameter | Type | Description |
|---|---:|---|
| `name` | string | Backup directory name under `lsplab-backup`. |

The selected backup is copied into a temporary staging directory first. Only
after staging succeeds does `restore` clear and replace the current lab. If the
backup cannot be read, the current lab is left unchanged and the staging
directory is removed.

On success:

```lua
true
```

On failure:

```lua
nil, err
```

This is destructive because it replaces the current lab. An MCP tool that
exposes this function should require explicit user confirmation.

## appmgr.rmlab()

Removes all resources in the lab.

```lua
local ok, err = appmgr.rmlab()
```

The lab must already be created.

Behavior:

1. Recursively iterates all lab files.
2. Removes files.
3. Removes directories in reverse order so children are removed before parents.
4. Aggregates any removal errors into one newline-separated error string.

On success:

```lua
true
```

On failure:

```lua
nil, err
```

This is destructive. An MCP tool that exposes this function should require
explicit user confirmation.

## Typical Named-Lab MCP Workflow

Create a user-named lab, or resolve an existing session selection:

```lua
local lab, err = appmgr.createLab("router-demo")
-- Existing selection: local lab, err = appmgr.getLab(selectedName)
if not lab then
   return FastMCP.error("Cannot resolve lab", { error = err })
end

local labIo, executeIo = lab:getLabIo()
```

Use the lab object for lifecycle and content operations:

```lua
local ok, err = lab:backup("before-new-example", true)
if not ok then return FastMCP.error("Cannot back up lab", { error=err }) end

ok, err = lab:copy2lab(ghio, "AJAX")
if not ok then return FastMCP.error("Cannot copy example", { error=err }) end

if not lab:isRunning() then
   ok, err = lab:start()
   if not ok then return FastMCP.error("Cannot start lab", { error=err }) end
end
```

An MCP server should keep only the selected lab name in session state, resolve
the object for each call, ask the user when selection is ambiguous, and require
confirmation for destructive lifecycle changes. It must ask for explicit lab
and backup names instead of inventing them.

Recommended mapping:

| MCP behavior | Manager or lab function |
|---|---|
| List labs | `appmgr.listLabs()` |
| Create lab | `appmgr.createLab(name, basePath)` |
| Resolve lab | `appmgr.getLab(name)` |
| Change route | `appmgr.setLabBasePath(name, basePath)` |
| Rename lab | `appmgr.renameLab(name, newName)` |
| Delete lab and backups | `appmgr.deleteLab(name)` |
| Runtime IO detection | `lab:getLabIo()` |
| Start or stop | `lab:start()` / `lab:stop()` |
| Running status | `lab:isRunning()` |
| Recursive listing | `appmgr.recDirIter(io, path, ldir)` |
| Copy source tree | `lab:copy2lab(sourceIo, path)` |
| Move or copy backup | `lab:backup(name, false)` / `lab:backup(name, true)` |
| Clear lab | `lab:rmlab()` |
