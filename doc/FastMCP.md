# Lua FastMCP-Style API for the Barracuda App Server

## Purpose

This document defines a Lua API inspired by FastMCP, but designed specifically for the Barracuda App Server (BAS) and HTTP-only deployments.

The goal is to give BAS Lua developers a compact, predictable way to expose MCP-style components:

- **Tools**: callable Lua functions the model may invoke.
- **Resources**: read-only URI-addressed data exposed to the model or client.
- **Prompts**: reusable, parameterized prompt templates.

This document intentionally avoids HTTP transport details. It focuses only on how a developer creates and uses a `FastMCP` instance in Lua and how components are registered.

---

## Design Principles

This API follows the same developer-facing idea as FastMCP: create a server object, register components on it, and let the framework expose those components to MCP clients.

The Lua version differs from Python FastMCP in one important way: Lua does not have Python-style decorators or type annotations. Therefore, metadata such as parameter schemas, descriptions, MIME types, and annotations must be provided explicitly.

The API should feel natural in BAS Lua:

```lua
local mcp = FastMCP.new {
   name = "DeviceManager",
   version = "1.0.0"
}

mcp:tool("rebootDevice", {
   description = "Reboot the device after an optional delay.",
   inputSchema = {
      type = "object",
      properties = {
         delaySeconds = { type = "integer", minimum = 0, default = 0 }
      }
   }
}, function(args, ctx)
   return { ok = true, scheduled = true, delaySeconds = args.delaySeconds or 0 }
end)
```

---

## Module Overview

Recommended module name:

```lua
local FastMCP = require "fastmcp.engine"
```

Recommended constructor:

```lua
local mcp = FastMCP.new(options)
```

Where `options` is a Lua table:

```lua
local mcp = FastMCP.new {
   name = "My BAS MCP Server",
   version = "1.0.0",
   instructions = "Provides tools and resources for managing the embedded device.",
   meta = {
      vendor = "Real Time Logic",
      product = "Barracuda App Server"
   }
}
```

### Constructor Options

| Option | Type | Required | Description |
|---|---:|---:|---|
| `name` | string | yes | Human-readable server name. |
| `version` | string | no | Server or application version. |
| `instructions` | string | no | Optional instructions shown to the MCP client. |
| `meta` | table | no | Application-specific metadata. |
| `strictSchemas` | boolean | no | If true, reject undeclared parameters. Recommended default: `true`. |
| `defaultEnabled` | boolean | no | Default enabled state for registered components. Recommended default: `true`. |

---

## Core Object: `FastMCP`

A `FastMCP` instance owns the component registry. It does not need to know how the HTTP transport is implemented; it only needs to expose operations that the BAS HTTP layer can call.

Recommended methods:

```lua
mcp:tool(name, options, handler)
mcp:resource(uri, options, handlerOrValue)
mcp:resourceTemplate(uriTemplate, options, handler)
mcp:prompt(name, options, handler)

mcp:listTools(ctx)
mcp:callTool(name, arguments, ctx)

mcp:listResources(ctx)
mcp:readResource(uri, ctx)

mcp:listResourceTemplates(ctx)
mcp:readResourceTemplate(uri, ctx)

mcp:listPrompts(ctx)
mcp:getPrompt(name, arguments, ctx)

mcp:enable(kind, id)
mcp:disable(kind, id)
mcp:remove(kind, id)
```

The HTTP layer can map MCP requests to these methods, but that mapping is outside the scope of this document.

---

## Context Object

Each handler receives a `ctx` table as its second argument. The context gives handlers access to request-local information without coupling them to HTTP.

Example:

```lua
function(args, ctx)
   return {
      user = ctx.user,
      requestId = ctx.requestId
   }
end
```

Recommended context fields:

| Field | Type | Description |
|---|---:|---|
| `requestId` | string | Unique request identifier. |
| `user` | table/string/nil | Authenticated user or principal, if available. |
| `session` | table/nil | Session data, if available. |
| `client` | table/nil | Client metadata. |
| `log` | function/table | Optional logging helper. |
| `meta` | table | Request-specific metadata. |

The context should be read-only from the framework’s perspective, but handlers may use it for authorization, logging, and request-scoped behavior.

