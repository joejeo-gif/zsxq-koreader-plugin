local JSON = require("json")

local API = {}
API.__index = API

API.DEFAULT_ENDPOINT = "https://mcp.zsxq.com/topic/mcp"
API.MAX_DOWNLOAD_BYTES = 12 * 1024 * 1024
API.PROTOCOL_VERSION = "2024-11-05"

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function decode(text)
    local ok, value = pcall(JSON.decode, text)
    if ok then return value end
    return nil
end

local function header(headers, name)
    if type(headers) ~= "table" then return nil end
    for key, value in pairs(headers) do
        if tostring(key):lower() == name:lower() then return value end
    end
    return nil
end

function API.new(token, endpoint)
    return setmetatable({
        token = trim(token),
        endpoint = trim(endpoint) ~= "" and trim(endpoint) or API.DEFAULT_ENDPOINT,
        request_id = 0,
        session_id = nil,
        initialized = false,
    }, API)
end

function API.parseTransport(body, expected_id)
    body = tostring(body or "")
    local direct = decode(body)
    if type(direct) == "table" then return direct end

    local normalized = body:gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n\n"
    local last
    for event in normalized:gmatch("(.-)\n%s*\n") do
        local data = {}
        for line in event:gmatch("([^\n]*)\n?") do
            local value = line:match("^data:%s?(.*)$")
            if value and value ~= "[DONE]" then table.insert(data, value) end
        end
        if #data > 0 then
            local payload = decode(table.concat(data, "\n"))
            if type(payload) == "table" then
                if not expected_id or tostring(payload.id) == tostring(expected_id) then
                    last = payload
                end
            end
        end
    end
    return last
end

function API.unwrap(payload, expected_id)
    if type(payload) ~= "table" then
        return false, "服务器没有返回有效的 JSON / SSE 数据。"
    end
    if expected_id and tostring(payload.id) ~= tostring(expected_id) then
        return false, "MCP 响应 ID 与请求不匹配。"
    end
    if payload.error then
        local message = payload.error.message or payload.error
        return false, "官方接口错误：" .. tostring(message)
    end
    if payload.result == nil then return false, "MCP 响应缺少 result。" end
    local result = payload.result
    if type(result) ~= "table" then return false, "接口返回格式不完整。" end
    if result.isError then return false, "官方工具执行失败。" end

    if type(result.structuredContent) == "table" then
        result = result.structuredContent
    elseif type(result.content) == "table" then
        local parsed, plain = nil, {}
        for _, item in ipairs(result.content) do
            if type(item) == "table" and item.type == "text" and item.text then
                table.insert(plain, item.text)
                if not parsed then
                    local value = decode(item.text)
                    if type(value) == "table" then parsed = value end
                end
            end
        end
        if parsed then
            result = parsed
        elseif #plain > 0 then
            result = { success = true, text = table.concat(plain, "\n") }
        end
    end
    if type(result) ~= "table" or next(result) == nil then
        return false, "接口返回了空结果。"
    end
    if result.success == false then
        return false, tostring(result.error or result.message or "知识星球返回失败。")
    end
    return true, result
end

