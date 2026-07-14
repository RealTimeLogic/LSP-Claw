-- Derived from opcua-model-builder/.lua/zip_writer.lua.
-- Emits bounded classic ZIP32 archives using method 0 (stored/uncompressed).
local M={}

local function makeBitOps()
   local native=load([[
return {
  bxor=function(a,b) return (a ~ b) & 0xffffffff end,
  rshift=function(a,n) return (a >> n) & 0xffffffff end
}
]])
   if native then
      local ok,ops=pcall(native)
      if ok and ops then return ops end
   end
   if bit32 and bit32.bxor and bit32.rshift then return bit32 end
   if bit and bit.bxor and bit.rshift then return bit end
   local function bxor(a,b)
      local result,bitValue=0,1
      a,b=a%0x100000000,b%0x100000000
      for _=1,32 do
         if a%2 ~= b%2 then result=result+bitValue end
         a,b=math.floor(a/2),math.floor(b/2)
         bitValue=bitValue*2
      end
      return result
   end
   return {bxor=bxor,rshift=function(a,n) return math.floor((a%0x100000000)/(2^n)) end}
end

local bit=makeBitOps()
local function u16(value)
   value=value%0x10000
   return string.char(value%0x100,math.floor(value/0x100)%0x100)
end
local function u32(value)
   value=value%0x100000000
   return string.char(value%0x100,math.floor(value/0x100)%0x100,
      math.floor(value/0x10000)%0x100,math.floor(value/0x1000000)%0x100)
end

local crcTable
local function buildCrcTable()
   local table32={}
   for index=0,255 do
      local crc=index
      for _=1,8 do
         crc=crc%2 == 1 and bit.bxor(bit.rshift(crc,1),0xEDB88320) or bit.rshift(crc,1)
      end
      table32[index]=crc
   end
   return table32
end

local function crcUpdate(crc,data)
   crcTable=crcTable or buildCrcTable()
   for index=1,#data do
      local byte=string.byte(data,index)
      crc=bit.bxor(bit.rshift(crc,8),crcTable[bit.bxor(crc,byte)%256])
   end
   return crc
end

local function crc32(data)
   return bit.bxor(crcUpdate(0xFFFFFFFF,data),0xFFFFFFFF)%0x100000000
end

local function normalizedPath(path,directory)
   path=tostring(path or ""):gsub("\\","/")
   assert(not path:find("%z"),"ZIP entry path must not contain NUL bytes")
   assert(not path:match("^/"),"ZIP entry path must be relative")
   assert(not path:match("^[A-Za-z]:"),"ZIP entry path must not contain a drive prefix")
   assert(not path:match("^//"),"ZIP entry path must not contain a UNC prefix")
   directory=directory == true or path:sub(-1) == "/"
   path=path:gsub("/+$","")
   assert(path ~= "","ZIP entry path is required")
   local depth=0
   for part in path:gmatch("[^/]+") do
      assert(part ~= "..","ZIP entry path must not contain a parent segment")
      assert(part ~= ".","ZIP entry path must not contain a current-directory segment")
      assert(part ~= "","ZIP entry path must not contain an empty segment")
      depth=depth+1
   end
   return path,directory,depth
end

