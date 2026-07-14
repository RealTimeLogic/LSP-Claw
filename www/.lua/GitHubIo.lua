local mtime=1759270202
local json,sfind,sfmt = ba.json,string.find,string.format
local dirMeta={ mtime = mtime, size = 0, isdir = true }
local function strip(path) return path:gsub("^/",""):gsub("/+$","") end
local ua="BAS-LuaIo/1.4"

local function readAPI(buf)
   local offset = 0
   local function read(maxsize)
      if not maxsize or maxsize == "a" then
	 local out = buf:sub(offset + 1)
	 offset = #buf
	 return out
      end
      local to	= math.min(#buf, offset + maxsize)
      local out = buf:sub(offset + 1, to)
      offset = to
      return out
   end
   local function seek(off) if off < 0 or off > #buf then return nil end; offset = off; return true end
   return {
      read = read,
      write = function() return nil end,
      seek = seek,
      flush = function() return true end,
      close = function() return true end
   }
end


local function create(op)
   local mtime = "number" == type(op.mtime) and op.mtime or mtime
   assert(op and op.owner and op.repo, "owner/repo required")
   local log=op.log and ("function" == type(op.log) and
			 op.log or function(u,c,m) tracep(false,1,"GitHubIo:",u,c,m) end)
      or function() end
   local lockdir,fCache,hCache=op.lockdir or ".LOCK",{},nil
   local api	= op.api or "https://api.github.com"
   local branch = op.branch or "main"
   local base	= api .. "/repos/" .. op.owner .. "/" .. op.repo .. "/contents/"
   local repoBase = api .. "/repos/" .. op.owner .. "/" .. op.repo
   local tokenConfigured = op.token and op.token ~= "" and true or false
   local readTokenEnabled = tokenConfigured
   local archiveCacheIo = op.archiveCacheIo
   local archiveCachePath = op.archiveCachePath or "GitHubIo-Public-Read-Cache.zip"
   local publicArchiveEnabled = op.publicArchiveFallback == true and archiveCacheIo ~= nil
   local publicArchiveMode = publicArchiveEnabled and not tokenConfigured
   local archiveIo,archiveRoot

   ---------- HTTP helper (per-request client) --------

   local function hCreate()
      if hCache then
	 local httpc=hCache
	 hCache=nil
	 return httpc
      end
      return require("httpc").create()
   end

   local function hClose(httpc)
      httpc:close()
      if not hCache then hCache=httpc end
   end

   -- WebDAV meta data cache
   local function cachable(name)
      name=name:gsub("^/","")
      return 1 == sfind(name,lockdir,1,true) or sfind(name,".DAV",1,true) and true or false
   end

   local function urlFor(path)
      return base .. strip(path)
   end

   local function okStatus(code, okCodes)
      if not okCodes then return code == 200 end
      for _, okCode in ipairs(okCodes) do
	 if code == okCode then return true end
      end
      return false
   end

   local function headerValue(header, name)
      if not header then return nil end
      return header[name] or header[name:lower()] or header[name:upper()]
   end

   local function responseMeta(header, code)
      return {
	 status = code,
	 rateLimit = tonumber(headerValue(header, "x-ratelimit-limit")),
	 rateRemaining = tonumber(headerValue(header, "x-ratelimit-remaining")),
	 rateReset = tonumber(headerValue(header, "x-ratelimit-reset")),
	 etag = headerValue(header, "etag"),
	 location = headerValue(header, "location"),
	 contentType = headerValue(header, "content-type"),
      }
   end

   local function githubError(action, path, code, body, header)
      local message
      local ok, decoded = pcall(json.decode, body or "")
      if ok and type(decoded) == "table" then message = decoded.message end
      if not message or message == "" then message = tostring(body or ""):sub(1, 240) end
      local meta = responseMeta(header, code)
      local rate = ""
      if meta.rateRemaining ~= nil or meta.rateReset ~= nil then
	 rate = sfmt(" rateRemaining=%s rateReset=%s",
	    tostring(meta.rateRemaining), tostring(meta.rateReset))
      end
      return sfmt("%s %s: GitHub HTTP %s%s%s",
	 action, strip(path or ""), tostring(code), message ~= "" and ": " .. message or "", rate)
   end

   local function ghReq(method, url, hdr, bodyStr, query, okCodes)
      local function perform(useToken)
         local httpc = hCreate()
         local header = {
	    ["Accept"]	   = "application/vnd.github+json",
	    ["User-Agent"] = ua,
         }
         if useToken then header["Authorization"]="Bearer "..op.token end
         if hdr then for k,v in pairs(hdr) do header[k] = v end end
         if not useToken then header["Authorization"]=nil end
         local req = { url = url, method = method, header = header }
         if query then req.query = query end
         if bodyStr then req.size = #bodyStr end
         local ok, err = httpc:request(req)
         if not ok then hClose(httpc); return nil, err end
         if bodyStr then
	    ok,err=httpc:write(bodyStr)
	    if not ok then hClose(httpc); return nil, err end
         end
         local body = httpc:read("a") or ""
         local code = httpc:status()
         local responseHeader=httpc:header()
         hClose(httpc)
         return code,body,responseHeader
      end

      local useToken=tokenConfigured and (method ~= "GET" or readTokenEnabled) and true or false
      local responseUsedToken=useToken
      local code,body,header=perform(useToken)
      if not code then return nil,body end
      if method == "GET" and code == 401 and useToken then
         readTokenEnabled=false
         publicArchiveMode=publicArchiveEnabled
         log(url,code,"GitHub token rejected; retrying public read without authentication")
         code,body,header=perform(false)
         responseUsedToken=false
         if not code then return nil,body end
      end
      if method == "GET" and code == 403 and not responseUsedToken and publicArchiveEnabled then
	 local meta=responseMeta(header,code)
	 local message=string.lower(body or "")
	 if meta.rateRemaining == 0 or sfind(message,"rate limit",1,true) then
	    publicArchiveMode=true
	 end
      end
      if not okStatus(code, okCodes) then
	 local parsed
	 pcall(function() parsed=json.decode(body) end)
	 log(url,code,parsed and parsed.message or "")
      end
      return code, body, header
   end

   local function ensurePublicArchive()
      if archiveIo then return true end
      if not publicArchiveEnabled then return nil,"public archive fallback is not configured" end
      local url=op.archiveUrl or
	 ("https://codeload.github.com/%s/%s/zip/refs/heads/%s"):format(op.owner,op.repo,branch)
      local httpc=hCreate()
      local ok,err=httpc:request{
	 url=url,
	 method="GET",
	 header={
	    ["Accept"]="application/zip",
	    ["User-Agent"]=ua,
	 }
      }
      if not ok then hClose(httpc); return nil,err or "archive request failed" end
      local body=httpc:read("a") or ""
      local code=httpc:status()
      hClose(httpc)
      if code ~= 200 then return nil,"public archive HTTP "..tostring(code) end

      local fp
      fp,err=archiveCacheIo:open(archiveCachePath,"w")
      if not fp then return nil,"cannot create public archive cache: "..tostring(err or "?") end
      ok,err=fp:write(body)
      local closeOk,closeErr=fp:close()
      if not ok then return nil,"cannot write public archive cache: "..tostring(err or "?") end
      if closeOk == nil and closeErr then return nil,"cannot close public archive cache: "..tostring(closeErr) end

      local zio
      zio,err=ba.mkio(archiveCacheIo,archiveCachePath)
      if not zio then return nil,"cannot open public archive cache: "..tostring(err or "?") end
      local root
      for name,isdir in zio:files("",true) do
	 if isdir then root=name break end
      end
      if not root then
	 if zio.close then zio:close() end
	 return nil,"public archive has no repository root"
      end
      archiveIo,archiveRoot=zio,root
      log(url,code,"using public repository ZIP fallback")
      return true
   end

   local function archivePath(name)
      name=strip(name)
      return name == "" and archiveRoot or archiveRoot.."/"..name
   end

   local function archiveGetMeta(name)
      local ok,err=ensurePublicArchive()
      if not ok then return nil,err end
      local full=archivePath(name)
      local st=archiveIo:stat(full)
      if not st then return nil,"enoent" end
      if not st.isdir then
	 return {type="file",size=tonumber(st.size or 0),archive=true}
      end
      local list={archive=true}
      for child,isdir in archiveIo:files(full,true) do
	 if child ~= ".keep" then
	    local childPath=full.."/"..child
	    local childStat=archiveIo:stat(childPath)
	    list[#list+1]={
	       name=child,
	       path=(strip(name) == "" and child or strip(name).."/"..child),
	       type=isdir and "dir" or "file",
	       size=childStat and tonumber(childStat.size or 0) or 0,
	       archive=true,
	    }
	 end
      end
      return list
   end

   local function archiveOpen(name)
      local ok,err=ensurePublicArchive()
      if not ok then return nil,err end
      local fp
      fp,err=archiveIo:open(archivePath(name),"r")
      if not fp then return nil,err or "enoent" end
      local body
      body,err=fp:read("a")
      fp:close()
      if body == nil then return nil,err or "noaccess" end
      return readAPI(body)
   end

   -- Raw-by-path (respects branch/path protections)
   local function ghGetRawByPath(path, ref)
      local status,body,header=ghReq("GET",urlFor(path),{
	 ["Accept"]="application/vnd.github.raw+json"
      },nil,ref and {ref=ref} or nil)
      if not status then return nil,body or "noaccess" end
      return (status == 200) and body or nil, githubError("read raw", path, status, body, header)
   end

   -- Raw-by-blob SHA (great for large files too)
   local function ghGetBlobRaw(sha, path)
      local status,body,header=ghReq("GET",
	 api.."/repos/"..op.owner.."/"..op.repo.."/git/blobs/"..sha,
	 {["Accept"]="application/vnd.github.raw+json"})
      if not status then return nil,body or "noaccess" end
      return (status == 200) and body or nil, githubError("read blob", path or sha, status, body, header)
   end

   -- -------- GitHub Contents helpers --------
   local function ghGetMeta(path, ref, allowArchive)
      if allowArchive and publicArchiveMode then return archiveGetMeta(path) end
      local code, body, header = ghReq("GET", urlFor(path), nil, nil, ref and { ref = ref } or nil)
      if code == 200 then
	 return json.decode(body)
      elseif code == 404 then
	 return nil, "enoent"
      else
	 if allowArchive and publicArchiveMode then
	    local node,archiveErr=archiveGetMeta(path)
	    if node then return node end
	    return nil,githubError("metadata",path,code,body,header).."; public archive fallback failed: "..tostring(archiveErr)
	 end
	 return nil, githubError("metadata", path, code, body, header)
      end
   end

   local function ghPutFile(path, b64content, message, sha)
      local payload = {
	 message = message,
	 content = b64content,
	 branch	 = branch,
      }
      if sha then payload.sha = sha end
      local code, body = ghReq(
	 "PUT", urlFor(path),
	 { ["Content-Type"] = "application/json" },
	 json.encode(payload)
      )
      if code == 200 or code == 201 then
	 return json.decode(body)
      elseif code == 409 then
	 return nil, "exist"
      else
	 return nil, "noaccess"
      end
   end

   local function ghDeleteNode(path, sha, message)
      local payload = { message = message, sha = sha, branch = branch }
      local code,err = ghReq(
	 "DELETE", urlFor(path),
	 { ["Content-Type"] = "application/json" },
	 json.encode(payload)
      )
      if code == 200 then
	 return true
      elseif code == 404 then
	 return nil, "enoent"
      else
	 return nil, "noaccess"
      end
   end

   -- Directory detection
   local function isArray(t)
      return type(t) == "table" and t[1] ~= nil and t.type == nil
   end

   -- -------- LuaIo callbacks --------
   local function stat(name)
      name=strip(name)
      if name==lockdir then return dirMeta end
      local m=fCache[name]
      if m then return m end
      local node, err = ghGetMeta(name, branch, true)
      if not node then return nil, err end
      if node.type == "file" then return { mtime = mtime, size = node.size, isdir = false } end
      return dirMeta
   end

   local function ioFiles(name)
      local list, err = ghGetMeta(name, branch, true)
      if not list then return nil, err end
      if list.type == "file" then return nil, "noaccess" end
      local i = 0
      local function it_read()
	 i = i + 1
	 if i <= #list and list[i].name == ".keep" then i = i + 1 end
	 return i <= #list
      end
      local function it_name() return list[i] and list[i].name or nil end
      local function it_stat()
	 local n = list[i]
	 if not n then return nil end
	 return { mtime = mtime, size = tonumber(n.size or 0), isdir = (n.type == "dir") }
      end
      return { read = it_read, name = it_name, stat = it_stat }
   end

   local function treeType(githubType)
      if githubType == "tree" then return "dir" end
      if githubType == "blob" then return "file" end
      if githubType == "commit" then return "submodule" end
      return githubType
   end

   local function apiJson(method, path, hdr, payload, query, okCodes)
      local code, body, header = ghReq(
	 method,
	 repoBase .. path,
	 hdr,
	 payload and json.encode(payload) or nil,
	 query,
	 okCodes or {200}
      )
      if not code then return nil, body end
      local meta = responseMeta(header, code)
      if not okStatus(code, okCodes or {200}) then return nil, "Err:" .. tostring(body), meta end
      return body ~= "" and json.decode(body) or nil, nil, meta, body
   end

   local function normalizeCommit(c)
      if not c then return nil end
      local commit = c.commit or {}
      return {
	 sha = c.sha,
	 nodeId = c.node_id,
	 htmlUrl = c.html_url,
	 message = commit.message,
	 author = commit.author and {
	    name = commit.author.name,
	    email = commit.author.email,
	    date = commit.author.date,
	 } or nil,
	 committer = commit.committer and {
	    name = commit.committer.name,
	    email = commit.committer.email,
	    date = commit.committer.date,
	 } or nil,
      }
   end

   local function normalizeRef(ref)
      if not ref then return nil end
      return {
	 ref = ref.ref,
	 type = ref.object and ref.object.type or nil,
	 sha = ref.object and ref.object.sha or nil,
	 url = ref.object and ref.object.url or nil,
      }
   end

   local function paged(path, opts)
      opts = opts or {}
      local perPage = opts.per_page or opts.perPage or 100
      local maxPages = opts.max_pages or opts.maxPages or 10
      local out = {}
      for page = 1, maxPages do
	 local query = { per_page = perPage, page = page }
	 for k, v in pairs(opts) do
	    if k ~= "per_page" and k ~= "perPage" and k ~= "max_pages" and k ~= "maxPages" then
	       query[k] = v
	    end
	 end
	 local decoded, err, meta = apiJson("GET", path, nil, nil, query)
	 if not decoded then return nil, err, meta end
	 for _, item in ipairs(decoded) do out[#out + 1] = item end
	 if #decoded < perPage then return out, nil, meta end
      end
      return out, nil, { truncated = true, maxPages = maxPages }
   end

   local function mkdir(name)
      name=strip(name)
      if cachable(name) then return true end
      local keepPath = strip(name) .. "/.keep"
      local ok, err = ghPutFile(
	 keepPath,
	 ba.b64encode(""),
	 ("ci: mkdir %s"):format(name)
      )
      return ok and true or nil, err
   end

   local function deletePath(path)
      local node, err = ghGetMeta(path, branch, false)
      if not node then return nil, err end

      if node.type == "file" then
	 return ghDeleteNode(path, node.sha, ("ci: delete %s"):format(path))
      end
      local code, body = ghReq("GET", urlFor(path), nil, nil, { ref = branch })
      if code ~= 200 then return nil, "noaccess" end
      for _, entry in ipairs(node) do
	 local p = strip(path) .. "/" .. entry.name
	 local ok2, e2 = deletePath(p)
	 if not ok2 then return nil, e2 end
      end
      return true
   end

   local function rmdir(name)
      local ok, err = deletePath(name)
      if ok then return true end
      if err == "enoent" then return nil, "enoent" end
      return nil, err
   end

   local function remove(name)
      name=strip(name)
      if fCache[name] then
	 fCache[name]=nil
	 return true
      end
      local node, err = ghGetMeta(name, branch, false)
      if not node then return nil, err end
      if node.type ~= "file" then return nil, "invalidname" end
      return ghDeleteNode(name, node.sha, ("ci: delete %s"):format(name))
   end

   local function open(name, mode)
      name=strip(name)
      mode = mode or "r"
      if mode == "r" then
	 local m=fCache[name]
	 if m then return readAPI(m.payload) end
	 if publicArchiveMode then return archiveOpen(name) end
	 local node,nodeErr=ghGetMeta(name,branch,true)
	 if not node then return nil, nodeErr or "enoent" end
	 if node.type ~= "file" then return nil, "enoent" end
	 if publicArchiveMode or node.archive then return archiveOpen(name) end
	 local content, contentErr = ghGetRawByPath(name, branch)
	 if not content then
	    content, contentErr = ghGetBlobRaw(node.sha, name)
	    if not content then return nil, contentErr or "noaccess" end
	 end
	 return readAPI(content)
      elseif mode == "w" then
	 local node,nodeErr=ghGetMeta(name,branch,false)
	 if cachable(name) then
	    local t={}
	    return {
	       read = function() return nil end,
	       write = function(buf) table.insert(t,buf) return true end,
	       seek = function() return nil, "noaccess" end,
	       flush = function() return true end,
	       close = function()
		  t={payload=table.concat(t),isdir=false,mtime=mtime}
		  t.size=#t.payload
		  fCache[name]=t
		  return true
	       end
	    }
	 end
	 if not node and nodeErr ~= "enoent" then return nil,nodeErr end
	 local currentSha = node and node.sha or nil
	 local writeBuf = {}
	 local function write(data) writeBuf[#writeBuf+1] = data return true end
	 local function doUpload()
	    local b64 = ba.b64encode(table.concat(writeBuf))
	    local ok, err = ghPutFile(
	       name, b64,
	       currentSha and ("ci: update %s"):format(name) or ("ci: create %s"):format(name),
	       currentSha
	    )
	    if not ok then return nil, err end
	    currentSha = ok.content and ok.content.sha or currentSha
	    return true
	 end
	 return {
	    read = function() return nil end,
	    write = write,
	    seek = function() return nil, "noaccess" end,
	    flush = function() return true end,
	    close = function() return doUpload() end
	 }
      else
	 return nil, "invalidname"
      end
   end

   local function files(opts)
      opts = opts or {}
      local ref = opts.ref or opts.branch or branch
      local code, body, header = ghReq("GET", repoBase .. "/git/trees/" .. ref, nil, nil, {recursive=1})
      local meta = responseMeta(header, code)
      if code ~= 200 then return nil,"Err:"..tostring(body), meta end
      local decoded = json.decode(body)
      if type(decoded) ~= "table" or type(decoded.tree) ~= "table" then
	 return nil, "invalidresponse"
      end
      local list = {}
      for _, entry in ipairs(decoded.tree) do
	 local name = strip(entry.path or "")
	 if name ~= "" and name ~= ".keep" and not name:find("/.keep$", 1, true) then
	    list[#list + 1] = {
	       name = name,
	       type = treeType(entry.type),
	       githubType = entry.type,
	       mode = entry.mode,
	       sha = entry.sha,
	       size = entry.size,
	    }
	 end
      end
      list.sha = decoded.sha
      list.truncated = decoded.truncated and true or false
      list.rateLimit = meta.rateLimit
      list.rateRemaining = meta.rateRemaining
      list.rateReset = meta.rateReset
      return list
   end

   local function commits(path, opts)
      opts = opts or {}
      local query = {
	 sha = opts.sha or opts.ref or opts.branch or branch,
	 path = path and strip(path) ~= "" and strip(path) or nil,
	 since = opts.since,
	 ["until"] = opts["until"],
	 author = opts.author,
	 committer = opts.committer,
	 perPage = opts.perPage or opts.per_page,
	 maxPages = opts.maxPages or opts.max_pages,
      }
      local list, err, meta = paged("/commits", query)
      if not list then return nil, err, meta end
      local out = {}
      for _, c in ipairs(list) do out[#out + 1] = normalizeCommit(c) end
      return out, nil, meta
   end

   local function lastModified(path, opts)
      opts = opts or {}
      opts.perPage = 1
      opts.maxPages = 1
      local list, err, meta = commits(path, opts)
      if not list then return nil, err, meta end
      local c = list[1]
      if not c then return nil, "enoent", meta end
      return {
	 name = strip(path or ""),
	 sha = c.sha,
	 date = c.committer and c.committer.date or c.author and c.author.date,
	 commit = c,
      }, nil, meta
   end

   local function compare(baseRef, headRef)
      assert(baseRef and headRef, "base and head required")
      local decoded, err, meta = apiJson("GET", "/compare/" .. baseRef .. "..." .. headRef)
      if not decoded then return nil, err, meta end
      local commitsOut, filesOut = {}, {}
      for _, c in ipairs(decoded.commits or {}) do commitsOut[#commitsOut + 1] = normalizeCommit(c) end
      for _, f in ipairs(decoded.files or {}) do
	 filesOut[#filesOut + 1] = {
	    name = f.filename,
	    status = f.status,
	    sha = f.sha,
	    previousName = f.previous_filename,
	    additions = f.additions,
	    deletions = f.deletions,
	    changes = f.changes,
	    patch = f.patch,
	 }
      end
      return {
	 status = decoded.status,
	 aheadBy = decoded.ahead_by,
	 behindBy = decoded.behind_by,
	 totalCommits = decoded.total_commits,
	 mergeBaseCommit = normalizeCommit(decoded.merge_base_commit),
	 baseCommit = normalizeCommit(decoded.base_commit),
	 commits = commitsOut,
	 files = filesOut,
      }, nil, meta
   end

   local function refs(prefix)
      local path = prefix and strip(prefix) ~= "" and "/git/refs/" .. strip(prefix) or "/git/refs"
      local decoded, err, meta = apiJson("GET", path)
      if not decoded then return nil, err, meta end
      local out = {}
      if decoded.ref then
	 out[1] = normalizeRef(decoded)
      else
	 for _, r in ipairs(decoded) do out[#out + 1] = normalizeRef(r) end
      end
      return out, nil, meta
   end

   local function branches(opts)
      local list, err, meta = paged("/branches", opts)
      if not list then return nil, err, meta end
      local out = {}
      for _, b in ipairs(list) do
	 out[#out + 1] = {
	    name = b.name,
	    sha = b.commit and b.commit.sha or nil,
	    protected = b.protected and true or false,
	 }
      end
      return out, nil, meta
   end

   local function tags(opts)
      local list, err, meta = paged("/tags", opts)
      if not list then return nil, err, meta end
      local out = {}
      for _, t in ipairs(list) do
	 out[#out + 1] = {
	    name = t.name,
	    sha = t.commit and t.commit.sha or nil,
	 }
      end
      return out, nil, meta
   end

   local function repoInfo()
      local decoded, err, meta = apiJson("GET", "")
      if not decoded then return nil, err, meta end
      return {
	 owner = decoded.owner and decoded.owner.login or op.owner,
	 repo = decoded.name or op.repo,
	 fullName = decoded.full_name,
	 defaultBranch = decoded.default_branch,
	 private = decoded.private and true or false,
	 fork = decoded.fork and true or false,
	 size = decoded.size,
	 htmlUrl = decoded.html_url,
	 cloneUrl = decoded.clone_url,
	 sshUrl = decoded.ssh_url,
      }, nil, meta
   end

   local function defaultBranch()
      local info, err, meta = repoInfo()
      return info and info.defaultBranch or nil, err, meta
   end

   local function rateLimit()
      local code, body, header = ghReq("GET", api .. "/rate_limit", nil, nil, nil, {200})
      local meta = responseMeta(header, code)
      if code ~= 200 then return nil, "Err:" .. tostring(body), meta end
      return json.decode(body), nil, meta
   end

   local function archive(format, ref)
      format = format or "zip"
      if format == "zip" then format = "zipball" end
      if format == "tar" or format == "tar.gz" then format = "tarball" end
      if format ~= "zipball" and format ~= "tarball" then return nil, "invalidname" end
      ref = ref or branch
      local code, body, header = ghReq("GET", repoBase .. "/" .. format .. "/" .. ref, nil, nil, nil, {200,301,302})
      local meta = responseMeta(header, code)
      local location = meta.location
      if (code == 301 or code == 302) and location then
	 code, body, header = ghReq(
	    "GET",
	    location,
	    { ["Accept"] = "application/octet-stream" },
	    nil,
	    nil,
	    {200}
	 )
	 meta = responseMeta(header, code)
      end
      if code ~= 200 then return nil, "Err:" .. tostring(body), meta end
      return body, nil, meta
   end

   local function commitBatch(changes, message, opts)
      opts = opts or {}
      assert(type(changes) == "table", "changes table required")
      message = message or opts.message or "ci: batch update"
      local ref = opts.branch or branch
      local head, err, meta = apiJson("GET", "/git/ref/heads/" .. ref)
      if not head then return nil, err, meta end
      local headSha = head.object and head.object.sha
      if not headSha then return nil, "invalidresponse" end
      local headCommit
      headCommit, err, meta = apiJson("GET", "/git/commits/" .. headSha)
      if not headCommit then return nil, err, meta end
      local baseTree = headCommit.tree and headCommit.tree.sha
      if not baseTree then return nil, "invalidresponse" end

      local tree = {}
      for _, change in ipairs(changes) do
	 local path = strip(change.path or change.name or "")
	 if path == "" then return nil, "invalidname" end
	 if change.delete or change.remove then
	    local null = json.null or ba.json.null
	    if not null then return nil, "jsonnull" end
	    tree[#tree + 1] = {
	       path = path,
	       mode = change.mode or "100644",
	       type = "blob",
	       sha = null,
	    }
	 else
	    local content = change.b64content or ba.b64encode(change.content or change.data or "")
	    local blob
	    blob, err, meta = apiJson(
	       "POST",
	       "/git/blobs",
	       { ["Content-Type"] = "application/json" },
	       { content = content, encoding = "base64" },
	       nil,
	       {201}
	    )
	    if not blob then return nil, err, meta end
	    tree[#tree + 1] = {
	       path = path,
	       mode = change.mode or "100644",
	       type = change.type or "blob",
	       sha = blob.sha,
	    }
	 end
      end

      local newTree
      newTree, err, meta = apiJson(
	 "POST",
	 "/git/trees",
	 { ["Content-Type"] = "application/json" },
	 { base_tree = baseTree, tree = tree },
	 nil,
	 {201}
      )
      if not newTree then return nil, err, meta end
      local newCommit
      newCommit, err, meta = apiJson(
	 "POST",
	 "/git/commits",
	 { ["Content-Type"] = "application/json" },
	 { message = message, tree = newTree.sha, parents = {headSha} },
	 nil,
	 {201}
      )
      if not newCommit then return nil, err, meta end
      local updated
      updated, err, meta = apiJson(
	 "PATCH",
	 "/git/refs/heads/" .. ref,
	 { ["Content-Type"] = "application/json" },
	 { sha = newCommit.sha, force = opts.force and true or false },
	 nil,
	 {200}
      )
      if not updated then return nil, err, meta end
      return {
	 sha = newCommit.sha,
	 htmlUrl = newCommit.html_url,
	 ref = updated.ref,
	 tree = newTree.sha,
	 files = #changes,
      }, nil, meta
   end

   return ba.create.luaio{
      open   = open,
      files  = ioFiles,
      stat   = stat,
      mkdir  = mkdir,
      rmdir  = rmdir,
      remove = remove,
   },
   {
      files=files,
      commits=commits,
      lastModified=lastModified,
      compare=compare,
      refs=refs,
      branches=branches,
      tags=tags,
      repo=repoInfo,
      defaultBranch=defaultBranch,
      rateLimit=rateLimit,
      archive=archive,
      commitBatch=commitBatch,
   }
end

return { create = create }
