local FastMCP = require"fastmcp.engine"
local rw = require"rwfile"

local M = {}
local infoContentIo
local configurationStatusProvider

local tinsert = table.insert
local sfmt = string.format

local readAnnotations = { readOnlyHint = true, idempotentHint = true }
local mutateAnnotations = { readOnlyHint = false, destructiveHint = false }
local destructiveAnnotations = { readOnlyHint = false, destructiveHint = true }

local function objectSchema(properties, required)
   local schema = {
      type = "object",
      properties = properties or {},
      additionalProperties = false
   }
   if required and #required > 0 then schema.required = required end
   return schema
end

local function stringSchema(description, default)
   local schema = { type = "string", description = description }
   if default ~= nil then schema.default = default end
   return schema
end

local function boolSchema(description, default)
   local schema = { type = "boolean", description = description }
   if default ~= nil then schema.default = default end
   return schema
end

local function enumSchema(values, description, default)
   local schema = { type = "string", enum = values, description = description }
   if default ~= nil then schema.default = default end
   return schema
end

local function result(message, runtime, data, warnings, nextActions)
   data=data or {}
   if runtime and runtime.labName and data.labName == nil then data.labName=runtime.labName end
   return {
      ok = true,
      message = message,
      runtime = runtime,
      warnings = warnings or {},
      nextActions = nextActions or {},
      data = data
   }
end

local function traceBufferSize(value)
   local size = tonumber(value) or 0
   if size < 0 then size = 0 end
   return math.floor(size)
end

