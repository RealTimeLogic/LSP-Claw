local pcall=require"fastmcp.engine".pcall
local Dispatcher = require "fastmcp.dispatcher"
local Http = {}
local Streamable = {}
Streamable.__index = Streamable

local randomSeeded = false
local sessionCounter = 0

local function setOrigin(cmd)
   local origin = cmd:header("Origin")
   if origin then
      cmd:setheader("Access-Control-Allow-Origin",origin)
      cmd:setheader("Vary","Origin")
   else
      cmd:setheader("Access-Control-Allow-Origin","*")
   end
   cmd:setheader("Access-Control-Expose-Headers","MCP-Protocol-Version,Mcp-Session-Id")
end

local function setStreamableCors(cmd, origin)
   if origin then
      cmd:setheader("Access-Control-Allow-Origin", origin)
      cmd:setheader("Vary", "Origin")
   end
   cmd:setheader("Access-Control-Expose-Headers", "MCP-Protocol-Version,MCP-Session-Id")
end

local function setStreamableBaseHeaders(self, cmd, origin, sessionId)
   setStreamableCors(cmd, origin)
   cmd:setheader("MCP-Protocol-Version", self.protocolVersion)
   if sessionId then cmd:setheader("MCP-Session-Id", sessionId) end
end

local function encodeBounded(obj, limit)
   local encoded, err = Dispatcher.jsonEncode(obj)
   if not encoded then return nil, tostring(err) end
   if limit and #encoded > limit then return nil, "encoded response exceeds limit" end
   return encoded
end

local function serializationErrorJson(err)
   err = tostring(err)
   if #err > 512 then err = err:sub(1, 509) .. "..." end
   local encoded = Dispatcher.jsonEncode(Dispatcher.jsonRpcError(nil, -32603, "Response serialization failed", err))
   return encoded or '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Response serialization failed"}}'
end

local function sendJson(cmd,obj,status,maxBytes)
   cmd:reset()
   cmd:setstatus(status or 200)
   setOrigin(cmd)
   cmd:setheader("Content-Type","application/json")
   cmd:setheader("MCP-Protocol-Version","2025-11-25")
   local encoded, err = encodeBounded(obj, maxBytes)
   if not encoded then encoded = serializationErrorJson(err); cmd:setstatus(500) end
   cmd:write(encoded)
end

local function sendStreamableJson(self, cmd, obj, status, origin, sessionId)
   cmd:reset()
   cmd:setstatus(status or 200)
   setStreamableBaseHeaders(self, cmd, origin, sessionId)
   cmd:setheader("Content-Type", "application/json")
   local encoded, err = encodeBounded(obj, self.maxResponseBytes)
   if not encoded then encoded = serializationErrorJson(err); cmd:setstatus(500) end
   cmd:write(encoded)
end

local function sendEmpty(cmd,status)
   cmd:reset()
   cmd:setstatus(status or 204)
   setOrigin(cmd)
   cmd:setheader("Content-Length","0")
end

local function sendStreamableEmpty(self, cmd, status, origin, sessionId)
   cmd:reset()
   cmd:setstatus(status or 204)
   setStreamableBaseHeaders(self, cmd, origin, sessionId)
   cmd:setheader("Content-Length", "0")
end

