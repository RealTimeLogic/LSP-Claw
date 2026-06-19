This MCP server helps AI agents build Barracuda App Server (BAS), Mako Server,
Xedge, and Xedge32 applications. It supports two main workflows:

1. Select, read, copy, and adapt examples from the RealTimeLogic/LSP-Examples
   GitHub repository.
2. Design and build a new lab application directly from the user's request by
   creating and editing files through the MCP tools.

The server may run on a different machine than the AI client. Treat MCP tools,
resources, and trace notifications as the authority for runtime state, lab file
contents, and server feedback. Do not assume direct filesystem access to the
server's lab.

The server provides two distinct environments:

1. GitHub source examples
   - Read-only reference material.
   - Used for selecting, reading, and copying starter projects.
   - Accessed with tools such as:
     - getExampleCatalog
     - readExampleFile

2. Local lab app
   - Writable BAS/Mako/Xedge app managed by LSP-Claw.
   - Used for all modifications after copying an example or when creating a
     new app from scratch.
   - Accessed with tools such as:
     - createLab
     - copyExampleToLab
     - listLabFiles
     - readLabFile
     - writeLabFile
     - startLab
     - stopLab
     - backupLab
     - listLabBackups
     - restoreLab
     - readRuntimeTrace

When using the Streamable HTTP transport, open the MCP GET SSE stream after
initialize and keep it open while writing and running lab programs. The server
forwards BAS trace output as JSON-RPC notifications/message events with
logger = "trace". Use these messages as runtime feedback for LSP pages:
trace(...) output, Lua exceptions, stack traces, and server diagnostics can
appear there while the lab app runs. This applies in all supported host modes:
Mako Server, Mako Server powering Xedge, and standalone Xedge.

For full LSP-Claw support, the MCP client must expose asynchronous server
notifications to the AI agent/model. Tool responses such as startLab and
writeLabFile only confirm that the requested operation was accepted; they do
not prove that Lua runtime code behaved correctly. If your client does not
expose notifications/message events to the agent/model, say so explicitly and
do not claim to have observed runtime trace output.

If async notifications are not visible to the agent/model, call
readRuntimeTrace immediately after startLab, writeLabFile with xlua activation,
or any request that should execute Lua code. readRuntimeTrace returns buffered
trace text and always clears the buffer. Check the returned overflowed,
truncated, and droppedBytes fields before relying on the beginning of the trace
text. This is a compatibility fallback; live notifications/message events
remain the preferred real-time signal.

Tool responses such as getLabStatus and startLab may include labApp paths. These
paths are relative to the BAS/MCP server origin. Derive the full browser URL by
combining the MCP server scheme, host, and port with the returned path. For
example, if the MCP server is http://localhost/lsp-claw/mcp.lsp, lab path /
means http://localhost/. If the MCP server is remote, use that remote host
instead of localhost.

Recommended workflow when the user asks which GitHub example to use:

1. Use getExampleCatalog to read the AI catalog.
2. Select the example yourself from catalog summary, topics, useWhen,
   avoidWhen, compatibility, variants, defaultVariant, and run fields.
3. Use readExampleFile to read the selected example's AGENTS.md, for example
   AJAX/AGENTS.md or Light-Dashboard/AGENTS.md.
4. Follow the selected AGENTS.md file. Read the README, variant README, design
   note, or source files it directs you to read before copying or editing.
5. Choose the exact GitHub source directory to copy. The sourcePath must be a
   runnable app directory such as AJAX/www, Light-Dashboard/custom, or
   SMQ-examples/RPC/www.
6. Use copyExampleToLab with the explicit sourcePath to create a local editable
   lab. copyExampleToLab copies the contents of sourcePath into the lab root
   and strips the selected sourcePath prefix. For example, sourcePath AJAX/www
   creates lab/index.lsp, not lab/AJAX/www/index.lsp or lab/www/index.lsp.
7. Open the Streamable HTTP GET SSE stream before running the lab.
8. Use lab tools for all further edits.
9. Use startLab to run the lab and monitor trace notifications for errors.
10. If trace notifications are not visible to the agent/model, call
   readRuntimeTrace immediately after startLab.

Example selection guidance:

- LSP-Claw does not rank or recommend examples. The AI agent is responsible for
  choosing the example.
- Prefer examples whose summary, useWhen notes, topics, protocols, variants,
  defaultVariant, and run commands match the user's requested workflow.
- Use avoidWhen to reject examples that appear superficially related but do not
  fit the user's goal.
- If the user's request is specific enough to implement directly, build from
  scratch instead of forcing an example workflow.
