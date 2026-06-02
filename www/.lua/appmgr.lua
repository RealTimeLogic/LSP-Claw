local labn="lsplab"
local backupn=labn.."-backup"
local bio=ba.openio("home") or ba.openio("disk") -- Base IO
local running,labIo,labIoExec,backupIo,err,makoAppEnv=false
local sfmt=string.format
local tinsert=table.insert
local rw=require"rwfile"

if xedge then -- Create labIoExec
   local io=xedge.lio -- The execute 'xlua file' IO
   local function np(name) return "$"..labn.."/"..name:gsub("^/+", "") end
   labIoExec={
      open=function(self,name,mode) return io:open(np(name),mode) end,
      files=function(self,name) return io:files(np(name)) end,
      stat=function(self,name) return io:stat(np(name)) end,
      mkdir=function(self,name) return io:mkdir(np(name)) end,
      rmdir=function(self,name) return io:rmdir(np(name)) end,
      remove=function(self,name) return io:remove(np(name)) end
   }
end

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
   

local function createLab()
   local err
   if labIo then return labIo end
   backupIo,err=mkio(bio,backupn)
   if backupIo then
      labIo,err=mkio(bio,labn)
      if labIo then return true end
   end
   return nil,err
end

local start = xedge and
   function()
      return xedge.auxapp(labn, labIo, {dirname=""})
   end or
   function()
      makoAppEnv,err=mako.createapp("", 1, labIo)
      if makoAppEnv then return true end
      return nil,err
   end

local function notRunning() return nil, "not running" end

local appmgr={
   filePath=filePath,
   recDirIter=recDirIter,
   stop = xedge and
      function()
	 if running then running=false return xedge.auxapp(labn, labIo, {running=false}) end
	 return notRunning()
      end or
      function()
	 if running then
	    running=false
	    local ok,err=mako.stopapp(makoAppEnv)
	    mako.removeapp(makoAppEnv)
	    return ok,err
	 end
	 return notRunning()
      end
}

function appmgr.create()
   return createLab()
end

function appmgr.getLabIo() return labIo,labIoExec end

function appmgr.start()
   local ok,err=createLab()
   if ok then
      if running then return nil,"already running" end
      ok,err=start()
      if ok then
	 running=true
	 return true
      end
   end
   return nil,err
end

function appmgr.running() return running end

local function copyDir(fromIo, basePath, toIo, copy, baseLen)
   local x,err=true
   for path,name in recDirIter(fromIo,basePath,true) do
      if name then
	 local fname=filePath(path,name)
	 if copy then
	    x,err=rw.file(fromIo,fname)
	    if x then x,err=rw.file(toIo,fname,x) end
	    if not x then err=sfmt("copy %s: %s",fname,err) break end
	 else
	    local from=fromIo:realpath(fname):sub(baseLen)
	    local to=toIo:realpath(fname):sub(baseLen)
	    x,err=bio:rename(from,to)
	    if not x then err=sfmt("move %s: %s",fname,err) break end
	 end
      else -- dir
	 x,err=mkdir(toIo,path)
	 if not x then err=sfmt("mkdir %s: %s",path,err) break end
      end
   end
   if x and not copy then k,err=appmgr.rmlab() end
   if x then return true end
   return nil,err
end

local function stripBasePath(basePath, fname)
   if #basePath == 0 then return fname end
   if fname == basePath then return "" end
   return fname:sub(#basePath + 2)
end

local function copyDirContents(fromIo, basePath, toIo)
   local x,err=true
   for path,name in recDirIter(fromIo,basePath,true) do
      if name then
	 local fromName=filePath(path,name)
	 local toName=stripBasePath(basePath,fromName)
	 x,err=rw.file(fromIo,fromName)
	 if x then x,err=rw.file(toIo,toName,x) end
	 if not x then err=sfmt("copy %s: %s",fromName,err) break end
      else
	 local toPath=stripBasePath(basePath,path)
	 if #toPath > 0 then
	    x,err=mkdir(toIo,toPath)
	    if not x then err=sfmt("mkdir %s: %s",toPath,err) break end
	 end
      end
   end
   if x then return true end
   return nil,err
end


function appmgr.backup(name, copy)
   if not labIo then return nil,"lab not created" end
   local toIo,err=mkio(backupIo,name)
   if not toIo then return nil,err end
   return copyDir(labIo, "", toIo, copy, #bio:realpath""+1)
end

function appmgr.rmlab()
   local errList,ok,err={}
   if not labIo then return nil,"lab not created" end
   local list,rlist={},{}
   for path,name in recDirIter(labIo,"",true) do
      if name then
	 local fname=filePath(path,name)
	 ok,err=labIo:remove(fname)
	 if not ok then tinsert(errList,sfmt("%s: %s",fname,err)) end
      else
	 tinsert(list, path)
      end
   end
   for i = #list, 1, -1 do tinsert(rlist, list[i]) end
   list={}
   for _,n in ipairs(rlist) do
      ok,err=labIo:rmdir(n)
      if not ok then tinsert(errList,sfmt("%s: %s",n,err)) end
   end
   if 0 == #errList then return true end
   return nil,table.concat(errList,"\n")
end

function appmgr.copy2lab(ghio,path)
   if not labIo then return nil,"lab not created" end
   local st,err=ghio:stat(path)
   if not st then return nil,sfmt("stat %s: %s",path,err) end
   if not st.isdir then return nil,sfmt("%s not a directory",path) end
   return copyDirContents(ghio, path, labIo)
end

return appmgr
