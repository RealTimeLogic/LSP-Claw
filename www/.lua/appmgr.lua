local legacyLabName="lsplab"
local registryFile="LSP-Claw-Labs.json"
local registryVersion=1
local bio=ba.openio("home") or ba.openio("disk") -- Base IO
local sfmt=string.format
local tinsert=table.insert
local rw=require"rwfile"

local registry,labsByName,labsByKey

local function filePath(path,file)
   return #path > 0 and path.."/"..file or file
end


-- A recursive directory iterator
local function recDirIter(io,curPath,ldir)
   local name,co,doDir
   doDir=function(path)
      curPath=path
      if ldir and #path > 0 then
	 name=nil
	 coroutine.yield()
      end
      for file,isdir in io:files(path, true) do
	 if "." ~= file and ".." ~= file then
	    if isdir then
	       doDir(filePath(path,file))
	       curPath=path
	    else
	       name=file
	       coroutine.yield()
	    end
	 end
      end
   end
   co=coroutine.create(
      function()
	 doDir(curPath)
	 name,curPath=nil,nil
	 coroutine.yield()
      end
   )
   return function()
      coroutine.resume(co)
      return curPath, name
   end
end

local function mkdir(io,name) -- Creates it if it does not exist
   local ok,err
   local st=io:stat(name)
   if st then
      if st.isdir then return true end
      err="not a directory"
   else
      ok,err=io:mkdir(name)
   end
   if ok then return true end
   return nil,sfmt("Cannot create %s: %s",bio:realpath(name),err or "?")
end

local function mkio(io,name)
   local ok,err=mkdir(io,name)
   if ok then
      io,err=ba.mkio(io,name)
      if io then return io end
   end
   return nil,err
end

local function copyTable(t)
   local copy={}
   for k,v in pairs(t) do copy[k]=v end
   return copy
end

local function validateLabName(name)
   if type(name) ~= "string" then return nil,"lab name must be a string" end
   if #name < 1 or #name > 64 then return nil,"lab name must contain 1 to 64 characters" end
   if not name:match("^[A-Za-z0-9][A-Za-z0-9_-]*$") then
      return nil,"lab name must start with a letter or digit and contain only letters, digits, hyphen, and underscore"
   end
   local key=name:lower()
   if key:match("%-backup$") or key:find("-stage-",1,true) then
      return nil,"lab name uses a reserved backup or staging suffix"
   end
   return name
end

local function validateBasePath(basePath)
   if basePath == nil then return nil end
   if type(basePath) ~= "string" then return nil,"base path must be a string" end
   if basePath == "" then return "" end
   if #basePath > 64 or not basePath:match("^[A-Za-z0-9][A-Za-z0-9_-]*$") then
      return nil,"base path must be empty or one URL-safe segment containing letters, digits, hyphen, and underscore"
   end
   return basePath
end

local function newLabInfo(name,basePath,now,basePathExplicit)
   return {
      name=name,
      basePath=basePath,
      basePathExplicit=basePathExplicit == true,
      createdAt=now,
      updatedAt=now,
      running=false
   }
end

local function saveRegistry()
   local encoded,err=ba.json.encode(registry)
   if not encoded then return nil,err or "cannot encode lab registry" end
   local ok
   ok,err=rw.file(bio,registryFile,encoded)
   if ok then return true end
   return nil,sfmt("Cannot write %s: %s",registryFile,err or "?")
end

local function indexRegistry()
   labsByName={}
   labsByKey={}
   for _,info in ipairs(registry.labs) do
      labsByName[info.name]=info
      labsByKey[info.name:lower()]=info
   end
end