local function setupRuntimeTrace(runtimeTrace, defaultBufferSize)
   runtimeTrace = runtimeTrace or {}
   local segments = {}
   local head, tail = 1, 0
   local bytes = 0
   local limit = traceBufferSize(defaultBufferSize)
   local overflowed = false
   local droppedBytes = 0

   local function clear()
      segments = {}
      head, tail = 1, 0
      bytes = 0
      overflowed = false
      droppedBytes = 0
   end

   local function messageCount()
      return tail >= head and (tail - head + 1) or 0
   end

   local function trim()
      if limit <= 0 then
	 clear()
	 return
      end
      while bytes > limit and head <= tail do
	 local oldest = segments[head] or ""
	 local oldestSize = #oldest
	 local bytesWithoutOldest = bytes - oldestSize
	 if bytesWithoutOldest >= limit or oldestSize == 0 then
	    segments[head] = nil
	    head = head + 1
	    bytes = bytesWithoutOldest
	    overflowed = true
	    droppedBytes = droppedBytes + oldestSize
	 else
	    local keep = limit - bytesWithoutOldest
	    local trimmed = oldest:sub(oldestSize - keep + 1)
	    segments[head] = trimmed
	    bytes = bytesWithoutOldest + #trimmed
	    overflowed = true
	    droppedBytes = droppedBytes + oldestSize - #trimmed
	    break
	 end
      end
   end

   function runtimeTrace.record(data)
      if limit <= 0 then return false end
      data = tostring(data or "")
      if data == "" then return true end
      if #data > limit then
	 overflowed = true
	 droppedBytes = droppedBytes + #data - limit
	 data = data:sub(#data - limit + 1)
      end
      tail = tail + 1
      segments[tail] = data
      bytes = bytes + #data
      trim()
      return true
   end

   function runtimeTrace.read()
      local trace = messageCount() > 0 and table.concat(segments, "", head, tail) or ""
      local data = {
	 trace = trace,
	 bytes = bytes,
	 messageCount = messageCount(),
	 bufferSize = limit,
	 overflowed = overflowed,
	 truncated = overflowed,
	 droppedBytes = droppedBytes,
	 enabled = limit > 0,
	 cleared = true
      }
      clear()
      return data
   end

   function runtimeTrace.setBufferSize(size)
      limit = traceBufferSize(size)
      if limit <= 0 then clear() else trim() end
      return limit
   end

   runtimeTrace.setBufferSize(limit)
   return runtimeTrace
end

local function lower(value)
   return string.lower(tostring(value or ""))
end

local function endsWith(value, suffix)
   return suffix == "" or string.sub(value, -#suffix) == suffix
end

local function dirname(path)
   return string.match(path, "^(.*)/[^/]+$") or ""
end

local function validatePath(path, required, label, resolvedLabName)
   label = label or "path"
   if type(path) ~= "string" then
      return nil, FastMCP.error(label .. " must be a string", { code = "invalidPath", labName=resolvedLabName })
   end
   if path == "" then
      if required then
	 return nil, FastMCP.error(label .. " is required", { code = "invalidPath", labName=resolvedLabName })
      end
      return ""
   end
   if path:find("\\", 1, true) or path:find("..", 1, true) or path:match("^%a:") or path:sub(1, 1) == "/" then
      return nil, FastMCP.error(label .. " must be a safe relative BAS IO path", { code = "unsafePath", path = path, labName=resolvedLabName })
   end
   return path:gsub("/+$", "")
end

local function labName(lab)
   if lab and type(lab.name) == "function" then return lab.name(lab) end
   return nil
end

local function backupNameRequiredError(appmgr)
   local selectedLabName=labName(appmgr)
   local selectedDescription=selectedLabName and ("lab "..selectedLabName) or "the selected lab"
   return FastMCP.error("A user-provided backup name is required. Ask the user what name to use; do not invent one.", {
      code = "backupNameRequired",
      requiresUserInput = true,
      field = "backupName",
      labName = selectedLabName,
      nextActions = {
         "Ask the user what backup name to use for "..selectedDescription..".",
         "Do not derive a backup name from the date, lab name, task, or conversation."
      }
   })
end

local function backupAlreadyExistsError(appmgr, name, err)
   return FastMCP.error("A backup with this name already exists. Ask the user for another backup name.", {
      code = "backupAlreadyExists",
      requiresUserInput = true,
      field = "backupName",
      labName = labName(appmgr),
      backupName = name,
      error = err,
      nextActions = {
         "Tell the user that backup " .. tostring(name) .. " already exists.",
         "Ask the user for another backup name; do not overwrite or merge the existing backup."
      }
   })
end

local function validateBackupName(name, appmgr)
   if name == nil or name == "" or (type(name) == "string" and name:match("^%s*$")) then
      return nil, backupNameRequiredError(appmgr)
   end
   if type(name) ~= "string" then
      return nil, FastMCP.error("backupName must be a string", { code = "invalidBackupName", labName=labName(appmgr) })
   end
   if name:find("\\", 1, true) or name:find("/", 1, true) or name:find("..", 1, true) or name:match("^%a:") then
      return nil, FastMCP.error("backupName must be a safe backup directory name", { code = "unsafeBackupName", backupName = name, labName=labName(appmgr) })
   end
   return name
end

local function mapBackupNameInputError(appmgr, validationErr)
   if validationErr and validationErr.code == "required" and validationErr.field == "backupName" then
      return backupNameRequiredError(appmgr)
   end
end

local function ensureLab(lab)
   local ok, err = lab:create()
   if not ok then
      return nil, FastMCP.error("Cannot create lab", { code = "createLabFailed", labName=lab:name(), error = err })
   end
   local labIo, executeIo = lab:getLabIo()
   if not labIo then
      return nil, FastMCP.error("Lab IO is unavailable", { code = "labIoUnavailable", labName=lab:name() })
   end
   return labIo, executeIo
end

local function numberedLabChoices(labs)
   local choices={}
   for i,info in ipairs(labs or {}) do
      tinsert(choices,{
         number=i,
         labName=info.name,
         basePath=info.basePath,
         running=info.running,
         prompt=sfmt("Select lab %d",i)
      })
   end
   return choices
end

local function sessionLabName(ctx)
   if ctx and ctx.sessionState then return ctx.sessionState:get("activeLabName") end
end

local function setSessionLabName(ctx,name)
   if not ctx or not ctx.sessionState then return nil,"A stateful MCP session is required" end
   return ctx.sessionState:set("activeLabName",name)
end

local function resolveLab(appmgr,args,ctx)
   args=args or {}
   local requested=args.labName
   if requested == "" then requested=nil end
   local selected=requested or sessionLabName(ctx)
   if selected then
      local lab,err,code=appmgr.getLab(selected)
      if lab then return lab,requested and "argument" or "session" end
      return nil,FastMCP.error("The selected lab does not exist. Refresh the lab list and ask the user to choose again.",{
         code=code == "invalidLabName" and code or "unknownLab",
         labName=selected,
         error=err,
         nextActions={"Call listLabs to refresh the available labs.","Ask the user to select an available lab."}
      })
   end

   local labs,err=appmgr.listLabs()
   if not labs then return nil,FastMCP.error("Cannot list labs",{code="listLabsFailed",error=err}) end
   if #labs == 1 then
      local lab,labErr=appmgr.getLab(labs[1].name)
      if not lab then return nil,FastMCP.error("Cannot resolve the only lab",{code="unknownLab",error=labErr}) end
      if ctx and ctx.sessionState then setSessionLabName(ctx,lab:name()) end
      return lab,"automatic"
   end
   if #labs == 0 then
      return nil,FastMCP.error("No labs exist. Ask the user for a unique lab name before creating one.",{
         code="labCreationRequired",
         requiresUserInput=true,
         field="labName",
         nextActions={"Ask the user what name to use for the new lab.","Call createLab with that exact user-provided labName."}
      })
   end
   return nil,FastMCP.error("Multiple labs are available and this session has not selected one. Ask the user which lab to use.",{
      code="labSelectionRequired",
      requiresUserInput=true,
      field="labName",
      choices=numberedLabChoices(labs),
      nextActions={"Present the numbered lab choices to the user.","Call selectLab with the chosen labName."}
   })
end

local function labOperationError(lab,operation,err,code,defaultCode)
   if code == "labBusy" then
      return FastMCP.error("The lab is busy with another operation.",{
         code="labBusy",
         labName=lab:name(),
         requestedOperation=operation,
         activeOperation=lab:busy(),
         error=err,
         nextActions={"Report the active operation to the user.","Retry only when the operation has completed and retrying matches the user's intent."}
      })
   end
   return FastMCP.error("Cannot "..operation,{code=defaultCode,error=err,labName=lab:name()})
end

local function trimText(text)
   if type(text) ~= "string" then return nil end
   text = text:gsub("^%s+", ""):gsub("%s+$", "")
   return text ~= "" and text or nil
end

local function markdownText(path)
   if not infoContentIo then return nil end
   return trimText(rw.file(infoContentIo, path))
end

local function normalizedSetupPath(baseUri)
   baseUri = tostring(baseUri or "")
   if baseUri == "" then return "/" end
   if baseUri:sub(1, 1) ~= "/" then baseUri = "/" .. baseUri end
   if baseUri:sub(-1) ~= "/" then baseUri = baseUri .. "/" end
   return baseUri
end

local function configurationPagePath(baseUri)
   return normalizedSetupPath(baseUri) .. "lsp-claw-config.lsp"
end

local function requestOrigin(ctx)
   if type(ctx) ~= "table" then return nil end
   if type(ctx.serverOrigin) == "string" and ctx.serverOrigin ~= "" then return ctx.serverOrigin end
   if type(ctx.server) == "table" and type(ctx.server.origin) == "string" and ctx.server.origin ~= "" then
      return ctx.server.origin
   end
   return nil
end

local function absoluteUrl(origin, path)
   if not origin then return nil end
   path = tostring(path or "/")
   if path == "" then path = "/" end
   if path:sub(1, 1) ~= "/" then path = "/" .. path end
   return origin:gsub("/+$", "") .. path
end

local function archiveTicketUrl(ctx,ticket)
   local status=configurationStatusProvider and configurationStatusProvider() or {}
   local base=tostring(status.setupBaseUri or "")
   if base == "" then base="/" end
   if base:sub(1,1) ~= "/" then base="/"..base end
   if base:sub(-1) ~= "/" then base=base.."/" end
   local path=base.."archive.lsp?ticket="..ticket
   return absoluteUrl(requestOrigin(ctx),path),path
end

local function transferServiceUrl(ctx)
   local status=configurationStatusProvider and configurationStatusProvider() or {}
   local base=tostring(status.setupBaseUri or "")
   if base == "" then base="/" end
   if base:sub(1,1) ~= "/" then base="/"..base end
   if base:sub(-1) ~= "/" then base=base.."/" end
   local path=base.."transfer.lsp"
   return absoluteUrl(requestOrigin(ctx),path),path
end

local function configurationStatus(ctx)
   local status = {}
   if type(configurationStatusProvider) == "function" then
      status = configurationStatusProvider() or {}
   end
   local setupPath = configurationPagePath(status.setupBaseUri)
   local origin = requestOrigin(ctx)
   local githubTokenSet = status.githubTokenSet == true
   local mcpAuthTokenSet = status.mcpAuthTokenSet == true
   local browserAdminConfigured = status.browserAdminConfigured == true
   local warnings = {}
   if not githubTokenSet then
      tinsert(warnings, "No GitHub token is configured. Public GitHub access can still work, but requests are unauthenticated and may be rate limited.")
   end
   if not mcpAuthTokenSet then
      tinsert(warnings, "No MCP authentication token is configured. Any client that can reach this MCP endpoint can use the server.")
   end
   if not browserAdminConfigured then
      tinsert(warnings, "No browser configuration administrator is configured. Restart LSP-Claw once with -credentials before using the browser settings page.")
   end
   return {
      browserAdministrator = {
	 configured = browserAdminConfigured,
	 purpose = "Authenticates access to the browser configuration and lab-management page."
      },
      tokens = {
	 github = {
	    configured = githubTokenSet,
	    name = "GITHUB_TOKEN",
	    purpose = "Authenticates outbound GitHub API requests for reading RealTimeLogic/LSP-Examples.",
	    limitationWhenMissing = "Public GitHub access can still work, but requests are unauthenticated and may be rate limited."
	 },
	 mcpAuth = {
	    configured = mcpAuthTokenSet,
	    name = "MCP_AUTH_TOKEN",
	    purpose = "Requires inbound MCP clients to authenticate with a bearer token.",
	    securityWhenMissing = "Any client that can reach this MCP endpoint can use the server."
	 }
      },
      setupPage = {
	 baseUri = status.setupBaseUri or "",
	 path = setupPath,
	 url = absoluteUrl(origin, setupPath),
	 serverOrigin = origin,
	 urlTemplate = "http://<mcp-server-address>" .. setupPath,
	 guidance = "When LSP-Claw is already running, configure tokens from the browser configuration page. Use setupPage.url when present; otherwise replace <mcp-server-address> in urlTemplate with the host or IP address serving this MCP app."
      }
   }, warnings
end

local function runtimeInfo(appmgr,ctx,lab)
   local executeIo=xedge ~= nil
   local runtime=executeIo and "Xedge" or "Mako"
   local warnings = {}
   local poweredBy = nil
   if mako and xedge then
      poweredBy = "Mako Server powers Xedge"
   elseif xedge then
      poweredBy = "Standalone Xedge"
   elseif mako then
      poweredBy = "Mako Server"
   else
      poweredBy = "Unknown BAS host"
      local warning = markdownText(".info/runtimeWarningUnknownHost.md")
      if warning then tinsert(warnings, warning) end
   end
   local configuration, configurationWarnings = configurationStatus(ctx)
   for _, warning in ipairs(configurationWarnings or {}) do
      tinsert(warnings, warning)
   end
   local labs,labListErr=appmgr.listLabs()
   if not labs then
      labs={}
      tinsert(warnings,"Cannot read the lab registry: "..tostring(labListErr))
   end
   return {
      runtime = runtime,
      canExecuteXlua = executeIo,
      labRunning = lab and lab:isRunning() or nil,
      labName = lab and lab:name() or nil,
      labBasePath = lab and lab:basePath() or nil,
      labCount = #labs,
      poweredBy = poweredBy,
      guidance = executeIo and markdownText(".info/runtimeGuidanceXedge.md") or
	 markdownText(".info/runtimeGuidanceMako.md"),
      configuration = configuration,
      warnings = warnings
   }
end

local function readText(io, path, limit)
   local data, err = rw.file(io, path)
   if not data then return nil, err end
   if limit and #data > limit then
      return data:sub(1, limit), true
   end
   return data, false
end

local function writeText(io, path, content)
   return rw.file(io, path, content or "")
end

local exampleCatalogLoaded, exampleCatalogCache, exampleCatalogError = false, nil, nil
local exampleCatalogPath = ".ai/main-ai-catalog.json"

local function copyList(list)
   local out = {}
   for _, value in ipairs(list or {}) do tinsert(out, value) end
   return out
end

local function loadExampleCatalog(ghio)
   if exampleCatalogLoaded then return exampleCatalogCache, exampleCatalogError end
   exampleCatalogLoaded = true
   local text, err = readText(ghio, exampleCatalogPath)
   if not text then
      exampleCatalogError = err or "not found"
      return nil, exampleCatalogError
   end
   local ok, decoded = FastMCP.pcall(ba.json.decode, text)
   if not ok or type(decoded) ~= "table" then
      exampleCatalogError = tostring(decoded or "invalid JSON")
      return nil, exampleCatalogError
   end
   exampleCatalogCache = decoded
   return exampleCatalogCache
end

local function catalogEntries(catalog)
   if type(catalog) ~= "table" then return nil end
   if type(catalog.entries) == "table" then return catalog.entries end
   -- Transitional support for older unpublished catalogs.
   if type(catalog.examples) == "table" then return catalog.examples end
   return nil
end

local function catalogEntryPath(entry)
   return type(entry) == "table" and (entry.path or entry.examplePath) or nil
end

local function findCatalogEntry(catalog, examplePath)
   local entries = catalogEntries(catalog)
   if type(entries) ~= "table" then return nil end
   for _, entry in ipairs(entries) do
      if catalogEntryPath(entry) == examplePath then return entry end
   end
   return nil
end

local function catalogEntryForAgent(entry)
   if type(entry) ~= "table" then return nil end
   local examplePath = catalogEntryPath(entry)
   local out = {
      examplePath = examplePath,
      parentPath = dirname(examplePath or ""),
      name = entry.name or entry.title,
      summary = entry.summary,
      compatibility = copyList(entry.compatibility),
      protocols = copyList(entry.protocols),
      topics = copyList(entry.topics or entry.tags),
      useWhen = copyList(entry.use_when or entry.goodFor),
      avoidWhen = copyList(entry.avoid_when or entry.notFor),
      run = copyList(entry.run),
      variants = entry.variants,
      defaultVariant = entry.default_variant,
      prerequisites = entry.prerequisites,
      setup = entry.setup,
      targets = entry.targets,
      notes = copyList(entry.notes),
      catalogPath = entry.catalog_path,
      source = exampleCatalogPath
   }
   return out
end

local function runtimeWarnings(runtime, analysis)
   local warnings = {}
   if runtime and runtime.warnings then
      for _, warning in ipairs(runtime.warnings) do tinsert(warnings, warning) end
   end
   if analysis and analysis.hasXlua and runtime and runtime.runtime == "Mako" then
      local warning = markdownText(".info/runtimeWarningMakoXlua.md")
      if warning then tinsert(warnings, warning) end
   end
   return warnings
end

local function labAppPaths(files,ctx,lab)
   local has = {}
   for _, file in ipairs(files or {}) do has[file] = true end
   local basePath=lab and lab:basePath() or ""
   local mountPath=basePath == "" and "/" or "/"..basePath.."/"
   local entryPaths = { mountPath }
   if has["index.lsp"] then tinsert(entryPaths,mountPath.."index.lsp") end
   if has["index.html"] then tinsert(entryPaths,mountPath.."index.html") end
   local origin = requestOrigin(ctx)
   local entryUrls
   if origin then
      entryUrls = {}
      for _, path in ipairs(entryPaths) do
	 tinsert(entryUrls, absoluteUrl(origin, path))
      end
   end
   return {
      labName=lab and lab:name() or nil,
      basePath=basePath,
      mountPath=mountPath,
      appPath=mountPath,
      serverOrigin = origin,
      appUrl=absoluteUrl(origin,mountPath),
      entryPaths = entryPaths,
      entryUrls = entryUrls,
      commonEntryPaths = { "/", "/index.lsp", "/index.html" },
      urlGuidance = markdownText(".info/labUrlGuidance.md")
   }
end

local function markdownListItems(io, path)
   local srcIo = io or infoContentIo
   if srcIo then
      local text = rw.file(srcIo, path)
      if text then
	 local out = {}
	 for line in string.gmatch(text, "[^\r\n]+") do
	    local item = line:match("^%s*[-*]%s+(.+)$")
	    if item and item ~= "" then tinsert(out, item) end
	 end
	 if #out > 0 then return out end
      end
   end
   return {}
end

local function labOpenNextActions(io)
   return markdownListItems(io, ".info/labOpenNextActions.md")
end

local function exampleCopyGuidance(io)
   return markdownListItems(io, ".info/exampleCopyGuidance.md")
end

local function labStoppedNextActions()
   return markdownListItems(nil, ".info/labStoppedNextActions.md")
end

local function labStartedExtraNextActions()
   return markdownListItems(nil, ".info/labStartedExtraNextActions.md")
end

local function copyConflictNextActions()
   return markdownListItems(nil, ".info/copyExampleToLabConflictActions.md")
end

local function copyExampleToLabNextActions()
   return markdownListItems(nil, ".info/copyExampleToLabNextActions.md")
end

local function appendList(target, source)
   for _, item in ipairs(source or {}) do tinsert(target, item) end
   return target
end

local function labStatusData(appmgr,lab,ctx)
   local labIo, executeIoOrErr = ensureLab(lab)
   if not labIo then return nil, executeIoOrErr end
   local runtime, runtimeErr = runtimeInfo(appmgr,ctx,lab)
   if not runtime then return nil, runtimeErr end
   local topMap, top = {}, {}
   local files, dirs = {}, {}
   for path, name in appmgr.recDirIter(labIo, "", true) do
      if name then
	 local full = appmgr.filePath(path, name)
	 tinsert(files, full)
	 local root = path == "" and name or string.match(path, "^([^/]+)")
	 if root and not topMap[root] then topMap[root] = true; tinsert(top, root) end
      elseif path and path ~= "" then
	 tinsert(dirs, path)
	 local root = string.match(path, "^([^/]+)") or path
	 if root and not topMap[root] then topMap[root] = true; tinsert(top, root) end
      end
   end
   table.sort(top)
   table.sort(files)
   table.sort(dirs)
   return {
      runtime = runtime.runtime,
      labName=lab:name(),
      basePath=lab:basePath(),
      canExecuteXlua = runtime.canExecuteXlua,
      running=lab:isRunning(),
      containsFiles = #files > 0,
      fileCount = #files,
      directoryCount = #dirs,
      topLevelEntries = top,
      files = files,
      directories = dirs,
      labApp=labAppPaths(files,ctx,lab)
   }, runtime
end

local function labContainsEntries(labIo)
   for name in labIo:files() do
      if name and name ~= "." and name ~= ".." then return true end
   end
   return false
end

local function listLabFileNames(appmgr, labIo, includeDirectories)
   local files, dirs = {}, {}
   for path, name in appmgr.recDirIter(labIo, "", includeDirectories) do
      if name then
	 tinsert(files, appmgr.filePath(path, name))
      elseif includeDirectories and path and path ~= "" then
	 tinsert(dirs, path)
      end
   end
   table.sort(files)
   table.sort(dirs)
   return files, dirs
end

local function numberedBackupChoices(backups)
   local choices = {}
   for i, backupName in ipairs(backups or {}) do
      tinsert(choices, {
	 number = i,
	 backupName = backupName,
	 prompt = sfmt("Select backup %d", i)
      })
   end
   return choices
end

local function ensureParentDirs(io, path)
   local dir = dirname(path)
   if dir == "" then return true end
   local cur = ""
   for part in string.gmatch(dir, "[^/]+") do
      cur = cur == "" and part or cur .. "/" .. part
      local st = io:stat(cur)
      if not st then
	 local ok, err = io:mkdir(cur)
	 if not ok then return nil, sfmt("Cannot create %s: %s", cur, err or "?") end
      elseif not st.isdir then
	 return nil, cur .. " exists and is not a directory"
      end
   end
   return true
end

local function registerTools(mcp, ghio, info, appmgr, runtimeTrace, infoIo, archiveManager)
   mcp:tool("getRuntimeInfo", {
      description = "Return server-global Mako/Xedge runtime, configuration, and lab-capacity details. This tool does not require or change lab selection.",
      inputSchema = objectSchema(),
      annotations = readAnnotations
   }, function(args, ctx)
      local runtime, err = runtimeInfo(appmgr, ctx)
      if not runtime then return err end
      return result("Runtime information returned.", runtime, nil, runtime.warnings)
   end)

   mcp:tool("readRuntimeTrace", {
      description = "Return and clear the server-global BAS trace buffer. Trace messages cannot be reliably attributed to an individual lab.",
      inputSchema = objectSchema(),
      annotations = readAnnotations
   }, function()
      if not runtimeTrace or type(runtimeTrace.read) ~= "function" then
	 return result("Runtime trace buffering is not configured.", nil, {
	    trace = "",
	    bytes = 0,
	    messageCount = 0,
	    bufferSize = 0,
	    enabled = false,
	    cleared = true,
	    scope = "server-global",
	    labAttributionReliable = false
	 })
      end
      local data = runtimeTrace.read()
      data.scope="server-global"
      data.labAttributionReliable=false
      return result(data.trace ~= "" and "Runtime trace returned and cleared." or
	 "Runtime trace buffer was empty and cleared.", nil, data)
   end)

   mcp:tool("listLabs", {
      description="List all named labs and their direct base paths. If exactly one lab exists, it is selected automatically for this MCP session.",
      inputSchema=objectSchema(),
      annotations=readAnnotations
   }, function(args,ctx)
      local labs,err=appmgr.listLabs()
      if not labs then return FastMCP.error("Cannot list labs",{code="listLabsFailed",error=err}) end
      local active=sessionLabName(ctx)
      local selection="session"
      if active then
         local found=false
         for _,lab in ipairs(labs) do if lower(lab.name) == lower(active) then active=lab.name found=true break end end
         if not found then
            if ctx and ctx.sessionState then ctx.sessionState:remove("activeLabName") end
            active=nil
            selection="none"
         end
      end
      if #labs == 1 and not active then
         active=labs[1].name
         if ctx and ctx.sessionState then setSessionLabName(ctx,active) end
         selection="automatic"
      elseif not active then
         selection="none"
      end
      return result("Labs listed.",nil,{
         labs=labs,
         choices=numberedLabChoices(labs),
         labCount=#labs,
         activeLabName=active,
         selection=selection
      },nil,#labs > 1 and not active and {"Present the numbered choices and ask the user which lab to select."} or nil)
   end)

   mcp:tool("selectLab", {
      description="Select an existing lab for only the current MCP session. This does not start, stop, create, or modify the lab.",
      inputSchema=objectSchema({labName=stringSchema("Exact lab name returned by listLabs.")},{"labName"}),
      annotations=mutateAnnotations
   }, function(args,ctx)
      if not ctx or not ctx.sessionState then
         return FastMCP.error("Lab selection requires a stateful MCP session.",{code="statefulSessionRequired"})
      end
      local lab,err,code=appmgr.getLab(args.labName)
      if not lab then return FastMCP.error("Lab was not found",{code=code or "unknownLab",labName=args.labName,error=err}) end
      local ok,stateErr=setSessionLabName(ctx,lab:name())
      if not ok then return FastMCP.error("Cannot store the lab selection",{code="sessionStateFailed",error=stateErr}) end
      return result("Lab selected for this MCP session.",runtimeInfo(appmgr,ctx,lab),{
         activeLabName=lab:name(),
         basePath=lab:basePath(),
         selection="session"
      })
   end)

   mcp:tool("getLabStatus", {
      description = "Return lab runtime, running state, file counts, top-level entries, and file lists.",
      inputSchema=objectSchema({labName=stringSchema("Optional explicit lab override; otherwise use this session's selection.")}),
      annotations = readAnnotations
   }, function(args, ctx)
      local lab,labErr=resolveLab(appmgr,args,ctx)
      if not lab then return labErr end
      local status, runtimeOrErr = labStatusData(appmgr,lab,ctx)
      if not status then return runtimeOrErr end
      status.labCount=runtimeOrErr.labCount
      status.activeLabName=sessionLabName(ctx)
      local nextActions = status.running and labOpenNextActions(infoIo) or labStoppedNextActions()
      return result("Lab status returned.", runtimeOrErr, status, runtimeOrErr.warnings, nextActions)
   end)

   mcp:tool("createLab", {
      description="Create a uniquely named lab and select it for this MCP session. Never invent the labName; use the name provided by the user.",
      inputSchema=objectSchema({
         labName=stringSchema("Unique lab name explicitly provided by the user."),
         basePath=stringSchema("Optional direct URL base path. Empty means root; omit to assign automatically.")
      },{"labName"}),
      annotations = mutateAnnotations
   }, function(args, ctx)
      local lab,createErr,createCode,routeChanged=appmgr.createLab(args.labName,args.basePath)
      if not lab then
         return FastMCP.error("Cannot create lab",{code=createCode or "createLabFailed",labName=args.labName,error=createErr})
      end
      if ctx and ctx.sessionState then setSessionLabName(ctx,lab:name()) end
      local runtime=runtimeInfo(appmgr,ctx,lab)
      return result("Lab created and selected.",runtime,{
         created=true,
         activeLabName=lab:name(),
         basePath=lab:basePath(),
         routeChanged=routeChanged
      },runtime.warnings,routeChanged and {"Tell the user that the existing lab URL changed to /"..routeChanged.newBasePath.."/."} or nil)
   end)

   mcp:tool("renameLab", {
      description="Rename a stopped lab and its backup storage. Requires explicit confirmation.",
      inputSchema=objectSchema({
         labName=stringSchema("Existing lab name."),
         newLabName=stringSchema("New unique lab name explicitly provided by the user."),
         confirmed=boolSchema("Must be true after explicit user confirmation.",false)
      },{"labName","newLabName"}),
      annotations=destructiveAnnotations
   }, function(args,ctx)
      if args.confirmed ~= true then return FastMCP.error("Renaming a lab requires confirmation.",{code="renameLabRequiresConfirmation",requiresConfirmation=true,labName=args.labName,newLabName=args.newLabName}) end
      local lab,err,code=appmgr.renameLab(args.labName,args.newLabName)
      if not lab then
         local existing=appmgr.getLab(args.labName)
         if code == "labBusy" and existing then return labOperationError(existing,"rename lab",err,code,"renameLabFailed") end
         return FastMCP.error("Cannot rename lab",{code=code or "renameLabFailed",labName=args.labName,newLabName=args.newLabName,error=err})
      end
      if sessionLabName(ctx) and lower(sessionLabName(ctx)) == lower(args.labName) then setSessionLabName(ctx,lab:name()) end
      local runtime=runtimeInfo(appmgr,ctx,lab)
      return result("Lab renamed.",runtime,{renamed=true,oldLabName=args.labName,newLabName=lab:name(),basePath=lab:basePath()},runtime.warnings)
   end)

   mcp:tool("deleteLab", {
      description="Permanently delete a stopped lab, all lab files, and all of its backups. Requires explicit confirmation.",
      inputSchema=objectSchema({
         labName=stringSchema("Lab to delete."),
         confirmed=boolSchema("Must be true after explicit user confirmation.",false)
      },{"labName"}),
      annotations=destructiveAnnotations
   }, function(args,ctx)
      if args.confirmed ~= true then return FastMCP.error("Deleting a lab and all of its backups requires confirmation.",{code="deleteLabRequiresConfirmation",requiresConfirmation=true,labName=args.labName}) end
      local ok,err,code,routeChanged=appmgr.deleteLab(args.labName)
      if not ok then
         local existing=appmgr.getLab(args.labName)
         if code == "labBusy" and existing then return labOperationError(existing,"delete lab",err,code,"deleteLabFailed") end
         return FastMCP.error("Cannot delete lab",{code=code or "deleteLabFailed",labName=args.labName,error=err})
      end
      if sessionLabName(ctx) and lower(sessionLabName(ctx)) == lower(args.labName) then ctx.sessionState:remove("activeLabName") end
      return result("Lab and its backups were deleted.",runtimeInfo(appmgr,ctx),{
         deleted=true,
         labName=args.labName,
         routeChanged=routeChanged
      },nil,routeChanged and {"The sole remaining automatically routed lab now uses the server root."} or nil)
   end)

   mcp:tool("setLabBasePath", {
      description="Change the direct URL base path for a stopped lab. Empty means the server root. Requires explicit confirmation.",
      inputSchema=objectSchema({
         labName=stringSchema("Existing lab name."),
         basePath=stringSchema("Empty for root or one URL-safe path segment."),
         confirmed=boolSchema("Must be true after explicit user confirmation.",false)
      },{"labName","basePath"}),
      annotations=mutateAnnotations
   }, function(args,ctx)
      if args.confirmed ~= true then return FastMCP.error("Changing a lab URL requires confirmation.",{code="setLabBasePathRequiresConfirmation",requiresConfirmation=true,labName=args.labName,basePath=args.basePath}) end
      local lab,err,code=appmgr.setLabBasePath(args.labName,args.basePath,true)
      if not lab then
         local existing=appmgr.getLab(args.labName)
         if code == "labBusy" and existing then return labOperationError(existing,"change lab base path",err,code,"setLabBasePathFailed") end
         return FastMCP.error("Cannot change lab base path",{code=code or "setLabBasePathFailed",labName=args.labName,basePath=args.basePath,error=err})
      end
      local runtime=runtimeInfo(appmgr,ctx,lab)
      return result("Lab base path changed.",runtime,{changed=true,basePath=lab:basePath(),labApp=labAppPaths({},ctx,lab)},runtime.warnings)
   end)

   if archiveManager then
      mcp:tool("prepareLabExport", {
         description="Prepare a complete, uncompressed ZIP export of a lab and return a short-lived one-time download URL. The browser or client downloads the ZIP directly; do not copy it through MCP text.",
         inputSchema=objectSchema({labName=stringSchema("Optional explicit lab override; otherwise use this session's selection.")}),
         annotations=readAnnotations
      }, function(args,ctx)
         local lab,resolveErr=resolveLab(appmgr,args,ctx)
         if not lab then return resolveErr end
         local prepared,err,code=archiveManager:prepareExport(lab)
         if not prepared then return labOperationError(lab,"export lab",err,code,"exportLabFailed") end
         local url,path=archiveTicketUrl(ctx,prepared.ticket)
         prepared.ticket=nil
         prepared.downloadUrl=url
         prepared.downloadPath=path
         prepared.labName=lab:name()
         return result("Lab export prepared. The download URL is short-lived and works once.",runtimeInfo(appmgr,ctx,lab),prepared,nil,{
            "Download the ZIP directly from downloadUrl before it expires.",
            "Do not request the ZIP contents through MCP text."
         })
      end)

      mcp:tool("prepareLabImport", {
         description="Prepare a short-lived one-time URL for uploading a complete lab ZIP. Use createNew for a new named lab or replace for a confirmed replacement of a stopped lab. Import never merges files.",
         inputSchema=objectSchema({
            labName=stringSchema("Destination lab name explicitly provided by the user."),
            conflictAction=stringSchema("createNew or replace."),
            confirmed=boolSchema("Must be true after explicit user confirmation when conflictAction is replace.",false)
         },{"labName","conflictAction"}),
         annotations=destructiveAnnotations
      }, function(args,ctx)
         local prepared,err,code=archiveManager:prepareImport(args.labName,args.conflictAction,args.confirmed)
         if not prepared then
            return FastMCP.error("Cannot prepare lab import",{
               code=code or "prepareLabImportFailed",
               labName=args.labName,
               conflictAction=args.conflictAction,
               requiresConfirmation=code == "labReplaceRequiresConfirmation" and true or nil,
               error=err
            })
         end
         local url,path=archiveTicketUrl(ctx,prepared.ticket)
         prepared.ticket=nil
         prepared.uploadUrl=url
         prepared.uploadPath=path
         prepared.method="POST"
         prepared.contentType="application/zip"
         return result("Lab import upload prepared. POST the raw ZIP body to the short-lived URL once.",runtimeInfo(appmgr,ctx),prepared,nil,{
            "Upload the ZIP directly to uploadUrl as application/zip before it expires.",
            "Do not encode or transfer the ZIP through MCP text."
         })
      end)

      mcp:tool("prepareLabTransfer", {
         description="Prepare one immutable lab ZIP snapshot for direct download by another LSP-Claw server. Returns a 60-second single-use capability; relay the descriptor only to importLabTransfer on the destination and never log the transfer ticket.",
         inputSchema=objectSchema({labName=stringSchema("Optional explicit lab override; otherwise use this session's selection.")}),
         annotations=readAnnotations
      }, function(args,ctx)
         local lab,resolveErr=resolveLab(appmgr,args,ctx)
         if not lab then return resolveErr end
         local prepared,err,code=archiveManager:prepareTransfer(lab)
         if not prepared then return labOperationError(lab,"prepare lab transfer",err,code,"prepareLabTransferFailed") end
         local url,path=transferServiceUrl(ctx)
         if not url then return FastMCP.error("Cannot determine the public transfer URL",{code="serverOriginUnavailable"}) end
         prepared.transferUrl=url
         prepared.transferPath=path
         prepared.sourceOrigin=requestOrigin(ctx)
         return result("Direct lab transfer prepared. Relay this descriptor immediately to the destination importLabTransfer tool.",runtimeInfo(appmgr,ctx,lab),prepared,nil,{
            "Call importLabTransfer on the destination server before expiresAt.",
            "Do not print, log, summarize, or retain transferTicket after the destination call."
         })
      end)

      mcp:tool("importLabTransfer", {
         description="Pull a prepared lab snapshot directly from another LSP-Claw server. Requires explicit confirmation of the exact source origin. Never forwards this server's MCP token and never follows redirects.",
         inputSchema=objectSchema({
            transferUrl={type="string",minLength=1,maxLength=2048,description="Exact transferUrl returned by the source prepareLabTransfer tool."},
            transferTicket={type="string",minLength=32,maxLength=32,description="Single-use transferTicket returned by the source; never log it."},
            expectedBytes={type="integer",minimum=1,description="Exact expectedBytes returned by the source."},
            digest={type="string",minLength=71,maxLength=71,description="Exact sha256 digest descriptor returned by the source."},
            destinationLabName=stringSchema("Destination lab name explicitly provided by the user."),
            conflictAction=enumSchema({"createNew","replace"},"Create a new lab or completely replace a stopped lab."),
            confirmed=boolSchema("True only after the user confirms the displayed source origin and any replacement.",false),
            confirmedSourceOrigin=stringSchema("Exact source origin shown in the confirmation request, for example http://device-1.")
         },{"transferUrl","transferTicket","expectedBytes","digest","destinationLabName","conflictAction"}),
         annotations=destructiveAnnotations
      }, function(args,ctx)
         local imported,err,code,sourceOrigin=archiveManager:importTransfer(args)
         if not imported then
            local nextActions
            if code == "transferSourceRequiresConfirmation" then
               nextActions={
                  "Show the user the exact source origin: "..tostring(sourceOrigin)..".",
                  "Ask the user to confirm this origin and the destination action.",
                  "Call importLabTransfer again with confirmed=true and confirmedSourceOrigin set to that exact origin."
               }
            end
            return FastMCP.error("Cannot import direct lab transfer",{
               code=code or "importLabTransferFailed",
               sourceOrigin=sourceOrigin,
               destinationLabName=args.destinationLabName,
               conflictAction=args.conflictAction,
               requiresConfirmation=code == "transferSourceRequiresConfirmation" and true or nil,
               error=err,
               nextActions=nextActions
            })
         end
         local lab=appmgr.getLab(imported.labName)
         if ctx and ctx.sessionState and lab then setSessionLabName(ctx,lab:name()) end
         return result("Lab transferred directly between LSP-Claw servers.",runtimeInfo(appmgr,ctx,lab),imported,nil,{
            "Discard the source transfer descriptor; its ticket has been consumed."
         })
      end)
   end

   mcp:tool("startLab", {
      description = "Start the lab app through appmgr.",
      inputSchema=objectSchema({labName=stringSchema("Optional explicit lab override; otherwise use this session's selection.")}),
      annotations = mutateAnnotations
   }, function(args, ctx)
      local lab,labErr=resolveLab(appmgr,args,ctx)
      if not lab then return labErr end
      local labIo, executeIoOrErr = ensureLab(lab)
      if not labIo then return executeIoOrErr end
      local runtime = runtimeInfo(appmgr,ctx,lab)
      local files = listLabFileNames(appmgr, labIo, false)
      local hasXlua = false
      for _, file in ipairs(files) do if endsWith(lower(file), ".xlua") then hasXlua = true end end
      local warnings = runtimeWarnings(runtime, { hasXlua = hasXlua })
      if lab:isRunning() then
	 local data = { started = false, alreadyRunning = true, labApp = labAppPaths(files,ctx,lab) }
	 return result("Lab is already running.", runtime, data, warnings, labOpenNextActions(infoIo))
      end
      local ok, err, operationCode = lab:start()
      runtime = runtimeInfo(appmgr,ctx,lab)
      if not ok then return labOperationError(lab,"start lab",err,operationCode,"startLabFailed") end
      local data = { started = true, labApp = labAppPaths(files,ctx,lab) }
      local nextActions = labOpenNextActions(infoIo)
      appendList(nextActions, labStartedExtraNextActions())
      return result("Lab started.", runtime, data, warnings, nextActions)
   end)

   mcp:tool("stopLab", {
      description = "Stop the lab app through appmgr.",
      inputSchema=objectSchema({labName=stringSchema("Optional explicit lab override; otherwise use this session's selection.")}),
      annotations = mutateAnnotations
   }, function(args, ctx)
      local lab,labErr=resolveLab(appmgr,args,ctx)
      if not lab then return labErr end
      local runtime, runtimeErr = runtimeInfo(appmgr,ctx,lab)
      if not runtime then return runtimeErr end
      if not lab:isRunning() then
	 return result("Lab is already stopped.", runtime, { stopped = false, alreadyStopped = true }, runtime.warnings)
      end
      local ok, err, operationCode = lab:stop()
      runtime = runtimeInfo(appmgr,ctx,lab)
      if not ok then return labOperationError(lab,"stop lab",err,operationCode,"stopLabFailed") end
      return result("Lab stopped.", runtime, { stopped = true }, runtime.warnings)
   end)

   mcp:tool("getExampleCatalog", {
      description = "Return the AI catalog from RealTimeLogic/LSP-Examples. The AI agent must choose examples from this data.",
      inputSchema = objectSchema({
	 path = stringSchema("Optional example path to return one catalog entry.", "")
      }),
      annotations = readAnnotations
   }, function(args)
      local catalog, catalogErr = loadExampleCatalog(ghio)
      if not catalog then
	 return FastMCP.error("Cannot read example catalog", {
	    code = "exampleCatalogUnavailable",
	    path = exampleCatalogPath,
	    error = catalogErr
	 })
      end
      local entries = catalogEntries(catalog) or {}
      if args.path and args.path ~= "" then
	 local path, pathErr = validatePath(args.path, true, "path")
	 if not path then return pathErr end
	 local entry = findCatalogEntry(catalog, path)
	 if not entry then
	    return FastMCP.error("Catalog entry was not found", {
	       code = "catalogEntryNotFound",
	       path = path
	    })
	 end
	 return result("Catalog entry returned.", nil, {
	    agentGuidance = { copyExampleToLab = exampleCopyGuidance(infoIo) },
	    catalogPath = exampleCatalogPath,
	    entry = catalogEntryForAgent(entry),
	    copyGuidance = exampleCopyGuidance(infoIo)
	 })
      end
      local out = {}
      for _, entry in ipairs(entries) do tinsert(out, catalogEntryForAgent(entry)) end
      return result("Example catalog returned.", nil, {
	 agentGuidance = { copyExampleToLab = exampleCopyGuidance(infoIo) },
	 catalogPath = exampleCatalogPath,
	 schemaVersion = catalog.schema_version,
	 generatedBy = catalog.generated_by,
	 declaredCount = catalog.catalog_count,
	 entries = out,
	 entryCount = #out,
	 copyGuidance = exampleCopyGuidance(infoIo)
      })
   end)

   mcp:tool("readExampleFile", {
      description = "Read one file from the GitHub examples repository.",
      inputSchema = objectSchema({
	 path = stringSchema("GitHub file path such as AJAX/README.md.")
      }, { "path" }),
      annotations = readAnnotations
   }, function(args)
      local path, pathErr = validatePath(args.path, true, "path")
      if not path then return pathErr end
      local st, err = ghio:stat(path)
      if not st then return FastMCP.error("Example file was not found", { code = "exampleFileNotFound", path = path, error = err }) end
      if st.isdir then return FastMCP.error("Path is a directory", { code = "examplePathIsDirectory", path = path }) end
      local text, readErr = readText(ghio, path)
      if not text then return FastMCP.error("Cannot read example file", { code = "readExampleFileFailed", path = path, error = readErr }) end
      return result("Example file read.", nil, { path = path, content = text, size = #text })
   end)

   mcp:tool("copyExampleToLab", {
      description = "Copy the contents of a caller-selected GitHub example source directory into the lab root. The selected sourcePath directory itself is stripped. If conflictAction is backupExisting, use only a backupName explicitly provided by the user; ask the user when it is missing and never invent one.",
      inputSchema = objectSchema({
	 sourcePath = stringSchema("GitHub directory whose contents are copied into the lab root. Use AJAX/www to put index.lsp at lab root; do not use AJAX unless the lab should contain a www directory."),
	 conflictAction = enumSchema({ "abort", "deleteExisting", "backupExisting" }, "What to do if the lab already contains files.", "abort"),
	 confirmed = boolSchema("True only after the user explicitly confirmed the conflict action.", false),
	 backupName = stringSchema("Backup name when conflictAction is backupExisting."),
	 labName = stringSchema("Optional explicit lab override; otherwise use this session's selection.")
      }, { "sourcePath" }),
      annotations = destructiveAnnotations
   }, function(args,ctx)
      local lab,resolveErr=resolveLab(appmgr,args,ctx)
      if not lab then return resolveErr end
      local sourcePath, sourceErr = validatePath(args.sourcePath,true,"sourcePath",lab:name())
      if not sourcePath then return sourceErr end
      local st, statErr = ghio:stat(sourcePath)
      if not st then return FastMCP.error("Example source path was not found", { code = "exampleSourceNotFound", labName=lab:name(), sourcePath = sourcePath, error = statErr }) end
      if not st.isdir then return FastMCP.error("Example source path must be a directory", { code = "exampleSourceNotDirectory", labName=lab:name(), sourcePath = sourcePath }) end
      local labIo, labErr = ensureLab(lab)
      if not labIo then return labErr end
      local runtime, runtimeErr = runtimeInfo(appmgr,ctx,lab)
      if not runtime then return runtimeErr end
      local conflictAction = args.conflictAction or "abort"
      local labHasEntries = labContainsEntries(labIo)
      if labHasEntries and args.confirmed ~= true then
	 return FastMCP.error("The lab already contains files. Ask the user whether to abort, delete existing files, or back up existing files before copying.", {
	    code = "labConflictRequiresConfirmation",
	    labName=lab:name(),
	    requiresConfirmation = true,
	    choices = { "abort", "deleteExisting", "backupExisting" },
	    nextActions = copyConflictNextActions()
	 })
      end
      if labHasEntries then
	 if conflictAction == "abort" then
	    return result("Copy aborted. Lab was not changed.", runtime, {
	       copied = false,
	       conflictAction = conflictAction,
	       sourcePath = sourcePath,
	       copySemantics = markdownText(".info/copyExampleToLabAbortedSemantics.md")
	    }, runtime.warnings)
	 elseif conflictAction == "deleteExisting" then
	    -- lab:copy2lab stages the source first, then replaces the lab.
	 elseif conflictAction == "backupExisting" then
	    local backupName, backupErr = validateBackupName(args.backupName,lab)
	    if not backupName then return backupErr end
	    local ok, err, backupCode = lab:backup(backupName,true)
	    if not ok then
	       if backupCode == "backupAlreadyExists" then return backupAlreadyExistsError(lab,backupName,err) end
	       return labOperationError(lab,"back up lab before copy",err,backupCode,"backupLabFailed")
	    end
	    args.backupName = backupName
	 else
	    return FastMCP.error("Invalid conflictAction", { code = "invalidConflictAction", labName=lab:name(), conflictAction = conflictAction })
	 end
      end
      local ok, err, operationCode = lab:copy2lab(ghio,sourcePath)
      if not ok then return labOperationError(lab,"copy example to lab",err,operationCode,"copyExampleFailed") end
      local copiedLabFiles = listLabFileNames(appmgr, labIo, false)
      return result("Example copied to lab.", runtime, {
	 copied = true,
	 sourcePath = sourcePath,
	 copySemantics = markdownText(".info/copyExampleToLabCopiedSemantics.md"),
	 copiedFiles = copiedLabFiles,
	 conflictAction = labHasEntries and conflictAction or "none",
	 backupName = args.backupName
      }, runtime.warnings, copyExampleToLabNextActions())
   end)

   mcp:tool("listLabFiles", {
      description = "List files in the local lab.",
      inputSchema = objectSchema({
	 recursive = boolSchema("Reserved; recursive listing is always used.", true),
	 includeDirectories = boolSchema("Include directory entries.", false),
	 labName = stringSchema("Optional explicit lab override; otherwise use this session's selection.")
      }),
      annotations = readAnnotations
   }, function(args,ctx)
      local lab,resolveErr=resolveLab(appmgr,args,ctx)
      if not lab then return resolveErr end
      local labIo, labErr = ensureLab(lab)
      if not labIo then return labErr end
      local runtime = runtimeInfo(appmgr,ctx,lab)
      local files, dirs = listLabFileNames(appmgr, labIo, args.includeDirectories == true)
      return result("Lab files listed.", runtime, {
	 recursive = true,
	 includeDirectories = args.includeDirectories == true,
	 files = files,
	 directories = dirs,
	 fileCount = #files,
	 directoryCount = #dirs
      }, runtime.warnings)
   end)

   mcp:tool("readLabFile", {
      description = "Read one file from the local lab.",
      inputSchema = objectSchema({
	 path = stringSchema("Lab file path."),
	 labName = stringSchema("Optional explicit lab override; otherwise use this session's selection.")
      }, { "path" }),
      annotations = readAnnotations
   }, function(args,ctx)
      local lab,resolveErr=resolveLab(appmgr,args,ctx)
      if not lab then return resolveErr end
      local path, pathErr = validatePath(args.path,true,"path",lab:name())
      if not path then return pathErr end
      local labIo, labErr = ensureLab(lab)
      if not labIo then return labErr end
      local st, err = labIo:stat(path)
      if not st then return FastMCP.error("Lab file was not found", { code = "labFileNotFound", labName=lab:name(), path = path, error = err }) end
      if st.isdir then return FastMCP.error("Path is a directory", { code = "labPathIsDirectory", labName=lab:name(), path = path }) end
      local text, readErr = readText(labIo, path)
      if not text then return FastMCP.error("Cannot read lab file", { code = "readLabFileFailed", labName=lab:name(), path = path, error = readErr }) end
      return result("Lab file read.",runtimeInfo(appmgr,ctx,lab),{path=path,content=text,size=#text})
   end)

   mcp:tool("writeLabFile", {
      description = "Create or replace one lab file, optionally activating .xlua when running under Xedge.",
      inputSchema = objectSchema({
	 path = stringSchema("Lab file path."),
	 content = stringSchema("File content."),
	 overwrite = boolSchema("Allow replacing an existing file.", false),
	 confirmed = boolSchema("True only after the user explicitly confirmed overwrite.", false),
	 activateXlua = boolSchema("For running Xedge labs, activate .xlua when possible.", false),
	 labName = stringSchema("Optional explicit lab override; otherwise use this session's selection.")
      }, { "path", "content" }),
      annotations = mutateAnnotations
   }, function(args,ctx)
      local lab,resolveErr=resolveLab(appmgr,args,ctx)
      if not lab then return resolveErr end
      local path, pathErr = validatePath(args.path,true,"path",lab:name())
      if not path then return pathErr end
      local labIo, executeIoOrErr = ensureLab(lab)
      if not labIo then return executeIoOrErr end
      local executeIo = executeIoOrErr
      local runtime = runtimeInfo(appmgr,ctx,lab)
      local st = labIo:stat(path)
      if st and st.isdir then return FastMCP.error("Cannot overwrite a directory", { code = "labPathIsDirectory", labName=lab:name(), path = path }) end
      if st and args.overwrite ~= true then
	 return FastMCP.error("Lab file exists and overwrite is false", { code = "overwriteRequired", labName=lab:name(), path = path })
      end
      if st and args.overwrite == true and args.confirmed ~= true then
	 return FastMCP.error("Overwriting an existing lab file requires confirmed = true after user confirmation", {
	    code = "overwriteRequiresConfirmation",
	    labName=lab:name(),
	    requiresConfirmation = true,
	    path = path
	 })
      end
      local warnings = runtimeWarnings(runtime, { hasXlua = endsWith(lower(path), ".xlua") })
      local targetIo, activatedXlua = labIo, false
      if args.activateXlua == true and endsWith(lower(path), ".xlua") and executeIo and lab:isRunning() then
	 targetIo, activatedXlua = executeIo, true
      elseif args.activateXlua == true then
	 local warning = markdownText(".info/runtimeWarningActivateXluaUnavailable.md")
	 if warning then tinsert(warnings, warning) end
      end
      local ok,err,operationCode=lab:exclusive("writeLabFile",function()
         local writeOk,writeErr=ensureParentDirs(targetIo,path)
         if not writeOk then return nil,writeErr end
         writeOk,writeErr=writeText(targetIo,path,tostring(args.content or ""))
         if writeOk then lab:touch() end
         return writeOk,writeErr
      end)
      if not ok then return labOperationError(lab,"write lab file",err,operationCode,"writeLabFileFailed") end
      return result("Lab file written.", runtime, {
	 path = path,
	 bytes = #(tostring(args.content or "")),
	 overwritten = st ~= nil,
	 activatedXlua = activatedXlua
      }, warnings)
   end)

   mcp:tool("clearLab", {
      description = "Clear all files in the resolved lab. Requires explicit confirmation.",
      inputSchema = objectSchema({
	 confirmed = boolSchema("Must be true after explicit user confirmation.", false),
	 labName = stringSchema("Optional explicit lab override; otherwise use this session's selection.")
      }),
      annotations = destructiveAnnotations
   }, function(args,ctx)
      local lab,resolveErr=resolveLab(appmgr,args,ctx)
      if not lab then return resolveErr end
      local runtime, runtimeErr = runtimeInfo(appmgr,ctx,lab)
      if not runtime then return runtimeErr end
      if args.confirmed ~= true then
	 return FastMCP.error("Clearing the lab requires confirmed = true after explicit user confirmation", {
	    code = "clearLabRequiresConfirmation",
	    labName=lab:name(),
	    requiresConfirmation = true,
	    choices = { "abort", "clearLab" }
	 })
      end
      local ok,err,operationCode=lab:rmlab()
      if not ok then return labOperationError(lab,"clear lab",err,operationCode,"clearLabFailed") end
      return result("Lab cleared.", runtime, { cleared = true }, runtime.warnings)
   end)

   mcp:tool("backupLab", {
      description = "Back up the lab using a name explicitly provided by the user. If the user did not provide a name, ask before calling this tool; never invent or infer one. Existing backups are never overwritten or merged. copy=false moves files out of the lab.",
      inputSchema = objectSchema({
	 backupName = stringSchema("Required name explicitly provided by the user under appmgr's lsplab-backup namespace. Never generate this value."),
	 copy = boolSchema("true copies and preserves lab files; false moves files out of the lab.", true),
	 labName = stringSchema("Optional explicit lab override; otherwise use this session's selection.")
      }, { "backupName" }),
      onInputError = function(validationErr,args,ctx)
         local selected=args and args.labName or sessionLabName(ctx)
         local lab=selected and appmgr.getLab(selected) or nil
         return mapBackupNameInputError(lab,validationErr)
      end,
      annotations = mutateAnnotations
   }, function(args,ctx)
      local lab,resolveErr=resolveLab(appmgr,args,ctx)
      if not lab then return resolveErr end
      local runtime, runtimeErr = runtimeInfo(appmgr,ctx,lab)
      if not runtime then return runtimeErr end
      local backupName, backupErr = validateBackupName(args.backupName,lab)
      if not backupName then return backupErr end
      local copy = args.copy ~= false
      local ok, err, backupCode = lab:backup(backupName,copy)
      if not ok then
         if backupCode == "backupAlreadyExists" then return backupAlreadyExistsError(lab,backupName,err) end
         return labOperationError(lab,"back up lab",err,backupCode,"backupLabFailed")
      end
      return result(copy and "Lab copied to backup." or "Lab moved to backup.", runtime, {
	 backupName = backupName,
	 copy = copy,
	 movedOutOfLab = not copy
      }, runtime.warnings)
   end)

   mcp:tool("listLabBackups", {
      description = "List available lab backup directories with numbered choices for restore selection.",
      inputSchema=objectSchema({labName=stringSchema("Optional explicit lab override; otherwise use this session's selection.")}),
      annotations = readAnnotations
   }, function(args,ctx)
      local lab,resolveErr=resolveLab(appmgr,args,ctx)
      if not lab then return resolveErr end
      local runtime, runtimeErr = runtimeInfo(appmgr,ctx,lab)
      if not runtime then return runtimeErr end
      local backups, err = lab:listBackups()
      if not backups then return FastMCP.error("Cannot list lab backups", { code = "listLabBackupsFailed", labName=lab:name(), error = err }) end
      local choices = numberedBackupChoices(backups)
      local nextActions = {}
      if #choices > 0 then
	 tinsert(nextActions, "Present these backups to the user as numbered options.")
	 tinsert(nextActions, "If the user says \"Select backup 1\", call restoreLab with the backupName from choice number 1 after confirmation.")
      else
	 tinsert(nextActions, "Tell the user no lab backups were found.")
      end
      return result("Lab backups listed.", runtime, {
	 backups = backups,
	 choices = choices,
	 backupCount = #backups
      }, runtime.warnings, nextActions)
   end)

   mcp:tool("restoreLab", {
      description = "Restore a named lab backup into the lab. Requires explicit confirmation.",
      inputSchema = objectSchema({
	 backupName = stringSchema("Backup directory name returned by listLabBackups."),
	 confirmed = boolSchema("Must be true after explicit user confirmation.", false),
	 labName = stringSchema("Optional explicit lab override; otherwise use this session's selection.")
      }, { "backupName" }),
      annotations = destructiveAnnotations
   }, function(args,ctx)
      local lab,resolveErr=resolveLab(appmgr,args,ctx)
      if not lab then return resolveErr end
      local runtime, runtimeErr = runtimeInfo(appmgr,ctx,lab)
      if not runtime then return runtimeErr end
      local backupName, backupErr = validateBackupName(args.backupName,lab)
      if not backupName then return backupErr end
      if args.confirmed ~= true then
	 local backups = lab:listBackups() or {}
	 return FastMCP.error("Restoring a lab backup replaces the current lab and requires confirmed = true after explicit user confirmation.", {
	    code = "restoreLabRequiresConfirmation",
	    labName=lab:name(),
	    requiresConfirmation = true,
	    backupName = backupName,
	    choices = numberedBackupChoices(backups),
	    nextActions = {
	       "Ask the user to confirm restoring backupName.",
	       "If the user selected a numbered backup, map the number to choices[number].backupName before calling restoreLab."
	    }
	 })
      end
      local ok, err, operationCode = lab:restore(backupName)
      if not ok then
	 if operationCode == "labBusy" then return labOperationError(lab,"restore lab",err,operationCode,"restoreLabFailed") end
	 local backups = lab:listBackups() or {}
	 return FastMCP.error("Cannot restore lab backup", {
	    code = "restoreLabFailed",
	    labName=lab:name(),
	    backupName = backupName,
	    error = err,
	    choices = numberedBackupChoices(backups),
	    nextActions = #backups > 0 and {
	       "Present the available backup choices to the user.",
	       "Ask the user to select a backup by number or exact backupName."
	    } or {
	       "Tell the user no matching backup was found."
	    }
	 })
      end
      local labIo, labErr = ensureLab(lab)
      if not labIo then return labErr end
      local files, dirs = listLabFileNames(appmgr, labIo, true)
      return result("Lab backup restored.", runtime, {
	 restored = true,
	 backupName = backupName,
	 files = files,
	 directories = dirs,
	 fileCount = #files,
	 directoryCount = #dirs
      }, runtime.warnings, {
	 "Use startLab to run the restored lab.",
	 "Use listLabFiles or readLabFile to inspect restored files."
      })
   end)
end

local function registerResources(mcp, ghio, info, appmgr, instructions, infoIo)
   mcp:resource("lspclaw://instructions", {
      name = "LSP-Claw Instructions",
      description = "Stable server instructions for agents using LSP-Claw.",
      mimeType = "text/markdown",
      annotations = readAnnotations
   }, function()
      return FastMCP.resourceContent{ text = instructions or "", mimeType = "text/markdown" }
   end)

   mcp:resource("lspclaw://runtime", {
      name = "LSP-Claw Runtime",
      description = "Current Mako/Xedge runtime details.",
      mimeType = "application/json",
      annotations = readAnnotations
   }, function(ctx)
      local runtime, err = runtimeInfo(appmgr, ctx)
      if not runtime then return err end
      return runtime
   end)

   mcp:resource("lspclaw://lab/status", {
      name = "LSP-Claw Lab Status",
      description = "Current lab status and file summary.",
      mimeType = "application/json",
      annotations = readAnnotations
   }, function(ctx)
      local lab,resolveErr=resolveLab(appmgr,{},ctx)
      if not lab then return resolveErr end
      local status, err = labStatusData(appmgr,lab,ctx)
      if not status then return err end
      return status
   end)

   mcp:resource("lspclaw://examples/root", {
      name = "LSP-Claw GitHub Example Root",
      description = "Root-level entries in RealTimeLogic/LSP-Examples plus catalog and copy guidance.",
      mimeType = "application/json",
      annotations = readAnnotations
   }, function()
      local items = {}
      local iter, iterErr = ghio:files("", true)
      if not iter then return FastMCP.error("Cannot list GitHub examples", { code = "githubListFailed", error = iterErr }) end
      for name, isdir, _, size in iter do
	 tinsert(items, { name = name, type = isdir and "dir" or "file", size = size })
      end
      local catalogEntriesOut = {}
      local catalog, catalogErr = loadExampleCatalog(ghio)
      for _, entry in ipairs(catalogEntries(catalog) or {}) do
	 tinsert(catalogEntriesOut, catalogEntryForAgent(entry))
      end
      return {
	 agentGuidance = { copyExampleToLab = exampleCopyGuidance(infoIo) },
	 items = items,
	 count = #items,
	 catalogEntries = catalogEntriesOut,
	 catalogEntryCount = #catalogEntriesOut,
	 copyGuidance = exampleCopyGuidance(infoIo),
	 catalog = {
	    path = exampleCatalogPath,
	    available = catalog ~= nil,
	    error = catalogErr
	 }
      }
   end)
end

local function registerPrompts(mcp, io)
   mcp:prompt("chooseExampleForUserGoal", {
      description = "Workflow for selecting a BAS/Mako/Xedge example for a user goal.",
      arguments = {
	 userGoal = { description = "The user's requested application goal.", required = false },
	 targetRuntime = { description = "auto, mako, xedge, or xedge32.", required = false }
      }
   }, function(args)
      return sfmt(rw.file(io, ".info/chooseExampleForUserGoal.md"),
	 tostring(args.userGoal or "unspecified"))
   end)

   mcp:prompt("buildFromExampleWorkflow", {
      description = "Workflow for copying an example, modifying lab files, and starting the lab.",
      arguments = {
	 examplePath = { description = "Selected GitHub example path.", required = false },
	 userGoal = { description = "User goal for modifications after copying.", required = false }
      }
   }, function(args)
      return sfmt(rw.file(io, ".info/buildFromExampleWorkflow.md"),
	 tostring(args.examplePath or "not selected"),
	 tostring(args.userGoal or "not specified"))
   end)

   mcp:prompt("makoXedgeRuntimeGuide", {
      description = "Explain Mako vs Xedge runtime behavior for LSP-Claw labs.",
      arguments = {}
   }, function()
      return rw.file(io, ".info/makoXedgeRuntimeGuide.md")
   end)
end

function M.register(mcp, ghio, info, appmgr, options)
   options = options or {}
   infoContentIo = options.io
   configurationStatusProvider = options.configurationStatus
   local runtimeTrace = setupRuntimeTrace(options.runtimeTrace, options.runtimeTraceBufferSize)
   registerTools(mcp, ghio, info, appmgr, runtimeTrace, options.io, options.archiveManager)
   registerResources(mcp, ghio, info, appmgr, options.instructions, options.io)
   registerPrompts(mcp, options.io)
   return mcp
end

return M