---

# Tools

Tools are executable capabilities. They are the MCP component most similar to remote procedure calls, but they should be described for LLM use rather than only for human API users.

## Registering a Tool

```lua
mcp:tool(name, options, handler)
```

Example:

```lua
mcp:tool("add", {
   description = "Add two numbers and return the result.",
   inputSchema = {
      type = "object",
      properties = {
         a = { type = "number", description = "First number" },
         b = { type = "number", description = "Second number" }
      },
      required = { "a", "b" },
      additionalProperties = false
   },
   outputSchema = {
      type = "object",
      properties = {
         result = { type = "number" }
      },
      required = { "result" }
   },
   tags = { "math", "demo" },
   annotations = {
      readOnlyHint = true,
      idempotentHint = true
   }
}, function(args, ctx)
   return { result = args.a + args.b }
end)
```

## Tool Options

| Option | Type | Required | Description |
|---|---:|---:|---|
| `description` | string | recommended | Description shown to the LLM/client. |
| `inputSchema` | table | recommended | JSON Schema-style input schema. |
| `outputSchema` | table | no | JSON Schema-style output schema. |
| `tags` | table | no | List of tags for grouping/filtering. |
| `meta` | table | no | Custom metadata. |
| `annotations` | table | no | MCP-style behavioral hints. |
| `enabled` | boolean | no | Whether the tool is visible and callable. |
| `timeoutMs` | number | no | Optional execution timeout hint. |
| `authorize` | function | no | Component-level authorization function. |

## Tool Handler Signature

```lua
function(args, ctx)
   -- args: validated input arguments
   -- ctx: request context
   return result
end
```

Recommended return forms:

### Return a Lua table

```lua
return { status = "ok" }
```

The framework serializes the table as JSON-compatible content.

### Return plain text

```lua
return "Device reboot scheduled."
```

The framework returns text content.

### Return a structured tool result

```lua
return FastMCP.toolResult {
   content = {
      { type = "text", text = "Device status collected." },
      { type = "json", json = { temperature = 42.1, unit = "C" } }
   },
   meta = {
      source = "device-monitor"
   }
}
```

## Error Handling

Handlers should report expected failures using `FastMCP.error`:

```lua
mcp:tool("setRelay", {
   description = "Set relay state.",
   inputSchema = {
      type = "object",
      properties = {
         relay = { type = "integer", minimum = 1 },
         state = { type = "boolean" }
      },
      required = { "relay", "state" },
      additionalProperties = false
   }
}, function(args, ctx)
   if args.relay > 4 then
      return FastMCP.error("Invalid relay number", {
         code = "invalidRelay",
         relay = args.relay
      })
   end

   -- device-specific logic here
   return { ok = true }
end)
```

Recommended error helper:

```lua
FastMCP.error(message, details)
```

Where `details` is optional metadata.

---

# Resources

Resources expose read-only data through URIs. They are useful for device status, configuration snapshots, logs, documentation, schemas, and runtime metadata.

Resources should not perform side effects. Use tools for actions.

## Registering a Static Resource

```lua
mcp:resource("device://info", {
   name = "DeviceInfo",
   description = "Static information about the device.",
   mimeType = "application/json"
}, {
   model = "Xedge32",
   firmware = "1.2.0"
})
```

## Registering a Dynamic Resource

```lua
mcp:resource("device://status", {
   name = "DeviceStatus",
   description = "Current runtime status of the device.",
   mimeType = "application/json",
   annotations = {
      readOnlyHint = true,
      idempotentHint = false
   }
}, function(ctx)
   return {
      uptime = ba.datetime and ba.datetime() or nil,
      heap = collectgarbage("count")
   }
end)
```

## Resource Options

| Option | Type | Required | Description |
|---|---:|---:|---|
| `name` | string | no | Human-readable resource name. |
| `description` | string | recommended | Description shown to the client. |
| `mimeType` | string | recommended | Resource MIME type, such as `text/plain` or `application/json`. |
| `tags` | table | no | Tags for grouping/filtering. |
| `meta` | table | no | Custom metadata. |
| `annotations` | table | no | MCP-style resource hints. |
| `enabled` | boolean | no | Whether the resource is visible and readable. |
| `authorize` | function | no | Component-level authorization function. |

