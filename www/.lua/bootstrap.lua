local M={}

local ARGUMENTS={
   ["-credentials"]="credentials",
   ["-credentials-file"]="credentialsFile",
   ["-token"]="token",
   ["-token-file"]="tokenFile"
}

local function bootstrapRequested(argv)
   for _,value in ipairs(argv) do
      if ARGUMENTS[value] then return true end
   end
   return false
end

local function arguments(argv)
   local result={}
   local index=1
   while index <= #argv do
      local option=argv[index]
      local field=ARGUMENTS[option]
      if field then
         if result[field] ~= nil then
            error("Duplicate LSP-Claw bootstrap option: "..option,2)
         end
         local value=argv[index+1]
         if type(value) ~= "string" or value == "" or value:sub(1,1) == "-" then
            error("LSP-Claw bootstrap option "..option.." requires a value",2)
         end
         result[field]=value
         index=index+2
      else
         index=index+1
      end
   end
   if result.credentials and result.credentialsFile then
      error("Use either -credentials or -credentials-file, not both",2)
   end
   if result.token and result.tokenFile then
      error("Use either -token or -token-file, not both",2)
   end
   return result
end

local function readSecret(path,label)
   local fp,openErr=_G.io.open(path,"rb")
   if not fp then
      error("Cannot read LSP-Claw "..label.." file "..path..": "..tostring(openErr),2)
   end
   local value,readErr=fp:read("*a")
   fp:close()
   if not value then
      error("Cannot read LSP-Claw "..label.." file "..path..": "..tostring(readErr),2)
   end
   if #value > 8192 then error("LSP-Claw "..label.." file is too large",2) end
   if value:byte(1) == 0xEF and value:byte(2) == 0xBB and value:byte(3) == 0xBF then
      value=value:sub(4)
   end
   value=value:gsub("[\r\n]+$","")
   if value:find("[\r\n]") then
      error("LSP-Claw "..label.." file must contain one line",2)
   end
   return value
end

local function parseCredentials(value)
   local separator=value:find(":",1,true)
   if not separator then
      error("LSP-Claw bootstrap credentials must use username:password",2)
   end
   local username=value:sub(1,separator-1)
   local password=value:sub(separator+1)
   if username == "" or password == "" then
      error("LSP-Claw bootstrap username and password must not be empty",2)
   end
   return username,password
end

function M.run(options)
   local argv=options.argv or {}
   if not bootstrapRequested(argv) then return false end

   if options.admin:configured() then
      trace("LSP-Claw command-line bootstrap ignored: an administrator already exists")
      return false
   end
   local parsed=arguments(argv)
   if not parsed.credentials and not parsed.credentialsFile then
      error("LSP-Claw command-line bootstrap requires -credentials or -credentials-file",2)
   end

   local credentialValue=parsed.credentials or readSecret(parsed.credentialsFile,"credentials")
   local username,password=parseCredentials(credentialValue)
   local token=parsed.token or (parsed.tokenFile and readSecret(parsed.tokenFile,"token"))
   if token then
      local valid,validationErr=options.validateToken(token)
      if not valid then error(validationErr,2) end
      token=valid
   end

   local created,createErr=options.admin:create(username,password)
   if not created then error("LSP-Claw administrator bootstrap failed: "..tostring(createErr),2) end

   if token then
      local callOk,saved,saveErr=pcall(options.saveToken,token)
      if not callOk or not saved then
         local rollbackOk,rollbackErr=options.admin:clear()
         local detail=callOk and saveErr or saved
         if not rollbackOk then
            detail=tostring(detail).."; administrator rollback failed: "..tostring(rollbackErr)
         end
         error("LSP-Claw MCP token bootstrap failed: "..tostring(detail or "unknown error"),2)
      end
   end

   trace("LSP-Claw command-line bootstrap created the first browser administrator")
   if token then trace("LSP-Claw command-line bootstrap enabled MCP authentication") end
   return true
end

return M
