# Lua FastMCP for the Barracuda App Server

Lua FastMCP is the transport-neutral MCP component framework used by LSP-Claw.
It can also be embedded in other BAS, Mako Server, and Xedge applications. The
implementation is in `www/.lua/fastmcp/` and has no third-party Lua dependency.

Version 0.2.0 implements tools, resources, resource templates, prompts,
JSON-RPC dispatch, and MCP Streamable HTTP. It intentionally borrows the
component model and name from Python FastMCP; it is not the Python package and
does not provide decorators or annotation-based schema inference.

## Modules

| Module | Responsibility |
|---|---|
| `fastmcp.engine` | Component registration, authorization, schema boundaries, and MCP capabilities |
| `fastmcp.schema` | The supported JSON Schema subset, validation, defaults, and request-local copies |
| `fastmcp.dispatcher` | JSON-RPC method dispatch and MCP result translation |
| `fastmcp.http` | Compatibility HTTP and stateful Streamable HTTP adapters |

## Creating a Server

Use `FastMCP.create`, following the established constructor convention for
Barracuda App Server Lua modules:

```lua
local FastMCP = require "fastmcp.engine"

local mcp = FastMCP.create {
   name = "Device Assistant",
   version = "1.0.0",
   instructions = "Use read operations before mutations.",
   strictSchemas = true,
   authorize = function(component, ctx) return true end,
   onDuplicate = "replace"
}
```

Options are `name` (required), `version`, `instructions`, `websiteUrl`,
`icons`, `meta`, `defaultEnabled`, `authorize`, `onDuplicate`,
`experimentalCapabilities`, and `strictSchemas`. Duplicate modes are
`replace`, `ignore`, `warn`, and `error`.

`strictSchemas` defaults to `true`. Validation always checks declared values.
Strict mode additionally rejects unknown object fields when a schema says
`additionalProperties = false`. Defaults are applied to a copy; caller-owned
argument tables and registration metadata are not changed. Schema validation
is not authorization.

Absent properties remain optional unless named by `required` or supplied with
a default. Lua tables are shape-checked: contiguous numeric-key tables are
arrays, string-key tables are objects, and an empty table may represent either.
Sparse, mixed-key, and invalid-key tables are rejected instead of being
silently converted to another JSON shape.

## Tools

```lua
mcp:tool("setLevel", {
   description = "Set the output level.",
   inputSchema = {
      type = "object",
      properties = {
         level = { type="integer", minimum=0, maximum=100 }
      },
      required = { "level" },
      additionalProperties = false
   },
   outputSchema = {
      type = "object",
      properties = { applied = { type="integer" } },
      required = { "applied" },
      additionalProperties = false
   },
   annotations = { idempotentHint=true }
}, function(args, ctx)
   return { applied=args.level }
end)
```

Input is validated before the handler runs. When `outputSchema` exists, the
handler's table result, or a `toolResult.structuredContent` value, is validated
afterward. Invalid client input becomes a tool error with structured `field`,
`code`, `expected`, and `received` details. Invalid output is reported as an
`outputValidation` tool implementation error.

Useful result helpers are:

```lua
return FastMCP.error("Cannot set level", { code="deviceRejected" })

return FastMCP.toolResult {
   content = { { type="text", text="Level updated" } },
   structuredContent = { applied=42 },
   meta = { request="example" }
}
```

## Resources and Resource Templates

```lua
mcp:resource("device://status", {
   name="Device status", mimeType="application/json"
}, function(ctx)
   return { online=true }
end)

mcp:resourceTemplate("device://logs/{name}", {
   name="Named log",
   mimeType="text/plain",
   parameters = {
      name = { type="string", required=true, minLength=1 }
   }
}, function(params, ctx)
   return FastMCP.resourceContent { text=readLog(params.name) }
end)
```

Static resource values are also allowed. Template captures are percent-decoded
exactly once. `+` remains `+`, as appropriate for a URI path. Invalid percent
encoding and decoded slashes are rejected, and declared parameters are
validated before the handler runs.

## Prompts

```lua
mcp:prompt("diagnose", {
   description="Create a diagnostic workflow.",
   arguments = {
      symptom = { type="string", required=true, minLength=3 }
   }
}, function(args, ctx)
   return "Diagnose this symptom: " .. args.symptom
end)
```

Prompt arguments use the same schema subset and are rejected as JSON-RPC
invalid parameters when they do not validate. A prompt handler may return a
string, messages, or `FastMCP.promptResult`.

## Supported Schema Subset

The validator supports:

- `type`: `object`, `array`, `string`, `number`, `integer`, `boolean`, `null`
- `properties`, `required`, `additionalProperties`, and `default`
- `enum` and `items`
- `minimum`, `maximum`, `minLength`, and `maxLength`
- nested objects and arrays

This is deliberately not a complete JSON Schema implementation. Keywords such
as `$ref`, combinators, patterns, formats, tuple schemas, and conditional
schemas are unsupported. Tool schemas are checked at registration so an
unsupported keyword fails early.

## Registry Control and Authorization

```lua
mcp:disable("tool", "setLevel")
mcp:enable("tool", "setLevel")
mcp:remove("tool", "setLevel")
```

