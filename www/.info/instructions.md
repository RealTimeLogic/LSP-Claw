This MCP server helps AI agents build Barracuda App Server (BAS), Mako Server,
Xedge, and Xedge32 applications.

Treat the MCP tools, returned resources, lab file inventory, and trace output as
the authority for the remote lab. The MCP server may run on a different machine
than the AI client. Do not assume direct filesystem access to the lab.

## Environments

LSP-Claw exposes two separate environments:

1. GitHub source examples
   - Read-only reference material from RealTimeLogic/LSP-Examples.
   - Use for selecting, reading, and copying starter projects.
   - Typical tools: getExampleCatalog, readExampleFile, copyExampleToLab.

2. Local lab app
   - One or more writable BAS/Mako/Xedge apps managed by LSP-Claw.
   - Use for all changes after copying an example or creating a new app.
   - Typical tools: createLab, listLabFiles, readLabFile, writeLabFile,
     startLab, stopLab, backupLab, listLabBackups, restoreLab,
     readRuntimeTrace.

Only modify lab files through the MCP lab tools. Respect lab path restrictions,
overwrite protections, and backup/restore semantics.

## Multiple Labs

- Call `listLabs` when the user has not identified a lab or when a stored
  selection is no longer valid.
- If exactly one lab exists, LSP-Claw selects it automatically for the current
  MCP session.
- If multiple labs exist and the session has no selection, present the numbered
  choices and ask the user. Never guess a lab.
- Use `selectLab` to change only the current MCP session. Selection never starts,
  stops, creates, or modifies a lab.
- An explicit `labName` on a lab-bound tool overrides selection for that call
  only; it does not change the session selection.
- When no lab exists, ask the user for a unique name before calling `createLab`.
  Never invent or infer a lab name.
- `renameLab`, `deleteLab`, and `setLabBasePath` require explicit confirmation
  and a stopped lab. Deleting a lab also deletes all of its backups.
- All labs share the server's configured MCP bearer token. Labs isolate
  workspace and runtime state; they are not separate authorization domains.

## Complete Lab Archives

- Use `prepareLabExport` when the user asks to copy or extract a complete lab.
  Download the returned one-time URL directly to the user's requested path;
  never request or relay ZIP bytes through MCP text or model context.
- Use `prepareLabImport` for a local ZIP. POST the raw ZIP directly to the
  returned one-time URL as `application/zip`. A locally prepared ZIP may be
  stored or compressed.
- Import requires a user-provided destination lab name and `conflictAction` of
  `createNew` or `replace`. Never infer the destination name.
- `replace` requires explicit user confirmation and a stopped lab. Import does
  not merge archive files with destination files.
- Transfer URLs expire and work once. Prepare a new URL after expiration, use,
  or a failed request. Do not put bearer tokens into these URLs.
- The browser configuration page provides direct Download ZIP and Upload ZIP
  controls for transfers to and from the user's file system.
- To copy between two configured LSP-Claw MCP servers, call
  `prepareLabTransfer` on the source entity, then call `importLabTransfer` on
  the destination entity with the returned descriptor. Do not read individual
  files or relay ZIP bytes.
- Before the destination fetch, show the exact `sourceOrigin` returned by
  `transferSourceRequiresConfirmation` and ask the user to confirm it. Pass
  that exact value as `confirmedSourceOrigin`; never infer confirmation.
- The source and destination normally have different MCP bearer tokens. Never
  copy, expose, or forward either persistent token. Relay only the short-lived
  transfer descriptor, and do not print, log, summarize, or retain its
  `transferTicket` after the destination call.

## Runtime Feedback

When using Streamable HTTP, open the MCP GET SSE stream after initialize and keep
it open while writing and running lab programs. Trace notifications with
logger = "trace" may include trace(...), Lua exceptions, stack traces, and BAS
diagnostics.

The trace stream and `readRuntimeTrace` buffer are server-global. Do not claim
that an ordinary trace message belongs to a selected lab unless the application
itself included reliable identifying context in the message.

Tool responses such as startLab and writeLabFile only prove that the request was
accepted. They do not prove that Lua code ran correctly.

If async notifications are not visible to the AI agent/model:

- say so explicitly,
- call readRuntimeTrace immediately after startLab, writeLabFile with .xlua
  activation, or any action expected to execute Lua code,
- inspect overflowed, truncated, and droppedBytes before relying on the trace.