local function readBody(cmd, maxBytes)
   local declared = tonumber(cmd:header("Content-Length") or "")
   if declared and declared > maxBytes then return nil, "Request body too large", 413 end
   local body = {}
   local bytes = 0
   local ok,err = pcall(function()
			    for data in cmd:rawrdr() do
			       bytes = bytes + #data
			       if bytes > maxBytes then error("Request body too large") end
			       body[#body + 1] = data
			    end
			 end)
   if not ok then return nil,err,bytes > maxBytes and 413 or 400 end
   return table.concat(body)
end

local function decodeJson(body)
   local ok,result,err = pcall(ba.json.decode,body)
   if not ok then return nil,"Invalid JSON" end
   if result == nil then return nil,err or "Invalid JSON" end
   return result
end

local function headerIncludes(value, token)
   if not value then return false end
   return string.find(string.lower(value), string.lower(token), 1, true) ~= nil
end

local function sessionHeader(cmd)
   return cmd:header("MCP-Session-Id") or cmd:header("Mcp-Session-Id")
end

local function firstHeaderValue(value)
   if type(value) ~= "string" then return nil end
   value = value:match("^%s*([^,]+)") or value
   value = value:gsub("^%s+", ""):gsub("%s+$", "")
   return value ~= "" and value or nil
end

local function forwardedParam(value, name)
   value = firstHeaderValue(value)
   if not value then return nil end
   local pattern = name .. '="?([^";,]+)"?'
   return value:match(pattern)
end

local function safeHost(value)
   value = firstHeaderValue(value)
   if not value or value:find("[\r\n]") then return nil end
   if not value:match("^[%w%-%._:%[%]]+$") then return nil end
   return value
end

local function safeProto(value)
   value = string.lower(firstHeaderValue(value) or "")
   if value == "http" or value == "https" then return value end
   return nil
end

local function requestServer(cmd, trustForwardedHeaders)
   local forwarded = trustForwardedHeaders and cmd:header("Forwarded") or nil
   local host = (trustForwardedHeaders and safeHost(cmd:header("X-Forwarded-Host"))) or
	 (trustForwardedHeaders and safeHost(forwardedParam(forwarded, "host"))) or safeHost(cmd:header("Host"))
   if not host then return nil end
   local proto = (trustForwardedHeaders and safeProto(cmd:header("X-Forwarded-Proto"))) or
	 (trustForwardedHeaders and safeProto(forwardedParam(forwarded, "proto"))) or
	 "http"
   return {
      origin = proto .. "://" .. host,
      host = host,
      protocol = proto,
      advisory = true
   }
end

local function newContext(cmd,request,session,stream,transport)
   local requestId = request and request.id or nil
   local server = requestServer(cmd, transport and transport.trustForwardedHeaders)
   if requestId == nil and ba and type(ba.rndbs) == "function" and type(ba.b64urlencode) == "function" then
      requestId = ba.b64urlencode(ba.rndbs(12))
   end
   return {
      requestId = requestId and tostring(requestId) or tostring(os.time()) .. "-" .. tostring(math.random(1000000)),
      headers = {
	 origin = cmd:header("Origin"),
	 accept = cmd:header("Accept"),
	 contentType = cmd:header("Content-Type"),
	 protocolVersion = cmd:header("MCP-Protocol-Version"),
	 sessionId = sessionHeader(cmd),
	 authorization = cmd:header("Authorization"),
	 host = cmd:header("Host"),
	 forwardedHost = cmd:header("X-Forwarded-Host"),
	 forwardedProto = cmd:header("X-Forwarded-Proto"),
	 forwarded = cmd:header("Forwarded")
      },
      server = server,
      serverOrigin = server and server.origin or nil,
      session = session,
      sessionId = session and session.id or nil,
      client = session and session.client or nil,
      stream = stream,
      user = nil,
      log = function(level,message) tracep(false,level,"MCP",message) end
   }
end

local function jsonRpcError(id, code, message, data)
   return Dispatcher.jsonRpcError(id, code, message, data)
end

local function isBatch(value)
   return type(value) == "table" and value[1] ~= nil
end

local function isJsonRpcRequest(value)
   return type(value) == "table" and value.jsonrpc == "2.0" and
	  type(value.method) == "string" and value.id ~= nil
end

local function isJsonRpcNotification(value)
   return type(value) == "table" and value.jsonrpc == "2.0" and
	  type(value.method) == "string" and value.id == nil
end

local function isJsonRpcResponse(value)
   return type(value) == "table" and value.jsonrpc == "2.0" and
	  value.method == nil and (value.result ~= nil or value.error ~= nil)
end

local function statusForResponse(response)
   if type(response) == "table" and response.error then
      if response.error.code == -32700 or response.error.code == -32600 then
	 return 400
      elseif response.error.code == -32601 then
	 return 404
      elseif response.error.code == -32001 then
	 return 403
      end
   end
   return 200
end

local function visibleAscii(value)
   return type(value) == "string" and string.match(value, "^[%g]+$") ~= nil
end

local function seedRandom()
   if randomSeeded then return end
   randomSeeded = true
   math.randomseed(os.time() + math.floor(collectgarbage("count") * 1000))
   math.random()
   math.random()
end

local function makeSessionId()
   if ba and type(ba.rndbs) == "function" and type(ba.b64urlencode) == "function" then
      return "mcp-" .. ba.b64urlencode(ba.rndbs(24))
   end
   seedRandom()
   sessionCounter = sessionCounter + 1
   return "mcp-" .. tostring(os.time()) .. "-" ..
	  tostring(math.random(100000, 999999)) .. "-" ..
	  tostring(sessionCounter)
end

local function makeStreamHelper(transport, session)
   if not session then return nil end
   local stream = {}
   function stream:notify(method, params)
      return transport:notify(session.id, method, params)
   end
   function stream:log(level, message, logger)
      return self:notify("notifications/message", {
	 level = level or "info",
	 logger = logger or "BAS",
	 data = message or ""
      })
   end
   function stream:progress(progressToken, progress, total, message)
      local params = {
	 progressToken = progressToken,
	 progress = progress
      }
      if total ~= nil then params.total = total end
      if message ~= nil then params.message = message end
      return self:notify("notifications/progress", params)
   end
   return stream
end

function Streamable:authorize(cmd, ctx)
   local origin = cmd:header("Origin")
   if type(self.authorizeOrigin) == "function" then
      local ok, allowed, reason = pcall(self.authorizeOrigin, origin, cmd, ctx or {})
      if not ok then return false, tostring(allowed), origin end
      if not allowed then return false, reason, origin end
      return true, nil, origin
   end
   if origin then return false, "Origin is not allowed", origin end
   return true, nil, origin
end

function Streamable:createSession(protocolVersion, client)
   self:cleanupSessions(self.clock())
   local count = 0
   for _ in pairs(self.sessions) do count = count + 1 end
   if count >= self.maxSessions then return nil, "Session capacity reached" end
   local id = self.sessionIdFactory and self.sessionIdFactory() or makeSessionId()
   if not visibleAscii(id) or #id > 128 then return nil, "Invalid generated session ID" end
   local attempts = 0
   while self.sessions[id] do
      attempts = attempts + 1
      if attempts > 10 then return nil, "Cannot generate unique session ID" end
      id = self.sessionIdFactory and self.sessionIdFactory() or makeSessionId()
   end
   local now = self.clock()
   local session = {
      id = id,
      createdAt = now,
      updatedAt = now,
      protocolVersion = protocolVersion or self.protocolVersion,
      client = client,
      streams = {}
   }
   self.sessions[id] = session
   return session
end

function Streamable:getSession(id)
   if not visibleAscii(id) then return nil end
   return self.sessions[id]
end

function Streamable:requireSession(cmd, origin)
   if not self.stateful then return nil, nil end
   local id = sessionHeader(cmd)
   if not id then
      return nil, 400, "Missing MCP-Session-Id"
   end
   local session = self:getSession(id)
   if not session then
      return nil, 404, "Unknown MCP-Session-Id"
   end
   local now = self.clock()
   if self:isSessionExpired(session, now) then self:closeSession(id); return nil, 404, "Expired MCP-Session-Id" end
   session.updatedAt = now
   return session, nil, nil
end

function Streamable:writeFrameToStream(session, streamId, message)
   local stream = session and session.streams and session.streams[streamId]
   if not stream or not stream.socket then return false end
   local encoded, encodeErr = encodeBounded(message, self.maxNotificationBytes)
   if not encoded then return false, encodeErr end
   encoded = string.gsub(encoded, "\\/", "/")
   local frame = "event: message\n" .. "data: " .. encoded .. "\n\n"
   local chunk = string.format("%X\r\n%s\r\n", #frame, frame)
   local ok, err = stream.socket:write(chunk)
   if not ok then
      self:removeStream(session.id, streamId)
      return false
   end
   return true
end

function Streamable:removeStream(sessionId, streamId)
   local session = self.sessions[sessionId]
   if not session or not session.streams then return end
   local stream = session.streams[streamId]
   session.streams[streamId] = nil
   if stream and type(self.onStreamClose) == "function" then
      pcall(self.onStreamClose, session, stream, self)
   end
   if stream and stream.socket then stream.socket:close() end
end

function Streamable:addStream(session, socket)
   local count = 0
   for _ in pairs(session.streams) do count = count + 1 end
   if count >= self.maxStreamsPerSession then return nil, "Stream capacity reached" end
   self.streamCounter = self.streamCounter + 1
   local streamId = tostring(self.streamCounter)
   session.streams[streamId] = {
      id = streamId,
      socket = socket,
      createdAt = self.clock()
   }
   if type(self.onStreamOpen) == "function" then
      pcall(self.onStreamOpen, session, session.streams[streamId], self)
   end
   return streamId
end

function Streamable:notify(sessionId, method, params)
   local session = self.sessions[sessionId]
   if not session then return false, "unknown session" end
   local message = {
      jsonrpc = "2.0",
      method = method,
      params = params or {}
   }
   local delivered = false
   local ids = {}
   for streamId in pairs(session.streams) do ids[#ids + 1] = streamId end
   for _, streamId in ipairs(ids) do
      if self:writeFrameToStream(session, streamId, message) then
	 delivered = true
      end
   end
   return delivered
end

function Streamable:notifyAll(method, params)
   local delivered = false
   local ids = {}
   for sessionId in pairs(self.sessions) do ids[#ids + 1] = sessionId end
   for _, sessionId in ipairs(ids) do
      local ok = self:notify(sessionId, method, params)
      delivered = delivered or ok
   end
   return delivered
end

function Streamable:closeSession(sessionId)
   local session = self.sessions[sessionId]
   if not session then return false end
   local ids = {}
   for streamId in pairs(session.streams) do ids[#ids + 1] = streamId end
   for _, streamId in ipairs(ids) do
      self:removeStream(sessionId, streamId)
   end
   self.sessions[sessionId] = nil
   if self.eventStore and type(self.eventStore.delete) == "function" then
      pcall(self.eventStore.delete, sessionId)
   end
   return true
end

function Streamable:isSessionExpired(session, now)
   return now - session.updatedAt >= self.sessionIdleTimeoutSeconds or
      now - session.createdAt >= self.sessionMaxLifetimeSeconds
end

function Streamable:cleanupSessions(now)
   now = now or self.clock()
   local ids = {}
   for id, session in pairs(self.sessions) do if self:isSessionExpired(session, now) then ids[#ids + 1] = id end end
   for _, id in ipairs(ids) do self:closeSession(id) end
   self.lastCleanupAt = now
   return #ids
end

function Streamable:handleOptions(cmd)
   local allowed, reason, origin = self:authorize(cmd, {})
   if not allowed then
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32001, reason or "Origin forbidden"), 403, nil)
      return
   end
   cmd:reset()
   cmd:setstatus(204)
   setStreamableBaseHeaders(self, cmd, origin)
   cmd:setheader("Access-Control-Allow-Methods", "POST,GET,DELETE,OPTIONS")
   cmd:setheader("Access-Control-Allow-Headers", "Content-Type,Accept,Authorization,MCP-Protocol-Version,MCP-Session-Id,Mcp-Session-Id,Last-Event-ID")
   cmd:setheader("Content-Length", "0")
end

function Streamable:handleDelete(cmd)
   local allowed, reason, origin = self:authorize(cmd, {})
   if not allowed then
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32001, reason or "Origin forbidden"), 403, nil)
      return
   end
   local session, status, message = self:requireSession(cmd, origin)
   if not session then
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32600, message), status, origin)
      return
   end
   local sessionId = session.id
   self:closeSession(sessionId)
   sendStreamableEmpty(self, cmd, 204, origin, sessionId)