Kinds may be singular or plural: tool, resource, resourceTemplate, and prompt.
Removal also removes the ordering entry, so re-registering an identifier does
not duplicate it in list responses.

The server-level `authorize(component, ctx)` callback and component-level
`authorize(ctx)` callback control discovery and access. Returning false hides
or rejects the component. HTTP authentication and browser Origin policy belong
in the HTTP adapter/application and are separate from component authorization.

## Streamable HTTP

```lua
local Http = require "fastmcp.http"

local transport = Http.streamable(mcp, {
   stateful = true,
   enableGetStream = true,
   protocolVersion = "2025-11-25",
   authorizeOrigin = authorizeRequest,
   trustForwardedHeaders = false,
   maxRequestBodyBytes = 1024 * 1024,
   maxResponseBytes = 4 * 1024 * 1024,
   maxNotificationBytes = 256 * 1024,
   maxSessions = 16,
   maxStreamsPerSession = 2,
   sessionIdleTimeoutSeconds = 30 * 60,
   sessionMaxLifetimeSeconds = 8 * 60 * 60,
   cleanupIntervalSeconds = 60
})

function app.cmdService(cmd)
   return transport:handle(cmd)
end
```

POST requires `Content-Type: application/json`; parameters such as `charset`
are accepted. A declared or observed oversized body returns HTTP 413. The
adapter rejects oversized encoded responses and notifications rather than
writing or retaining them. Checking a response size necessarily allocates its
encoded representation first.

An initialize request creates a session and returns `MCP-Session-Id`.
Subsequent POST, GET-stream, and DELETE requests must carry the ID. Missing IDs
return 400; unknown, closed, or expired IDs return 404. DELETE closes all
streams and removes the session. Cleanup runs opportunistically, and
`cleanupSessions(now)` is available for deterministic tests. Sessions contain
transport/client metadata only, not application workspace state.

The default limits are the values shown above. Tests may inject `clock` and
`sessionIdFactory`. A custom session ID must be unique, visible ASCII, and at
most 128 bytes. The built-in generator uses BAS cryptographic random bytes and
URL-safe base64 when available, with a collision-checked compatibility
fallback. A deployment may inject its own platform-specific factory.

GET streams require `Accept: text/event-stream`. `ctx.stream` provides
`notify`, `log`, and `progress` helpers. Notifications are bounded by
`maxNotificationBytes`. SSE replay is not implemented: setting
`resumable=true` fails during adapter construction, and `Last-Event-ID` is
rejected. Heartbeats, cancellation, pagination, and list-change notifications
are not implemented in version 0.2.0.

The engine advertises only implemented capabilities. Component list-change
flags are false, and logging is not advertised. `logging/setLevel` returns
method-not-found. `completion/complete` currently returns an empty completion
set and is not advertised as a capability.

### Proxy-derived URLs

Direct requests derive advisory `serverOrigin` from a validated `Host` header.
Forwarded headers are ignored by default. Set `trustForwardedHeaders=true` only
when the application is behind a trusted proxy that sanitizes `Forwarded`,
`X-Forwarded-Host`, and `X-Forwarded-Proto`. The derived URL is navigation
metadata, never an authentication or authorization boundary.

### Compatibility HTTP Adapter

```lua
Http.handle(mcp, cmd, {
   maxRequestBodyBytes = 1024 * 1024,
   maxResponseBytes = 4 * 1024 * 1024,
   trustForwardedHeaders = false
})
```

This stateless adapter remains available. It now enforces JSON content type
and request/response bounds too. Prefer Streamable HTTP for MCP clients.

## Serialization Contract

`fastmcp.dispatcher` preserves `FastMCP.array {}` as JSON arrays and ordinary
empty tables as objects. It encodes `ba.json.null` as JSON null. Cycles,
non-finite numbers, functions/userdata, and non-string object keys are
programming errors and produce a bounded server error; they are never silently
converted to null or invalid JSON. Binary resource content supplied as `blob`
is base64 encoded; `blobBase64` is passed through.

`Dispatcher.jsonEncode(value)` follows the normal Lua error-return convention:
it returns the encoded string on success, or `nil, error` when the value cannot
be represented as JSON. It does not throw for a serialization failure. The
dispatcher translates such failures into JSON-RPC error `-32603`, and the HTTP
adapters return a bounded HTTP 500 error response.

## Tests

Run the generic standalone suite from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/fastmcp/Test-FastMCP.ps1
```

It stages only `fastmcp` modules into a temporary Mako app. Run the LSP-Claw
integration regression separately:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-LSP-Claw.ps1
```

The second test starts LSP-Claw, initializes Streamable HTTP, lists tools,
calls `getRuntimeInfo`, verifies the origin-aware setup URL, deletes the
session, and stops Mako.

## Relationship to Python FastMCP

The shared ideas are one server-owned registry and first-class tools,
resources, templates, and prompts. Lua metadata and schemas are explicit.
For the Python project, see [FastMCP](https://gofastmcp.com/). For the protocol,
see the [Model Context Protocol](https://modelcontextprotocol.io/).