Do not trace secrets, bearer tokens, authorization headers, cookies, private
keys, or large payloads.

## URLs

Tool responses such as getLabStatus and startLab may include labApp.appUrl and
labApp.entryUrls. Prefer those absolute URLs when present.

If only relative lab paths are available, derive the browser URL from the MCP
server scheme, host, and port. Do not assume localhost unless the MCP endpoint
itself is localhost.

## Optional Public Skills

Use these only when the task touches the matching area. Do not load every skill
by default.

- BAS skill selector:
  https://realtimelogic.com/downloads/ai-skills/AGENTS.md
- BAS VFS/routing/resource readers:
  https://realtimelogic.com/downloads/ai-skills/VFS-skill.md
- Authentication, authorization, sessions, users:
  https://realtimelogic.com/downloads/ai-skills/Authentication-Authorization-Skill.md
- General OWASP-style BAS security review:
  https://realtimelogic.com/downloads/ai-skills/OWASP-General-Security-Skill.md
- SQLite dedicated-writer pattern:
  https://realtimelogic.com/downloads/ai-skills/SQLite-Skill.md
- SMQ topics, browser/device messaging, broker authorization:
  https://realtimelogic.com/downloads/ai-skills/SMQ-Skill.md
- Lua/native bindings and custom BAS runtime integration:
  https://realtimelogic.com/downloads/ai-skills/Lua-Binding-Skill.md
- Mako Server deployment, services, mako.conf, logs, and certificates:
  https://realtimelogic.com/downloads/ai-skills/Deploy-Mako-Server-Skill.md
- LSP web interfaces, forms, htmx, Fetch/JSON, WebSockets, and dashboards:
  https://realtimelogic.com/downloads/ai-skills/Build-LSP-Web-Interfaces-Skill.md

Start with the smallest matching skill. Add another only when the task crosses
into that area. For example, combine VFS, authentication, and OWASP for a
protected REST/admin subtree; combine LSP web interfaces, SQLite, and OWASP for
a database-backed browser form or API; combine LSP web interfaces and SMQ for a
live browser/device dashboard.

## Example-First Workflow

When the user asks which GitHub example to use:

1. Use getExampleCatalog.
2. Select the example yourself from summary, topics, useWhen, avoidWhen,
   compatibility, variants, defaultVariant, and run fields.
3. Use readExampleFile to read the selected example's AGENTS.md, for example
   AJAX/AGENTS.md or Light-Dashboard/AGENTS.md.
4. Follow that AGENTS.md. Read the README, variant README, design note, or
   source files it names before copying or editing.
5. Choose the exact runnable source directory to copy, such as AJAX/www,
   Light-Dashboard/custom, or SMQ-examples/RPC/www.
6. Use copyExampleToLab with that exact sourcePath. It strips the selected
   prefix, so sourcePath AJAX/www creates lab/index.lsp, not lab/AJAX/www/index.lsp.
7. Open the SSE stream before running the lab.
8. Use lab tools for all further edits.
9. Use startLab and monitor trace notifications, or readRuntimeTrace if
   notifications are unavailable.

Selection rules:

- LSP-Claw does not rank examples. The AI agent chooses.
- Prefer examples whose useWhen, topics, protocol, variants, and run commands
  match the user's requested workflow.
- Use avoidWhen to reject superficially related examples that do not fit.
- If the request is specific enough to implement directly, build from scratch
  instead of forcing an example.
- When copying, choose the app root whose contents should become the lab root.
  Do not copy a parent directory that would leave wrapper folders such as www/
  inside the lab.

## Build-From-Scratch Workflow

When the user asks to design or build an app:

1. Use getRuntimeInfo and getLabStatus.
2. Resolve the lab with `listLabs`/`selectLab`. If no lab exists, ask the user
   for its name and call `createLab` with that exact name.
3. Use listLabFiles and readLabFile before modifying existing files.
4. Use writeLabFile for .lsp, .preload, static assets, and BAS app files.
5. Open the SSE stream before running or testing.
6. Use startLab.
7. Request the relevant .lsp page or app URL through the BAS host, preferring
   labApp.appUrl and labApp.entryUrls.
8. Monitor trace notifications or call readRuntimeTrace after runtime actions.
9. Use stopLab when finished or before changing startup-sensitive files.

If an existing example would not clearly accelerate the request, design the app
directly with the MCP tools.

## Backup Restore

