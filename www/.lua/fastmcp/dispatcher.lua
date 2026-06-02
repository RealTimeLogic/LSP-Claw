local FastMCP = require "fastmcp.engine"
local pcall=FastMCP.pcall
local Dispatcher = {}

local function jsonEncode(value)
   local ok, encoded = pcall(ba.json.encode, value)
   if ok and encoded then return encoded end
   return tostring(value)
end

local function jsonRpcError(id, code, message, data)
   local err = {
      code = code,
      message = message
   }
   if data ~= nil then err.data = data end
   return {
      jsonrpc = "2.0",
      id = id,
      error = err
   }
end

local function jsonRpcResult(id, result)
   return {
      jsonrpc = "2.0",
      id = id,
      result = result or {}
   }
end

local function isJsonRpcError(value)
   return type(value) == "table" and value.error and value.jsonrpc
end

local function stripMarker(t)
   if type(t) ~= "table" then return t end
   local out = {}
   for k, v in pairs(t) do
      if k ~= "fastmcpType" then out[k] = v end
   end
   return out
end

local function contentItem(item)
   if type(item) ~= "table" then
      return { type = "text", text = tostring(item) }
   end
   if item.type == "json" then
      return { type = "text", text = jsonEncode(item.json or item.value or {}) }
   end
   return stripMarker(item)
end