local function normalizeRegistry(decoded)
   if type(decoded) ~= "table" or decoded.format ~= "LSP-Claw-Labs" or decoded.version ~= registryVersion or type(decoded.labs) ~= "table" then
      return nil,"unsupported or invalid lab registry"
   end
   local normalized={
      format="LSP-Claw-Labs",
      version=registryVersion,
      labs={},
      migration=type(decoded.migration) == "table" and decoded.migration or nil
   }
   local keys,paths={},{}
   for _,info in ipairs(decoded.labs) do
      local name,nameErr=validateLabName(info and info.name)
      local basePath,pathErr=validateBasePath(info and info.basePath)
      if not name then return nil,"invalid lab registry entry: "..nameErr end
      if not basePath then return nil,"invalid lab registry entry for "..name..": "..(pathErr or "base path is required") end
      local key=name:lower()
      if keys[key] then return nil,"duplicate lab registry entry: "..name end
      local pathKey=basePath:lower()
      if paths[pathKey] then return nil,"duplicate lab base path: "..basePath end
      keys[key]=true
      paths[pathKey]=true
      tinsert(normalized.labs,{
         name=name,
         basePath=basePath,
         basePathExplicit=info.basePathExplicit == true,
         createdAt=tonumber(info.createdAt) or os.time(),
         updatedAt=tonumber(info.updatedAt) or os.time(),
         -- A process restart means a persisted running value is stale.
         running=false
      })
   end
   table.sort(normalized.labs,function(a,b) return a.name:lower() < b.name:lower() end)
   return normalized
end

local function loadRegistry()
   if registry then return true end
   local st=bio:stat(registryFile)
   if st then
      if st.isdir then return nil,registryFile.." is not a file" end
      local text,err=rw.file(bio,registryFile)
      if not text then return nil,sfmt("Cannot read %s: %s",registryFile,err or "?") end
      local ok,decoded=pcall(ba.json.decode,text)
      if not ok or type(decoded) ~= "table" then return nil,"Cannot decode "..registryFile end
      registry,err=normalizeRegistry(decoded)
      if not registry then return nil,err end
      indexRegistry()
      return true
   end

   local now=os.time()
   registry={format="LSP-Claw-Labs",version=registryVersion,labs={}}
   if bio:stat(legacyLabName) then
      tinsert(registry.labs,newLabInfo(legacyLabName,"",now,false))
      registry.migration={
         legacyLabName=legacyLabName,
         legacyBackupName=legacyLabName.."-backup",
         detectedAt=now,
         contentsMoved=false,
         rollbackPreserved=true,
         verified=false
      }
   end
   indexRegistry()
   return saveRegistry()
end

local function removeAll(io)
   local errList,ok,err={}
   local list,rlist={},{}
   for path,name in recDirIter(io,"",true) do
      if name then
	 local fname=filePath(path,name)
	 ok,err=io:remove(fname)
	 if not ok then tinsert(errList,sfmt("%s: %s",fname,err)) end
      else
	 tinsert(list,path)
      end
   end
   for i=#list,1,-1 do tinsert(rlist,list[i]) end
   for _,name in ipairs(rlist) do
      ok,err=io:rmdir(name)
      if not ok then tinsert(errList,sfmt("%s: %s",name,err)) end
   end
   if #errList == 0 then return true end
   return nil,table.concat(errList,"\n")
end

