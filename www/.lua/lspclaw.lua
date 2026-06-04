local FastMCP = require"fastmcp.engine"
local rw = require"rwfile"

local M = {}

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

local function startsWith(value, prefix)
   return prefix == "" or string.sub(value, 1, #prefix) == prefix
end

local function basename(path)
   return string.match(path, "([^/]+)$") or path
end

local function dirname(path)
   return string.match(path, "^(.*)/[^/]+$") or ""
end

local function githubRawUrl(path)
   return "https://raw.githubusercontent.com/RealTimeLogic/LSP-Examples/refs/heads/master/" .. path
end

local function stripExampleRoot(examplePath, filePath)
   if examplePath == "" then return filePath end
   if filePath == examplePath then return "" end
   return filePath:sub(#examplePath + 2)
end

local function labTargetFiles(examplePath, files)
   local out = {}
   for _, file in ipairs(files or {}) do
      local target = stripExampleRoot(examplePath, file)
      if target ~= "" then tinsert(out, target) end
   end
   return out
end

local function joinPath(path, name)
   if not path or path == "" then return name end
   if not name or name == "" then return path end
   return path .. "/" .. name
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

local function runtimeInfo(appmgr)
   local labIo, executeIoOrErr = ensureLab(appmgr)
   if not labIo then return nil, executeIoOrErr end
   local _, executeIo = labIo, executeIoOrErr
   local runtime = executeIo and "Xedge" or "Mako"
   local warnings = {}
   if xedge and not executeIo then
      tinsert(warnings, "Xedge is present, but this lab cannot auto-execute .xlua files through the current app manager.")
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
      tinsert(warnings, "Neither mako nor xedge global exists.")
   end
   return {
      runtime = runtime,
      canExecuteXlua = executeIo ~= nil,
      labRunning = appmgr.running(),
      poweredBy = poweredBy,
      guidance = executeIo and
	 "Xedge can store and auto-execute .xlua files when the lab is running." or
	 "Mako Server executes .preload and .lsp files. It can store .xlua files, but it does not auto-execute them.",
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

local function allRepoFiles(info)
   local files, err = info.files()
   if not files then
      return nil, FastMCP.error("Cannot list GitHub examples", { code = "githubListFailed", error = err })
   end
   return files
end

local copyList
local appRootFiles
local exampleIndexLoaded, exampleIndexCache, exampleIndexError = false, nil, nil

local function loadExampleIndex(ghio)
   if exampleIndexLoaded then return exampleIndexCache, exampleIndexError end
   exampleIndexLoaded = true
   local text, err = readText(ghio, ".ai/example-index.json")
   if not text then
      exampleIndexError = err or "not found"
      return nil, exampleIndexError
   end
   local ok, decoded = FastMCP.pcall(ba.json.decode, text)
   if not ok or type(decoded) ~= "table" then
      exampleIndexError = tostring(decoded or "invalid JSON")
      return nil, exampleIndexError
   end
   exampleIndexCache = decoded
   return exampleIndexCache
end

local function listText(list)
   local out = {}
   if type(list) == "table" then
      for _, value in ipairs(list) do out[#out + 1] = tostring(value) end
   end
   return table.concat(out, " ")
end

local function lowerListText(list)
   return lower(listText(list))
end

local function findIndexExample(index, examplePath)
   if type(index) ~= "table" or type(index.examples) ~= "table" then return nil end
   for _, example in ipairs(index.examples) do
      if example.examplePath == examplePath then return example end
   end
   return nil
end

local function indexedRuntimeNotes(example, targetRuntime)
   local notes = {}
   if type(example.runtime) == "table" then
      if type(example.runtime.notes) == "table" then
	 for _, note in ipairs(example.runtime.notes) do tinsert(notes, note) end
      end
      local rt = lower(targetRuntime or "auto")
      local status = example.runtime[rt]
      if rt ~= "auto" and status and status ~= "compatible" then
	 tinsert(notes, "Indexed runtime compatibility for " .. rt .. ": " .. tostring(status) .. ".")
      end
   end
   return notes
end

local function indexedCandidate(example, includeScore)
   local importantFiles = {}
   if type(example.appRoots) == "table" then
      for _, root in ipairs(example.appRoots) do
	 if type(root.importantFiles) == "table" then
	    for _, file in ipairs(root.importantFiles) do tinsert(importantFiles, file) end
	 end
      end
   end
   local out = {
      examplePath = example.examplePath,
      parentPath = dirname(example.examplePath or ""),
      title = example.title,
      summary = example.summary,
      tags = copyList(example.tags),
      goodFor = copyList(example.goodFor),
      notFor = copyList(example.notFor),
      readmePath = example.readme,
      readmeRawUrl = example.rawReadmeUrl or (example.readme and githubRawUrl(example.readme) or nil),
      appRoots = example.appRoots or {},
      runtime = example.runtime,
      importantFiles = importantFiles,
      source = ".ai/example-index.json"
   }
   if includeScore then
      out.score = example.score
      out.reasons = copyList(example.reasons)
      out.runtimeNotes = copyList(example.runtimeNotes)
   end
   return out
end

local function indexedAppRootCandidates(example, analysis)
   local out = {}
   if type(example) ~= "table" or type(example.appRoots) ~= "table" then return out end
   for _, root in ipairs(example.appRoots) do
      local appRootPath = root.appRootPath
      if type(appRootPath) == "string" and appRootPath ~= "" then
	 local sourceFiles = appRootFiles(appRootPath, analysis.files)
	 tinsert(out, {
	    appRootPath = appRootPath,
	    label = root.label or basename(appRootPath),
	    command = root.run,
	    source = ".ai/example-index.json",
	    confidence = "high",
	    summary = root.summary,
	    importantFiles = copyList(root.importantFiles),
	    omitFromCompactContext = copyList(root.omitFromCompactContext),
	    sourceFiles = sourceFiles,
	    labTargetFiles = labTargetFiles(appRootPath, sourceFiles),
	    fileCount = #sourceFiles
	 })
      end
   end
   table.sort(out, function(a, b) return a.appRootPath < b.appRootPath end)
   return out
end

local function indexedAppRoot(example, appRootPath)
   if type(example) ~= "table" or type(example.appRoots) ~= "table" then return nil end
   for _, root in ipairs(example.appRoots) do
      if root.appRootPath == appRootPath then return root end
   end
   return nil
end

local entryInPath

local function pathDepth(path)
   local depth = 0
   for _ in string.gmatch(path, "[^/]+") do depth = depth + 1 end
   return depth
end

local function markerForPath(path)
   local base = lower(basename(path))
   return {
      isReadme = startsWith(base, "readme"),
      isPreload = base == ".preload",
      isLsp = endsWith(base, ".lsp"),
      isLua = endsWith(base, ".lua"),
      isXlua = endsWith(base, ".xlua"),
      isIndexHtml = base == "index.html"
   }
end

local function isImportantFile(path)
   local marker = markerForPath(path)
   local base = lower(basename(path))
   return marker.isPreload or marker.isIndexHtml or marker.isReadme or marker.isLsp or
      marker.isLua or marker.isXlua or endsWith(base, ".js") or endsWith(base, ".css")
end

local function buildExampleIndex(files)
   local nodes, fileEntries = {}, {}
   local function node(path)
      local n = nodes[path]
      if not n then
	 n = {
	    examplePath = path,
	    parentPath = dirname(path),
	    depth = pathDepth(path),
	    score = 0,
	    reasons = {},
	    directFiles = {},
	    files = {},
	    importantFiles = {},
	    readmePath = nil,
	    readmeRawUrl = nil,
	    fileMarkers = {
	       hasPreload = false,
	       hasLsp = false,
	       hasLua = false,
	       hasXlua = false,
	       hasIndexHtml = false
	    }
	 }
	 nodes[path] = n
      end
      return n
   end
   for _, entry in ipairs(files) do
      if entry.type == "dir" then
	 node(entry.name)
      elseif entry.type == "file" then
	 local parent = dirname(entry.name)
	 if parent ~= "" then
	    local n = node(parent)
	    tinsert(n.directFiles, entry.name)
	    local marker = markerForPath(entry.name)
	    if marker.isReadme and not n.readmePath then
	       n.readmePath = entry.name
	       n.readmeRawUrl = githubRawUrl(entry.name)
	    end
	    if marker.isPreload then n.fileMarkers.hasPreload = true end
	    if marker.isLsp then n.fileMarkers.hasLsp = true end
	    if marker.isLua then n.fileMarkers.hasLua = true end
	    if marker.isXlua then n.fileMarkers.hasXlua = true end
	    if marker.isIndexHtml then n.fileMarkers.hasIndexHtml = true end
	 end
	 tinsert(fileEntries, entry.name)
      end
   end
   local candidates = {}
   for path, n in pairs(nodes) do
      local base = basename(path)
      local hidden = startsWith(base, ".") or path:find("/%.", 1) ~= nil
      local marker = n.fileMarkers
      local candidate = not hidden and (
	 n.depth == 1 or n.readmePath ~= nil or marker.hasPreload or marker.hasLsp or
	 marker.hasXlua or marker.hasIndexHtml
      )
      if candidate then
	 for _, file in ipairs(fileEntries) do
	    if entryInPath(file, path) then
	       tinsert(n.files, file)
	       if isImportantFile(file) then tinsert(n.importantFiles, file) end
	    end
	 end
	 n.fileCount = #n.files
	 n.nested = n.depth > 1
	 tinsert(candidates, n)
      end
   end
   table.sort(candidates, function(a, b) return a.examplePath < b.examplePath end)
   return candidates
end

copyList = function(list)
   local out = {}
   for _, value in ipairs(list or {}) do tinsert(out, value) end
   return out
end

local function copyMarkers(markers)
   return {
      hasPreload = markers and markers.hasPreload or false,
      hasLsp = markers and markers.hasLsp or false,
      hasLua = markers and markers.hasLua or false,
      hasXlua = markers and markers.hasXlua or false,
      hasIndexHtml = markers and markers.hasIndexHtml or false
   }
end

local function publicExampleCandidate(candidate, includeScore)
   local out = {
      examplePath = candidate.examplePath,
      parentPath = candidate.parentPath,
      nested = candidate.nested,
      depth = candidate.depth,
      fileCount = candidate.fileCount,
      files = copyList(candidate.files),
      importantFiles = copyList(candidate.importantFiles),
      readmePath = candidate.readmePath,
      readmeRawUrl = candidate.readmeRawUrl,
      fileMarkers = copyMarkers(candidate.fileMarkers)
   }
   if includeScore then
      out.score = candidate.score
      out.reasons = copyList(candidate.reasons)
      out.runtimeNotes = copyList(candidate.runtimeNotes)
   end
   return out
end

function entryInPath(entryName, path)
   if path == "" then return true end
   return entryName == path or startsWith(entryName, path .. "/")
end

local function pathIsDirInFiles(files, path)
   if path == "" then return true end
   for _, entry in ipairs(files or {}) do
      if entry.name == path and entry.type == "dir" then return true end
      if entryInPath(entry.name, path) and entry.name ~= path then return true end
   end
   return false
end

local function entriesUnderFiles(files, path)
   local out = {}
   for _, entry in ipairs(files or {}) do
      if entryInPath(entry.name, path) and entry.name ~= path then out[#out + 1] = entry end
   end
   return out
end

local function analyzeEntries(examplePath, entries)
   local analysis = {
      examplePath = examplePath,
      fileCount = 0,
      directoryCount = 0,
      files = {},
      directories = {},
      readmes = {},
      readmeRawUrls = {},
      entryPoints = {},
      extensions = {},
      hasPreload = false,
      hasLsp = false,
      hasLua = false,
      hasXlua = false,
      hasIndexHtml = false
   }
   for _, entry in ipairs(entries) do
      local name = entry.name
      local base = lower(basename(name))
      if entry.type == "dir" then
	 analysis.directoryCount = analysis.directoryCount + 1
	 tinsert(analysis.directories, name)
      else
	 analysis.fileCount = analysis.fileCount + 1
	 tinsert(analysis.files, name)
	 local ext = string.match(lower(name), "%.([%w_]+)$")
	 if ext then analysis.extensions[ext] = (analysis.extensions[ext] or 0) + 1 end
	 if base == ".preload" then analysis.hasPreload = true; tinsert(analysis.entryPoints, name) end
	 if endsWith(base, ".lsp") then analysis.hasLsp = true; tinsert(analysis.entryPoints, name) end
	 if endsWith(base, ".lua") then analysis.hasLua = true end
	 if endsWith(base, ".xlua") then analysis.hasXlua = true; tinsert(analysis.entryPoints, name) end
	 if base == "index.html" then analysis.hasIndexHtml = true; tinsert(analysis.entryPoints, name) end
	 if startsWith(base, "readme") then
	    tinsert(analysis.readmes, name)
	    tinsert(analysis.readmeRawUrls, githubRawUrl(name))
	 end
      end
   end
   return analysis
end

local function runtimeWarnings(runtime, analysis)
   local warnings = {}
   if runtime and runtime.warnings then
      for _, warning in ipairs(runtime.warnings) do tinsert(warnings, warning) end
   end
   if analysis and analysis.hasXlua and runtime and runtime.runtime == "Mako" then
      tinsert(warnings, "This example contains .xlua files. Mako can store them, but only Xedge auto-executes .xlua files.")
   end
   return warnings
end

local function cleanCommandToken(value)
   if not value then return nil end
   value = tostring(value):gsub("[`\"']", ""):gsub("^%s+", ""):gsub("%s+$", "")
   value = value:gsub("[,;%.%)]$", "")
   if value == "" or value:find("<", 1, true) or value:find(">", 1, true) then return nil end
   return value
end

local function normalizeReadmeCd(value)
   value = cleanCommandToken(value)
   if not value then return nil end
   value = value:gsub("\\", "/")
   value = value:gsub("^%./", "")
   value = value:gsub("^LSP%-Examples/", "")
   value = value:gsub("/+$", "")
   if value == "." then return "" end
   if value:find("..", 1, true) or value:match("^%a:") or value:sub(1, 1) == "/" then return nil end
   return value
end

appRootFiles = function(appRootPath, files)
   local out = {}
   for _, file in ipairs(files or {}) do
      if entryInPath(file, appRootPath) then tinsert(out, file) end
   end
   return out
end

local function directChildName(parent, child)
   if not startsWith(child, parent .. "/") then return nil end
   local rest = child:sub(#parent + 2)
   return rest:match("^([^/]+)$")
end

local function addAppRootCandidate(candidates, seen, dirMap, appRootPath, options)
   if not appRootPath or appRootPath == "" or seen[appRootPath] then return end
   if not dirMap[appRootPath] then return end
   seen[appRootPath] = true
   options = options or {}
   tinsert(candidates, {
      appRootPath = appRootPath,
      label = options.label or basename(appRootPath),
      command = options.command,
      source = options.source or "heuristic",
      confidence = options.confidence or "medium"
   })
end

local function detectAppRootCandidates(analysis)
   local candidates, seen = {}, {}
   local dirMap = { [analysis.examplePath] = true }
   for _, dir in ipairs(analysis.directories or {}) do dirMap[dir] = true end
   local function add(path, options) addAppRootCandidate(candidates, seen, dirMap, path, options) end

   if analysis.readmeText then
      for _, readme in ipairs(analysis.readmeText) do
	 local currentCd = dirname(readme.path)
	 for line in string.gmatch(readme.content or "", "[^\r\n]+") do
	    local cd = line:match("^%s*cd%s+([^%s`]+)") or line:match("`%s*cd%s+([^%s`]+)")
	    cd = normalizeReadmeCd(cd)
	    if cd then currentCd = cd end
	    for target in line:gmatch("mako%s+[^%r\n]*%-l::([^%s`]+)") do
	       local cleanTarget = cleanCommandToken(target)
	       if cleanTarget and not endsWith(lower(cleanTarget), ".zip") and not cleanTarget:find(":", 1, true) then
		  cleanTarget = cleanTarget:gsub("\\", "/"):gsub("^%./", ""):gsub("/+$", "")
		  local command = line:gsub("^%s+", ""):gsub("%s+$", "")
		  local path = joinPath(currentCd, cleanTarget)
		  if not dirMap[path] and dirMap[cleanTarget] then path = cleanTarget end
		  if dirMap[path] then
		     add(path, {
			label = basename(path),
			command = command,
			source = readme.path,
			confidence = "high"
		     })
		  end
	       end
	    end
	 end
      end
   end

   if #candidates == 0 then
      if analysis.hasPreload or analysis.hasLsp or analysis.hasXlua or analysis.hasIndexHtml then
	 add(analysis.examplePath, {
	    label = basename(analysis.examplePath),
	    source = "file markers",
	    confidence = "medium"
	 })
      end
      local children = {}
      for _, dir in ipairs(analysis.directories or {}) do
	 local child = directChildName(analysis.examplePath, dir)
	 if child then children[dir] = true end
      end
      for dir in pairs(children) do
	 local childFiles = appRootFiles(dir, analysis.files)
	 local childAnalysis = analyzeEntries(dir, {})
	 childAnalysis.files = childFiles
	 for _, file in ipairs(childFiles) do
	    local base = lower(basename(file))
	    if base == ".preload" then childAnalysis.hasPreload = true end
	    if endsWith(base, ".lsp") then childAnalysis.hasLsp = true end
	    if endsWith(base, ".xlua") then childAnalysis.hasXlua = true end
	    if base == "index.html" then childAnalysis.hasIndexHtml = true end
	 end
	 if childAnalysis.hasPreload or childAnalysis.hasLsp or childAnalysis.hasXlua or childAnalysis.hasIndexHtml then
	    add(dir, {
	       label = basename(dir),
	       source = "file markers",
	       confidence = "low"
	    })
	 end
      end
   end

   table.sort(candidates, function(a, b) return a.appRootPath < b.appRootPath end)
   for _, candidate in ipairs(candidates) do
      local files = appRootFiles(candidate.appRootPath, analysis.files)
      candidate.sourceFiles = files
      candidate.labTargetFiles = labTargetFiles(candidate.appRootPath, files)
      candidate.fileCount = #files
   end
   return candidates
end

local function inspectExampleData(ghio, info, appmgr, examplePath, includeReadme)
   local path, pathErr = validatePath(examplePath, true, "examplePath")
   if not path then return nil, pathErr end
   local files, filesErr = allRepoFiles(info)
   if not files then return nil, filesErr end
   if not pathIsDirInFiles(files, path) then
      return nil, FastMCP.error("Example path was not found", { code = "exampleNotFound", examplePath = path })
   end
   local entries = entriesUnderFiles(files, path)
   local analysis = analyzeEntries(path, entries)
   local runtime, runtimeErr = runtimeInfo(appmgr)
   if not runtime then return nil, runtimeErr end
   local index = loadExampleIndex(ghio)
   local indexed = findIndexExample(index, path)
   if indexed then
      analysis.indexMetadata = indexedCandidate(indexed, false)
   end
   analysis.runtimeCompatibility = {
      mako = analysis.hasXlua and "Stores .xlua files but does not auto-execute them." or "Compatible with Mako Server.",
      xedge = "Compatible with Xedge. .xlua files auto-execute only when the lab app is running."
   }
   if includeReadme ~= false then
      analysis.readmeText = {}
      for _, readmePath in ipairs(analysis.readmes) do
	 local text, truncated = readText(ghio, readmePath, 12000)
	 tinsert(analysis.readmeText, {
	    path = readmePath,
	    rawUrl = githubRawUrl(readmePath),
	    content = text or "",
	    truncated = truncated == true
	 })
      end
   end
   return analysis, runtime, runtimeWarnings(runtime, analysis)
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
      urlGuidance = "Paths are relative to the BAS/MCP server origin. Derive the full URL by combining the MCP server scheme, host, and port with the path. For example, / means http://localhost/ when localhost is the MCP server address."
   }
end

local function labOpenNextActions(labApp)
   return {
      "Open http://localhost/ to view the lab app, where localhost is the MCP server address. If the MCP server is remote, replace localhost with that host name or IP address.",
      "The returned labApp paths are relative to the MCP server origin; combine the MCP scheme/host/port with the relative path.",
      "After requesting a page, inspect trace notifications or call readRuntimeTrace to check for LSP/Lua errors."
   }
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

local function importantSource(path)
   local base = lower(basename(path))
   return base == ".preload" or base == "index.html" or startsWith(base, "readme") or
      endsWith(base, ".lsp") or endsWith(base, ".lua") or endsWith(base, ".xlua") or
      endsWith(base, ".js") or endsWith(base, ".css")
end

local function addUniquePath(out, seen, path)
   if type(path) == "string" and path ~= "" and not seen[path] then
      seen[path] = true
      tinsert(out, path)
   end
end

local function omitPatternMatches(pattern, path)
   if pattern == path then return true end
   if endsWith(pattern, "/*") then return startsWith(path, pattern:sub(1, #pattern - 1)) end
   if startsWith(pattern, "*") and endsWith(path, pattern:sub(2)) then return true end
   if endsWith(pattern, "*") and startsWith(path, pattern:sub(1, #pattern - 1)) then return true end
   return false
end

local function omitReason(path, omitList)
   for _, pattern in ipairs(omitList or {}) do
      pattern = tostring(pattern or "")
      if pattern ~= "" and omitPatternMatches(pattern, path) then
	 return "listed in omitFromCompactContext"
      end
   end
   return nil
end

local function isStyleFile(path)
   return endsWith(lower(basename(path)), ".css")
end

local function targetRuntimeNotes(targetRuntime, analysis, currentRuntime)
   targetRuntime = lower(targetRuntime or "auto")
   if targetRuntime == "" then targetRuntime = "auto" end
   local notes = {}
   if targetRuntime == "auto" then
      tinsert(notes, "Auto target uses the active lab runtime: " .. currentRuntime.runtime .. ".")
   elseif targetRuntime == "mako" and analysis.hasXlua then
      tinsert(notes, "Target is Mako, but this example contains .xlua files that Mako will not auto-execute.")
   elseif targetRuntime == "xedge" or targetRuntime == "xedge32" then
      tinsert(notes, "Target is Xedge. .xlua files auto-execute when the lab app is running.")
      if targetRuntime == "xedge32" then
	 tinsert(notes, "For Xedge32, review memory and platform APIs before expanding the example.")
      end
   end
   return notes
end

local function registerTools(mcp, ghio, info, appmgr, runtimeTrace)
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
      local nextActions = status.running and labOpenNextActions(status.labApp) or {
	 "Use startLab to run the lab app.",
	 "When the lab is running, combine the returned labApp relative paths with the MCP server origin to open the app."
      }
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
	 return result("Lab is already running.", runtime, data, warnings, labOpenNextActions(data.labApp))
      end
      local ok, err = appmgr.start()
      runtime = runtimeInfo(appmgr)
      if not ok then
	 return FastMCP.error("Cannot start lab", { code = "startLabFailed", error = err })
      end
      local data = { started = true, labApp = labAppPaths(files) }
      local nextActions = labOpenNextActions(data.labApp)
      tinsert(nextActions, "Use stopLab when finished.")
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

   mcp:tool("listExamples", {
      description = "List GitHub example directories and, optionally, files from RealTimeLogic/LSP-Examples.",
      inputSchema = objectSchema({
	 path = stringSchema("GitHub example path to list.", ""),
	 recursive = boolSchema("Use info.files() to list recursively.", false),
	 includeFiles = boolSchema("Include files in addition to directories.", false)
      }),
      annotations = readAnnotations
   }, function(args)
      local path, pathErr = validatePath(args.path or "", false, "path")
      if not path then return pathErr end
      local recursive = args.recursive == true
      local includeFiles = args.includeFiles == true
      local items = {}
      local repoFiles, errResult
      if recursive then
	 repoFiles, errResult = allRepoFiles(info)
	 if not repoFiles then return errResult end
	 for _, entry in ipairs(repoFiles) do
	    if entryInPath(entry.name, path) and (includeFiles or entry.type == "dir") then
	       tinsert(items, entry)
	    end
	 end
      else
	 if path ~= "" then
	    local st, err = ghio:stat(path)
	    if not st then return FastMCP.error("Example path was not found", { code = "exampleNotFound", path = path, error = err }) end
	    if not st.isdir then return FastMCP.error("Example path must be a directory", { code = "exampleNotDirectory", path = path }) end
	 end
	 local iter, iterErr = ghio:files(path, true)
	 if not iter then return FastMCP.error("Cannot list GitHub examples", { code = "githubListFailed", path = path, error = iterErr }) end
	 for name, isdir, _, size in iter do
	    if includeFiles or isdir then
	       tinsert(items, {
		  name = appmgr.filePath(path, name),
		  type = isdir and "dir" or "file",
		  size = size
	       })
	    end
	 end
      end
      local exampleCandidates = {}
      local index, indexErr = loadExampleIndex(ghio)
      if index and type(index.examples) == "table" then
	 for _, example in ipairs(index.examples) do
	    if entryInPath(example.examplePath, path) then
	       tinsert(exampleCandidates, indexedCandidate(example, false))
	    end
	 end
      else
	 if not repoFiles then
	    repoFiles, errResult = allRepoFiles(info)
	    if not repoFiles then return errResult end
	 end
	 for _, candidate in ipairs(buildExampleIndex(repoFiles)) do
	    if entryInPath(candidate.examplePath, path) then
	       tinsert(exampleCandidates, publicExampleCandidate(candidate, false))
	    end
	 end
      end
      return result("Examples listed.", nil, {
	 path = path,
	 recursive = recursive,
	 includeFiles = includeFiles,
	 items = items,
	 count = #items,
	 exampleCandidates = exampleCandidates,
	 exampleCandidateCount = #exampleCandidates,
	 exampleIndex = {
	    available = index ~= nil,
	    error = indexErr
	 }
      })
   end)

   mcp:tool("inspectExample", {
      description = "Inspect one GitHub example directory for entry points, file types, README text, and runtime warnings.",
      inputSchema = objectSchema({
	 examplePath = stringSchema("Example directory such as AJAX."),
	 includeReadme = boolSchema("Include README content.", true)
      }, { "examplePath" }),
      annotations = readAnnotations
   }, function(args)
      local analysis, runtime, warnings = inspectExampleData(ghio, info, appmgr, args.examplePath, args.includeReadme ~= false)
      if not analysis then return runtime end
      return result("Example inspected.", runtime, analysis, warnings, {
	 "Use planCopyExampleToLab before copying.",
	 "Use prepareExampleForAi for compact source context."
      })
   end)

   mcp:tool("suggestExamples", {
      description = "Score GitHub examples against a user goal using the repo AI index when available, falling back to repository paths and file markers.",
      inputSchema = objectSchema({
	 userGoal = stringSchema("User goal or feature request."),
	 targetRuntime = enumSchema({ "auto", "mako", "xedge", "xedge32" }, "Target runtime.", "auto"),
	 maxResults = { type = "integer", minimum = 1, maximum = 20, default = 5 }
      }, { "userGoal" }),
      annotations = readAnnotations
   }, function(args)
      local userGoal = tostring(args.userGoal or "")
      local targetRuntime = lower(args.targetRuntime or "auto")
      local maxResults = tonumber(args.maxResults) or 5
      if maxResults < 1 then maxResults = 1 elseif maxResults > 20 then maxResults = 20 end
      local runtime, runtimeErr = runtimeInfo(appmgr)
      if not runtime then return runtimeErr end
      local words = {}
      for word in string.gmatch(lower(userGoal), "[%w_%-]+") do
	 if #word >= 3 then words[#words + 1] = word end
      end
      local ranked = {}
      local index, indexErr = loadExampleIndex(ghio)
      if index and type(index.examples) == "table" then
	 for _, example in ipairs(index.examples) do
	    example.score = 0
	    example.reasons = {}
	    local text = lower(table.concat({
	       example.examplePath or "",
	       example.title or "",
	       example.summary or "",
	       listText(example.tags),
	       listText(example.goodFor)
	    }, " "))
	    local appRootText = {}
	    if type(example.appRoots) == "table" then
	       for _, root in ipairs(example.appRoots) do
		  tinsert(appRootText, root.appRootPath or "")
		  tinsert(appRootText, root.label or "")
		  tinsert(appRootText, root.summary or "")
	       end
	    end
	    text = text .. " " .. lower(table.concat(appRootText, " "))
	    local notForText = lowerListText(example.notFor)
	    local tagsText = " " .. lowerListText(example.tags) .. " "
	    for _, word in ipairs(words) do
	       local matched = false
	       if tagsText:find(" " .. word .. " ", 1, true) then
		  example.score = example.score + 5
		  matched = true
	       elseif text:find(word, 1, true) then
		  example.score = example.score + 2
		  matched = true
	       end
	       if notForText:find(word, 1, true) then
		  example.score = example.score - 4
		  tinsert(example.reasons, "notFor matched " .. word)
	       elseif matched then
		  tinsert(example.reasons, "matched " .. word)
	       end
	    end
	    if example.score == 0 and #words == 0 then example.score = 1 end
	    if type(example.runtime) == "table" then
	       local rtStatus = example.runtime[targetRuntime]
	       if targetRuntime ~= "auto" and rtStatus and rtStatus ~= "compatible" then
		  example.score = example.score - 3
		  tinsert(example.reasons, "runtime " .. targetRuntime .. " is " .. tostring(rtStatus))
	       end
	    end
	    if example.score > 0 then
	       example.runtimeNotes = indexedRuntimeNotes(example, targetRuntime)
	       tinsert(ranked, example)
	    end
	 end
      else
	 local files, errResult = allRepoFiles(info)
	 if not files then return errResult end
	 for _, candidate in ipairs(buildExampleIndex(files)) do
	    local pathText = lower(candidate.examplePath)
	    local importantText = lower(table.concat(candidate.importantFiles, " "))
	    local fileText = lower(table.concat(candidate.files, " "))
	    for _, word in ipairs(words) do
	       local matched = false
	       if pathText:find(word, 1, true) then
		  candidate.score = candidate.score + 3
		  matched = true
	       end
	       if importantText:find(word, 1, true) then
		  candidate.score = candidate.score + 2
		  matched = true
	       elseif fileText:find(word, 1, true) then
		  candidate.score = candidate.score + 1
		  matched = true
	       end
	       if matched then
		  tinsert(candidate.reasons, "matched " .. word)
	       end
	    end
	    if candidate.score == 0 and #words == 0 then candidate.score = 1 end
	    if candidate.nested and candidate.score > 0 then candidate.score = candidate.score + 1 end
	    if candidate.fileMarkers.hasXlua and targetRuntime == "mako" then
	       candidate.score = candidate.score - 2
	       tinsert(candidate.reasons, ".xlua is Xedge-only for auto execution")
	    elseif candidate.fileMarkers.hasXlua and (targetRuntime == "xedge" or targetRuntime == "xedge32") then
	       candidate.score = candidate.score + 2
	       tinsert(candidate.reasons, "contains .xlua for Xedge")
	    end
	    if candidate.score > 0 then
	       candidate.runtimeNotes = targetRuntimeNotes(targetRuntime, { hasXlua = candidate.fileMarkers.hasXlua }, runtime)
	       tinsert(ranked, candidate)
	    end
	 end
      end
      table.sort(ranked, function(a, b)
	 if a.score == b.score then return (a.examplePath or "") < (b.examplePath or "") end
	 return a.score > b.score
      end)
      local out = {}
      for i = 1, math.min(maxResults, #ranked) do
	 out[#out + 1] = index and indexedCandidate(ranked[i], true) or publicExampleCandidate(ranked[i], true)
      end
      return result("Examples suggested.", runtime, {
	 userGoal = userGoal,
	 targetRuntime = targetRuntime,
	 results = out,
	 exampleIndex = {
	    available = index ~= nil,
	    error = indexErr
	 }
      }, runtime.warnings, {
	 "Call inspectExample on likely matches.",
	 "Call planCopyExampleToLab before copying."
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
      return result("Example file read.", nil, { path = path, rawUrl = githubRawUrl(path), content = text, size = #text })
   end)

   mcp:tool("prepareExampleForAi", {
      description = "Return compact indexed README and important source context before copying an example.",
      inputSchema = objectSchema({
	 examplePath = stringSchema("Example directory such as AJAX."),
	 appRootPath = stringSchema("Optional BAS app root directory such as AJAX/www or Light-Dashboard/custom."),
	 targetRuntime = enumSchema({ "auto", "mako", "xedge", "xedge32" }, "Target runtime.", "auto"),
	 maxFiles = { type = "integer", minimum = 1, maximum = 30, default = 10 },
	 maxBytes = { type = "integer", minimum = 1000, maximum = 60000, default = 16000 },
	 includeStyles = boolSchema("Include CSS files even when the index marks them as omittable.", false)
      }, { "examplePath" }),
      annotations = readAnnotations
   }, function(args)
      local analysis, runtime, warnings = inspectExampleData(ghio, info, appmgr, args.examplePath, false)
      if not analysis then return runtime end
      local appRootPath
      if args.appRootPath and args.appRootPath ~= "" then
	 local appRootErr
	 appRootPath, appRootErr = validatePath(args.appRootPath, false, "appRootPath")
	 if appRootPath == nil then return appRootErr end
      end
      local maxFiles = tonumber(args.maxFiles) or 10
      if maxFiles < 1 then maxFiles = 1 elseif maxFiles > 30 then maxFiles = 30 end
      local maxBytes = tonumber(args.maxBytes) or 16000
      if maxBytes < 1000 then maxBytes = 1000 elseif maxBytes > 60000 then maxBytes = 60000 end
      local includeStyles = args.includeStyles == true
      local index, indexErr = loadExampleIndex(ghio)
      local indexed = findIndexExample(index, analysis.examplePath)
      local selectedRoot = indexed and appRootPath and indexedAppRoot(indexed, appRootPath) or nil
      if appRootPath and not selectedRoot and indexed then
	 return FastMCP.error("appRootPath was not found in the example index", {
	    code = "indexedAppRootNotFound",
	    examplePath = analysis.examplePath,
	    appRootPath = appRootPath
	 })
      end
      if not selectedRoot and indexed and type(indexed.appRoots) == "table" and #indexed.appRoots == 1 then
	 selectedRoot = indexed.appRoots[1]
	 appRootPath = selectedRoot.appRootPath
      end
      local pathList, seenPaths = {}, {}
      local omitList = {}
      if indexed then
	 addUniquePath(pathList, seenPaths, indexed.readme)
	 if selectedRoot then
	    omitList = selectedRoot.omitFromCompactContext or {}
	    for _, path in ipairs(selectedRoot.importantFiles or {}) do addUniquePath(pathList, seenPaths, path) end
	 elseif type(indexed.appRoots) == "table" then
	    for _, root in ipairs(indexed.appRoots) do
	       for _, path in ipairs(root.importantFiles or {}) do addUniquePath(pathList, seenPaths, path) end
	       for _, pattern in ipairs(root.omitFromCompactContext or {}) do tinsert(omitList, pattern) end
	    end
	 end
      end
      if #pathList == 0 then
	 for _, path in ipairs(analysis.files) do
	    if importantSource(path) then addUniquePath(pathList, seenPaths, path) end
	 end
      end
      local selected, total = {}, 0
      local omitted = {}
      for _, path in ipairs(pathList) do
	 if #selected >= maxFiles then
	    tinsert(omitted, { path = path, reason = "maxFiles reached" })
	 elseif not includeStyles and isStyleFile(path) then
	    tinsert(omitted, { path = path, reason = "style file omitted by default" })
	 else
	    local reason = omitReason(path, omitList)
	    if reason then
	       tinsert(omitted, { path = path, reason = reason })
	    elseif total < maxBytes then
	       local remaining = maxBytes - total
	       local text, truncated = readText(ghio, path, remaining)
	       if text then
		  total = total + #text
		  tinsert(selected, { path = path, rawUrl = githubRawUrl(path), content = text, truncated = truncated == true })
	       else
		  tinsert(omitted, { path = path, reason = "cannot read file" })
	       end
	    else
	       tinsert(omitted, { path = path, reason = "maxBytes reached" })
	    end
	 end
      end
      if not indexed and type(analysis.readmes) == "table" and #selected < maxFiles and total < maxBytes then
	 for _, path in ipairs(analysis.readmes) do
	    if not seenPaths[path] then
	       local remaining = maxBytes - total
	       local text, truncated = readText(ghio, path, remaining)
	       if text then
		  total = total + #text
		  tinsert(selected, { path = path, rawUrl = githubRawUrl(path), content = text, truncated = truncated == true })
	       end
	       seenPaths[path] = true
	    end
	 end
      end
      local notes = indexed and indexedRuntimeNotes(indexed, args.targetRuntime or "auto") or targetRuntimeNotes(args.targetRuntime or "auto", analysis, runtime)
      if not indexed and indexErr then
	 tinsert(warnings, "Example index unavailable; used legacy source selection: " .. tostring(indexErr))
      end
      for _, note in ipairs(notes) do tinsert(warnings, note) end
      return result("Example context prepared.", runtime, {
	 analysis = analysis,
	 selectedFiles = selected,
	 omittedFiles = omitted,
	 selectedFileCount = #selected,
	 selectedBytes = total,
	 selectedAppRootPath = appRootPath,
	 recommendedPlanCopyExampleToLab = { examplePath = analysis.examplePath },
	 recommendedCopyExampleToLab = appRootPath and {
	    examplePath = analysis.examplePath,
	    appRootPath = appRootPath
	 } or nil,
	 exampleIndex = {
	    available = index ~= nil,
	    used = indexed ~= nil,
	    error = indexErr
	 }
      }, warnings, {
	 "Call planCopyExampleToLab.",
	 "Ask the user before copying if the lab contains files."
      })
   end)

   mcp:tool("planCopyExampleToLab", {
      description = "Plan copying a GitHub example app root into the lab without writing.",
      inputSchema = objectSchema({
	 examplePath = stringSchema("Example directory such as AJAX.")
      }, { "examplePath" }),
      annotations = readAnnotations
   }, function(args)
      local analysis, runtime, warnings = inspectExampleData(ghio, info, appmgr, args.examplePath, false)
      if not analysis then return runtime end
      local index, indexErr = loadExampleIndex(ghio)
      local indexed = findIndexExample(index, analysis.examplePath)
      if not indexed then
	 analysis, runtime, warnings = inspectExampleData(ghio, info, appmgr, args.examplePath, true)
	 if not analysis then return runtime end
      end
      local appRootCandidates = indexed and indexedAppRootCandidates(indexed, analysis) or detectAppRootCandidates(analysis)
      if not indexed and indexErr then
	 tinsert(warnings, "Example index unavailable; used README/file-marker app root detection: " .. tostring(indexErr))
      end
      local labIo, labErr = ensureLab(appmgr)
      if not labIo then return labErr end
      local labFiles = listLabFileNames(appmgr, labIo, false)
      local hasFiles = #labFiles > 0
      local selected = #appRootCandidates == 1 and appRootCandidates[1] or nil
      local nextActions = {}
      if #appRootCandidates == 0 then
	 tinsert(nextActions, "No app root was detected. Ask the user for the BAS app directory to copy.")
      elseif #appRootCandidates > 1 then
	 tinsert(nextActions, "Ask the user which appRootPath variant to copy.")
      end
      tinsert(nextActions, hasFiles and
	 "Ask the user whether to abort, deleteExisting, or backupExisting before copying." or
	 "Call copyExampleToLab with the selected appRootPath.")
      return result("Copy plan returned. No lab files were changed.", runtime, {
	 examplePath = analysis.examplePath,
	 appRootCandidates = appRootCandidates,
	 appRootCandidateCount = #appRootCandidates,
	 requiresAppRootSelection = #appRootCandidates ~= 1,
	 selectedAppRootPath = selected and selected.appRootPath or nil,
	 sourceFilesToCopy = selected and selected.sourceFiles or {},
	 labTargetFiles = selected and selected.labTargetFiles or {},
	 fileCount = analysis.fileCount,
	 containsXlua = analysis.hasXlua,
	 labContainsFiles = hasFiles,
	 existingLabFiles = labFiles,
	 requiresConfirmation = hasFiles,
	 exampleIndex = {
	    available = index ~= nil,
	    used = indexed ~= nil,
	    error = indexErr
	 },
	 safeCopyExampleToLabArgs = selected and (hasFiles and {
	    examplePath = analysis.examplePath,
	    appRootPath = selected.appRootPath,
	    conflictAction = "backupExisting",
	    confirmed = true,
	    backupName = "before-" .. analysis.examplePath:gsub("[^%w_%-]+", "-") .. "-" .. tostring(os.time())
	 } or {
	    examplePath = analysis.examplePath,
	    appRootPath = selected.appRootPath,
	    conflictAction = "abort",
	    confirmed = false
	 }) or nil
      }, warnings, nextActions)
   end)

   mcp:tool("copyExampleToLab", {
      description = "Copy a selected GitHub app root directory into the local lab using appmgr.copy2lab.",
      inputSchema = objectSchema({
	 examplePath = stringSchema("Example directory such as AJAX."),
	 appRootPath = stringSchema("BAS app root directory to copy, such as AJAX/www or Light-Dashboard/htmx."),
	 conflictAction = enumSchema({ "abort", "deleteExisting", "backupExisting" }, "What to do if the lab already contains files.", "abort"),
	 confirmed = boolSchema("True only after the user explicitly confirmed the conflict action.", false),
	 backupName = stringSchema("Backup name when conflictAction is backupExisting.")
      }, { "examplePath", "appRootPath" }),
      annotations = destructiveAnnotations
   }, function(args)
      local appRootPath, appRootErr = validatePath(args.appRootPath, true, "appRootPath")
      if not appRootPath then return appRootErr end
      local analysis, runtime, warnings = inspectExampleData(ghio, info, appmgr, args.examplePath, true)
      if not analysis then return runtime end
      if appRootPath ~= analysis.examplePath and not startsWith(appRootPath, analysis.examplePath .. "/") then
	 return FastMCP.error("appRootPath must be the examplePath or a directory under examplePath", {
	    code = "appRootOutsideExample",
	    examplePath = analysis.examplePath,
	    appRootPath = appRootPath
	 })
      end
      local appRootKnown = appRootPath == analysis.examplePath
      if not appRootKnown then
	 for _, dir in ipairs(analysis.directories or {}) do
	    if dir == appRootPath then appRootKnown = true break end
	 end
      end
      if not appRootKnown then
	 return FastMCP.error("appRootPath was not found under examplePath", {
	    code = "appRootNotFound",
	    examplePath = analysis.examplePath,
	    appRootPath = appRootPath
	 })
      end
      local labIo, labErr = ensureLab(appmgr)
      if not labIo then return labErr end
      local conflictAction = args.conflictAction or "abort"
      local labHasEntries = labContainsEntries(labIo)
      if labHasEntries and args.confirmed ~= true then
	 return FastMCP.error("The lab already contains files. Ask the user whether to abort, delete existing files, or back up existing files before copying.", {
	    code = "labConflictRequiresConfirmation",
	    requiresConfirmation = true,
	    choices = { "abort", "deleteExisting", "backupExisting" },
	    nextActions = {
	       "Call planCopyExampleToLab.",
	       "Ask the user to choose a conflictAction.",
	       "Call copyExampleToLab with confirmed = true only after user confirmation."
	    }
	 })
      end
      if labHasEntries then
	 if conflictAction == "abort" then
	    return result("Copy aborted. Lab was not changed.", runtime, {
	       copied = false,
	       conflictAction = conflictAction,
	       examplePath = analysis.examplePath
	    }, warnings)
	 elseif conflictAction == "deleteExisting" then
	    local ok, err = appmgr.rmlab()
	    if not ok then return FastMCP.error("Cannot clear lab before copy", { code = "clearLabFailed", error = err }) end
	 elseif conflictAction == "backupExisting" then
	    local backupName, backupErr = validateBackupName(args.backupName)
	    if not backupName then return backupErr end
	    local ok, err = appmgr.backup(backupName, false)
	    if not ok then return FastMCP.error("Cannot back up lab before copy", { code = "backupLabFailed", backupName = backupName, error = err }) end
	    analysis.backupName = backupName
	 else
	    return FastMCP.error("Invalid conflictAction", { code = "invalidConflictAction", conflictAction = conflictAction })
	 end
      end
      local ok, err = appmgr.copy2lab(ghio, appRootPath)
      if not ok then return FastMCP.error("Cannot copy example to lab", { code = "copyExampleFailed", examplePath = analysis.examplePath, appRootPath = appRootPath, error = err }) end
      local sourceFiles = appRootFiles(appRootPath, analysis.files)
      local copiedLabFiles = labTargetFiles(appRootPath, sourceFiles)
      return result("Example copied to lab.", runtime, {
	 copied = true,
	 examplePath = analysis.examplePath,
	 appRootPath = appRootPath,
	 sourceFiles = sourceFiles,
	 copiedFiles = copiedLabFiles,
	 conflictAction = labHasEntries and conflictAction or "none",
	 backupName = analysis.backupName
      }, warnings, {
	 "Use listLabFiles or readLabFile to inspect the copied lab.",
	 "Use startLab to run it."
      })
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
	 tinsert(warnings, "activateXlua was requested, but .xlua activation is only available for running Xedge labs and .xlua files. The file was stored without activation.")
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

local function registerResources(mcp, ghio, info, appmgr, instructions)
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
      description = "Root-level entries in RealTimeLogic/LSP-Examples.",
      mimeType = "application/json",
      annotations = readAnnotations
   }, function()
      local items = {}
      local iter, iterErr = ghio:files("", true)
      if not iter then return FastMCP.error("Cannot list GitHub examples", { code = "githubListFailed", error = iterErr }) end
      for name, isdir, _, size in iter do
	 tinsert(items, { name = name, type = isdir and "dir" or "file", size = size })
      end
      local exampleCandidates = {}
      local index, indexErr = loadExampleIndex(ghio)
      if index and type(index.examples) == "table" then
	 for _, example in ipairs(index.examples) do
	    tinsert(exampleCandidates, indexedCandidate(example, false))
	 end
      else
	 local files, errResult = allRepoFiles(info)
	 if not files then return errResult end
	 for _, candidate in ipairs(buildExampleIndex(files)) do
	    tinsert(exampleCandidates, publicExampleCandidate(candidate, false))
	 end
      end
      return {
	 items = items,
	 count = #items,
	 exampleCandidates = exampleCandidates,
	 exampleCandidateCount = #exampleCandidates,
	 exampleIndex = {
	    available = index ~= nil,
	    error = indexErr
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
   local runtimeTrace = setupRuntimeTrace(options.runtimeTrace, options.runtimeTraceBufferSize)
   registerTools(mcp, ghio, info, appmgr, runtimeTrace)
   registerResources(mcp, ghio, info, appmgr, options.instructions)
   registerPrompts(mcp, options.io)
   return mcp
end

return M