## Resource Handler Signature

```lua
function(ctx)
   return value
end
```

Recommended return forms:

```lua
return "plain text"
```

```lua
return { status = "ok", temperature = 41.8 }
```

```lua
return FastMCP.resourceContent {
   mimeType = "application/octet-stream",
   blob = binaryData
}
```

For BAS, binary data should be treated explicitly. Do not assume all Lua strings are text.

---

# Resource Templates

Resource templates allow dynamic resources based on URI parameters.

Example URI template:

```lua
mcp:resourceTemplate("device://log/{name}", {
   name = "DeviceLog",
   description = "Read a named device log.",
   mimeType = "text/plain",
   parameters = {
      name = {
         type = "string",
         description = "Log name, such as system or audit."
      }
   }
}, function(params, ctx)
   local name = params.name

   if name ~= "system" and name ~= "audit" then
      return FastMCP.error("Unknown log", { code = "unknownLog", name = name })
   end

   return "Example log content for " .. name
end)
```

## Resource Template Options

| Option | Type | Required | Description |
|---|---:|---:|---|
| `name` | string | no | Human-readable template name. |
| `description` | string | recommended | Description shown to the client. |
| `mimeType` | string | recommended | MIME type returned by this template. |
| `parameters` | table | recommended | URI parameter metadata. |
| `tags` | table | no | Tags for grouping/filtering. |
| `meta` | table | no | Custom metadata. |
| `annotations` | table | no | MCP-style hints. |
| `enabled` | boolean | no | Whether the template is visible and readable. |
| `authorize` | function | no | Component-level authorization function. |

## Resource Template Handler Signature

```lua
function(params, ctx)
   return value
end
```

Where `params` contains values extracted from the URI template.

---

# Prompts

Prompts are reusable message templates. They should help the user or LLM perform structured tasks using your server.

## Registering a Prompt

```lua
mcp:prompt("diagnoseDevice", {
   description = "Create a diagnostic prompt for analyzing device status.",
   arguments = {
      deviceId = {
         type = "string",
         description = "Device identifier",
         required = true
      },
      includeLogs = {
         type = "boolean",
         description = "Whether to include logs in the diagnosis",
         required = false,
         default = false
      }
   },
   tags = { "diagnostics" }
}, function(args, ctx)
   return {
      {
         role = "user",
         content = "Analyze device " .. args.deviceId ..
                   " and explain likely causes of any reported fault."
      }
   }
end)
```

## Prompt Options

| Option | Type | Required | Description |
|---|---:|---:|---|
| `description` | string | recommended | Description shown to the client. |
| `arguments` | table | no | Prompt argument definitions. |
| `tags` | table | no | Tags for grouping/filtering. |
| `meta` | table | no | Custom metadata. |
| `enabled` | boolean | no | Whether the prompt is visible and callable. |
| `authorize` | function | no | Component-level authorization function. |

## Prompt Handler Signature

```lua
function(args, ctx)
   return messages
end
```

Recommended return forms:

### Return a string

```lua
return "Explain the current device status in simple terms."
```

The framework can convert this into a single user message.

### Return a message list

```lua
return {
   { role = "system", content = "You are an embedded device diagnostics assistant." },
   { role = "user", content = "Analyze the current alarm state." }
}
```

Recommended message format:

| Field | Type | Description |
|---|---:|---|
| `role` | string | `user`, `assistant`, or `system`. |
| `content` | string/table | Message content. Use string for normal text. |

---

# Component Metadata

All component types should support a common metadata shape.

```lua
{
   name = "HumanReadableName",
   description = "Description shown to the MCP client.",
   tags = { "device", "diagnostics" },
   enabled = true,
   meta = {
      version = "1.0.0",
      owner = "firmware-team"
   },
   annotations = {
      readOnlyHint = true,
      destructiveHint = false,
      idempotentHint = true,
      openWorldHint = false
   }
}
```

## Recommended Annotation Hints

