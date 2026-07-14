local Schema = {}

local supported = {
   type=true, properties=true, required=true, additionalProperties=true,
   default=true, enum=true, items=true, minimum=true, maximum=true,
   minLength=true, maxLength=true, description=true, title=true
}

local function clone(value, seen)
   if type(value) ~= "table" then return value end
   seen = seen or {}
   if seen[value] then error("cyclic value") end
   seen[value] = true
   local out = {}
   for k, v in pairs(value) do out[clone(k, seen)] = clone(v, seen) end
   seen[value] = nil
   return out
end

local function valueType(value)
   if value == nil or (ba and ba.json and value == ba.json.null) then return "null" end
   local t = type(value)
   if t == "number" and value % 1 == 0 then return "integer" end
   return t
end

local function tableShape(value)
   local hasArrayKeys = false
   local hasObjectKeys = false
   local maxIndex = 0
   local arrayKeyCount = 0
   for key in pairs(value) do
      if key ~= "fastmcpType" then
         if type(key) == "number" and key >= 1 and key % 1 == 0 then
            hasArrayKeys = true
            arrayKeyCount = arrayKeyCount + 1
            if key > maxIndex then maxIndex = key end
         elseif type(key) == "string" then
            hasObjectKeys = true
         else
            return "invalid"
         end
      end
   end
   if hasArrayKeys and hasObjectKeys then return "mixed" end
   if hasObjectKeys then return "object" end
   if not hasArrayKeys then return "empty" end
   if arrayKeyCount ~= maxIndex then return "sparse" end
   return "array"
end

local function failure(path, code, message, expected, value)
   return nil, {
      code = code,
      field = path ~= "" and path or "$",
      message = message,
      expected = expected,
      received = valueType(value)
   }
end

local function same(a, b)
   if type(a) ~= type(b) then return false end
   if type(a) ~= "table" then return a == b end
   for k, v in pairs(a) do if not same(v, b[k]) then return false end end
   for k in pairs(b) do if a[k] == nil then return false end end
   return true
end

local validate
validate = function(schema, value, path, strict)
   if type(schema) ~= "table" then
      return failure(path, "invalidSchema", "Schema must be an object", "object", schema)
   end
   if value == nil and schema.default ~= nil then value = clone(schema.default) end
   local expected = schema.type
   local actual = valueType(value)
   local shape = actual == "table" and tableShape(value) or nil
   if expected then
      local matches = actual == expected or (expected == "number" and actual == "integer")
      if actual == "table" and expected == "object" then
         matches = shape == "object" or shape == "empty"
      elseif actual == "table" and expected == "array" then
         matches = shape == "array" or shape == "empty"
      end
      if not matches then
         return failure(path, "type", "Value has the wrong type", expected, value)
      end
   end
   if actual == "table" and not expected then
      if schema.properties and shape ~= "object" and shape ~= "empty" then
         return failure(path, "type", "Value has the wrong type", "object", value)
      elseif schema.items and shape ~= "array" and shape ~= "empty" then
         return failure(path, "type", "Value has the wrong type", "array", value)
      end
   end
   if schema.enum then
      local found = false
      for _, allowed in ipairs(schema.enum) do if same(value, allowed) then found = true; break end end
      if not found then return failure(path, "enum", "Value is not in the allowed set", "enum", value) end
   end
   if type(value) == "number" then
      if schema.minimum ~= nil and value < schema.minimum then return failure(path, "minimum", "Value is below minimum", schema.minimum, value) end
      if schema.maximum ~= nil and value > schema.maximum then return failure(path, "maximum", "Value is above maximum", schema.maximum, value) end
   elseif type(value) == "string" then
      if schema.minLength ~= nil and #value < schema.minLength then return failure(path, "minLength", "String is too short", schema.minLength, value) end
      if schema.maxLength ~= nil and #value > schema.maxLength then return failure(path, "maxLength", "String is too long", schema.maxLength, value) end
   elseif type(value) == "table" and (expected == "array" or schema.items) then
      local out = {}
      for i, item in ipairs(value) do
         local checked, err = validate(schema.items or {}, item, path .. "[" .. i .. "]", strict)
         if not checked and err then return nil, err end
         out[i] = checked
      end
      return out
   elseif type(value) == "table" and (expected == "object" or schema.properties) then
      local out, props = {}, schema.properties or {}
      local required = {}
      for _, name in ipairs(schema.required or {}) do required[name] = true end
      for name, propSchema in pairs(props) do
         local fieldPath = path == "" and name or path .. "." .. name
         if value[name] ~= nil or propSchema.default ~= nil then
            local checked, err = validate(propSchema, value[name], fieldPath, strict)
            if err then return nil, err end
            if checked ~= nil then out[name] = checked end
         elseif required[name] then
            return failure(fieldPath, "required", "Required value is missing", "present", nil)
         end
      end
      for _, name in ipairs(schema.required or {}) do
         if value[name] == nil and props[name] == nil then
            return failure(path == "" and name or path .. "." .. name, "required", "Required value is missing", "present", nil)
         end
      end
      for name, item in pairs(value) do
         if props[name] == nil then
            if strict and schema.additionalProperties == false then
               return failure(path == "" and tostring(name) or path .. "." .. tostring(name), "additionalProperties", "Unknown field", "declared property", item)
            end
            out[name] = clone(item)
         end
      end
      return out
   end
   return clone(value)
end

function Schema.validate(schema, value, options)
   return validate(schema or {}, value, "", not options or options.strict ~= false)
end

function Schema.check(schema, path)
   path = path or "$"
   if type(schema) ~= "table" then return nil, path .. " must be a table" end
   for key in pairs(schema) do
      if not supported[key] then return nil, path .. " uses unsupported keyword " .. tostring(key) end
   end
   if schema.properties then
      if type(schema.properties) ~= "table" then return nil, path .. ".properties must be a table" end
      for name, child in pairs(schema.properties) do
         local ok, err = Schema.check(child, path .. ".properties." .. tostring(name)); if not ok then return nil, err end
      end
   end
   if schema.items then local ok, err = Schema.check(schema.items, path .. ".items"); if not ok then return nil, err end end
   return true
end

return Schema