end

function Streamable:handleGet(cmd)
   self:cleanupSessions(self.clock())
   local allowed, reason, origin = self:authorize(cmd, {})
   if not allowed then
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32001, reason or "Origin forbidden"), 403, nil)
      return
   end
   if not self.enableGetStream then
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32600, "GET SSE streams are disabled"), 405, origin)
      return
   end
   if not headerIncludes(cmd:header("Accept"), "text/event-stream") then
      if self.allowNonSseGet then
	 sendStreamableEmpty(self, cmd, 204, origin)
	 return
      end
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32600, "Accept must include text/event-stream"), 406, origin)
      return
   end
   if cmd:header("Last-Event-ID") and not self.resumable then
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32600, "Event replay is not implemented"), 400, origin)
      return
   end
   local session, status, message = self:requireSession(cmd, origin)
   if not session then
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32600, message), status, origin)
      return
   end
   local streamCount = 0
   for _ in pairs(session.streams) do streamCount = streamCount + 1 end
   if streamCount >= self.maxStreamsPerSession then
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32000, "Stream capacity reached"), 429, origin, session.id)
      return
   end

   cmd:reset()
   cmd:setstatus(200)
   setStreamableBaseHeaders(self, cmd, origin, session.id)
   cmd:setheader("Content-Type", "text/event-stream")
   cmd:setheader("Cache-Control", "no-cache, no-transform")
   cmd:write(": connected\n\n")
   cmd:flush()

   local socket = ba.socket.req2sock(cmd)
   if not socket then return end
   local streamId = self:addStream(session, socket)
   socket:event(function(sock)
      sock:read()
      self:removeStream(session.id, streamId)
   end, "s")
   if type(cmd.abort) == "function" then cmd:abort() end