| Annotation | Applies To | Meaning |
|---|---|---|
| `readOnlyHint` | tools/resources | Does not modify state. |
| `destructiveHint` | tools | May destroy, delete, reset, or overwrite data. |
| `idempotentHint` | tools/resources | Repeating the operation has the same practical effect. |
| `openWorldHint` | tools | May interact with external systems beyond the device. |

These are hints for clients and models. They are not security controls.

---

# Authorization

Authorization should be available globally and per component, but the component API should stay simple.

## Global Authorization

```lua
local mcp = FastMCP.new {
   name = "SecureDeviceManager",
   authorize = function(component, ctx)
      return ctx.user and ctx.user.role == "admin"
   end
}
```

## Component-Level Authorization

```lua
mcp:tool("factoryReset", {
   description = "Reset the device to factory defaults.",
   inputSchema = {
      type = "object",
      properties = {
         confirm = { type = "string" }
      },
      required = { "confirm" },
      additionalProperties = false
   },
   annotations = {
      destructiveHint = true,
      idempotentHint = false
   },
   authorize = function(ctx)
      return ctx.user and ctx.user.role == "admin"
   end
}, function(args, ctx)
   if args.confirm ~= "factory-reset" then
      return FastMCP.error("Confirmation phrase is incorrect.")
   end

   return { ok = true, resetScheduled = true }
end)
```

The framework should use authorization in two places:

1. When listing components, unauthorized components should be hidden.
2. When invoking a component directly, authorization must still be checked.

---

# Enabling, Disabling, and Removing Components

Components should be manageable at runtime.

```lua
mcp:disable("tool", "factoryReset")
mcp:enable("tool", "factoryReset")
mcp:remove("tool", "factoryReset")

mcp:disable("resource", "device://status")
mcp:disable("prompt", "diagnoseDevice")
```

Recommended component kinds:

```lua
"tool"
"resource"
"resourceTemplate"
"prompt"
```

Disabled components should not appear in list operations and should not be callable/readable.

---

# Recommended Validation Behavior

Because Lua is dynamically typed, validation should happen before calling the handler.

Recommended behavior:

1. Validate input arguments against `inputSchema` for tools.
2. Validate prompt arguments against `arguments`.
3. Validate resource template URI parameters against `parameters`.
4. Reject unknown fields when `additionalProperties = false`.
5. Apply defaults before handler execution.
6. Return structured errors instead of raw Lua exceptions.

Example:

```lua
local result = mcp:callTool("add", { a = 10, b = 5 }, ctx)
```

Expected result:

```lua
{ result = 15 }
```

Invalid call:

```lua
local result = mcp:callTool("add", { a = 10 }, ctx)
```

Expected framework error:

```lua
FastMCP.error("Missing required argument: b", {
   code = "validationError",
   field = "b"
})
```

---

# Suggested Implementation Skeleton

This section shows the shape of the Lua module. It is not a full implementation, but it defines the intended API contract.

