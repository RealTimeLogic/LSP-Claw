# LSP-Claw Design

## Purpose

LSP-Claw is an MCP server for AI-assisted development of BAS, Mako Server,
Xedge, and Xedge32 applications. It gives an AI agent controlled access to two
separate areas:

- The read-only `RealTimeLogic/LSP-Examples` GitHub repository.
- A writable local lab app managed by LSP-Claw.

The design goal is to let the AI agent inspect examples, create or modify a lab
application, start the lab, and use runtime trace output for debugging without
giving the agent unrestricted access to the host filesystem.

Related documents:

- [FastMCP.md](FastMCP.md) explains the Lua MCP framework, Streamable HTTP
  transport, sessions, resources, tools, prompts, and notifications.
- [appmgr.md](appmgr.md) explains the lab manager API used by LSP-Claw for lab
  creation, copying, backup, clearing, start, and stop operations.
- [Lab-Archives.md](Lab-Archives.md) defines complete lab ZIP import/export,
  validation limits, transfer tickets, and staged replacement.
- [README.md](../README.md) is the user-facing tutorial and setup guide.

## Runtime Structure

The runtime entry point is `www/.preload`.

At startup, `.preload`:

1. Requires Mako or Xedge.
2. Creates the app-local Lua loader with `mako.createloader(io)` or
   `xedge.createloader(io)`.
3. Loads optional GitHub and MCP authentication tokens.
4. Creates a `GitHubIo` instance for `RealTimeLogic/LSP-Examples`.
5. Creates the `appmgr` lab manager.
6. Creates the lab archive manager.
7. Creates a FastMCP server.
8. Registers the LSP-Claw tools, resources, and prompts through
   `require"lspclaw".register(...)`.
9. Creates the Streamable HTTP transport.
10. Exposes the MCP, archive, and browser lab-management services.

`www/mcp.lsp` is intentionally small:

```lua
<?lsp
app.cmdService(request)
?>
```

The MCP transport owns the HTTP protocol details. LSP-Claw owns the tools,
resources, prompts, lab behavior, and agent-facing instructions.

## Major Modules

### `www/.preload`

`.preload` wires the application together. It owns:

- Runtime detection and loader setup.
- Token loading and encrypted token storage through `app.getSetTokens`.
- GitHub IO creation.
- Trace capture and trace forwarding.
- MCP Streamable HTTP transport configuration.
- Origin and bearer-token authorization.
- Short-lived archive upload/download services using the same authentication
  boundary as the setup page and MCP endpoint.

### `www/.lua/lspclaw.lua`

`lspclaw.lua` registers the MCP API. It should contain behavior and structured
API definitions, not long agent-facing prose. Agent-facing prose is stored in
`www/.info`.

