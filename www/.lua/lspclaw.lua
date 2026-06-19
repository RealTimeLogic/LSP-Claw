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
   return {
      ok = true,
      message = message,
      runtime = runtime,
      warnings = warnings or {},
      nextActions = nextActions or {},
      data = data or {}
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

local function validatePath(path, required, label)
   label = label or "path"
   if type(path) ~= "string" then
      return nil, FastMCP.error(label .. " must be a string", { code = "invalidPath" })
   end
   if path == "" then
      if required then
	 return nil, FastMCP.error(label .. " is required", { code = "invalidPath" })
      end
      return ""
   end
   if path:find("\\", 1, true) or path:find("..", 1, true) or path:match("^%a:") or path:sub(1, 1) == "/" then
      return nil, FastMCP.error(label .. " must be a safe relative BAS IO path", { code = "unsafePath", path = path })
   end
   return path:gsub("/+$", "")
end

local function validateBackupName(name)
   if name == nil or name == "" then return "backup-" .. tostring(os.time()) end
   if type(name) ~= "string" then
      return nil, FastMCP.error("backupName must be a string", { code = "invalidBackupName" })
   end
   if name:find("\\", 1, true) or name:find("/", 1, true) or name:find("..", 1, true) or name:match("^%a:") then
      return nil, FastMCP.error("backupName must be a safe backup directory name", { code = "unsafeBackupName", backupName = name })
   end
   return name
end

local function ensureLab(appmgr)
   local ok, err = appmgr.create()
   if not ok then
      return nil, FastMCP.error("Cannot create lab", { code = "createLabFailed", error = err })
   end
   local labIo, executeIo = appmgr.getLabIo()
   if not labIo then
      return nil, FastMCP.error("Lab IO is unavailable", { code = "labIoUnavailable" })
   end
   return labIo, executeIo
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

local function configurationStatus()
   local status = {}
   if type(configurationStatusProvider) == "function" then
      status = configurationStatusProvider() or {}
   end
   local setupPath = normalizedSetupPath(status.setupBaseUri)
   local githubTokenSet = status.githubTokenSet == true
   local mcpAuthTokenSet = status.mcpAuthTokenSet == true
   local warnings = {}
   if not githubTokenSet then
      tinsert(warnings, "No GitHub token is configured. Public GitHub access can still work, but requests are unauthenticated and may be rate limited.")
   end
   if not mcpAuthTokenSet then
      tinsert(warnings, "No MCP authentication token is configured. Any client that can reach this MCP endpoint can use the server.")
   end
   return {
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
	 urlTemplate = "http://<mcp-server-address>" .. setupPath,
	 guidance = "When LSP-Claw is already running, configure tokens from the browser setup page. Replace <mcp-server-address> with the host or IP address serving this MCP app."
      }
   }, warnings
end