- Read the selected example's AGENTS.md before recommending or copying.
- When copying an example, choose the app root directory whose contents should
  become the lab root. Do not copy a parent example directory if that would
  leave wrapper directories such as www/ inside the lab.

For example, if the user asks for a simple HTML form that updates a simulated
LED state, a basic form or small request/response example is usually more
appropriate than a logging, debugging, upload, or database example, even if one
of those has overlapping keywords.

Recommended workflow when the user asks to design or build an app:

1. Use getRuntimeInfo and getLabStatus to understand the target runtime.
2. Use createLab if the lab does not exist.
3. Use readLabFile and listLabFiles when modifying an existing lab.
4. Use writeLabFile to create or update .lsp, .preload, static assets, and
   other BAS app files.
5. Open the Streamable HTTP GET SSE stream before running or testing the lab.
6. Use startLab to run the lab.
7. Request the relevant .lsp page or app URL through the BAS host. Prefer the
   labApp paths returned by getLabStatus or startLab, and combine them with the
   MCP server origin.
8. Monitor trace notifications for trace output, Lua exceptions, and stack
   traces. Use that feedback to fix files with writeLabFile.
9. If trace notifications are not visible to the agent/model, call
   readRuntimeTrace immediately after runtime actions and inspect the returned
   trace text.
10. Use stopLab when finished or before changing startup-sensitive files.

Backup restore workflow:

- Use listLabBackups when the user asks what backups exist or wants to restore
  a previous lab.
- Present listLabBackups choices as numbered options. If the user says
  "Select backup 1", map 1 to choices[1].backupName and use that exact
  backupName.
- restoreLab replaces the current lab and requires explicit confirmation.
- If restoreLab reports that a backup was not found, show the numbered backup
  choices returned by the tool and ask the user to select one by number or exact
  backupName.

Runtime debugging pattern:

- If a Lua program does not behave as expected, temporarily instrument .lsp or
  .preload code with trace(...) messages.
- Keep the Streamable HTTP GET SSE stream open and inspect trace
  notifications to understand control flow, values, request parameters, and
  failing branches.
- For notification-blind clients, use readRuntimeTrace after each runtime action
  that should produce trace output. The tool drains the current trace buffer.
- Remove temporary trace instrumentation after the issue is understood or fixed.
- Do not trace secrets, tokens, authorization headers, cookies, or large payloads.

If the user did not ask for an existing GitHub example, do not spend time
searching examples unless an example would clearly accelerate the requested
application. It is valid to design the lab app directly with the available MCP
API.

Development rules:

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
  table. For example, in .preload use app.temperature = { value = 21.0 }, and
  in index.lsp read local temperature = app.temperature.
- Prefer small, incremental, working changes.
- Preserve existing example structure unless there is a strong reason to refactor.
- Explain all created or modified files.
- When targeting Xedge32, avoid APIs unsuitable for constrained embedded environments.

Safety rules:

- Only modify lab files through the MCP lab tools.
- Respect lab path restrictions and overwrite protections.
- Avoid large or binary files unless explicitly requested.

BAS API guidance:

- Use [basapi.md](https://realtimelogic.com/downloads/basapi.md) as
  the source of truth for BAS, Mako, Xedge, Lua Server Pages,
  request/response APIs, timers, sockets, JSON, trace, and server
  runtime behavior.
- Use
  [BAS tutorials.md](https://realtimelogic.com/downloads/tutorials.md)
  and [Mako Tutorials](https://makoserver.net/download/tutorials.md)
  for architecture, design patterns, browser/server communication
  options, security guidance, and examples.
- Use the [ESP32 API](https://realtimelogic.com/downloads/esp32api.md) for
  Xedge32 and ESP32-specific hardware APIs such as GPIO, I2C, ADC, and UART.
- Use the [OPC UA API](https://realtimelogic.com/downloads/opcuaapi.md) when designing OPC UA apps.
- If API syntax or behavior is unclear, search the documentation bundles before
  writing code. Do not invent BAS APIs.
- Prefer BAS-native APIs and examples over third-party Lua modules or generic
  web-framework patterns.
- Treat BAS as an embedded/edge application server, not a traditional web
  stack.
- Keep responsibilities separated:
  - Server-side Lua/LSP handles data, state, validation, security, and device
    or runtime logic.
  - Browser JavaScript handles rendering, interaction, and calling server
    endpoints.
- Choose the communication pattern intentionally:
  - LSP/forms for simple server-rendered pages.
  - Fetch/AJAX or REST for request/response JSON APIs.
  - SMQ or WebSockets for real-time browser/server interaction.
  - trace(...) plus Streamable HTTP trace notifications for runtime debugging.
- Verify protocol-specific code against official documentation before
  generating or changing it.
