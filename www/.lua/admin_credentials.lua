local rw=require"rwfile"

local M={}
local DATABASE_PATH="LSP-Claw-Admin.bin"
local KEY_NAME="LSP-Claw-Config-Admin"

local function secureEqual(a,b)
   a,b=tostring(a or ""),tostring(b or "")
   local length=math.max(#a,#b,32)
   local different=(#a == #b) and 0 or 1
   for index=1,length do
      if (a:byte(index) or 0) ~= (b:byte(index) or 0) then
         different=different+1
      end
   end
   return different == 0
end

function M.create(storeIo)
   assert(storeIo,"administrator storage IO is required")
   local tju=ba.tpm.jsonuser(KEY_NAME,false)
   if storeIo:stat(DATABASE_PATH) then
      local encrypted,readErr=rw.file(storeIo,DATABASE_PATH)
      if not encrypted then
         return nil,"cannot read browser administrator database: "..tostring(readErr or "unknown error")
      end
      local ok,loadErr=tju.setdb(encrypted)
      if not ok then
         return nil,"cannot load browser administrator database: "..tostring(loadErr or "invalid data")
      end
   end

   local self={}

   function self:users()
      return tju.users()
   end

   function self:configured()
      return #tju.users() > 0
   end

   function self:isAdministrator(username)
      if type(username) ~= "string" or username == "" then return false end
      for _,storedName in ipairs(tju.users()) do
         if storedName == username then return true end
      end
      return false
   end

   function self:authenticate(username,password)
      if type(username) ~= "string" or type(password) ~= "string" then return false end
      local storedPassword=tju.getauth():getpwd(username)
      if type(storedPassword) ~= "string" then return false end
      return secureEqual(storedPassword,password)
   end

   function self:create(username,password)
      if self:configured() then return nil,"a browser administrator already exists" end
      local callOk,encrypted=pcall(tju.setuser,username,password)
      if not callOk then return nil,"cannot create browser administrator: "..tostring(encrypted) end
      local saved,saveErr=rw.file(storeIo,DATABASE_PATH,encrypted)
      if not saved then
         tju=ba.tpm.jsonuser(KEY_NAME,false)
         return nil,"cannot save browser administrator database: "..tostring(saveErr or "unknown error")
      end
      return true
   end

   function self:clear()
      if storeIo:stat(DATABASE_PATH) then
         local ok,removeErr=storeIo:remove(DATABASE_PATH)
         if not ok then
            return nil,"cannot remove browser administrator database: "..tostring(removeErr or "unknown error")
         end
      end
      tju=ba.tpm.jsonuser(KEY_NAME,false)
      return true
   end

   return self
end

return M