local function runtimeInfo(appmgr)
   local labIo, executeIoOrErr = ensureLab(appmgr)
   if not labIo then return nil, executeIoOrErr end
   local _, executeIo = labIo, executeIoOrErr
   local runtime = executeIo and "Xedge" or "Mako"
   local warnings = {}
   if xedge and not executeIo then
      local warning = markdownText(".info/runtimeWarningXedgeNoExecuteIo.md")
      if warning then tinsert(warnings, warning) end
   end
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
   local configuration, configurationWarnings = configurationStatus()
   for _, warning in ipairs(configurationWarnings or {}) do
      tinsert(warnings, warning)
   end
   return {
      runtime = runtime,
      canExecuteXlua = executeIo ~= nil,
      labRunning = appmgr.running(),
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

local function labAppPaths(files)
   local has = {}
   for _, file in ipairs(files or {}) do has[file] = true end
   local entryPaths = { "/" }
   if has["index.lsp"] then tinsert(entryPaths, "/index.lsp") end
   if has["index.html"] then tinsert(entryPaths, "/index.html") end
   return {
      mountPath = "/",
      appPath = "/",
      entryPaths = entryPaths,
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

local function labStatusData(appmgr)
   local labIo, executeIoOrErr = ensureLab(appmgr)
   if not labIo then return nil, executeIoOrErr end
   local runtime, runtimeErr = runtimeInfo(appmgr)
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
      canExecuteXlua = runtime.canExecuteXlua,
      running = appmgr.running(),
      containsFiles = #files > 0,
      fileCount = #files,
      directoryCount = #dirs,
      topLevelEntries = top,
      files = files,
      directories = dirs,
      labApp = labAppPaths(files)
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

local function registerTools(mcp, ghio, info, appmgr, runtimeTrace, infoIo)
   mcp:tool("getRuntimeInfo", {
      description = "Return Mako/Xedge runtime details for the LSP-Claw lab.",
      inputSchema = objectSchema(),
      annotations = readAnnotations
   }, function()
      local runtime, err = runtimeInfo(appmgr)
      if not runtime then return err end
      return result("Runtime information returned.", runtime, nil, runtime.warnings)
   end)

   mcp:tool("readRuntimeTrace", {
      description = "Return buffered BAS trace output and clear the runtime trace buffer.",
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
	    cleared = true
	 })
      end
      local data = runtimeTrace.read()
      return result(data.trace ~= "" and "Runtime trace returned and cleared." or
	 "Runtime trace buffer was empty and cleared.", nil, data)
   end)

   mcp:tool("getLabStatus", {
      description = "Return lab runtime, running state, file counts, top-level entries, and file lists.",
      inputSchema = objectSchema(),
      annotations = readAnnotations
   }, function()
      local status, runtimeOrErr = labStatusData(appmgr)
      if not status then return runtimeOrErr end
      local nextActions = status.running and labOpenNextActions(infoIo) or labStoppedNextActions()
      return result("Lab status returned.", runtimeOrErr, status, runtimeOrErr.warnings, nextActions)
   end)

   mcp:tool("createLab", {
      description = "Create the local LSP-Claw lab storage if it does not already exist.",
      inputSchema = objectSchema(),
      annotations = mutateAnnotations
   }, function()
      local labIo, executeIoOrErr = ensureLab(appmgr)
      if not labIo then return executeIoOrErr end
      local runtime = runtimeInfo(appmgr)
      return result("Lab is ready.", runtime, { created = true }, runtime.warnings)
   end)

   mcp:tool("startLab", {
      description = "Start the lab app through appmgr.",
      inputSchema = objectSchema(),
      annotations = mutateAnnotations
   }, function()
      local labIo, executeIoOrErr = ensureLab(appmgr)
      if not labIo then return executeIoOrErr end
      local runtime = runtimeInfo(appmgr)
      local files = listLabFileNames(appmgr, labIo, false)
      local hasXlua = false
      for _, file in ipairs(files) do if endsWith(lower(file), ".xlua") then hasXlua = true end end
      local warnings = runtimeWarnings(runtime, { hasXlua = hasXlua })
      if appmgr.running() then
	 local data = { started = false, alreadyRunning = true, labApp = labAppPaths(files) }
	 return result("Lab is already running.", runtime, data, warnings, labOpenNextActions(infoIo))
      end
      local ok, err = appmgr.start()
      runtime = runtimeInfo(appmgr)
      if not ok then
	 return FastMCP.error("Cannot start lab", { code = "startLabFailed", error = err })
      end
      local data = { started = true, labApp = labAppPaths(files) }
      local nextActions = labOpenNextActions(infoIo)
      appendList(nextActions, labStartedExtraNextActions())
      return result("Lab started.", runtime, data, warnings, nextActions)
   end)

   mcp:tool("stopLab", {
      description = "Stop the lab app through appmgr.",
      inputSchema = objectSchema(),
      annotations = mutateAnnotations
   }, function()
      local runtime, runtimeErr = runtimeInfo(appmgr)
      if not runtime then return runtimeErr end
      if not appmgr.running() then
	 return result("Lab is already stopped.", runtime, { stopped = false, alreadyStopped = true }, runtime.warnings)
      end
      local ok, err = appmgr.stop()
      runtime = runtimeInfo(appmgr)
      if not ok then
	 return FastMCP.error("Cannot stop lab", { code = "stopLabFailed", error = err })
      end
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
      description = "Copy the contents of a caller-selected GitHub example source directory into the lab root. The selected sourcePath directory itself is stripped.",
      inputSchema = objectSchema({
	 sourcePath = stringSchema("GitHub directory whose contents are copied into the lab root. Use AJAX/www to put index.lsp at lab root; do not use AJAX unless the lab should contain a www directory."),
	 conflictAction = enumSchema({ "abort", "deleteExisting", "backupExisting" }, "What to do if the lab already contains files.", "abort"),
	 confirmed = boolSchema("True only after the user explicitly confirmed the conflict action.", false),
	 backupName = stringSchema("Backup name when conflictAction is backupExisting.")
      }, { "sourcePath" }),
      annotations = destructiveAnnotations
   }, function(args)
      local sourcePath, sourceErr = validatePath(args.sourcePath, true, "sourcePath")
      if not sourcePath then return sourceErr end
      local st, statErr = ghio:stat(sourcePath)
      if not st then return FastMCP.error("Example source path was not found", { code = "exampleSourceNotFound", sourcePath = sourcePath, error = statErr }) end
      if not st.isdir then return FastMCP.error("Example source path must be a directory", { code = "exampleSourceNotDirectory", sourcePath = sourcePath }) end
      local labIo, labErr = ensureLab(appmgr)
      if not labIo then return labErr end
      local runtime, runtimeErr = runtimeInfo(appmgr)
      if not runtime then return runtimeErr end
      local conflictAction = args.conflictAction or "abort"
      local labHasEntries = labContainsEntries(labIo)
      if labHasEntries and args.confirmed ~= true then
	 return FastMCP.error("The lab already contains files. Ask the user whether to abort, delete existing files, or back up existing files before copying.", {
	    code = "labConflictRequiresConfirmation",
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
	    -- appmgr.copy2lab stages the source first, then replaces the lab.
	 elseif conflictAction == "backupExisting" then
	    local backupName, backupErr = validateBackupName(args.backupName)
	    if not backupName then return backupErr end
	    local ok, err = appmgr.backup(backupName, true)
	    if not ok then return FastMCP.error("Cannot back up lab before copy", { code = "backupLabFailed", backupName = backupName, error = err }) end
	    args.backupName = backupName
	 else
	    return FastMCP.error("Invalid conflictAction", { code = "invalidConflictAction", conflictAction = conflictAction })
	 end
      end
      local ok, err = appmgr.copy2lab(ghio, sourcePath)
      if not ok then return FastMCP.error("Cannot copy example to lab", { code = "copyExampleFailed", sourcePath = sourcePath, error = err }) end
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
	 includeDirectories = boolSchema("Include directory entries.", false)
      }),
      annotations = readAnnotations
   }, function(args)
      local labIo, labErr = ensureLab(appmgr)
      if not labIo then return labErr end
      local runtime = runtimeInfo(appmgr)
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
	 path = stringSchema("Lab file path.")
      }, { "path" }),
      annotations = readAnnotations
   }, function(args)
      local path, pathErr = validatePath(args.path, true, "path")
      if not path then return pathErr end
      local labIo, labErr = ensureLab(appmgr)
      if not labIo then return labErr end
      local st, err = labIo:stat(path)
      if not st then return FastMCP.error("Lab file was not found", { code = "labFileNotFound", path = path, error = err }) end
      if st.isdir then return FastMCP.error("Path is a directory", { code = "labPathIsDirectory", path = path }) end
      local text, readErr = readText(labIo, path)
      if not text then return FastMCP.error("Cannot read lab file", { code = "readLabFileFailed", path = path, error = readErr }) end
      return result("Lab file read.", nil, { path = path, content = text, size = #text })
   end)

   mcp:tool("writeLabFile", {
      description = "Create or replace one lab file, optionally activating .xlua when running under Xedge.",
      inputSchema = objectSchema({
	 path = stringSchema("Lab file path."),
	 content = stringSchema("File content."),
	 overwrite = boolSchema("Allow replacing an existing file.", false),
	 confirmed = boolSchema("True only after the user explicitly confirmed overwrite.", false),
	 activateXlua = boolSchema("For running Xedge labs, activate .xlua when possible.", false)
      }, { "path", "content" }),
      annotations = mutateAnnotations
   }, function(args)
      local path, pathErr = validatePath(args.path, true, "path")
      if not path then return pathErr end
      local labIo, executeIoOrErr = ensureLab(appmgr)
      if not labIo then return executeIoOrErr end
      local executeIo = executeIoOrErr
      local runtime = runtimeInfo(appmgr)
      local st = labIo:stat(path)
      if st and st.isdir then return FastMCP.error("Cannot overwrite a directory", { code = "labPathIsDirectory", path = path }) end
      if st and args.overwrite ~= true then
	 return FastMCP.error("Lab file exists and overwrite is false", { code = "overwriteRequired", path = path })
      end
      if st and args.overwrite == true and args.confirmed ~= true then
	 return FastMCP.error("Overwriting an existing lab file requires confirmed = true after user confirmation", {
	    code = "overwriteRequiresConfirmation",
	    requiresConfirmation = true,
	    path = path
	 })
      end
      local warnings = runtimeWarnings(runtime, { hasXlua = endsWith(lower(path), ".xlua") })
      local targetIo, activatedXlua = labIo, false
      if args.activateXlua == true and endsWith(lower(path), ".xlua") and executeIo and appmgr.running() then
	 targetIo, activatedXlua = executeIo, true
      elseif args.activateXlua == true then
	 local warning = markdownText(".info/runtimeWarningActivateXluaUnavailable.md")
	 if warning then tinsert(warnings, warning) end
      end
      local ok, err = ensureParentDirs(targetIo, path)
      if not ok then return FastMCP.error("Cannot create parent directories", { code = "mkdirFailed", path = path, error = err }) end
      ok, err = writeText(targetIo, path, tostring(args.content or ""))
      if not ok then return FastMCP.error("Cannot write lab file", { code = "writeLabFileFailed", path = path, error = err }) end
      return result("Lab file written.", runtime, {
	 path = path,
	 bytes = #(tostring(args.content or "")),
	 overwritten = st ~= nil,
	 activatedXlua = activatedXlua
      }, warnings)
   end)

   mcp:tool("clearLab", {
      description = "Clear all lab files using appmgr.rmlab. Requires explicit confirmation.",
      inputSchema = objectSchema({
	 confirmed = boolSchema("Must be true after explicit user confirmation.", false)
      }),
      annotations = destructiveAnnotations
   }, function(args)
      local runtime, runtimeErr = runtimeInfo(appmgr)
      if not runtime then return runtimeErr end
      if args.confirmed ~= true then
	 return FastMCP.error("Clearing the lab requires confirmed = true after explicit user confirmation", {
	    code = "clearLabRequiresConfirmation",
	    requiresConfirmation = true,
	    choices = { "abort", "clearLab" }
	 })
      end
      local ok, err = appmgr.rmlab()
      if not ok then return FastMCP.error("Cannot clear lab", { code = "clearLabFailed", error = err }) end
      return result("Lab cleared.", runtime, { cleared = true }, runtime.warnings)
   end)

   mcp:tool("backupLab", {
      description = "Back up the lab using appmgr.backup. copy=false moves files out of the lab.",
      inputSchema = objectSchema({
	 backupName = stringSchema("Backup name under appmgr's lsplab-backup namespace."),
	 copy = boolSchema("true copies and preserves lab files; false moves files out of the lab.", true)
      }, { "backupName" }),
      annotations = mutateAnnotations
   }, function(args)
      local runtime, runtimeErr = runtimeInfo(appmgr)
      if not runtime then return runtimeErr end
      local backupName, backupErr = validateBackupName(args.backupName)
      if not backupName then return backupErr end
      local copy = args.copy ~= false
      local ok, err = appmgr.backup(backupName, copy)
      if not ok then return FastMCP.error("Cannot back up lab", { code = "backupLabFailed", backupName = backupName, error = err }) end
      return result(copy and "Lab copied to backup." or "Lab moved to backup.", runtime, {
	 backupName = backupName,
	 copy = copy,
	 movedOutOfLab = not copy
      }, runtime.warnings)
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
   }, function()
      local runtime, err = runtimeInfo(appmgr)
      if not runtime then return err end
      return runtime
   end)

   mcp:resource("lspclaw://lab/status", {
      name = "LSP-Claw Lab Status",
      description = "Current lab status and file summary.",
      mimeType = "application/json",
      annotations = readAnnotations
   }, function()
      local status, err = labStatusData(appmgr)
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
   registerTools(mcp, ghio, info, appmgr, runtimeTrace, options.io)
   registerResources(mcp, ghio, info, appmgr, options.instructions, options.io)
   registerPrompts(mcp, options.io)
   return mcp
end

return M
