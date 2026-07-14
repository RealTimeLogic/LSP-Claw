local M={}

local zipWriter=require"zip_writer"
local rw=require"rwfile"
local sfmt=string.format
local tinsert=table.insert

local manifestName=".lsp-claw-lab.json"
local formatName="lsp-claw-lab"
local formatVersion=1
local importStageOwner="LSPClawImport"

local function join(path,name)
   return path == "" and name or path.."/"..name
end

local function safePath(path)
   path=tostring(path or ""):gsub("\\","/")
   if path == "" then return nil,"path is empty" end
   if path:find("%z") then return nil,"path contains NUL" end
   if path:match("^/") or path:match("^//") then return nil,"absolute paths are not allowed" end
   if path:match("^[A-Za-z]:") then return nil,"drive paths are not allowed" end
   local depth=0
   for part in path:gmatch("[^/]+") do
      if part == "." or part == ".." or part == "" then return nil,"dot path segments are not allowed" end
      depth=depth+1
   end
   if depth == 0 then return nil,"path is empty" end
   return path,depth
end

local function streamCopy(fromIo,fromName,toIo,toName,maxBytes,onChunk)
   local source,err=fromIo:open(fromName,"rb")
   if not source then return nil,"cannot open "..fromName..": "..tostring(err) end
   local target
   target,err=toIo:open(toName,"wb")
   if not target then source:close() return nil,"cannot create "..toName..": "..tostring(err) end
   local total,ok=0,true
   while true do
      local chunk,readErr=source:read(16384)
      if chunk and #chunk > 0 then
         total=total+#chunk
         if total > maxBytes then ok,err=nil,"file exceeds import size limit: "..fromName break end
         if onChunk then onChunk(chunk) end
         ok,err=target:write(chunk)
         if not ok then break end
      elseif readErr then
         ok,err=nil,readErr
         break
      else
         break
      end
   end
   local sourceOk,sourceErr=source:close()
   local targetOk,targetErr=target:close()
   if not ok then return nil,tostring(err) end
   if sourceOk == false then return nil,tostring(sourceErr) end
   if targetOk == false then return nil,tostring(targetErr) end
   return total
end

local function removeFile(io,path)
   if io and path then pcall(function() io:remove(path) end) end
end