local function sortedEntries(files,options)
   local sorted,seen={},{}
   local maxEntries=options.maxEntries or 4096
   assert(#(files or {}) <= maxEntries,"ZIP entry count exceeds limit of "..maxEntries)
   for _,file in ipairs(files or {}) do
      local path,directory,depth=normalizedPath(file.path,file.directory)
      assert(depth <= (options.maxDepth or 32),"ZIP entry nesting exceeds configured limit: "..path)
      local key=path:lower()
      assert(not seen[key],"duplicate ZIP entry path: "..path)
      seen[key]=true
      sorted[#sorted+1]={
         path=path,
         directory=directory,
         content=file.content,
         producer=file.producer,
         source=file.source
      }
   end
   table.sort(sorted,function(a,b) return a.path < b.path end)
   return sorted
end

local function emitEntry(entry,output)
   if entry.directory then return end
   if type(entry.producer) == "function" then return entry.producer(output) end
   if type(entry.source) == "table" then
      local source,err=entry.source.io:open(entry.source.path,"rb")
      assert(source,"cannot open ZIP source "..tostring(entry.source.path)..": "..tostring(err))
      while true do
         local chunk=source:read(16384)
         if not chunk or #chunk == 0 then break end
         output(chunk)
      end
      local ok,closeErr=source:close()
      assert(ok,"cannot close ZIP source: "..tostring(closeErr))
      return
   end
   output(tostring(entry.content or ""))
end

local function measure(entry,maxEntryBytes)
   local crc,size=0xFFFFFFFF,0
   emitEntry(entry,function(chunk)
      assert(type(chunk) == "string","ZIP producer must emit string chunks")
      size=size+#chunk
      assert(size <= maxEntryBytes,"ZIP entry exceeds size limit: "..entry.path)
      crc=crcUpdate(crc,chunk)
   end)
   return bit.bxor(crc,0xFFFFFFFF)%0x100000000,size
end

local function writeInternal(files,output,options)
   assert(type(output) == "function","ZIP output callback is required")
   options=options or {}
   local maxEntryBytes=options.maxEntryBytes or 64*1024*1024
   local maxArchiveBytes=options.maxArchiveBytes or 64*1024*1024
   local central,offset,total={},0,0
   local function emit(data)
      total=total+#data
      assert(total <= maxArchiveBytes,"ZIP archive exceeds size limit of "..maxArchiveBytes.." bytes")
      local ok,err=output(data)
      assert(ok ~= false,"ZIP output failed: "..tostring(err))
   end

   local entries=sortedEntries(files,options)
   assert(#entries <= 65535,"ZIP32 entry limit exceeded")
   for _,entry in ipairs(entries) do
      local name=entry.path..(entry.directory and "/" or "")
      assert(#name <= 65535,"ZIP entry name is too long")
      local crc,size=measure(entry,maxEntryBytes)
      assert(size < 0x100000000 and offset < 0x100000000,"ZIP32 size or offset limit exceeded")
      local header=table.concat({
         u32(0x04034B50),u16(20),u16(0),u16(0),u16(0),u16(0),
         u32(crc),u32(size),u32(size),u16(#name),u16(0),name
      })
      emit(header)
      local emittedCrc,emittedSize=0xFFFFFFFF,0
      emitEntry(entry,function(chunk)
         assert(type(chunk) == "string","ZIP producer must emit string chunks")
         emittedCrc=crcUpdate(emittedCrc,chunk)
         emittedSize=emittedSize+#chunk
         emit(chunk)
      end)
      emittedCrc=bit.bxor(emittedCrc,0xFFFFFFFF)%0x100000000
      assert(emittedSize == size and emittedCrc == crc,"ZIP entry changed between reads: "..name)
      central[#central+1]=table.concat({
         u32(0x02014B50),u16(20),u16(20),u16(0),u16(0),u16(0),u16(0),
         u32(crc),u32(size),u32(size),u16(#name),u16(0),u16(0),u16(0),u16(0),
         u32(entry.directory and 0x10 or 0),u32(offset),name
      })
      offset=offset+#header+size
   end
   local centralBody=table.concat(central)
   emit(centralBody)
   emit(table.concat({
      u32(0x06054B50),u16(0),u16(0),u16(#central),u16(#central),
      u32(#centralBody),u32(offset),u16(0)
   }))
   return {entryCount=#entries,size=total,stored=true,zip64=false}
end

function M.write(files,output,options)
   local ok,result=pcall(writeInternal,files,output,options)
   if ok then return result end
   return nil,tostring(result)
end

function M.encode(files,options)
   local chunks={}
   local info,err=M.write(files,function(chunk) chunks[#chunks+1]=chunk return true end,options)
   if not info then return nil,err end
   return table.concat(chunks),info
end

M._crc32=crc32
M._normalizePath=normalizedPath

return M