end

function Streamable:handlePost(cmd)
   self:cleanupSessions(self.clock())
   local allowed, reason, origin = self:authorize(cmd, {})
   if not allowed then
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32001, reason or "Origin forbidden"), 403, nil)
      return
   end
   local accept = cmd:header("Accept")
   if self.requireStrictAccept and
      (not headerIncludes(accept, "application/json") or
       not headerIncludes(accept, "text/event-stream")) then
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32600, "Accept must include application/json and text/event-stream"), 406, origin)
      return
   end
   local contentType = string.lower(cmd:header("Content-Type") or "")
   if not contentType:match("^%s*application/json%s*[;]?") then
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32600, "Content-Type must be application/json"), 415, origin)
      return
   end
   if cmd:header("Last-Event-ID") and not self.resumable then
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32600, "Event replay is not implemented"), 400, origin)
      return
   end

   local body, bodyErr, bodyStatus = readBody(cmd, self.maxRequestBodyBytes)
   if not body then
      sendStreamableJson(self, cmd, jsonRpcError(nil, bodyStatus == 413 and -32000 or -32700, bodyErr), bodyStatus or 400, origin)
      return
   end

   local req, jsonErr = decodeJson(body)
   if not req then
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32700, jsonErr), 400, origin)
      return
   end
   if isBatch(req) then
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32600, "JSON-RPC batches are not allowed by MCP Streamable HTTP"), 400, origin)
      return
   end

   local isInitialize = isJsonRpcRequest(req) and req.method == "initialize"
   local session
   if self.stateful and not isInitialize then
      local status, message
      session, status, message = self:requireSession(cmd, origin)
      if not session then
	 sendStreamableJson(self, cmd, jsonRpcError(req.id, -32600, message), status, origin)
	 return
      end
   end

   if isJsonRpcNotification(req) or isJsonRpcResponse(req) then
      sendStreamableEmpty(self, cmd, 202, origin, session and session.id or nil)
      return
   end

   local stream = makeStreamHelper(self, session)
   local ctx = newContext(cmd, req, session, stream, self)
   local response = Dispatcher.dispatch(self.mcp, req, ctx)
   if response == nil then
      sendStreamableEmpty(self, cmd, 202, origin, session and session.id or nil)
      return
   end

   local responseSessionId = session and session.id or nil
   if isInitialize and type(response) == "table" and response.result and not response.error then
      local sessionErr
      session, sessionErr = self:createSession(response.result.protocolVersion or self.protocolVersion, ctx.client)
      if not session then
         sendStreamableJson(self, cmd, jsonRpcError(req.id, -32000, sessionErr), 503, origin)
         return
      end
      responseSessionId = session.id
   end
   sendStreamableJson(self, cmd, response, statusForResponse(response), origin, responseSessionId)
