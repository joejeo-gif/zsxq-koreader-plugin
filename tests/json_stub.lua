-- 测试用纯 Lua JSON 实现（自包含，避免依赖 KOReader 运行时或联网下载 rxi/json.lua）。
-- 支持 object / array / string / number / boolean / null 的 encode 与 decode。
local json = {}

json.null = setmetatable({}, { __tostring = function() return "null" end })

local function encode_string(s)
    local out = { '"' }
    for i = 1, #s do
        local c = s:sub(i, i)
        local b = c:byte()
        if c == '"' then out[#out + 1] = '\\"'
        elseif c == '\\' then out[#out + 1] = '\\\\'
        elseif c == '\n' then out[#out + 1] = '\\n'
        elseif c == '\r' then out[#out + 1] = '\\r'
        elseif c == '\t' then out[#out + 1] = '\\t'
        elseif c == '\b' then out[#out + 1] = '\\b'
        elseif c == '\f' then out[#out + 1] = '\\f'
        elseif b < 32 then out[#out + 1] = string.format('\\u%04x', b)
        else out[#out + 1] = c end
    end
    out[#out + 1] = '"'
    return table.concat(out)
end

local function is_array(t)
    local max = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        if k > max then max = k end
    end
    return max == #t
end

local encode_value
local function encode_table(t)
    local parts = {}
    if is_array(t) then
        for i = 1, #t do parts[i] = encode_value(t[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, v in pairs(t) do
        parts[#parts + 1] = encode_string(tostring(k)) .. ":" .. encode_value(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

encode_value = function(v)
    local kind = type(v)
    if v == nil or v == json.null then return "null" end
    if kind == "string" then return encode_string(v) end
    if kind == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return tostring(v)
    end
    if kind == "boolean" then return v and "true" or "false" end
    if kind == "table" then return encode_table(v) end
    return "null"
end

function json.encode(value)
    return encode_value(value)
end

local function utf8_char(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    end
    if code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000),
        0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

function json.decode(str)
    str = tostring(str or "")
    local pos = 1
    local parse_value

    local function skip_ws()
        while pos <= #str and str:sub(pos, pos):find("%s") do pos = pos + 1 end
    end

    local function parse_string()
        pos = pos + 1 -- skip opening quote
        local out = {}
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(out)
            elseif c == '\\' then
                local e = str:sub(pos + 1, pos + 1)
                local map = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f",
                    ['"'] = '"', ['\\'] = '\\', ['/'] = '/' }
                if e == "u" then
                    local hex = str:sub(pos + 2, pos + 5)
                    out[#out + 1] = utf8_char(tonumber(hex, 16) or 0)
                    pos = pos + 6
                else
                    out[#out + 1] = map[e] or e
                    pos = pos + 2
                end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        error("unterminated JSON string")
    end

    local function parse_object()
        pos = pos + 1
        local result = {}
        skip_ws()
        if str:sub(pos, pos) == "}" then pos = pos + 1 return result end
        while true do
            skip_ws()
            local key = parse_string()
            skip_ws()
            pos = pos + 1 -- skip ':'
            result[key] = parse_value()
            skip_ws()
            local c = str:sub(pos, pos)
            pos = pos + 1
            if c == "}" then break end
            if c ~= "," then error("expected ',' or '}' in JSON object") end
        end
        return result
    end

    local function parse_array()
        pos = pos + 1
        local result = {}
        skip_ws()
        if str:sub(pos, pos) == "]" then pos = pos + 1 return result end
        while true do
            result[#result + 1] = parse_value()
            skip_ws()
            local c = str:sub(pos, pos)
            pos = pos + 1
            if c == "]" then break end
            if c ~= "," then error("expected ',' or ']' in JSON array") end
        end
        return result
    end

    parse_value = function()
        skip_ws()
        local c = str:sub(pos, pos)
        if c == '"' then return parse_string() end
        if c == "{" then return parse_object() end
        if c == "[" then return parse_array() end
        if str:sub(pos, pos + 3) == "true" then pos = pos + 4 return true end
        if str:sub(pos, pos + 4) == "false" then pos = pos + 5 return false end
        if str:sub(pos, pos + 3) == "null" then pos = pos + 4 return json.null end
        local num = str:sub(pos):match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*")
        if num and num ~= "" and num ~= "-" then
            pos = pos + #num
            return tonumber(num)
        end
        error("invalid JSON value at byte " .. pos)
    end

    return parse_value()
end

return json