The current design intentionally keeps the example API minimal. The server does
not rank examples, inspect examples semantically, or select app roots. The AI
agent makes those decisions by reading [catalog and example guidance](https://github.com/RealTimeLogic/LSP-Examples/blob/master/.ai/main-ai-catalog.json).

### `www/.lua/appmgr.lua`

`appmgr` manages the lab app. See [appmgr.md](appmgr.md) for the full API.

Important behavior:

- `appmgr` persists known labs and lifecycle metadata in
  `LSP-Claw-Labs.json`; lab file contents never enter the registry.
- Each named lab uses a top-level storage directory and a sibling
  `<labName>-backup` directory. Labs are not nested under a common container.
- An existing `lsplab` installation is registered without moving its contents
  and keeps `lsplab-backup`.
- Each stateful MCP session stores only its selected lab name. Lab objects and
  contents remain in `appmgr`, not in the FastMCP session.
- With one lab, selection is automatic. With multiple labs, lab-bound tools
  return `labSelectionRequired` until the user chooses with `selectLab`.
- Lab-bound tools accept an optional `labName` override for one call without
  changing session selection.
- Routes are direct (`/lab1/`, not `/labs/lab1/`) and unique. A user can change
  a stopped lab's route with `setLabBasePath` after confirmation.
- `appmgr.copy2lab(io, path)` copies the contents of the selected source path
  into the lab root and strips the selected source path prefix.
- Copying is staged outside the lab first. The lab is replaced only after all
  source files have been read successfully, so GitHub read failures do not
  leave a partial copy in the lab.
- Under Mako, `.lsp` and `.preload` execute, but `.xlua` files are stored only.
- Under Xedge, `.xlua` activation is available through the execution IO when
  the lab is running.

### `www/.lua/fastmcp/*`

FastMCP provides the MCP engine and HTTP transport. See [FastMCP.md](FastMCP.md)
for the current API, schema subset, limits, and transport contract. LSP-Claw
explicitly trusts forwarded headers because it is commonly routed as an Xedge
application; its front-end proxy must sanitize those headers. FastMCP ignores
forwarded headers by default in other applications.

LSP-Claw uses the Streamable HTTP transport because runtime trace notifications
are important to the AI workflow.

## MCP API

LSP-Claw exposes a deliberately small API.

### Tools

- `getRuntimeInfo`
- `readRuntimeTrace`
- `getLabStatus`
- `listLabs`
- `selectLab`
- `createLab`
- `renameLab`
- `deleteLab`
- `setLabBasePath`
- `startLab`
- `stopLab`
- `getExampleCatalog`
- `readExampleFile`
- `copyExampleToLab`
- `listLabFiles`
- `readLabFile`
- `writeLabFile`
- `clearLab`
- `backupLab`
- `listLabBackups`
- `restoreLab`
- `prepareLabExport`
- `prepareLabImport`
- `prepareLabTransfer`
- `importLabTransfer`

`prepareLabExport` and `prepareLabImport` return short-lived direct binary
transfer URLs. Archive bytes are not returned by MCP. See
[Lab-Archives.md](Lab-Archives.md).

The transfer pair lets an MCP client relay only a small, short-lived snapshot
descriptor from one independently authenticated LSP-Claw entity to another.
The destination downloads and validates the archive directly; neither server's
persistent MCP token is sent to the other.

### Resources

- `lspclaw://instructions`
- `lspclaw://runtime`
- `lspclaw://lab/status`
- `lspclaw://examples/root`

`lspclaw://examples/root` includes the root GitHub entries, catalog entries,
and copy guidance. The guidance is intentionally early in the payload so an
agent does not need to infer copy behavior from implementation details.

### Resource Templates

LSP-Claw currently exposes no resource templates. `resources/templates/list`
must return an empty JSON array.

### Prompts

- `chooseExampleForUserGoal`
- `buildFromExampleWorkflow`
- `makoXedgeRuntimeGuide`

Prompt text is stored in `www/.info`.

## Example Selection Design

Example discovery is based on `.ai/main-ai-catalog.json` in the
`RealTimeLogic/LSP-Examples` repository.

`getExampleCatalog` returns that catalog, optionally filtered to one example
path. The catalog is selection data for the AI agent. It is not a server-side
recommendation.

The intended workflow is:

1. Call `getRuntimeInfo`.
2. Call `getLabStatus`.
3. Call `getExampleCatalog`.
4. Choose an example using catalog fields such as `summary`, `topics`,
   `useWhen`, `avoidWhen`, `compatibility`, `variants`, `defaultVariant`, and
   `run`.
5. Read the selected example's `AGENTS.md` with `readExampleFile`.
6. Read any README, variant README, design document, or source file that
   `AGENTS.md` tells the agent to read.
7. Choose the exact runnable source directory.
8. Call `copyExampleToLab` only with that explicit `sourcePath`.

This design keeps the MCP server mechanical and leaves reasoning to the AI
agent.

## Copy Semantics

`copyExampleToLab` takes one required source directory:

```json
{
  "sourcePath": "AJAX/www"
}
```

The contents of `sourcePath` are copied into the lab root. The `sourcePath`
directory itself is stripped.

For example:

```text
sourcePath = AJAX/www
```

creates lab files such as:

```text
index.lsp
.config
```

It must not create:

```text
AJAX/www/index.lsp
www/index.lsp
```

This is important because the lab itself is the runnable application root.

If the lab already contains files, `copyExampleToLab` requires explicit
confirmation before deleting, moving, or overwriting existing lab content.
Internally, the source is staged before the lab is replaced. If GitHub returns
an error while reading the example, the existing lab is left unchanged and the
error preserves the upstream GitHub HTTP status and message where available.

## Lab Design

Named labs are the writable application areas exposed to the AI agent.

The lab workflow is:

1. `listLabs` discovers labs; `selectLab` chooses one for the MCP session.
2. `createLab` creates a user-named lab when none exists or another is needed.
3. `listLabFiles` and `readLabFile` inspect current lab files.
4. `writeLabFile` creates or updates lab files.
5. `copyExampleToLab` copies a selected example app root into the lab.
6. `backupLab` preserves lab state.
7. `listLabBackups` lists backup directories with numbered choices.
8. `restoreLab` restores a selected backup after explicit confirmation.
9. `clearLab` removes lab state after explicit confirmation.
10. `startLab` starts the lab app at its unique direct base path.
11. `stopLab` stops the lab app.

When the user asks to back up the lab without providing an exact name, the
agent must ask what name to use before calling `backupLab`. It must never derive
a name from the date, lab, task, or conversation. The same rule applies to
`copyExampleToLab` with `conflictAction = "backupExisting"`. Existing backup
names are rejected with `backupAlreadyExists`; they are never overwritten or
merged implicitly.

When a user wants to restore a backup but does not know the exact backup name,
the agent should call `listLabBackups` and present the returned choices as a
numbered list. If the user replies with a phrase such as `Select backup 1`, the
agent maps the number to `choices[1].backupName` and then calls `restoreLab`
with that exact backup name after confirmation.

The runtime trace is server-global. `readRuntimeTrace` reports
`labAttributionReliable = false`; selection does not filter ordinary BAS trace
messages by lab.

The AI agent must not assume local filesystem access to the server. It should
use MCP lab tools as the authority for lab state.

## Runtime Trace Design

Trace is a core part of LSP-Claw. AI agents need runtime feedback to understand
server-side Lua behavior.

`.preload` creates a trace logger and forwards trace data in two ways:

- Live Streamable HTTP notifications:
  `notifications/message` with `logger = "trace"`.
- A bounded runtime trace buffer exposed through `readRuntimeTrace`.

Clients should expose async notifications to the AI model when possible. If the
client does not expose notifications, the agent should call `readRuntimeTrace`
after runtime actions such as `startLab`, page requests, or `.xlua`
activation.

`readRuntimeTrace` always clears the buffer after reading. The buffer size is
configured by `.preload` and can be changed with `app.setRuntimeTraceBufferSize`.

## `.info` Guidance Files

Long agent-facing text is stored in `www/.info`, not inline in `lspclaw.lua`.

This includes:

- Main instructions.
- Prompt templates.
- Runtime guidance.
- Runtime warnings.
- Lab URL guidance.
- Lab next actions.
- Example copy guidance.
- Copy result semantics.

`lspclaw.lua` loads these files with:

```lua
local rw = require"rwfile"
rw.file(io, ".info/FILE-NAME.md")
```

Markdown bullet files are parsed into arrays for MCP `nextActions` and
guidance fields. Plain Markdown files are returned as strings.

Keeping this text in `.info` makes it easier to review and update guidance
without editing behavior code.

## Authentication And Tokens

LSP-Claw has two optional tokens:

- `GITHUB_TOKEN` or `GH_TOKEN` for outbound GitHub API access.
- `MCP_AUTH_TOKEN` for inbound MCP bearer-token authentication.

Under Mako, tokens can come from environment variables or `mako.conf`.

Both Mako and Xedge can also use the browser setup page. The setup page calls
`app.getSetTokens(githubToken, authToken)`. Tokens saved this way are stored
encrypted using key material derived from `ba.tpm.uniquekey`.

`getRuntimeInfo` reports whether each token is configured, but never returns
the token value. It also returns a setup page URL template derived from
`dir:baseuri()`:

```text
http://<mcp-server-address><base-uri>
```

For example, if `dir:baseuri()` is empty, the setup page is:

```text
http://<mcp-server-address>/
```

An AI agent should present this setup URL to the human when either token is
missing. It should explain that a missing GitHub token can cause unauthenticated
GitHub rate limits, while a missing MCP auth token means any client that can
reach the endpoint can use the MCP server.

If no MCP auth token is set, the MCP endpoint is unauthenticated. If a token is
set, MCP clients must provide the configured bearer token.

## Origin Handling

The Streamable HTTP transport calls `authorizeRequest`.

Origin behavior:

- Requests without an `Origin` header are allowed.
- Local browser origins such as `localhost`, `127.0.0.1`, and `[::1]` are
  allowed.
- Other origins are rejected.

This allows non-browser MCP clients to connect without an origin while still
protecting browser-based cross-origin access.

## AI Agent Contract

An AI agent should treat LSP-Claw as a remote controlled development
environment.

The agent should:

- Check runtime and call `listLabs` first; select a lab before requesting its
  status when multiple choices exist.
- Use the catalog to choose examples.
- Read the selected example's `AGENTS.md`.
- Choose explicit source paths when copying.
- Never rely on server-side ranking or inference.
- Use `copyExampleToLab` only after deciding the exact app root.
- Ask before destructive lab operations unless the user explicitly authorized
  them.
- Start the lab and inspect trace output.
- Prefer live `notifications/message` trace events when available.
- Use `readRuntimeTrace` as the fallback for clients that do not expose async
  notifications.

The agent should not:

- Assume local filesystem access to the lab.
- Copy a wrapper directory when the runnable app root is deeper.
- Treat `getExampleCatalog` as a recommendation engine.
- Invent BAS, Mako, Xedge, SMQ, or LSP APIs without checking documentation.

## Test Expectations

A complete MCP smoke test should verify:

- `initialize`
- `tools/list`
- `resources/list`
- `resources/templates/list`
- `prompts/list`
- The 21-tool surface, all resources, and all prompts
- Zero-lab `labCreationRequired` behavior
- Automatic single-lab selection and explicit multiple-lab selection
- Isolation between at least two stateful MCP sessions
- One-call `labName` overrides that do not change session selection
- Two simultaneous labs serving different content at distinct direct routes
- Rename, base-path change, delete, and session-selection cleanup
- Server-global trace metadata
- Required user-provided backup names and backup-name collisions

The repeatable framework, lab-management, and packaged regressions are
`tests/fastmcp/Test-FastMCP.ps1`,
`tests/lab-management/Test-LabManagement.ps1`, and
`tests/Test-LSP-Claw.ps1`. The lab-management test uses an isolated temporary
Mako home and two Mako process runs. It verifies legacy migration without a
move, name validation, top-level per-lab storage, isolated backup namespaces,
stale-stage recovery, registry persistence, lifecycle locks, rename/delete,
and restart behavior. The packaged test uses three stateful sessions and two
labs to verify selection isolation, explicit overrides, direct runtime routes,
session cleanup, and the 21-tool MCP surface. It also
verifies `backupNameRequired`, origin-aware lab URLs, actual HTTP content at
both lab routes, session deletion, and Mako process cleanup.