end

function Streamable:handle(cmd)
   local now = self.clock()
   if now - self.lastCleanupAt >= self.cleanupIntervalSeconds then self:cleanupSessions(now) end
   local method = cmd:method()
   if method == "OPTIONS" then return self:handleOptions(cmd) end
   if method == "GET" then return self:handleGet(cmd) end
   if method == "DELETE" then return self:handleDelete(cmd) end
   if method == "POST" then return self:handlePost(cmd) end
   local allowed, _, origin = self:authorize(cmd, {})
   if not allowed then
      sendStreamableJson(self, cmd, jsonRpcError(nil, -32001, "Origin forbidden"), 403, nil)
      return
   end
   sendStreamableJson(self, cmd, jsonRpcError(nil, -32600, "Invalid HTTP method"), 405, origin)
end

function Http.streamable(mcp, options)
   options = options or {}
   if options.resumable == true then error("FastMCP resumable transport is not implemented") end
   local self = setmetatable({
      mcp = mcp,
      sessions = {},
      streamCounter = 0,
      stateful = options.stateful ~= false,
      enableGetStream = options.enableGetStream ~= false,
      protocolVersion = options.protocolVersion or "2025-11-25",
      authorizeOrigin = options.authorizeOrigin,
      requireStrictAccept = options.requireStrictAccept ~= false,
      resumable = false,
      eventStore = options.eventStore,
      onStreamOpen = options.onStreamOpen,
      onStreamClose = options.onStreamClose,
      allowNonSseGet = options.allowNonSseGet == true,
      maxRequestBodyBytes = options.maxRequestBodyBytes or 1024 * 1024,
      maxResponseBytes = options.maxResponseBytes or 4 * 1024 * 1024,
      maxNotificationBytes = options.maxNotificationBytes or 256 * 1024,
      maxSessions = options.maxSessions or 16,
      maxStreamsPerSession = options.maxStreamsPerSession or 2,
      sessionIdleTimeoutSeconds = options.sessionIdleTimeoutSeconds or 30 * 60,
      sessionMaxLifetimeSeconds = options.sessionMaxLifetimeSeconds or 8 * 60 * 60,
      cleanupIntervalSeconds = options.cleanupIntervalSeconds or 60,
      clock = options.clock or os.time,
      sessionIdFactory = options.sessionIdFactory,
      trustForwardedHeaders = options.trustForwardedHeaders == true,
      lastCleanupAt = (options.clock or os.time)()
   }, Streamable)
   assert(self.maxRequestBodyBytes > 0 and self.maxResponseBytes > 0 and self.maxNotificationBytes > 0, "byte limits must be positive")
   assert(self.maxSessions > 0 and self.maxStreamsPerSession > 0, "session limits must be positive")
   return self