local function jsonResponse(response,status,value)
   local encoded=ba.json.encode(value)
   response:setstatus(status)
   response:setcontenttype("application/json; charset=utf-8")
   response:setheader("Cache-Control","no-store")
   response:setheader("Content-Length",tostring(#encoded))
   response:send(encoded)
end

local function ticketId()
   assert(type(ba.rndbs) == "function" and type(ba.b64urlencode) == "function","secure random ticket support is unavailable")
   return ba.b64urlencode(ba.rndbs(24))
end

local function secureEqual(a,b)
   a,b=tostring(a or ""),tostring(b or "")
   local length=math.max(#a,#b,32)
   local different=(#a == #b) and 0 or 1
   for index=1,length do
      local av,bv=a:byte(index) or 0,b:byte(index) or 0
      if av ~= bv then different=different+1 end
   end
   return different == 0
end

local Archive={}
Archive.__index=Archive

function Archive:_limits()
   return self.limits
end

function Archive:_cleanup()
   local now=os.time()
   for id,ticket in pairs(self.tickets) do
      if ticket.expiresAt <= now then
         removeFile(self.baseIo,ticket.path)
         self.tickets[id]=nil
      end
   end
end

function Archive:_newTicket(kind,data)
   self:_cleanup()
   local id=ticketId()
   data=data or {}
   data.kind=kind
   data.createdAt=os.time()
   data.expiresAt=data.createdAt+self.ticketTtl
   self.tickets[id]=data
   return id,data
end

function Archive:_collectLab(lab)
   local ok,err=lab:create()
   if not ok then return nil,err end
   local labIo=lab:getLabIo()
   local files,dirs,hasChild,total,dirCount={}, {}, {},0,0
   local limits=self.limits
   for path,name in self.appmgr.recDirIter(labIo,"",true) do
      if name then
         local file=join(path,name)
         if file:lower() == manifestName then return nil,"lab contains reserved archive manifest "..manifestName end
         local valid,depth=safePath(file)
         if not valid then return nil,"unsafe lab path "..file..": "..depth end
         if depth > limits.maxDepth then return nil,"lab path exceeds nesting limit: "..file end
         local stat=labIo:stat(file)
         local size=stat and tonumber(stat.size) or 0
         if size > limits.maxEntryBytes then return nil,"lab file exceeds size limit: "..file end
         total=total+size
         if total > limits.maxExpandedBytes then return nil,"lab exceeds expanded size limit" end
         tinsert(files,{path=file,source={io=labIo,path=file}})
         local parent=path
         while parent ~= "" do
            hasChild[parent]=true
            parent=parent:match("^(.*)/[^/]+$") or ""
         end
      else
         local valid,depth=safePath(path)
         if path ~= "" then
            if not valid then return nil,"unsafe lab directory "..path..": "..depth end
            if depth > limits.maxDepth then return nil,"lab directory exceeds nesting limit: "..path end
            dirs[path]=true
            dirCount=dirCount+1
            local parent=path:match("^(.*)/[^/]+$") or ""
            if parent ~= "" then hasChild[parent]=true end
         end
      end
   end
   local fileCount=#files
   if fileCount+dirCount+1 > limits.maxEntries then return nil,"lab exceeds archive entry limit" end
   local empty={}
   for path in pairs(dirs) do if not hasChild[path] then tinsert(empty,path) end end
   table.sort(empty)
   for path in pairs(dirs) do tinsert(files,{path=path,directory=true}) end
   return {entries=files,fileCount=fileCount,uncompressedBytes=total,emptyDirectories=empty,labIo=labIo}
end

function Archive:prepareExport(lab)
   self:_cleanup()
   return lab:exclusive("exportLab",function()
      local collected,err=self:_collectLab(lab)
      if not collected then return nil,err,"exportLabFailed" end
      local manifest={
         format=formatName,
         version=formatVersion,
         exportedLabName=lab:name(),
         createdAt=os.time(),
         fileCount=collected.fileCount,
         uncompressedBytes=collected.uncompressedBytes,
         emptyDirectories=collected.emptyDirectories
      }
      local manifestText=ba.json.encode(manifest)
      tinsert(collected.entries,{path=manifestName,content=manifestText})
      local id=ticketId()
      local path="LSP-Claw-export-"..id..".zip"
      local output
      output,err=self.baseIo:open(path,"wb")
      if not output then return nil,err,"exportLabFailed" end
      local hash=ba.crypto.hash"sha256"
      local info
      info,err=zipWriter.write(collected.entries,function(chunk)
         hash(chunk)
         return output:write(chunk)
      end,{
         maxEntries=self.limits.maxEntries,
         maxDepth=self.limits.maxDepth,
         maxEntryBytes=self.limits.maxEntryBytes,
         maxArchiveBytes=self.limits.maxArchiveBytes
      })
      local closeOk,closeErr=output:close()
      if not info or closeOk == false then
         removeFile(self.baseIo,path)
         return nil,err or closeErr,"exportLabFailed"
      end
      local ticket={
         path=path,
         labName=lab:name(),
         filename=lab:name()..".zip",
         size=info.size,
         sha256=hash(true,"hex"),
         manifest=manifest
      }
      ticket.createdAt=os.time()
      ticket.expiresAt=ticket.createdAt+self.ticketTtl
      ticket.kind="export"
      self.tickets[id]=ticket
      return {
         ticket=id,
         expiresAt=ticket.expiresAt,
         expiresInSeconds=self.ticketTtl,
         filename=ticket.filename,
         size=ticket.size,
         sha256=ticket.sha256,
         manifest=manifest,
         stored=true,
         compression="none"
      }
   end)
end

function Archive:prepareTransfer(lab)
   local prepared,err,code=self:prepareExport(lab)
   if not prepared then return nil,err,code end
   local ticket=self.tickets[prepared.ticket]
   if not ticket then return nil,"prepared transfer snapshot is unavailable","prepareLabTransferFailed" end
   ticket.kind="transfer"
   ticket.expiresAt=os.time()+self.transferTtl
   return {
      transferTicket=prepared.ticket,
      expiresAt=ticket.expiresAt,
      expiresInSeconds=self.transferTtl,
      expectedBytes=ticket.size,
      digest="sha256:"..ticket.sha256,
      sourceLab={name=lab:name(),basePath=lab:basePath()},
      stored=true,
      compression="none"
   }
end

function Archive:_validateImportTarget(labName,conflictAction,confirmed)
   local valid,err=self.appmgr.validateLabName(labName)
   if not valid then return nil,err,"invalidLabName" end
   if conflictAction ~= "createNew" and conflictAction ~= "replace" then
      return nil,"conflictAction must be createNew or replace","invalidConflictAction"
   end
   local existing,existingErr,existingCode=self.appmgr.getLab(valid)
   if conflictAction == "createNew" and existing then return nil,"lab "..valid.." already exists","labAlreadyExists" end
   if conflictAction == "createNew" and existingCode ~= "unknownLab" then return nil,existingErr,existingCode end
   if conflictAction == "replace" then
      if not existing then return nil,existingErr,existingCode end
      if confirmed ~= true then return nil,"replacing a lab requires explicit confirmation","labReplaceRequiresConfirmation" end
      if existing:isRunning() then return nil,"lab "..valid.." must be stopped before replacement","labMustBeStopped" end
   end
   return valid
end

function Archive:prepareImport(labName,conflictAction,confirmed)
   local valid,err,code=self:_validateImportTarget(labName,conflictAction,confirmed)
   if not valid then return nil,err,code end
   local id,ticket=self:_newTicket("import",{labName=valid,conflictAction=conflictAction,confirmed=confirmed == true})
   return {ticket=id,labName=valid,conflictAction=conflictAction,expiresAt=ticket.expiresAt,expiresInSeconds=self.ticketTtl,maxUploadBytes=self.limits.maxArchiveBytes}
end

local function mkdir(io,path)
   local stat=io:stat(path)
   if stat then return stat.isdir and true or nil,"path conflicts with a file: "..path end
   return io:mkdir(path)
end

function Archive:_validateAndStage(zipIo,uploadSize)
   local limits=self.limits
   local manifestText,manifestErr=rw.file(zipIo,manifestName)
   if not manifestText then return nil,"archive manifest is missing: "..tostring(manifestErr or manifestName) end
   if #manifestText > limits.maxManifestBytes then return nil,"archive manifest exceeds size limit" end
   local decodeOk,manifest=pcall(ba.json.decode,manifestText)
   if not decodeOk or type(manifest) ~= "table" then return nil,"archive manifest is invalid JSON" end
   if manifest.format ~= formatName or manifest.version ~= formatVersion then return nil,"unsupported lab archive format or version" end
   if type(manifest.fileCount) ~= "number" or type(manifest.uncompressedBytes) ~= "number" then return nil,"archive manifest counts are invalid" end
   if type(manifest.emptyDirectories) ~= "table" then return nil,"archive manifest emptyDirectories is required" end
   if manifest.fileCount < 0 or manifest.fileCount%1 ~= 0 or manifest.fileCount > limits.maxEntries then return nil,"archive manifest fileCount is invalid" end
   if manifest.uncompressedBytes < 0 or manifest.uncompressedBytes%1 ~= 0 or manifest.uncompressedBytes > limits.maxExpandedBytes then return nil,"archive manifest uncompressedBytes is invalid" end
   local emptyCount=0
   for key,value in pairs(manifest.emptyDirectories) do
      if type(key) ~= "number" or key < 1 or key%1 ~= 0 or type(value) ~= "string" then return nil,"archive manifest emptyDirectories is invalid" end
      emptyCount=emptyCount+1
   end
   if emptyCount ~= #manifest.emptyDirectories then return nil,"archive manifest emptyDirectories must be an array" end

   local stageIo,stageName,err=self.appmgr.createStageIo(importStageOwner)
   if not stageIo then return nil,err end
   local seen,files,dirs={}, {}, {}
   local fileCount,total,entryCount=0,0,0
   local ok,result=pcall(function()
      for path,name in self.appmgr.recDirIter(zipIo,"",true) do
         local item=name and join(path,name) or path
         if item ~= "" then
            local valid,depth=safePath(item)
            assert(valid,"unsafe archive path "..item..": "..tostring(depth))
            assert(depth <= limits.maxDepth,"archive path exceeds nesting limit: "..item)
            local key=item:lower()
            assert(not seen[key],"duplicate archive path: "..item)
            seen[key]=true
            entryCount=entryCount+1
            assert(entryCount <= limits.maxEntries,"archive exceeds entry limit")
            if name then
               if key ~= manifestName then tinsert(files,item) end
            else
               tinsert(dirs,item)
            end
         end
      end
      table.sort(dirs,function(a,b) return #a < #b or (#a == #b and a < b) end)
      for _,path in ipairs(dirs) do assert(mkdir(stageIo,path)) end
      for _,path in ipairs(files) do
         local size,copyErr=streamCopy(zipIo,path,stageIo,path,limits.maxEntryBytes)
         assert(size,copyErr)
         fileCount=fileCount+1
         total=total+size
         assert(total <= limits.maxExpandedBytes,"archive exceeds expanded size limit")
      end
      local emptySeen={}
      table.sort(manifest.emptyDirectories,function(a,b) return tostring(a) < tostring(b) end)
      for _,path in ipairs(manifest.emptyDirectories) do
         local valid,depth=safePath(path)
         assert(valid,"unsafe empty directory path: "..tostring(path)..": "..tostring(depth))
         assert(depth <= limits.maxDepth,"empty directory exceeds nesting limit: "..path)
         local key=path:lower()
         assert(not emptySeen[key],"duplicate empty directory path: "..path)
         emptySeen[key]=true
         local parent=""
         for part in path:gmatch("[^/]+") do
            parent=join(parent,part)
            assert(mkdir(stageIo,parent))
         end
      end
      assert(fileCount == manifest.fileCount,"manifest fileCount mismatch")
      assert(total == manifest.uncompressedBytes,"manifest uncompressedBytes mismatch")
      if uploadSize > 0 and total/uploadSize > limits.maxCompressionRatio then error("archive expansion ratio exceeds limit") end
      return true
   end)
   if not ok then
      self.appmgr.removeStage(stageIo,stageName)
      return nil,tostring(result)
   end
   return {stageIo=stageIo,stageName=stageName,manifest=manifest,fileCount=fileCount,uncompressedBytes=total}
end

function Archive:_saveUpload(request,id)
   local declared=tonumber(request:header("Content-Length") or "")
   if declared and declared > self.limits.maxArchiveBytes then return nil,"ZIP upload exceeds size limit" end
   local path="LSP-Claw-import-"..id..".zip"
   local file,err=self.baseIo:open(path,"wb")
   if not file then return nil,err end
   local size,hash=0,ba.crypto.hash"sha256"
   local ok,result=pcall(function()
      for chunk in request:rawrdr() do
         size=size+#chunk
         assert(size <= self.limits.maxArchiveBytes,"ZIP upload exceeds size limit")
         hash(chunk)
         assert(file:write(chunk))
      end
      assert(size > 0,"ZIP upload body is empty")
      assert(file:close())
      file=nil
      return true
   end)
   if file then pcall(function() file:close() end) end
   if not ok then removeFile(self.baseIo,path) return nil,tostring(result) end
   return {path=path,size=size,sha256=hash(true,"hex")}
end

function Archive:_importUpload(upload,ticket)
   local zipIo
   local created=false
   local lab
   local routeChanged
   local failureCode="importLabFailed"
   local ok,result,code=pcall(function()
      local openErr
      zipIo,openErr=ba.mkio(self.baseIo,upload.path)
      failureCode="invalidLabArchive"
      assert(zipIo,"cannot open uploaded ZIP: "..tostring(openErr))
      if ticket.conflictAction == "createNew" then
         local prepared,prepareErr=self:_validateAndStage(zipIo,upload.size)
         assert(prepared,prepareErr)
         local createErr,createCode
         lab,createErr,createCode,routeChanged=self.appmgr.createLab(ticket.labName)
         failureCode=createCode or "createLabFailed"
         if not lab then self.appmgr.removeStage(prepared.stageIo,prepared.stageName) error((createCode or "createLabFailed")..": "..tostring(createErr)) end
         created=true
         failureCode="importLabFailed"
         local replaced,replaceWarning=lab:exclusive("importLab",function()
            local commitOk,commitWarning,commitCode=lab:replaceWithStage(prepared.stageIo,prepared.stageName)
            if not commitOk then self.appmgr.removeStage(prepared.stageIo,prepared.stageName) return nil,commitWarning,commitCode end
            return true,commitWarning
         end)
         assert(replaced,replaceWarning)
         prepared.warning=replaceWarning
         return prepared
      else
         local getErr,getCode
         lab,getErr,getCode=self.appmgr.getLab(ticket.labName)
         failureCode=getCode or "unknownLab"
         if not lab then error((getCode or "unknownLab")..": "..tostring(getErr)) end
         failureCode="importLabFailed"
         assert(not lab:isRunning(),"lab must be stopped before replacement")
      end
      local staged,stageErr=lab:exclusive("importLab",function()
         failureCode="invalidLabArchive"
         local prepared,prepareErr=self:_validateAndStage(zipIo,upload.size)
         if not prepared then return nil,prepareErr end
         failureCode="importLabFailed"
         local replaced,replaceWarning,replaceCode=lab:replaceWithStage(prepared.stageIo,prepared.stageName)
         if not replaced then self.appmgr.removeStage(prepared.stageIo,prepared.stageName) return nil,replaceWarning,replaceCode end
         prepared.warning=replaceWarning
         return prepared
      end)
      assert(staged,stageErr)
      return staged
   end)
   if zipIo and zipIo.close then pcall(function() zipIo:close() end) end
   removeFile(self.baseIo,upload.path)
   if not ok then
      if created and lab then
         pcall(function() self.appmgr.deleteLab(lab:name()) end)
         if routeChanged then pcall(function() self.appmgr.setLabBasePath(routeChanged.labName,"",false) end) end
      end
      return nil,tostring(result),failureCode
   end
   return {
      imported=true,
      labName=ticket.labName,
      conflictAction=ticket.conflictAction,
      created=created,
      replaced=not created,
      uploadBytes=upload.size,
      sha256=upload.sha256,
      fileCount=result.fileCount,
      uncompressedBytes=result.uncompressedBytes,
      sourceLabName=result.manifest.exportedLabName,
      warning=result.warning
   }
end

function Archive:_import(request,id,ticket)
   local upload,err=self:_saveUpload(request,id)
   if not upload then return nil,err,"uploadFailed" end
   return self:_importUpload(upload,ticket)
end

local function validIpv4(host)
   local count=0
   for octet in host:gmatch("[^.]+") do
      count=count+1
      if not octet:match("^%d+$") or (#octet > 1 and octet:sub(1,1) == "0") or tonumber(octet) > 255 then return false end
   end
   return count == 4 and host:sub(1,1) ~= "." and host:sub(-1) ~= "." and not host:find("..",1,true)
end

local function validIpv6(host)
   if host == "" or not host:match("^[0-9A-Fa-f:%.]+$") then return false end
   local first=host:find("::",1,true)
   if first and host:find("::",first+2,true) then return false end
   local groups=0
   local sawIpv4=false
   for group in host:gmatch("[^:]+") do
      if group:find(".",1,true) then
         if sawIpv4 or not validIpv4(group) or group ~= host:match("([^:]+)$") then return false end
         sawIpv4=true
         groups=groups+2
      else
         if #group < 1 or #group > 4 or not group:match("^[0-9A-Fa-f]+$") then return false end
         groups=groups+1
      end
   end
   return first and groups < 8 or not first and groups == 8
end

local function parseTransferUrl(url)
   if type(url) ~= "string" or #url < 1 or #url > 2048 then return nil,"transferUrl must contain 1 to 2048 characters" end
   if url:find("[%z%c%s\\#%?]") then return nil,"transferUrl contains a forbidden character, query, or fragment" end
   local scheme,authority,path=url:match("^(https?)://([^/]+)(/.*)$")
   if not scheme then
      scheme,authority=url:match("^(https?)://([^/]+)$")
      path="/"
   end
   if not scheme or not authority or authority:find("@",1,true) then return nil,"transferUrl must be an HTTP or HTTPS URL without user-info" end
   local host,port
   if authority:sub(1,1) == "[" then
      host,port=authority:match("^%[([0-9A-Fa-f:%.]+)%]:(%d+)$")
      if not host then host=authority:match("^%[([0-9A-Fa-f:%.]+)%]$") end
      if not host or not validIpv6(host) then return nil,"transferUrl has an invalid IPv6 host" end
      host="["..host:lower().."]"
   else
      host,port=authority:match("^([^:]+):(%d+)$")
      host=host or authority
      if #host > 253 or host:find(":",1,true) or not host:match("^[A-Za-z0-9%.%-]+$") or host:sub(1,1) == "." or host:sub(-1) == "." then
         return nil,"transferUrl has an invalid host"
      end
      if host:find("..",1,true) then return nil,"transferUrl has an invalid host" end
      if host:match("^[%d%.]+$") and not validIpv4(host) then return nil,"transferUrl has an invalid IPv4 host" end
      for label in host:gmatch("[^.]+") do
         if #label > 63 or label:sub(1,1) == "-" or label:sub(-1) == "-" then return nil,"transferUrl has an invalid host" end
      end
      host=host:lower()
   end
   port=port and tonumber(port) or (scheme == "https" and 443 or 80)
   if not port or port < 1 or port > 65535 then return nil,"transferUrl has an invalid port" end
   local explicitPort=authority:match(":%d+$") ~= nil
   local origin=scheme.."://"..host..(explicitPort and ":"..port or "")
   return {url=url,scheme=scheme,host=host,port=port,path=path,origin=origin}
end

function Archive:_findTransferTicket(candidate)
   local foundId,found
   for id,ticket in pairs(self.tickets) do
      if ticket.kind == "transfer" and secureEqual(id,candidate) then foundId,found=id,ticket end
   end
   return foundId,found
end

function Archive:_streamSnapshot(ticket,response)
   local file,err=self.baseIo:open(ticket.path,"rb")
   if not file then removeFile(self.baseIo,ticket.path) return nil,err end
   response:setstatus(200)
   response:setcontenttype("application/zip")
   response:setheader("Cache-Control","no-store")
   response:setheader("Content-Length",tostring(ticket.size))
   response:setheader("X-LSP-Claw-SHA256",ticket.sha256)
   local streamed,streamErr=pcall(function()
      while true do
         local chunk=file:read(16384)
         if not chunk or #chunk == 0 then break end
         response:write(chunk)
      end
   end)
   pcall(function() file:close() end)
   removeFile(self.baseIo,ticket.path)
   if not streamed then return nil,tostring(streamErr) end
   return true
end

function Archive:handleTransfer(request,response)
   self:_cleanup()
   if request:header("Authorization") then
      jsonResponse(response,400,{ok=false,error="Persistent authorization credentials are forbidden on the transfer endpoint"})
      return
   end
   local candidate=request:header("X-LSP-Claw-Transfer-Ticket")
   local id,ticket=self:_findTransferTicket(candidate)
   if not ticket then jsonResponse(response,404,{ok=false,error="Transfer ticket is invalid, expired, or already used",code="transferExpired"}) return end
   self.tickets[id]=nil
   if request:method() ~= "GET" then
      removeFile(self.baseIo,ticket.path)
      jsonResponse(response,405,{ok=false,error="Transfer ticket requires GET"})
      return
   end
   local ok,err=self:_streamSnapshot(ticket,response)
   if not ok then error(err) end
end

function Archive:_fetchTransfer(parsed,ticket,expectedBytes,expectedDigest)
   local id=ticketId()
   local path="LSP-Claw-transfer-"..id..".zip"
   local output,err=self.baseIo:open(path,"wb")
   if not output then return nil,err,"transferDownloadFailed" end
   local http
   local total,hash=0,ba.crypto.hash"sha256"
   local failureCode="transferDownloadFailed"
   local ok,result,code=pcall(function()
      http=require"httpc".create{persistent=false}
      http:timeout(self.transferReadTimeoutMs)
      local requested,requestErr=http:request{
         url=parsed.url,
         method="GET",
         trusted=parsed.scheme == "https",
         header={
            ["Accept"]="application/zip",
            ["X-LSP-Claw-Transfer-Ticket"]=ticket
         }
      }
      assert(requested,"source request failed: "..tostring(requestErr))
      local status,statusErr=http:status()
      assert(status,"source response failed: "..tostring(statusErr))
      if status == 404 or status == 410 then failureCode="transferExpired" end
      if status >= 300 and status < 400 then failureCode="transferRedirectForbidden" end
      assert(status == 200,"source returned HTTP "..tostring(status).."; redirects are not allowed")
      local contentLength=tonumber(http:header"Content-Length" or "")
      assert(contentLength,"source response has no valid Content-Length")
      failureCode="transferDigestMismatch"
      assert(contentLength == expectedBytes,"source Content-Length differs from prepared descriptor")
      assert(contentLength <= self.limits.maxArchiveBytes,"source archive exceeds size limit")
      local sourceDigest=tostring(http:header"X-LSP-Claw-SHA256" or ""):lower()
      assert(secureEqual(sourceDigest,expectedDigest),"source digest header differs from prepared descriptor")
      local contentType=tostring(http:header"Content-Type" or ""):lower()
      assert(contentType == "application/zip" or contentType:match("^application/zip%s*;"),"source response is not application/zip")
      local started=os.time()
      failureCode="transferDownloadFailed"
      while true do
         assert(os.time()-started <= self.transferTotalTimeoutSeconds,"source transfer exceeded total time limit")
         local chunk,readErr=http:read(16384)
         if chunk and #chunk > 0 then
            total=total+#chunk
            assert(total <= self.limits.maxArchiveBytes,"source archive exceeds size limit")
            hash(chunk)
            assert(output:write(chunk))
         elseif readErr then
            error("source transfer read failed: "..tostring(readErr))
         else
            break
         end
      end
      assert(total == expectedBytes,"downloaded byte count differs from prepared descriptor")
      local digest=hash(true,"hex"):lower()
      failureCode="transferDigestMismatch"
      assert(secureEqual(digest,expectedDigest),"downloaded archive digest mismatch")
      assert(output:close())
      output=nil
      return {path=path,size=total,sha256=digest}
   end)
   if output then pcall(function() output:close() end) end
   if http then pcall(function() http:close() end) end
   if not ok then removeFile(self.baseIo,path) return nil,tostring(result),failureCode end
   return result
end

function Archive:importTransfer(args)
   args=args or {}
   local parsed,err=parseTransferUrl(args.transferUrl)
   if not parsed then return nil,err,"invalidTransferUrl" end
   if self.allowedTransferPorts and not self.allowedTransferPorts[parsed.port] then
      return nil,"source port is not allowed by this destination","invalidTransferUrl",parsed.origin
   end
   if args.confirmed ~= true or args.confirmedSourceOrigin ~= parsed.origin then
      return nil,"explicit confirmation of the exact source origin is required","transferSourceRequiresConfirmation",parsed.origin
   end
   if type(args.transferTicket) ~= "string" or #args.transferTicket ~= 32 or not args.transferTicket:match("^[A-Za-z0-9_-]+$") then
      return nil,"transfer ticket is invalid","invalidTransferTicket",parsed.origin
   end
   local expectedBytes=tonumber(args.expectedBytes)
   if not expectedBytes or expectedBytes < 1 or expectedBytes%1 ~= 0 or expectedBytes > self.limits.maxArchiveBytes then
      return nil,"expectedBytes is invalid","invalidTransferDescriptor",parsed.origin
   end
   local expectedDigest=type(args.digest) == "string" and args.digest:lower():match("^sha256:([0-9a-f]+)$")
   if not expectedDigest or #expectedDigest ~= 64 then return nil,"digest must be a SHA-256 descriptor","invalidTransferDescriptor",parsed.origin end
   local destination,validateErr,validateCode=self:_validateImportTarget(args.destinationLabName,args.conflictAction,args.confirmed)
   if not destination then return nil,validateErr,validateCode,parsed.origin end
   local upload,fetchErr,fetchCode=self:_fetchTransfer(parsed,args.transferTicket,expectedBytes,expectedDigest)
   if not upload then return nil,fetchErr,fetchCode,parsed.origin end
   local imported,importErr,importCode=self:_importUpload(upload,{
      labName=destination,
      conflictAction=args.conflictAction,
      confirmed=args.confirmed == true
   })
   if not imported then return nil,importErr,importCode,parsed.origin end
   imported.sourceOrigin=parsed.origin
   imported.transferUrl=parsed.url
   imported.digest="sha256:"..imported.sha256
   return imported
end

function Archive:handle(request,response,authorized)
   self:_cleanup()
   if not authorized then jsonResponse(response,401,{ok=false,error="Unauthorized"}) return end
   local id=request:data("ticket")
   local ticket=id and self.tickets[id]
   if not ticket then jsonResponse(response,404,{ok=false,error="Archive ticket is invalid, expired, or already used",code="transferExpired"}) return end
   if ticket.expiresAt <= os.time() then
      removeFile(self.baseIo,ticket.path)
      self.tickets[id]=nil
      jsonResponse(response,410,{ok=false,error="Archive ticket expired",code="transferExpired"})
      return
   end
   local method=request:method()
   if ticket.kind == "export" and method == "GET" then
      self.tickets[id]=nil
      local file,err=self.baseIo:open(ticket.path,"rb")
      if not file then removeFile(self.baseIo,ticket.path) jsonResponse(response,500,{ok=false,error=tostring(err),code="exportLabFailed"}) return end
      response:setstatus(200)
      response:setcontenttype("application/zip")
      response:setheader("Cache-Control","no-store")
      response:setheader("Content-Disposition",'attachment; filename="'..ticket.filename..'"')
      response:setheader("Content-Length",tostring(ticket.size))
      response:setheader("X-LSP-Claw-SHA256",ticket.sha256)
      local streamed,streamErr=pcall(function()
         while true do
            local chunk=file:read(16384)
            if not chunk or #chunk == 0 then break end
            response:write(chunk)
         end
      end)
      pcall(function() file:close() end)
      removeFile(self.baseIo,ticket.path)
      if not streamed then error(streamErr) end
      return
   end
   if ticket.kind == "import" and method == "POST" then
      local contentType=tostring(request:header("Content-Type") or ""):lower()
      if contentType ~= "application/zip" and not contentType:match("^application/zip%s*;") then
         jsonResponse(response,415,{ok=false,error="Content-Type must be application/zip",code="invalidLabArchive"})
         return
      end
      self.tickets[id]=nil
      local imported,err,code=self:_import(request,id,ticket)
      if not imported then jsonResponse(response,400,{ok=false,error=err,code=code}) return end
      jsonResponse(response,200,{ok=true,result=imported})
      return
   end
   jsonResponse(response,405,{ok=false,error="Method not allowed for this archive ticket"})
end

function M.create(appmgr,options)
   options=options or {}
   local limits={
      maxArchiveBytes=tonumber(options.maxArchiveBytes) or 64*1024*1024,
      maxExpandedBytes=tonumber(options.maxExpandedBytes) or 64*1024*1024,
      maxEntryBytes=tonumber(options.maxEntryBytes) or 64*1024*1024,
      maxEntries=tonumber(options.maxEntries) or 4096,
      maxDepth=tonumber(options.maxDepth) or 32,
      maxCompressionRatio=tonumber(options.maxCompressionRatio) or 100,
      maxManifestBytes=tonumber(options.maxManifestBytes) or 256*1024
   }
   local allowedTransferPorts=options.allowedTransferPorts
   if type(allowedTransferPorts) == "string" then
      local configured={}
      if allowedTransferPorts ~= "" then
         for value in allowedTransferPorts:gmatch("[^,%s]+") do
            local port=tonumber(value)
            assert(port and port%1 == 0 and port >= 1 and port <= 65535,"invalid LSP_CLAW_TRANSFER_ALLOWED_PORTS value: "..value)
            configured[port]=true
         end
         allowedTransferPorts=configured
      else
         allowedTransferPorts=nil
      end
   end
   local archive=setmetatable({
      appmgr=assert(appmgr,"appmgr is required"),
      baseIo=options.baseIo or ba.openio("home") or ba.openio("disk"),
      ticketTtl=tonumber(options.ticketTtl) or 5*60,
      transferTtl=tonumber(options.transferTtl) or 60,
      transferReadTimeoutMs=tonumber(options.transferReadTimeoutMs) or 5000,
      transferTotalTimeoutSeconds=tonumber(options.transferTotalTimeoutSeconds) or 30,
      allowedTransferPorts=allowedTransferPorts,
      limits=limits,
      tickets={}
   },Archive)
   local prefix=importStageOwner.."-stage-"
   for name,isdir in archive.baseIo:files("",true) do
      if isdir and name:sub(1,#prefix) == prefix then
         local stageIo=ba.mkio(archive.baseIo,name)
         if stageIo then archive.appmgr.removeStage(stageIo,name) end
      end
   end
   return archive
end

M.manifestName=manifestName
M.format=formatName
M.version=formatVersion
M._safePath=safePath
M._parseTransferUrl=parseTransferUrl
M._secureEqual=secureEqual

return M