function API:httpRequest(method, url, headers, body, max_bytes, extra)
    if not url:match("^https?://") then
        return false, nil, nil, nil, "仅支持 HTTP/HTTPS 地址。"
    end
    local client = url:match("^https://") and require("ssl.https") or require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")

    local chunks, received = {}, 0
    local request = {
        method = method,
        url = url,
        headers = headers or {},
        sink = function(chunk, err)
            if chunk then
                received = received + #chunk
                if max_bytes and received > max_bytes then
                    return nil, "download too large"
                end
                table.insert(chunks, chunk)
            elseif err then
                return nil, err
            end
            return 1
        end,
    }
    if body then
        request.source = ltn12.source.string(body)
        request.headers["Content-Length"] = tostring(#body)
    end
    if extra then
        for key, value in pairs(extra) do request[key] = value end
    end

    socketutil:set_timeout(10, 35)
    local ok, code, response_headers, status = pcall(function()
        return socket.skip(1, client.request(request))
    end)
    socketutil:reset_timeout()
    if not ok then return false, nil, nil, nil, tostring(code) end
    if type(code) ~= "number" then
        return false, nil, nil, nil, tostring(status or response_headers or code or "网络连接失败")
    end
    return true, code, response_headers or {}, table.concat(chunks), status
end

function API:rpc(method, params, allow_empty)
    local id
    if method ~= "notifications/initialized" then
        self.request_id = self.request_id + 1
        id = self.request_id
    end
    local body = JSON.encode({ jsonrpc = "2.0", id = id, method = method, params = params })
    local headers = {
        ["Authorization"] = "Bearer " .. self.token,
        ["Accept"] = "application/json, text/event-stream",
        ["Content-Type"] = "application/json",
        ["Connection"] = "close",
    }
    if self.session_id then headers["Mcp-Session-Id"] = self.session_id end
    if self.negotiated_version then headers["MCP-Protocol-Version"] = self.negotiated_version end

    local ok, code, response_headers, response, status = self:httpRequest(
        "POST", self.endpoint, headers, body, 8 * 1024 * 1024)
    if not ok then return false, "网络连接失败：" .. tostring(status or response or "未知错误") end
    if code == 401 then
        self.initialized = false
        self.session_id = nil
        self.negotiated_version = nil
        return false, "Token 已失效或无权访问（HTTP 401），请更新 MCP Token。", code
    end
    if code == 403 then return false, "没有访问权限（HTTP 403）。", code end
    if code < 200 or code >= 300 then
        return false, string.format("官方接口 HTTP %s：%s", tostring(code), tostring(status or "")), code
    end
    if allow_empty and trim(response) == "" then
        return true, { accepted = true }, response_headers, id
    end
    local payload = API.parseTransport(response, id)
    if not payload then return false, "MCP 响应为空或格式无法识别。", code end
    return true, payload, response_headers, id
end

function API:ensureSession()
    if self.initialized then return true end
    if self.token == "" then return false, "尚未配置知识星球 MCP Token。" end
    local ok, payload, headers, id = self:rpc("initialize", {
        protocolVersion = API.PROTOCOL_VERSION,
        capabilities = {},
        clientInfo = { name = "koreader-zsxq", version = "1.0.0" },
    })
    if not ok then return false, payload end
    local valid, result = API.unwrap(payload, id)
    if not valid then return false, result end
    self.session_id = header(headers, "mcp-session-id")
    self.negotiated_version = result.protocolVersion or API.PROTOCOL_VERSION
    local notified, notify_err = self:rpc("notifications/initialized", nil, true)
    if not notified then
        self.session_id = nil
        self.negotiated_version = nil
        return false, "MCP 初始化通知失败：" .. tostring(notify_err)
    end
    self.initialized = true
    return true
end

function API:call(tool, arguments)
    local ready, err = self:ensureSession()
    if not ready then return false, err end
    local ok, payload, _, id = self:rpc("tools/call", {
        name = tool,
        arguments = arguments or {},
    })
    if not ok then return false, payload end
    return API.unwrap(payload, id)
end

function API:getSelfInfo()
    return self:call("get_self_info", {})
end

function API:getUserID()
    if self.user_id then return true, self.user_id end
    local ok, info = self:getSelfInfo()
    if not ok then return false, info end
    local user = type(info.user) == "table" and info.user or info
    local user_id = user.user_id or user.id
    if user_id == nil or tostring(user_id) == "" then
        return false, "无法从账号信息中解析用户 ID。"
    end
    self.user_id = tostring(user_id)
    return true, self.user_id
end

function API:getGroups(limit)
    local ok, user_id = self:getUserID()
    if not ok then return false, user_id end
    return self:call("get_user_groups", { user_id = user_id, limit = limit or 50 })
end

function API:getHashtags(group_id)
    return self:call("get_group_hashtags", { group_id = tostring(group_id) })
end

function API:getTopics(group_id, hashtag_id, end_time, limit)
    local args = { limit = limit or 20 }
    local tool
    if hashtag_id then
        tool = "get_hashtag_topics"
        args.hashtag_id = tostring(hashtag_id)
    else
        tool = "get_group_topics"
        args.group_id = tostring(group_id)
    end
    if end_time and end_time ~= "" then args.end_time = end_time end
    return self:call(tool, args)
end

function API:getTopic(topic_id)
    return self:call("get_topic_info", { topic_id = tostring(topic_id) })
end

function API:getComments(topic_id, index, limit)
    local args = { topic_id = tostring(topic_id), limit = limit or 30 }
    if index and index ~= "" then args.index = index end
    return self:call("get_topic_comments", args)
end

function API:createComment(topic_id, text, replied_comment_id)
    local args = { topic_id = tostring(topic_id), text = tostring(text) }
    if replied_comment_id then args.replied_comment_id = tostring(replied_comment_id) end
    local ok, result = self:call("create_topic_comment", args)
    if not ok then return false, result end
    local comment_id = result.comment_id or (type(result.comment) == "table" and result.comment.comment_id)
    if result.success ~= true or not comment_id then
        return false, "接口未确认新评论 ID，不能判定为已发送。"
    end
    return true, result
end

function API:createTopic(group_id, title, content)
    if not group_id or tostring(group_id) == "" then
        return false, "缺少星球 ID，无法发帖。"
    end
    local args = {
        group_id = tostring(group_id),
        type = "talk",
        text_type = "plain",
    }
    title = tostring(title or ""):gsub("^%s+", ""):gsub("%s+$", "")
    content = tostring(content or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if title ~= "" then args.title = title end
    if content ~= "" then args.content = content end
    if not args.title and not args.content then
        return false, "标题和正文不能同时为空。"
    end
    local ok, result = self:call("create_topic", args)
    if not ok then return false, result end
    local topic_id = result.topic_id or (type(result.topic) == "table" and result.topic.topic_id)
    if result.success ~= true or not topic_id then
        return false, "接口未确认新帖子 ID，不能判定为已发布。"
    end
    return true, result
end

function API:download(url)
    local current = url
    local urlutil = require("socket.url")
    for _ = 1, 6 do
        local ok, code, headers, body, status = self:httpRequest("GET", current, {
            ["Accept"] = "text/html,application/xhtml+xml,application/pdf,text/plain,*/*;q=0.5",
            ["Connection"] = "close",
        }, nil, API.MAX_DOWNLOAD_BYTES, { redirect = false })
        if not ok then return false, "下载失败：" .. tostring(status or body or "网络错误") end
        if code >= 300 and code < 400 then
            local location = header(headers, "location")
            if not location then return false, "网页重定向缺少目标地址。" end
            current = urlutil.absolute(current, location)
        elseif code == 200 then
            return true, body, headers, current
        else
            return false, string.format("网页 HTTP %s：%s", tostring(code), tostring(status or ""))
        end
    end
    return false, "网页重定向次数过多。"
end

return API