- When the user asks to back up a lab without specifying an exact backup name,
  identify the selected lab and ask what name to use before calling backupLab.
- Never invent or infer a backup name from the date, lab name, task, or
  conversation.
- The same rule applies when copyExampleToLab uses conflictAction =
  backupExisting. Ask for backupName before calling the tool.
- If backupAlreadyExists is returned, ask for another name. Never overwrite or
  merge an existing backup implicitly.
- Use listLabBackups when the user asks what backups exist or wants restore.
- Present backup choices as numbered options.
- If the user says "Select backup 1", map 1 to choices[1].backupName.
- restoreLab replaces the current lab and requires explicit confirmation.
- If restoreLab reports "not found", show the numbered choices and ask for a
  number or exact backupName.

## Runtime Debugging

- Add temporary trace(...) messages to understand control flow, values, and
  failing branches.
- Use trace output, Lua exceptions, stack traces, and HTTP behavior to fix the
  smallest relevant file set.
- Remove temporary trace instrumentation after the issue is understood or fixed.
- Keep changes small and incremental.

## Development Rules

- Use only BAS/Mako/Xedge-compatible Lua.
- Use BAS APIs and existing project conventions.
- Do not introduce third-party Lua modules.
- Use correct LSP syntax:
  - <?lsp ?> for Lua execution
  - <?lsp= ?> for expression output
- For Mako-only testing, prefer .lsp files and HTTP requests to those pages.
- Use .xlua activation only when getRuntimeInfo reports Xedge support and the
  lab is running.
- For state shared between .preload and .lsp pages, store values on the app
  table, for example app.temperature = { value = 21.0 }.
- Preserve existing example structure unless there is a clear reason to refactor.
- Explain created or modified files.
- Avoid large or binary files unless explicitly requested.
- When targeting Xedge32, avoid APIs unsuitable for constrained embedded targets.

## BAS API Guidance

Use official BAS documentation and public BAS AI skills before inventing APIs.
The old BAS and Mako tutorial markdown files have been replaced by task-specific
skills. Use the BAS skill selector first when you need to choose which public
skill applies:

- BAS skill selector:
  https://realtimelogic.com/downloads/ai-skills/AGENTS.md

For exact API names, signatures, and behavior, use:

- basapi.md:
  https://realtimelogic.com/downloads/basapi.md
- ESP32/Xedge32 API:
  https://realtimelogic.com/downloads/esp32api.md
- OPC UA API:
  https://realtimelogic.com/downloads/opcuaapi.md

Reference priority:

1. Use basapi.md for BAS API syntax, signatures, and behavior.
2. Use esp32api.md for Xedge32 and ESP32-specific APIs.
3. Use opcuaapi.md for OPC UA-specific APIs.

Use task-specific skills for architecture and workflow guidance:

- Use VFS/routing for URL layout, static files, resource readers, directory
  callbacks, mounted subdirectories, WebDAV, WFS, and protection boundaries.
- Use authentication/authorization for login, sessions, users, roles, and
  protected pages or APIs.
- Use OWASP as a cross-cutting review when an app is public, production-ready,
  network-exposed, or handles untrusted input.
- Use SQLite before designing request handlers that mutate SQLite data.
- Use SMQ for publish/subscribe, presence, request/reply, browser/device
  messaging, or synchronized clients.
- Use Lua bindings only for native C/C++ integration and BAS native objects.
- Use LSP web interfaces when choosing full-page LSP, forms, htmx, Fetch/JSON,
  WebSockets, SMQ, dashboards, or control-panel interaction models.
- Use Mako deployment for unattended service operation, mako.conf, service
  identity, logs, restart behavior, and certificate lifecycle.

If a skill conflicts with the relevant API reference, trust the API reference.

Treat BAS as an embedded/edge application server, not a generic web framework.
Prefer BAS-native APIs and examples over third-party Lua modules.

Keep responsibilities separated:

- Server-side Lua/LSP handles data, state, validation, security, and device or
  runtime logic.
- Browser JavaScript handles rendering, interaction, and calls to server
  endpoints.

Choose communication intentionally:

- LSP/forms for simple server-rendered pages.
- Fetch/AJAX or REST for request/response JSON APIs.
- SMQ or WebSockets for real-time browser/server interaction.
- trace(...) plus MCP trace notifications for runtime debugging.

Verify protocol-specific code against official documentation before generating
or changing it.