end

function Http.handle(mcp,cmd,options)
   options = options or {}
   local maxRequestBodyBytes = options.maxRequestBodyBytes or 1024 * 1024
   local maxResponseBytes = options.maxResponseBytes or 4 * 1024 * 1024
   local method = cmd:method()

   if method == "OPTIONS" then
      cmd:reset()
      cmd:setstatus(204)
      setOrigin(cmd)
      cmd:setheader("Access-Control-Allow-Methods","POST,GET,OPTIONS")
      cmd:setheader("Access-Control-Allow-Headers","Content-Type,Accept,Authorization,MCP-Protocol-Version,Mcp-Session-Id,Last-Event-ID")
      cmd:setheader("Content-Length","0")
      return
   end

   if method == "GET" then
      sendEmpty(cmd,204)
      return
   end

   if method ~= "POST" then
      sendJson(cmd,Dispatcher.jsonRpcError(nil,-32600,"Invalid HTTP method"),405,maxResponseBytes)
      return
   end

   local contentType = string.lower(cmd:header("Content-Type") or "")
   if not contentType:match("^%s*application/json%s*[;]?") then
      sendJson(cmd,Dispatcher.jsonRpcError(nil,-32600,"Content-Type must be application/json"),415,maxResponseBytes)
      return
   end

   local body,bodyErr,bodyStatus = readBody(cmd,maxRequestBodyBytes)
   if not body then
      sendJson(cmd,Dispatcher.jsonRpcError(nil,bodyStatus == 413 and -32000 or -32700,bodyErr),bodyStatus or 400,maxResponseBytes)
      return
   end

   local req,jsonErr = decodeJson(body)
   if not req then
      sendJson(cmd,Dispatcher.jsonRpcError(nil,-32700,jsonErr),400,maxResponseBytes)
      return
   end

   local ctx = newContext(cmd,req,nil,nil,{ trustForwardedHeaders=options.trustForwardedHeaders == true })
   local response = Dispatcher.dispatch(mcp,req,ctx)
   if response == nil then
      sendEmpty(cmd,204)
      return
   end

   local status = statusForResponse(response)
   sendJson(cmd,response,status,maxResponseBytes)
end

return Http