```lua
local FastMCP = {}
FastMCP.__index = FastMCP

function FastMCP.new(options)
   assert(type(options) == "table", "options table required")
   assert(type(options.name) == "string", "server name required")

   local self = setmetatable({}, FastMCP)
   self.name = options.name
   self.version = options.version or "0.1.0"
   self.instructions = options.instructions
   self.meta = options.meta or {}
   self.strictSchemas = options.strictSchemas ~= false
   self.defaultEnabled = options.defaultEnabled ~= false
   self.authorize = options.authorize

   self.tools = {}
   self.resources = {}
   self.resourceTemplates = {}
   self.prompts = {}

   return self
end

function FastMCP:tool(name, options, handler)
   assert(type(name) == "string", "tool name required")
   assert(type(options) == "table", "tool options required")
   assert(type(handler) == "function", "tool handler required")

   self.tools[name] = {
      kind = "tool",
      name = name,
      description = options.description,
      inputSchema = options.inputSchema,
      outputSchema = options.outputSchema,
      tags = options.tags or {},
      meta = options.meta or {},
      annotations = options.annotations or {},
      enabled = options.enabled ~= false,
      authorize = options.authorize,
      handler = handler
   }

   return self
end

function FastMCP:resource(uri, options, handlerOrValue)
   assert(type(uri) == "string", "resource URI required")
   assert(type(options) == "table", "resource options required")

   self.resources[uri] = {
      kind = "resource",
      uri = uri,
      name = options.name,
      description = options.description,
      mimeType = options.mimeType,
      tags = options.tags or {},
      meta = options.meta or {},
      annotations = options.annotations or {},
      enabled = options.enabled ~= false,
      authorize = options.authorize,
      value = handlerOrValue
   }

   return self
end

function FastMCP:resourceTemplate(uriTemplate, options, handler)
   assert(type(uriTemplate) == "string", "resource template URI required")
   assert(type(options) == "table", "resource template options required")
   assert(type(handler) == "function", "resource template handler required")

   self.resourceTemplates[uriTemplate] = {
      kind = "resourceTemplate",
      uriTemplate = uriTemplate,
      name = options.name,
      description = options.description,
      mimeType = options.mimeType,
      parameters = options.parameters or {},
      tags = options.tags or {},
      meta = options.meta or {},
      annotations = options.annotations or {},
      enabled = options.enabled ~= false,
      authorize = options.authorize,
      handler = handler
   }

   return self
end

function FastMCP:prompt(name, options, handler)
   assert(type(name) == "string", "prompt name required")
   assert(type(options) == "table", "prompt options required")
   assert(type(handler) == "function", "prompt handler required")

   self.prompts[name] = {
      kind = "prompt",
      name = name,
      description = options.description,
      arguments = options.arguments or {},
      tags = options.tags or {},
      meta = options.meta or {},
      enabled = options.enabled ~= false,
      authorize = options.authorize,
      handler = handler
   }

   return self
end

return FastMCP
```

---

# Complete Example: BAS Device Management MCP Server

```lua
local FastMCP = require "fastmcp.engine"

local mcp = FastMCP.new {
   name = "BAS Device Manager",
   version = "1.0.0",
   instructions = "Use this server to inspect and manage an embedded device."
}

mcp:tool("getDeviceStatus", {
   description = "Return the current device status.",
   inputSchema = {
      type = "object",
      properties = {},
      additionalProperties = false
   },
   annotations = {
      readOnlyHint = true,
      idempotentHint = false
   }
}, function(args, ctx)
   return {
      status = "ok",
      heapKb = collectgarbage("count"),
      requestId = ctx.requestId
   }
end)

mcp:tool("setLed", {
   description = "Turn a device LED on or off.",
   inputSchema = {
      type = "object",
      properties = {
         led = {
            type = "integer",
            minimum = 1,
            description = "LED number"
         },
         state = {
            type = "boolean",
            description = "True turns the LED on; false turns it off."
         }
      },
      required = { "led", "state" },
      additionalProperties = false
   },
   annotations = {
      readOnlyHint = false,
      idempotentHint = true
   }
}, function(args, ctx)
   -- Device-specific LED logic goes here.
   return {
      ok = true,
      led = args.led,
      state = args.state
   }
end)

mcp:resource("device://status", {
   name = "DeviceStatus",
   description = "Current device runtime status.",
   mimeType = "application/json",
   annotations = {
      readOnlyHint = true
   }
}, function(ctx)
   return {
      status = "ok",
      heapKb = collectgarbage("count")
   }
end)

mcp:resource("docs://device/help", {
   name = "DeviceHelp",
   description = "Short help text for using the device manager.",
   mimeType = "text/plain"
}, [[
This MCP server exposes device management tools and resources.
Use tools for actions and resources for read-only context.
]])

mcp:resourceTemplate("device://logs/{name}", {
   name = "DeviceLog",
   description = "Read a named device log.",
   mimeType = "text/plain",
   parameters = {
      name = {
         type = "string",
         description = "Log name: system or audit."
      }
   }
}, function(params, ctx)
   if params.name ~= "system" and params.name ~= "audit" then
      return FastMCP.error("Unknown log", {
         code = "unknownLog",
         name = params.name
      })
   end

   return "Example " .. params.name .. " log content"
end)

mcp:prompt("diagnoseDevice", {
   description = "Create a prompt for diagnosing the current device status.",
   arguments = {
      symptom = {
         type = "string",
         description = "The symptom observed by the user.",
         required = true
      }
   }
}, function(args, ctx)
   return {
      {
         role = "system",
         content = "You are an embedded device diagnostics assistant."
      },
      {
         role = "user",
         content = "Diagnose this symptom: " .. args.symptom ..
                   ". Use available device resources before suggesting actions."
      }
   }
end)

return mcp
```

