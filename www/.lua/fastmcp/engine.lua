local FastMCP = {}
FastMCP.__index = FastMCP
local Schema = require "fastmcp.schema"

FastMCP.VERSION = "0.2.0"
FastMCP.protocolVersionDefault = "2025-11-25"
FastMCP.supportedProtocolVersions = {
   ["2025-11-25"] = true,
   ["2025-06-18"] = true,
   ["2025-03-26"] = true
}

local function shallowCopy(t)
   local out = {}
   if type(t) == "table" then
      for k, v in pairs(t) do out[k] = v end
   end
   return out
end

local function sortedKeys(t)
   local keys = {}
   if type(t) == "table" then
      for k in pairs(t) do keys[#keys + 1] = k end
   end
   table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
   return keys
end

local function mark(kind, value)
   value = value or {}
   value.fastmcpType = kind
   return value
end

local function errorHandler(err)
   local message = tostring(err) .. "\n" .. debug.traceback("STACK TRACE:", 2)
   if type(tracep) == "function" then tracep(false,9,"ERROR:",message)
   elseif type(trace) == "function" then trace("ERROR:",message)
   elseif type(print) == "function" then print("ERROR:",message) end
   return err
end

function FastMCP.pcall(f,...)
   return xpcall(f,errorHandler,...)
end
local pcall=FastMCP.pcall

function FastMCP.error(message, details, meta)
   return mark("error", {
		  message = tostring(message or "Error"),
		  details = details,
		  meta = meta
	       })
end

function FastMCP.protocolError(code, message, data)
   return mark("protocolError", {
		  code = code or -32603,
		  message = tostring(message or "Protocol error"),
		  data = data
	       })
end

function FastMCP.toolResult(result)
   result = result or {}
   result.meta = result.meta or result._meta
   return mark("toolResult", result)
end

function FastMCP.resourceContent(content)
   content = content or {}
   content.meta = content.meta or content._meta
   return mark("resourceContent", content)
end

function FastMCP.resourceResult(result)
   result = result or {}
   result.meta = result.meta or result._meta
   return mark("resourceResult", result)
end

function FastMCP.message(content, role)
   return { role = role or "user", content = content }
end

function FastMCP.promptResult(result)
   result = result or {}
   result.meta = result.meta or result._meta
   return mark("promptResult", result)
end

function FastMCP.array(value)
   return mark("array", value or {})
end

function FastMCP.isError(value)
   return type(value) == "table" and value.fastmcpType == "error"
end

function FastMCP.isProtocolError(value)
   return type(value) == "table" and value.fastmcpType == "protocolError"
end

function FastMCP.isToolResult(value)
   return type(value) == "table" and value.fastmcpType == "toolResult"
end

function FastMCP.isResourceContent(value)
   return type(value) == "table" and value.fastmcpType == "resourceContent"
end

function FastMCP.isResourceResult(value)
   return type(value) == "table" and value.fastmcpType == "resourceResult"
end

function FastMCP.isPromptResult(value)
   return type(value) == "table" and value.fastmcpType == "promptResult"
end

function FastMCP.isArray(value)
   return type(value) == "table" and value.fastmcpType == "array"
end

local function publicMeta(component)
   local meta = shallowCopy(component.meta)
   if type(component.tags) == "table" and #component.tags > 0 then
      meta.tags = component.tags
   end
   if next(meta) == nil then return nil end
   return meta
end

local function compileUriTemplate(template)
   local names = {}
   local pattern = "^"
   local pos = 1
   while true do
      local s, e, name = string.find(template, "{([%w_]+)}", pos)
      if not s then
	 local tail = string.sub(template, pos)
	 pattern = pattern .. (tail:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
	 break
      end
      local literal = string.sub(template, pos, s - 1)
      pattern = pattern .. (literal:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
      pattern = pattern .. "([^/]+)"
      names[#names + 1] = name
      pos = e + 1
   end
   pattern = pattern .. "$"
   return pattern, names
end

local function componentEnabled(self, options)
   if options.enabled ~= nil then return options.enabled ~= false end
   return self.defaultEnabled ~= false
end

local function mergeMeta(options)
   local meta = shallowCopy(options.meta)
   return meta
end

function FastMCP.create(options)
   if type(options) == "string" then options = { name = options } end
   assert(type(options) == "table", "options table required")
   assert(type(options.name) == "string", "server name required")

   local self = setmetatable({}, FastMCP)
   self.name = options.name
   self.version = tostring(options.version or FastMCP.VERSION)
   self.instructions = options.instructions
   self.websiteUrl = options.websiteUrl
   self.icons = options.icons
   self.meta = options.meta or {}
   self.defaultEnabled = options.defaultEnabled ~= false
   self.authorize = options.authorize
   self.onDuplicate = options.onDuplicate or "replace"
   self.experimentalCapabilities = options.experimentalCapabilities or {}
   self.strictSchemas = options.strictSchemas ~= false

   self.tools = {}
   self.toolOrder = {}
   self.resources = {}
   self.resourceOrder = {}
   self.resourceTemplates = {}
   self.resourceTemplateOrder = {}
   self.prompts = {}
   self.promptOrder = {}
   self.loggingLevel = "info"
   return self
end

local function registerComponent(self, map, order, id, component)
   if map[id] ~= nil then
      if self.onDuplicate == "error" then
	 error("Duplicate component: " .. tostring(id))
      elseif self.onDuplicate == "ignore" then
	 return map[id]
      elseif self.onDuplicate == "warn" then
	 trace("FastMCP duplicate component replaced:", id)
      end
   else
      order[#order + 1] = id
   end
   map[id] = component
   return component
end

function FastMCP:tool(name, options, handler)
   assert(type(name) == "string", "tool name required")
   assert(type(options) == "table", "tool options required")
   assert(type(handler) == "function", "tool handler required")

   local inputSchema = options.inputSchema or options.parameters or {
      type = "object", properties = {}, additionalProperties = false
   }
   local ok, schemaErr = Schema.check(inputSchema, "tool " .. name .. " inputSchema")
   assert(ok, schemaErr)
   if options.outputSchema then
      ok, schemaErr = Schema.check(options.outputSchema, "tool " .. name .. " outputSchema")
      assert(ok, schemaErr)
   end
   local component = {
      kind = "tool",
      name = name,
      title = options.title,
      description = options.description,
      inputSchema = inputSchema,
      outputSchema = options.outputSchema,
      tags = options.tags or {},
      meta = mergeMeta(options),
      annotations = options.annotations,
      icons = options.icons,
      execution = options.execution,
      enabled = componentEnabled(self, options),
      timeoutMs = options.timeoutMs,
      authorize = options.authorize or options.auth,
      onInputError = options.onInputError,
      handler = handler
   }
   registerComponent(self, self.tools, self.toolOrder, name, component)
   return self
end

function FastMCP:addTool(name, options, handler)
   return self:tool(name, options, handler)
end

function FastMCP:resource(uri, options, handlerOrValue)
   assert(type(uri) == "string", "resource URI required")
   assert(type(options) == "table", "resource options required")

   local component = {
      kind = "resource",
      uri = uri,
      name = options.name or uri,
      title = options.title,
      description = options.description,
      mimeType = options.mimeType or "text/plain",
      tags = options.tags or {},
      meta = mergeMeta(options),
      annotations = options.annotations,
      icons = options.icons,
      enabled = componentEnabled(self, options),
      authorize = options.authorize or options.auth,
      value = handlerOrValue
   }
   registerComponent(self, self.resources, self.resourceOrder, uri, component)
   return self
end

function FastMCP:addResource(uri, options, handlerOrValue)
   return self:resource(uri, options, handlerOrValue)
end

function FastMCP:resourceTemplate(uriTemplate, options, handler)
   assert(type(uriTemplate) == "string", "resource template URI required")
   assert(type(options) == "table", "resource template options required")
   assert(type(handler) == "function", "resource template handler required")

   local pattern, names = compileUriTemplate(uriTemplate)
   local component = {
      kind = "resourceTemplate",
      uriTemplate = uriTemplate,
      name = options.name or uriTemplate,
      title = options.title,
      description = options.description,
      mimeType = options.mimeType or "text/plain",
      parameters = options.parameters or {},
      tags = options.tags or {},
      meta = mergeMeta(options),
      annotations = options.annotations,
      icons = options.icons,
      enabled = componentEnabled(self, options),
      authorize = options.authorize or options.auth,
      handler = handler,
      pattern = pattern,
      paramNames = names
   }
   registerComponent(self, self.resourceTemplates, self.resourceTemplateOrder, uriTemplate, component)
   return self
end

function FastMCP:addResourceTemplate(uriTemplate, options, handler)
   return self:resourceTemplate(uriTemplate, options, handler)
end

function FastMCP:prompt(name, options, handler)
   assert(type(name) == "string", "prompt name required")
   assert(type(options) == "table", "prompt options required")
   assert(type(handler) == "function", "prompt handler required")

   local component = {
      kind = "prompt",
      name = name,
      title = options.title,
      description = options.description,
      arguments = options.arguments or {},
      tags = options.tags or {},
      meta = mergeMeta(options),
      icons = options.icons,
      enabled = componentEnabled(self, options),
      authorize = options.authorize or options.auth,
      handler = handler
   }
   registerComponent(self, self.prompts, self.promptOrder, name, component)
   return self
end

function FastMCP:addPrompt(name, options, handler)
   return self:prompt(name, options, handler)
end

function FastMCP:isAuthorized(component, ctx)
   if component.enabled == false then return false end
   if type(self.authorize) == "function" then
      local ok, allowed = pcall(self.authorize, component, ctx)
      if not ok or not allowed then return false end
   end
   if type(component.authorize) == "function" then
      local ok, allowed = pcall(component.authorize, ctx)
      if not ok or not allowed then return false end
   elseif type(component.authorize) == "boolean" and not component.authorize then
      return false
   end
   return true
end

function FastMCP:listTools(ctx)
   local out = FastMCP.array()
   for _, name in ipairs(self.toolOrder) do
      local tool = self.tools[name]
      if tool and self:isAuthorized(tool, ctx) then
	 local item = {
	    name = tool.name,
	    title = tool.title,
	    description = tool.description,
	    inputSchema = tool.inputSchema,
	    outputSchema = tool.outputSchema,
	    annotations = tool.annotations,
	    icons = tool.icons,
	    execution = tool.execution,
	    _meta = publicMeta(tool)
	 }
	 out[#out + 1] = item
      end
   end
   return out
end

function FastMCP:callTool(name, arguments, ctx)
   local tool = self.tools[name]
   if not tool or tool.enabled == false then
      return FastMCP.protocolError(-32602, "Unknown tool: " .. tostring(name))
   end
   if not self:isAuthorized(tool, ctx) then
      return FastMCP.protocolError(-32001, "Unauthorized")
   end
   local checked, validationErr = Schema.validate(tool.inputSchema, arguments or {}, { strict = self.strictSchemas })
   if validationErr then
      if type(tool.onInputError) == "function" then
         local ok, mapped = pcall(tool.onInputError, validationErr, arguments or {}, ctx or {})
         if not ok then
            return FastMCP.error("Error mapping invalid tool arguments for " .. tostring(name), {
               code = "inputErrorHandlerFailed"
            })
         end
         if mapped ~= nil then return mapped end
      end
      return FastMCP.error("Invalid tool arguments", validationErr)
   end
   local ok, result = pcall(tool.handler, checked, ctx or {})
   if not ok then
      return FastMCP.error("Error calling tool " .. tostring(name) .. ": " .. tostring(result), {
			      code = "toolError"
			   })
   end
   if tool.outputSchema and not FastMCP.isError(result) and not FastMCP.isProtocolError(result) then
      local output = FastMCP.isToolResult(result) and result.structuredContent or result
      local _, outputErr = Schema.validate(tool.outputSchema, output, { strict = self.strictSchemas })
      if outputErr then
         outputErr.code = "outputValidation"
         return FastMCP.error("Tool output does not match outputSchema", outputErr)
      end
   end
   return result
end

local function percentDecode(value)
   if value:find("%%[^%x]") or value:find("%%$", 1, false) or value:find("%%[%x]$", 1, false) then
      return nil, "invalidPercentEncoding"
   end
   local decoded = value:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
   if decoded:find("/", 1, true) then return nil, "encodedSlash" end
   return decoded
end

function FastMCP:listResources(ctx)
   local out = FastMCP.array()
   for _, uri in ipairs(self.resourceOrder) do
      local res = self.resources[uri]
      if res and self:isAuthorized(res, ctx) then
	 out[#out + 1] = {
	    uri = res.uri,
	    name = res.name,
	    title = res.title,
	    description = res.description,
	    mimeType = res.mimeType,
	    annotations = res.annotations,
	    icons = res.icons,
	    _meta = publicMeta(res)
	 }
      end
   end
   return out
end

function FastMCP:findResourceTemplate(uri, ctx)
   for _, templateId in ipairs(self.resourceTemplateOrder) do
      local tmpl = self.resourceTemplates[templateId]
      if tmpl and self:isAuthorized(tmpl, ctx) then
	 local captures = { string.match(uri, tmpl.pattern) }
	 if #captures > 0 then
	    local params = {}
	    for i, name in ipairs(tmpl.paramNames) do
	       local decoded, decodeErr = percentDecode(captures[i])
	       if not decoded then return tmpl, nil, FastMCP.error("Invalid resource-template parameter", { code=decodeErr, field=name }) end
	       params[name] = decoded
	    end
	    local properties, required = {}, {}
	    for name, def in pairs(tmpl.parameters or {}) do
	       properties[name] = def
	       if def.required == true then required[#required + 1] = name end
	    end
	    local checked, validationErr = Schema.validate({ type="object", properties=properties, required=required, additionalProperties=false }, params, { strict=self.strictSchemas })
	    if validationErr then return tmpl, nil, FastMCP.error("Invalid resource-template parameter", validationErr) end
	    return tmpl, checked
	 end
      end
   end
   return nil
end

function FastMCP:readResource(uri, ctx)
   local res = self.resources[uri]
   if res then
      if not self:isAuthorized(res, ctx) then
	 return FastMCP.protocolError(-32001, "Unauthorized")
      end
      if type(res.value) == "function" then
	 local ok, value = pcall(res.value, ctx or {})
	 if not ok then
	    return FastMCP.protocolError(-32603, "Error reading resource: " .. tostring(value))
	 end
	 return value, res
      end
      return res.value, res
   end

   local tmpl, params, templateErr = self:findResourceTemplate(uri, ctx)
   if tmpl then
      if templateErr then return templateErr, tmpl end
      local ok, value = pcall(tmpl.handler, params, ctx or {})
      if not ok then
	 return FastMCP.protocolError(-32603, "Error reading resource template: " .. tostring(value))
      end
      return value, tmpl
   end

   return FastMCP.protocolError(-32602, "Unknown resource: " .. tostring(uri))
end

function FastMCP:listResourceTemplates(ctx)
   local out = FastMCP.array()
   for _, uriTemplate in ipairs(self.resourceTemplateOrder) do
      local tmpl = self.resourceTemplates[uriTemplate]
      if tmpl and self:isAuthorized(tmpl, ctx) then
	 local meta = publicMeta(tmpl) or {}
	 if type(tmpl.parameters) == "table" and next(tmpl.parameters) ~= nil then
	    meta.parameters = tmpl.parameters
	 end
	 if next(meta) == nil then meta = nil end
	 out[#out + 1] = {
	    uriTemplate = tmpl.uriTemplate,
	    name = tmpl.name,
	    title = tmpl.title,
	    description = tmpl.description,
	    mimeType = tmpl.mimeType,
	    annotations = tmpl.annotations,
	    icons = tmpl.icons,
	    _meta = meta
	 }
      end
   end
   return out
end

local function promptArguments(definitions)
   local out = FastMCP.array()
   for _, name in ipairs(sortedKeys(definitions)) do
      local def = definitions[name]
      if type(def) == "table" then
	 out[#out + 1] = {
	    name = tostring(name),
	    title = def.title,
	    description = def.description,
	    required = def.required == true
	 }
      end
   end
   if #out == 0 then return nil end
   return out
end

function FastMCP:listPrompts(ctx)
   local out = FastMCP.array()
   for _, name in ipairs(self.promptOrder) do
      local prompt = self.prompts[name]
      if prompt and self:isAuthorized(prompt, ctx) then
	 out[#out + 1] = {
	    name = prompt.name,
	    title = prompt.title,
	    description = prompt.description,
	    arguments = promptArguments(prompt.arguments),
	    icons = prompt.icons,
	    _meta = publicMeta(prompt)
	 }
      end
   end
   return out
end

function FastMCP:getPrompt(name, arguments, ctx)
   local prompt = self.prompts[name]
   if not prompt or prompt.enabled == false then
      return FastMCP.protocolError(-32602, "Unknown prompt: " .. tostring(name))
   end
   if not self:isAuthorized(prompt, ctx) then
      return FastMCP.protocolError(-32001, "Unauthorized")
   end
   local properties, required = {}, {}
   for argName, def in pairs(prompt.arguments or {}) do
      properties[argName] = shallowCopy(def)
      properties[argName].required = nil
      properties[argName].type = properties[argName].type or "string"
      if def.required == true then required[#required + 1] = argName end
   end
   local checked, validationErr = Schema.validate({ type="object", properties=properties, required=required, additionalProperties=false }, arguments or {}, { strict=self.strictSchemas })
   if validationErr then return FastMCP.protocolError(-32602, "Invalid prompt arguments", validationErr) end
   local ok, result = pcall(prompt.handler, checked, ctx or {})
   if not ok then
      return FastMCP.protocolError(-32603, "Error getting prompt: " .. tostring(result))
   end
   return result, prompt
end

local function mapForKind(self, kind)
   if kind == "tool" or kind == "tools" then return self.tools end
   if kind == "resource" or kind == "resources" then return self.resources end
   if kind == "resourceTemplate" or kind == "resourceTemplates" then return self.resourceTemplates end
   if kind == "prompt" or kind == "prompts" then return self.prompts end
   return nil
end

local function orderForKind(self, kind)
   if kind == "tool" or kind == "tools" then return self.toolOrder end
   if kind == "resource" or kind == "resources" then return self.resourceOrder end
   if kind == "resourceTemplate" or kind == "resourceTemplates" then return self.resourceTemplateOrder end
   if kind == "prompt" or kind == "prompts" then return self.promptOrder end
end

function FastMCP:enable(kind, id)
   local map = mapForKind(self, kind)
   if map and map[id] then map[id].enabled = true; return true end
   return false
end

function FastMCP:disable(kind, id)
   local map = mapForKind(self, kind)
   if map and map[id] then map[id].enabled = false; return true end
   return false
end

function FastMCP:remove(kind, id)
   local map = mapForKind(self, kind)
   if map and map[id] then
      map[id] = nil
      local order = orderForKind(self, kind)
      for i, value in ipairs(order) do if value == id then table.remove(order, i); break end end
      return true
   end
   return false
end

function FastMCP:capabilities()
   local caps = {}
   if next(self.tools) ~= nil then caps.tools = { listChanged = false } end
   if next(self.resources) ~= nil or next(self.resourceTemplates) ~= nil then
      caps.resources = { listChanged = false }
   end
   if next(self.prompts) ~= nil then caps.prompts = { listChanged = false } end
   for k, v in pairs(self.experimentalCapabilities) do caps[k] = v end
   return caps
end

function FastMCP:initializeResult(params, ctx)
   params = params or {}
   local requested = params.protocolVersion
   local protocolVersion = FastMCP.supportedProtocolVersions[requested] and requested or FastMCP.protocolVersionDefault
   local instructions = self.instructions
   if type(instructions) == "function" then
      local ok, value = pcall(instructions, ctx or {})
      instructions = ok and value or nil
   end
   local result = {
      protocolVersion = protocolVersion,
      serverInfo = {
	 name = self.name,
	 title = self.title,
	 version = self.version,
	 websiteUrl = self.websiteUrl,
	 icons = self.icons
      },
      instructions = instructions,
      capabilities = self:capabilities()
   }
   if ctx and ctx.serverOrigin then
      result._meta = {
	 serverOrigin = ctx.serverOrigin,
	 urlGuidance = "Server-derived URLs are advisory. Prefer tool-result URLs when present."
      }
   end
   return result
end

function FastMCP:setLoggingLevel(level)
   return FastMCP.protocolError(-32601, "Logging is not implemented")
end

return FastMCP