local function contentArray(content)
   local out = {}
   if type(content) ~= "table" then
      return { { type = "text", text = tostring(content) } }
   end
   for _, item in ipairs(content) do
      out[#out + 1] = contentItem(item)
   end
   return out
end

function Dispatcher.toMcpToolResult(value)
   if FastMCP.isProtocolError(value) then return value end
   if FastMCP.isError(value) then
      local result = {
	 content = {
	    { type = "text", text = value.message }
	 },
	 isError = true
      }
      if value.details ~= nil then result.structuredContent = value.details end
      if value.meta ~= nil then result._meta = value.meta end
      return result
   end
   if FastMCP.isToolResult(value) then
      local result = {
	 content = contentArray(value.content or {}),
	 structuredContent = value.structuredContent,
	 isError = value.isError == true,
	 _meta = value.meta
      }
      return result
   end
   if type(value) == "string" then
      return {
	 content = {
	    { type = "text", text = value }
	 },
	 isError = false
      }
   end
   if type(value) == "table" then
      return {
	 content = {
	    { type = "text", text = jsonEncode(value) }
	 },
	 structuredContent = value,
	 isError = false
      }
   end
   if value == nil then
      return { content = {}, isError = false }
   end
   return {
      content = {
	 { type = "text", text = tostring(value) }
      },
      isError = false
   }
end

local function contentToResourceEntry(item, uri, defaultMimeType)
   item = item or {}
   local entry = {
      uri = item.uri or uri,
      mimeType = item.mimeType or defaultMimeType or "text/plain",
      _meta = item.meta
   }
   if item.blob ~= nil then
      entry.blob = ba.b64encode(item.blob)
   elseif item.blobBase64 ~= nil then
      entry.blob = item.blobBase64
   elseif item.text ~= nil then
      entry.text = tostring(item.text)
   elseif type(item.value) == "table" then
      entry.text = jsonEncode(item.value)
      entry.mimeType = item.mimeType or defaultMimeType or "application/json"
   elseif item.value ~= nil then
      entry.text = tostring(item.value)
   else
      entry.text = ""
   end
   return entry
end

function Dispatcher.toMcpResourceResult(value, uri, defaultMimeType)
   if FastMCP.isProtocolError(value) then return value end
   if FastMCP.isError(value) then
      return FastMCP.protocolError(-32603, value.message, value.details)
   end
   if FastMCP.isResourceResult(value) then
      local result = { contents = {}, _meta = value.meta }
      for _, item in ipairs(value.contents or {}) do
	 result.contents[#result.contents + 1] = contentToResourceEntry(item, uri, defaultMimeType)
      end
      return result
   end
   if FastMCP.isResourceContent(value) then
      return {
	 contents = {
	    contentToResourceEntry(value, uri, value.mimeType or defaultMimeType)
	 }
      }
   end
   if type(value) == "table" then
      return {
	 contents = {
	    {
	       uri = uri,
	       mimeType = defaultMimeType or "application/json",
	       text = jsonEncode(value)
	    }
	 }
      }
   end
   return {
      contents = {
	 {
	    uri = uri,
	    mimeType = defaultMimeType or "text/plain",
	    text = value == nil and "" or tostring(value)
	 }
      }
   }
end

local function promptContent(content)
   if type(content) == "string" then
      return { type = "text", text = content }
   end
   if type(content) == "table" then
      if content.fastmcpType then return stripMarker(content) end
      return content
   end
   return { type = "text", text = tostring(content) }
end

function Dispatcher.toMcpPromptResult(value, prompt)
   if FastMCP.isProtocolError(value) then return value end
   if FastMCP.isError(value) then
      return FastMCP.protocolError(-32603, value.message, value.details)
   end

   local description = prompt and prompt.description or nil
   local meta = prompt and prompt.meta or nil

   if FastMCP.isPromptResult(value) then
      description = value.description or description
      meta = value.meta or meta
      value = value.messages or {}
   end

   if type(value) == "string" then
      return {
	 description = description,
	 messages = {
	    {
	       role = "user",
	       content = { type = "text", text = value }
	    }
	 },
	 _meta = meta
      }
   end

   local messages = {}
   if type(value) == "table" then
      for _, msg in ipairs(value) do
	 if type(msg) == "string" then
	    messages[#messages + 1] = {
	       role = "user",
	       content = { type = "text", text = msg }
	    }
	 elseif type(msg) == "table" then
	    messages[#messages + 1] = {
	       role = msg.role or "user",
	       content = promptContent(msg.content)
	    }
	 end
      end
   end

   return {
      description = description,
      messages = messages,
      _meta = meta
   }
end

local function dispatchRequestProt(mcp, msg, ctx)
   local method = msg.method
   local params = msg.params or {}
   if method == "initialize" then
      ctx.client = {
	 info = params.clientInfo,
	 capabilities = params.capabilities
      }
      return mcp:initializeResult(params)
   elseif method == "ping" then
      return {}
   elseif method == "tools/list" then
      return { tools = mcp:listTools(ctx) }
   elseif method == "tools/call" then
      return Dispatcher.toMcpToolResult(mcp:callTool(params.name, params.arguments or {}, ctx))
   elseif method == "resources/list" then
      return { resources = mcp:listResources(ctx) }
   elseif method == "resources/templates/list" then
      return { resourceTemplates = mcp:listResourceTemplates(ctx) }
   elseif method == "resources/read" then
      local value, component = mcp:readResource(params.uri, ctx)
      local mimeType = component and component.mimeType or nil
      return Dispatcher.toMcpResourceResult(value, params.uri, mimeType)
   elseif method == "prompts/list" then
      return { prompts = mcp:listPrompts(ctx) }
   elseif method == "prompts/get" then
      local value, prompt = mcp:getPrompt(params.name, params.arguments or {}, ctx)
      return Dispatcher.toMcpPromptResult(value, prompt)
   elseif method == "logging/setLevel" then
      return mcp:setLoggingLevel(params.level)
   elseif method == "completion/complete" then
      return {
	 completion = {
	    values = {},
	    total = 0,
	    hasMore = false
	 }
      }
   else
      return FastMCP.protocolError(-32601, "Method not found: " .. tostring(method))
   end
end

local function dispatchRequest(mcp, msg, ctx)
   if type(msg) ~= "table" then
      return jsonRpcError(nil, -32600, "Invalid Request")
   end
   local id = msg.id
   local isNotification = id == nil
   if msg.jsonrpc ~= "2.0" then
      if isNotification then return nil end
      return jsonRpcError(id, -32600, "Invalid JSON-RPC version")
   end
   if type(msg.method) ~= "string" then
      if isNotification then return nil end
      return jsonRpcError(id, -32600, "Missing JSON-RPC method")
   end
   ctx = ctx or {}
   ctx.jsonrpcId = id
   ctx.method = msg.method
   ctx.meta = msg.params and msg.params._meta or nil
   if isNotification then
      return nil
   end
   local ok, result = pcall(dispatchRequestProt, mcp, msg, ctx)
   if not ok then
      return jsonRpcError(id, -32603, "Internal error", tostring(result))
   end
   if FastMCP.isProtocolError(result) then
      return jsonRpcError(id, result.code, result.message, result.data)
   end
   if isJsonRpcError(result) then
      result.id = id
      return result
   end
   return jsonRpcResult(id, result)
end

function Dispatcher.dispatch(mcp, msg, ctx)
   if type(msg) == "table" and msg[1] ~= nil then
      local responses = {}
      for _, one in ipairs(msg) do
	 local response = dispatchRequest(mcp, one, ctx)
	 if response ~= nil then responses[#responses + 1] = response end
      end
      if #responses == 0 then return nil end
      return responses
   end
   return dispatchRequest(mcp, msg, ctx)
end

Dispatcher.jsonRpcError = jsonRpcError
Dispatcher.jsonRpcResult = jsonRpcResult

return Dispatcher