---

# Recommended Developer Workflow

A BAS Lua developer should use the API in this order:

1. Create a `FastMCP` instance.
2. Register tools for actions.
3. Register resources for read-only data.
4. Register resource templates for URI-parameterized data.
5. Register prompts for reusable workflows.
6. Attach the instance to the BAS HTTP-facing MCP adapter.

Example:

```lua
local mcp = FastMCP.new { name = "MyServer" }

mcp:tool("doSomething", options, handler)
mcp:resource("data://something", options, handlerOrValue)
mcp:prompt("helpMe", options, handler)

return mcp
```

The adapter owns the HTTP mechanics. The application developer owns the MCP component definitions.

---

# Streamable HTTP Transport

The core `FastMCP` API remains transport-neutral. Developers still register tools, resources, resource templates, and prompts on the server object:

```lua
mcp:tool(...)
mcp:resource(...)
mcp:resourceTemplate(...)
mcp:prompt(...)
```

HTTP behavior belongs in `fastmcp.http`.

`Http.handle(mcp, cmd)` is the existing simple JSON request-response adapter. It accepts HTTP `POST` requests with JSON-RPC payloads and returns `application/json` responses. It remains available for applications that do not need MCP Streamable HTTP sessions or SSE streams.

`Http.streamable(mcp, options)` creates an MCP Streamable HTTP transport adapter:

```lua
local Http = require "fastmcp.http"

local transport = Http.streamable(mcp, {
   stateful = true,
   enableGetStream = true,
   protocolVersion = "2025-11-25",
   authorizeOrigin = function(origin, cmd, ctx)
      return origin == nil
   end
})

function app.cmdService(cmd)
   return transport:handle(cmd)
end
```

The streamable adapter owns MCP HTTP transport behavior: sessions, HTTP method handling, origin checks, and SSE streams. It does not change the component registration API.

## Sessions

When `stateful = true`, a successful `initialize` request creates a transport session. The response includes:

```text
MCP-Session-Id: <session-id>
MCP-Protocol-Version: 2025-11-25
```

Later requests must include the same `MCP-Session-Id`. Requests after initialization without a session ID return HTTP `400`; requests with an unknown or closed session ID return HTTP `404`. `DELETE` with `MCP-Session-Id` terminates the session.

Sessions are required for useful bidirectional behavior such as asynchronous logs, progress notifications, and server notifications delivered on a long-lived GET SSE stream.

## Origin Validation

Origin validation is callback-based:

```lua
authorizeOrigin = function(origin, cmd, ctx)
   return true
end
```

The callback is called for `OPTIONS`, `POST`, `GET`, and `DELETE`. It returns `true` to allow the request or `false, reason` to reject it with HTTP `403`. If no callback is supplied, browser-origin requests fail closed: requests with an `Origin` header are rejected, while requests without `Origin` are allowed.

## POST Requests

The streamable adapter expects strict Streamable HTTP `Accept` headers by default:

```text
Accept: application/json, text/event-stream
```

JSON-RPC batches are rejected with HTTP `400` because MCP `2025-11-25` Streamable HTTP requires each POST body to be one JSON-RPC request, notification, or response.

JSON-RPC notifications and client responses return HTTP `202 Accepted` with no body. JSON-RPC requests are dispatched through the existing dispatcher and currently return ordinary `application/json` JSON-RPC responses for short calls. POST response SSE streaming can be added later; this first version implements GET SSE streams for server-to-client messages not tied to one POST response.

## GET SSE Streams

`GET` opens a server-sent events stream when:

- `enableGetStream = true`
- `Accept` includes `text/event-stream`
- the request has a valid `MCP-Session-Id` when `stateful = true`

The HTTP response content type is `text/event-stream`. SSE is only the text framing. The `data:` payload is JSON-RPC JSON:

