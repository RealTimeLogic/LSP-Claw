# appmgr API Reference

## Overview

The `appmgr` module manages the local **LSP-Claw lab app**. The lab app is
stored in local persistent storage under:

```text
lsplab
```

Backups are stored next to it under:

```text
lsplab-backup
```

The module provides APIs for:

- Creating the lab and backup storage areas.
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

## Runtime Behavior

The behavior depends on the runtime environment.

| Runtime | Lab app support | `.preload` support | `.xlua` auto execution |
|---|---:|---:|---:|
| Mako Server | yes | yes | no |
| Xedge | yes | yes | yes |
| Xedge running as a Mako app | yes | yes | yes |

When running under Xedge, `appmgr.getLabIo()` returns a second IO object,
`executeIo`. This IO maps to Xedge's live execution IO and can auto-execute
`.xlua` files when the lab app is running.

When running under Mako, `executeIo` is not available. `.xlua` files may still
be stored in the lab as normal files, but Mako does not auto-execute them.

## appmgr.create()

Creates and initializes the lab and backup storage areas.

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

## appmgr.getLabIo()

Returns the lab storage IO and, when available, the Xedge execution IO.

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

Backs up the current lab contents into a subdirectory of `lsplab-backup`.

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

## Typical MCP Server Workflow

Initialize storage:

```lua
local ok, err = appmgr.create()
if not ok then
   return FastMCP.error("Cannot create lab", { error = err })
end
```

Detect runtime:

```lua
local labIo, executeIo = appmgr.getLabIo()

local runtime = {
   name = executeIo and "Xedge" or "Mako",
   canExecuteXlua = executeIo ~= nil,
   running = appmgr.running()
}
```

List files in a GitHub example:

```lua
for path, name in appmgr.recDirIter(ghio, "AJAX") do
   local file = appmgr.filePath(path, name)
   trace(file)
end
```

Copy a GitHub example into the lab:

```lua
local ok, err = appmgr.copy2lab(ghio, "AJAX")
if not ok then
   return FastMCP.error("Cannot copy example", { error = err })
end
```

Move existing lab files to a backup before copying a new example:

```lua
local ok, err = appmgr.backup("before-new-example")
if not ok then
   return FastMCP.error("Cannot back up lab", { error = err })
end

ok, err = appmgr.copy2lab(ghio, "AJAX")
if not ok then
   return FastMCP.error("Cannot copy example", { error = err })
end
```

Delete all lab files before copying a new example:

```lua
local ok, err = appmgr.rmlab()
if not ok then
   return FastMCP.error("Cannot clear lab", { error = err })
end

ok, err = appmgr.copy2lab(ghio, "AJAX")
```

Start the lab:

```lua
if not appmgr.running() then
   local ok, err = appmgr.start()
   if not ok then
      return FastMCP.error("Cannot start lab", { error = err })
   end
end
```

## AI Agent Recommendations

An MCP server built on `appmgr` should tell the AI agent to:

1. Call `appmgr.create()` during server initialization or before lab operations.
2. Use `appmgr.getLabIo()` to detect Mako vs Xedge.
3. Treat `executeIo ~= nil` as Xedge runtime detection.
4. Assume `.xlua` auto execution only works on Xedge.
5. Check `appmgr.running()` before using `executeIo` for live `.xlua` updates.
6. Use `appmgr.recDirIter()` for recursive source and lab listings.
7. Use `appmgr.copy2lab()` for copying complete examples from GitHub IO into the lab.
8. Use `appmgr.backup(name, true)` to copy-preserve existing lab files.
9. Use `appmgr.backup(name, false)` or `appmgr.backup(name)` to move existing lab files out of the way.
10. Use `appmgr.rmlab()` only after explicit user confirmation.
11. Ask the user before deleting, moving, or overwriting existing lab files.

## Notes for MCP Tool Authors

The `appmgr` API intentionally provides higher-level operations for common lab
management workflows. MCP tools should prefer these functions over duplicating
recursive copy, backup, and delete logic.

Recommended mapping:

| MCP tool behavior | appmgr function |
|---|---|
| Create lab | `appmgr.create()` |
| Runtime detection | `appmgr.getLabIo()` |
| Start lab | `appmgr.start()` |
| Stop lab | `appmgr.stop()` |
| Lab running status | `appmgr.running()` |
| Recursive listing | `appmgr.recDirIter(io, path, ldir)` |
| Join iterator path and name | `appmgr.filePath(path, name)` |
| Copy GitHub example to lab | `appmgr.copy2lab(ghio, path)` |
| Move lab to backup | `appmgr.backup(name, false)` |
| Copy lab to backup | `appmgr.backup(name, true)` |
| Clear lab | `appmgr.rmlab()` |