local function stripBasePath(basePath,fname)
   if #basePath == 0 then return fname end
   if fname == basePath then return "" end
   return fname:sub(#basePath+2)
end

local function copyFile(fromIo,fromName,toIo,toName)
   local source,err=fromIo:open(fromName,"rb")
   if not source then return nil,err end
   local target
   target,err=toIo:open(toName,"wb")
   if not target then source:close() return nil,err end
   local ok=true
   while true do
      local chunk,readErr=source:read(16384)
      if chunk and #chunk > 0 then
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
   if not ok then return nil,err end
   if sourceOk == false then return nil,sourceErr end
   if targetOk == false then return nil,targetErr end
   return true
end

local function copyDirContents(fromIo,basePath,toIo)
   local ok,err=true
   for path,name in recDirIter(fromIo,basePath,true) do
      if name then
	 local fromName=filePath(path,name)
	 local toName=stripBasePath(basePath,fromName)
	 ok,err=copyFile(fromIo,fromName,toIo,toName)
	 if not ok then err=sfmt("copy %s: %s",fromName,err) break end
      else
	 local toPath=stripBasePath(basePath,path)
	 if #toPath > 0 then
	    ok,err=mkdir(toIo,toPath)
	    if not ok then err=sfmt("mkdir %s: %s",path,err) break end
	 end
      end
   end
   if ok then return true end
   return nil,err
end

local Lab={}
Lab.__index=Lab

local function makeExecuteIo(name)
   if not xedge then return nil end
   local io=xedge.lio -- The execute 'xlua file' IO
   local function np(path) return "$"..name.."/"..path:gsub("^/+","") end
   return {
      open=function(self,path,mode) return io:open(np(path),mode) end,
      files=function(self,path) return io:files(np(path)) end,
      stat=function(self,path) return io:stat(np(path)) end,
      mkdir=function(self,path) return io:mkdir(np(path)) end,
      rmdir=function(self,path) return io:rmdir(np(path)) end,
      remove=function(self,path) return io:remove(np(path)) end
   }
end

local function newLab(info)
   return setmetatable({
      info=info,
      labn=info.name,
      backupn=info.name.."-backup",
      running=false,
      labIoExec=makeExecuteIo(info.name)
   },Lab)
end

function Lab:name()
   return self.labn
end

function Lab:metadata()
   local info=copyTable(self.info)
   info.running=self.running
   return info
end

function Lab:basePath()
   return self.info.basePath
end

function Lab:touch()
   self.info.updatedAt=os.time()
   self.info.running=self.running
   return saveRegistry()
end

function Lab:acquire(operation)
   if self.activeOperation then
      return nil,sfmt("lab %s is busy with %s",self.labn,self.activeOperation),"labBusy"
   end
   self.activeOperation=operation or "operation"
   return true
end

function Lab:release(operation)
   if not operation or self.activeOperation == operation then self.activeOperation=nil end
end

function Lab:busy()
   return self.activeOperation
end

function Lab:exclusive(operation,fn)
   local ok,err,code=self:acquire(operation)
   if not ok then return nil,err,code end
   local called,a,b,c,d=pcall(fn)
   self:release(operation)
   if not called then return nil,tostring(a),"labOperationFailed" end
   return a,b,c,d
end

function Lab:cleanupStages()
   if self.stageRecoveryComplete then return true end
   local prefix=self.labn.."-stage-"
   for name,isdir in bio:files("",true) do
      if isdir and name:sub(1,#prefix) == prefix then
         local stageIo,err=ba.mkio(bio,name)
         if not stageIo then return nil,err end
         local ok
         ok,err=removeAll(stageIo)
         if ok then ok,err=bio:rmdir(name) end
         if not ok then return nil,sfmt("Cannot remove stale staging directory %s: %s",name,err or "?") end
      end
   end
   self.stageRecoveryComplete=true
   return true
end

function Lab:create()
   if self.labIo then return self.labIo end
   local ok,err=self:cleanupStages()
   if not ok then return nil,err end
   self.backupIo,err=mkio(bio,self.backupn)
   if self.backupIo then
      self.labIo,err=mkio(bio,self.labn)
      if self.labIo then
         self:touch()
         return true
      end
   end
   return nil,err
end

function Lab:getLabIo()
   return self.labIo,self.labIoExec
end

function Lab:start()
   local ok,err=self:create()
   if not ok then return nil,err end
   if self.running then return nil,"already running" end
   if xedge then
      ok,err=xedge.auxapp(self.labn,self.labIo,{dirname=self.info.basePath})
   else
      self.makoAppEnv,err=mako.createapp(self.info.basePath,1,self.labIo)
      ok=self.makoAppEnv and true or nil
   end
   if ok then
      self.running=true
      self:touch()
      return true
   end
   return nil,err
end

function Lab:stop()
   if not self.running then return nil,"not running" end
   local ok,err
   if xedge then
      ok,err=xedge.auxapp(self.labn,self.labIo,{running=false})
   else
      ok,err=mako.stopapp(self.makoAppEnv)
      mako.removeapp(self.makoAppEnv)
      self.makoAppEnv=nil
   end
   self.running=false
   self:touch()
   return ok,err
end

function Lab:isRunning()
   return self.running
end

function Lab:rmlab()
   if not self.labIo then return nil,"lab not created" end
   local ok,err=removeAll(self.labIo)
   if ok then self:touch() end
   return ok,err
end

local function copyDir(fromIo,basePath,toIo,copy,baseLen,lab)
   local ok,err=true
   for path,name in recDirIter(fromIo,basePath,true) do
      if name then
	 local fname=filePath(path,name)
	 if copy then
	    ok,err=copyFile(fromIo,fname,toIo,fname)
	    if not ok then err=sfmt("copy %s: %s",fname,err) break end
	 else
	    local from=fromIo:realpath(fname):sub(baseLen)
	    local to=toIo:realpath(fname):sub(baseLen)
	    ok,err=bio:rename(from,to)
	    if not ok then err=sfmt("move %s: %s",fname,err) break end
	 end
      else
	 ok,err=mkdir(toIo,path)
	 if not ok then err=sfmt("mkdir %s: %s",path,err) break end
      end
   end
   if ok and not copy then ok,err=removeAll(lab.labIo) end
   if ok then return true end
   return nil,err
end

local function createStageIo(name)
   for i=1,1000 do
      local stageName=sfmt("%s-stage-%d-%d",name,os.time(),i)
      if not bio:stat(stageName) then
         local stageIo,err=mkio(bio,stageName)
         return stageIo,stageName,err
      end
   end
   return nil,nil,"Cannot create unique staging directory"
end

local function removeStage(stageIo,stageName)
   if stageIo then removeAll(stageIo) end
   if stageName then bio:rmdir(stageName) end
end

function Lab:createStageIo()
   return createStageIo(self.labn)
end

function Lab:removeStage(stageIo,stageName)
   return removeStage(stageIo,stageName)
end

-- Replace the stopped lab with a fully prepared sibling staging directory.
-- The directory renames keep the old lab available for rollback until the new
-- directory has taken its place. The caller owns validation and the lab lock.
function Lab:replaceWithStage(stageIo,stageName)
   if self.running then return nil,"lab must be stopped before import","labMustBeStopped" end
   if not stageIo or type(stageName) ~= "string" or not bio:stat(stageName) then
      return nil,"prepared staging directory is unavailable","invalidLabStage"
   end
   local ok,err=self:create()
   if not ok then return nil,err end
   local oldName
   for i=1,1000 do
      local candidate=sfmt("%s-stage-old-%d-%d",self.labn,os.time(),i)
      if not bio:stat(candidate) then oldName=candidate break end
   end
   if not oldName then return nil,"Cannot create unique rollback directory" end

   self.labIo=nil
   ok,err=bio:rename(self.labn,oldName)
   if not ok then
      self.labIo=ba.mkio(bio,self.labn)
      return nil,sfmt("Cannot stage existing lab %s: %s",self.labn,err or "?")
   end
   ok,err=bio:rename(stageName,self.labn)
   if not ok then
      local rollbackOk,rollbackErr=bio:rename(oldName,self.labn)
      self.labIo=ba.mkio(bio,self.labn)
      if not rollbackOk then
         return nil,sfmt("Cannot install imported lab (%s) and rollback failed (%s)",err or "?",rollbackErr or "?")
      end
      return nil,sfmt("Cannot install imported lab: %s",err or "?")
   end

   self.labIo,err=ba.mkio(bio,self.labn)
   if not self.labIo then
      bio:rename(self.labn,stageName)
      bio:rename(oldName,self.labn)
      self.labIo=ba.mkio(bio,self.labn)
      return nil,sfmt("Cannot open imported lab: %s",err or "?")
   end
   local oldIo=ba.mkio(bio,oldName)
   local cleanupOk,cleanupErr=true
   if oldIo then cleanupOk,cleanupErr=removeAll(oldIo) end
   if cleanupOk then cleanupOk,cleanupErr=bio:rmdir(oldName) end
   self:touch()
   return true,cleanupOk and nil or sfmt("Imported lab is active, but rollback cleanup failed: %s",cleanupErr or "?")
end

function Lab:backup(name,copy)
   if not self.labIo then return nil,"lab not created" end
   if self.backupIo:stat(name) then
      return nil,sfmt("backup %s already exists",name),"backupAlreadyExists"
   end
   local toIo,err=mkio(self.backupIo,name)
   if not toIo then return nil,err end
   local ok
   ok,err=copyDir(self.labIo,"",toIo,copy,#bio:realpath""+1,self)
   if ok then self:touch() end
   return ok,err
end

function Lab:listBackups()
   if not self.backupIo then return nil,"backup storage not created" end
   local backups={}
   for name,isdir in self.backupIo:files("",true) do
      if isdir and name ~= "." and name ~= ".." then tinsert(backups,name) end
   end
   table.sort(backups)
   return backups
end

function Lab:restore(name)
   if not self.labIo then return nil,"lab not created" end
   if not self.backupIo then return nil,"backup storage not created" end
   local st=self.backupIo:stat(name)
   if not st then return nil,sfmt("backup %s not found",name) end
   if not st.isdir then return nil,sfmt("backup %s is not a directory",name) end
   local stageIo,stageName,err=self:createStageIo()
   if not stageIo then return nil,err end
   local ok
   ok,err=copyDirContents(self.backupIo,name,stageIo)
   if not ok then self:removeStage(stageIo,stageName) return nil,err end
   ok,err=removeAll(self.labIo)
   if not ok then self:removeStage(stageIo,stageName) return nil,err end
   ok,err=copyDirContents(stageIo,"",self.labIo)
   self:removeStage(stageIo,stageName)
   if ok then self:touch() end
   return ok,err
end

function Lab:copy2lab(sourceIo,path)
   if not self.labIo then return nil,"lab not created" end
   local st,err=sourceIo:stat(path)
   if not st then return nil,sfmt("stat %s: %s",path,err) end
   if not st.isdir then return nil,sfmt("%s not a directory",path) end
   local stageIo,stageName
   stageIo,stageName,err=self:createStageIo()
   if not stageIo then return nil,err end
   local ok
   ok,err=copyDirContents(sourceIo,path,stageIo)
   if not ok then self:removeStage(stageIo,stageName) return nil,err end
   ok,err=removeAll(self.labIo)
   if not ok then self:removeStage(stageIo,stageName) return nil,err end
   ok,err=copyDirContents(stageIo,"",self.labIo)
   self:removeStage(stageIo,stageName)
   if ok then self:touch() end
   return ok,err
end

local function guardLabMethod(name)
   local implementation=Lab[name]
   Lab[name]=function(self,...)
      local a,b,c,d=...
      return self:exclusive(name,function() return implementation(self,a,b,c,d) end)
   end
end

for _,name in ipairs{"start","stop","rmlab","backup","restore","copy2lab"} do guardLabMethod(name) end

local objects={}

local function objectFor(info)
   local lab=objects[info.name]
   if not lab then lab=newLab(info) objects[info.name]=lab end
   return lab
end

local function addLab(name,basePath,basePathExplicitOverride)
   local ok,err=loadRegistry()
   if not ok then return nil,err end
   name,err=validateLabName(name)
   if not name then return nil,err,"invalidLabName" end
   local key=name:lower()
   if labsByKey[key] then return nil,"lab "..name.." already exists","labAlreadyExists" end
   local basePathExplicit=basePathExplicitOverride
   if basePathExplicit == nil then basePathExplicit=basePath ~= nil end
   local requestedPath=basePath
   if requestedPath == nil then requestedPath=#registry.labs == 0 and "" or name end
   local normalizedPath
   normalizedPath,err=validateBasePath(requestedPath)
   if not normalizedPath then return nil,err,"invalidLabBasePath" end
   local pathKey=normalizedPath:lower()
   for _,info in ipairs(registry.labs) do
      if info.basePath:lower() == pathKey then
         return nil,"base path "..normalizedPath.." is already used by lab "..info.name,"labBasePathAlreadyExists"
      end
   end
   local now=os.time()
   local info=newLabInfo(name,normalizedPath,now,basePathExplicit)
   tinsert(registry.labs,info)
   table.sort(registry.labs,function(a,b) return a.name:lower() < b.name:lower() end)
   indexRegistry()
   ok,err=saveRegistry()
   if not ok then
      for i,item in ipairs(registry.labs) do if item == info then table.remove(registry.labs,i) break end end
      indexRegistry()
      return nil,err
   end
   local lab=objectFor(info)
   ok,err=lab:create()
   if ok then return lab end
   for i,item in ipairs(registry.labs) do
      if item == info then table.remove(registry.labs,i) break end
   end
   objects[info.name]=nil
   indexRegistry()
   saveRegistry()
   bio:rmdir(info.name.."-backup")
   return nil,err
end

local function getLab(name)
   local ok,err=loadRegistry()
   if not ok then return nil,err end
   local valid
   valid,err=validateLabName(name)
   if not valid then return nil,err,"invalidLabName" end
   local info=labsByKey[valid:lower()]
   if not info then return nil,"unknown lab "..valid,"unknownLab" end
   return objectFor(info)
end

local function defaultLab(createIfMissing)
   local lab,err,code=getLab(legacyLabName)
   if lab or not createIfMissing or code ~= "unknownLab" then return lab,err,code end
   return addLab(legacyLabName,"",false)
end

local appmgr={filePath=filePath,recDirIter=recDirIter}

function appmgr.validateLabName(name)
   return validateLabName(name)
end

function appmgr.registryFile()
   return registryFile
end

function appmgr.createStageIo(labName)
   local valid,err=validateLabName(labName)
   if not valid then return nil,nil,err end
   return createStageIo(valid)
end

function appmgr.removeStage(stageIo,stageName)
   return removeStage(stageIo,stageName)
end

function appmgr.listLabs()
   local ok,err=loadRegistry()
   if not ok then return nil,err end
   local list={}
   for _,info in ipairs(registry.labs) do
      local lab=objects[info.name]
      local copy=copyTable(info)
      copy.running=lab and lab.running or false
      tinsert(list,copy)
   end
   return list
end

function appmgr.getLab(name)
   return getLab(name)
end

function appmgr.createLab(name,basePath)
   local ok,err=loadRegistry()
   if not ok then return nil,err end
   local routeChanged
   if #registry.labs == 1 and registry.labs[1].basePath == "" and registry.labs[1].basePathExplicit ~= true then
      local existing=objectFor(registry.labs[1])
      if existing:isRunning() then
         return nil,"lab "..existing:name().." must be stopped before another lab is created","labMustBeStopped"
      end
      local changed,changeErr,changeCode=appmgr.setLabBasePath(existing:name(),existing:name(),false)
      if not changed then return nil,changeErr,changeCode end
      routeChanged={labName=existing:name(),oldBasePath="",newBasePath=existing:name()}
   end
   local lab,createErr,createCode=addLab(name,basePath)
   if lab then return lab,nil,nil,routeChanged end
   if routeChanged then appmgr.setLabBasePath(routeChanged.labName,"",false) end
   return nil,createErr,createCode
end

local function routeOwner(basePath,exceptInfo)
   local key=basePath:lower()
   for _,info in ipairs(registry.labs) do
      if info ~= exceptInfo and info.basePath:lower() == key then return info end
   end
end

function appmgr.setLabBasePath(name,basePath,basePathExplicit)
   local lab,err,code=getLab(name)
   if not lab then return nil,err,code end
   if lab:isRunning() then return nil,"lab "..lab:name().." must be stopped before changing its base path","labMustBeStopped" end
   local normalized
   normalized,err=validateBasePath(basePath)
   if not normalized then return nil,err,"invalidLabBasePath" end
   local owner=routeOwner(normalized,lab.info)
   if owner then return nil,"base path "..normalized.." is already used by lab "..owner.name,"labBasePathAlreadyExists" end
   local oldPath,oldExplicit=lab.info.basePath,lab.info.basePathExplicit
   lab.info.basePath=normalized
   lab.info.basePathExplicit=basePathExplicit ~= false
   lab.info.updatedAt=os.time()
   local ok
   ok,err=saveRegistry()
   if ok then return lab end
   lab.info.basePath,lab.info.basePathExplicit=oldPath,oldExplicit
   return nil,err
end

function appmgr.renameLab(name,newName)
   local lab,err,code=getLab(name)
   if not lab then return nil,err,code end
   if lab:isRunning() then return nil,"lab "..lab:name().." must be stopped before it is renamed","labMustBeStopped" end
   newName,err=validateLabName(newName)
   if not newName then return nil,err,"invalidLabName" end
   if labsByKey[newName:lower()] then return nil,"lab "..newName.." already exists","labAlreadyExists" end
   local ok
   ok,err=lab:create()
   if not ok then return nil,err end

   local oldName,oldBackup=lab.labn,lab.backupn
   local newBackup=newName.."-backup"
   local oldPath=lab.info.basePath
   local newPath=oldPath
   if not lab.info.basePathExplicit and oldPath:lower() == oldName:lower() then newPath=newName end
   local owner=routeOwner(newPath,lab.info)
   if owner then return nil,"base path "..newPath.." is already used by lab "..owner.name,"labBasePathAlreadyExists" end

   ok,err=bio:rename(oldBackup,newBackup)
   if not ok then return nil,sfmt("Cannot rename %s to %s: %s",oldBackup,newBackup,err or "?") end
   ok,err=bio:rename(oldName,newName)
   if not ok then
      bio:rename(newBackup,oldBackup)
      return nil,sfmt("Cannot rename %s to %s: %s",oldName,newName,err or "?")
   end

   local info=lab.info
   info.name=newName
   info.basePath=newPath
   info.updatedAt=os.time()
   lab.labn=newName
   lab.backupn=newBackup
   lab.labIo=ba.mkio(bio,newName)
   lab.backupIo=ba.mkio(bio,newBackup)
   lab.labIoExec=makeExecuteIo(newName)
   objects[oldName]=nil
   objects[newName]=lab
   indexRegistry()
   ok,err=saveRegistry()
   if ok then return lab end

   bio:rename(newName,oldName)
   bio:rename(newBackup,oldBackup)
   info.name=oldName
   info.basePath=oldPath
   lab.labn=oldName
   lab.backupn=oldBackup
   lab.labIo=ba.mkio(bio,oldName)
   lab.backupIo=ba.mkio(bio,oldBackup)
   lab.labIoExec=makeExecuteIo(oldName)
   objects[newName]=nil
   objects[oldName]=lab
   indexRegistry()
   return nil,err
end

function appmgr.deleteLab(name)
   local lab,err,code=getLab(name)
   if not lab then return nil,err,code end
   if lab:isRunning() then return nil,"lab "..lab:name().." must be stopped before it is deleted","labMustBeStopped" end
   local ok
   ok,err=lab:create()
   if not ok then return nil,err end
   ok,err=removeAll(lab.labIo)
   if not ok then return nil,err end
   ok,err=removeAll(lab.backupIo)
   if not ok then return nil,err end
   ok,err=bio:rmdir(lab.labn)
   if not ok then return nil,sfmt("Cannot remove lab directory %s: %s",lab.labn,err or "?") end
   ok,err=bio:rmdir(lab.backupn)
   if not ok then return nil,sfmt("Cannot remove backup directory %s: %s",lab.backupn,err or "?") end
   for i,info in ipairs(registry.labs) do
      if info == lab.info then table.remove(registry.labs,i) break end
   end
   if registry.migration and registry.migration.legacyLabName == lab:name() then
      registry.migration.legacyDeletedAt=os.time()
   end
   objects[lab:name()]=nil
   indexRegistry()
   ok,err=saveRegistry()
   if ok then return true end
   return nil,err
end

local function guardManagerLabMethod(name)
   local implementation=appmgr[name]
   appmgr[name]=function(labName,...)
      local lab,err,code=getLab(labName)
      if not lab then return nil,err,code end
      local a,b,c,d=...
      return lab:exclusive(name,function() return implementation(labName,a,b,c,d) end)
   end
end

for _,name in ipairs{"setLabBasePath","renameLab","deleteLab"} do guardManagerLabMethod(name) end

-- Compatibility API: existing callers may continue to operate on lsplab.
function appmgr.create()
   local lab,err=defaultLab(true)
   if not lab then return nil,err end
   return lab:create()
end

function appmgr.name()
   return legacyLabName
end

function appmgr.getLabIo()
   local lab=defaultLab(false)
   if not lab then return nil end
   return lab:getLabIo()
end

function appmgr.start()
   local lab,err=defaultLab(true)
   if not lab then return nil,err end
   return lab:start()
end

function appmgr.stop()
   local lab,err=defaultLab(false)
   if not lab then return nil,err end
   return lab:stop()
end

function appmgr.running()
   local lab=defaultLab(false)
   return lab and lab:isRunning() or false
end

function appmgr.backup(name,copy)
   local lab,err=defaultLab(false)
   if not lab then return nil,err end
   return lab:backup(name,copy)
end

function appmgr.listBackups()
   local lab,err=defaultLab(false)
   if not lab then return nil,err end
   return lab:listBackups()
end

function appmgr.restore(name)
   local lab,err=defaultLab(false)
   if not lab then return nil,err end
   return lab:restore(name)
end

function appmgr.rmlab()
   local lab,err=defaultLab(false)
   if not lab then return nil,err end
   return lab:rmlab()
end

function appmgr.copy2lab(sourceIo,path)
   local lab,err=defaultLab(false)
   if not lab then return nil,err end
   return lab:copy2lab(sourceIo,path)
end

return appmgr