```text
event: message
data: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","logger":"BAS","data":"hello"}}

```

The transport exposes notification helpers:

```lua
transport:notify(sessionId, method, params)
transport:notifyAll(method, params)
transport:closeSession(sessionId)
```

Handlers also receive `ctx.stream` when a session stream can receive messages:

```lua
ctx.stream:notify(method, params)
ctx.stream:log(level, message, logger)
ctx.stream:progress(progressToken, progress, total, message)
```

`ctx.stream:log("info", "Starting lab")` sends a `notifications/message` JSON-RPC notification. `ctx.stream:progress(token, 1, 3, "Copying files")` sends a `notifications/progress` JSON-RPC notification.

## Resumability

Event replay is not implemented in this first version:

```lua
resumable = false
```

Requests with `Last-Event-ID` return HTTP `400` unless resumability is explicitly implemented in a future transport with an event store.

## Complete Streamable Example

```lua
local FastMCP = require "fastmcp.engine"
local Http = require "fastmcp.http"

local mcp = FastMCP {
   name = "Streamable Demo",
   version = "0.1.0"
}

mcp:tool("emitLog", {
   description = "Emit a test log notification.",
   inputSchema = {
      type = "object",
      properties = {
         message = { type = "string" }
      },
      additionalProperties = false
   }
}, function(args, ctx)
   if ctx.stream then
      ctx.stream:log("info", args.message or "Hello from Lua FastMCP", "fastmcp.demo")
   end
   return { ok = true }
end)

local transport = Http.streamable(mcp, {
   stateful = true,
   enableGetStream = true,
   protocolVersion = "2025-11-25",
   authorizeOrigin = function(origin, cmd, ctx)
      return origin == nil
   end
})

function app.cmdService(cmd)
   return transport:handle(cmd)
end
```

---

# Naming Recommendations

Lua developers should use camelCase names for tools and prompts:

```lua
getDeviceStatus
setLed
readConfig
factoryReset
```

Resource URIs should be stable and descriptive:

```lua
device://status
device://config
device://logs/system
docs://device/help
```

Resource templates should use clear parameter names:

```lua
device://logs/{name}
device://config/{section}
sensor://{sensorId}/history
```

---

# Tools vs. Resources vs. Prompts

| Need | Use | Example |
|---|---|---|
| Perform an action | Tool | `setLed`, `rebootDevice`, `clearAlarm` |
| Read current data | Resource | `device://status` |
| Read parameterized data | Resource template | `device://logs/{name}` |
| Provide a reusable workflow prompt | Prompt | `diagnoseDevice` |

Rule of thumb:

- If it changes device state, make it a **tool**.
- If it only exposes data, make it a **resource**.
- If it helps the model or user perform a task, make it a **prompt**.

---

# Minimal Public API Summary

```lua
local FastMCP = require "fastmcp.engine"

local mcp = FastMCP.new {
   name = "ServerName",
   version = "1.0.0"
}

mcp:tool(name, options, function(args, ctx)
   return result
end)

mcp:resource(uri, options, function(ctx)
   return content
end)

mcp:resource(uri, options, staticValue)

mcp:resourceTemplate(uriTemplate, options, function(params, ctx)
   return content
end)

mcp:prompt(name, options, function(args, ctx)
   return messages
end)

return mcp
```

---

# Notes on Relationship to FastMCP

This Lua API is intentionally modeled after FastMCP’s server-side component model:

- A single server object owns the MCP component registry.
- Tools expose callable functions.
- Resources expose read-only URI-addressed data.
- Resource templates expose URI-parameterized data.
- Prompts expose reusable parameterized message templates.
- Metadata and schemas make components discoverable and usable by LLM clients.

The main adaptation is that Lua requires explicit metadata and schemas, while Python FastMCP can infer much of this from decorators, function signatures, type annotations, and docstrings.

---

# Source References

- FastMCP documentation: https://gofastmcp.com/getting-started/welcome
- FastMCP tools documentation: https://gofastmcp.com/servers/tools
- FastMCP resources documentation: https://gofastmcp.com/v2/servers/resources
- FastMCP prompts documentation: https://gofastmcp.com/v2/servers/prompts
