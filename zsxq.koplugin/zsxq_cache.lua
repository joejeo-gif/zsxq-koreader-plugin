local DataStorage = require("datastorage")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local Content = require("zsxq_content")

local Cache = {}
Cache.__index = Cache

function Cache.new(root)
    root = root or (DataStorage:getSettingsDir() .. "/zsxq")
    local self = setmetatable({ root = root, available = false }, Cache)
    local ok, err = util.makePath(root)
    if not ok then
        self.error = err or "无法创建缓存目录"
        return self
    end
    ok, err = util.makePath(root .. "/articles")
    if not ok then
        self.error = err or "无法创建长文缓存目录"
        return self
    end
    self.available = true
    return self
end

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function writeFile(path, data)
    local temp = path .. ".tmp"
    local file, err = io.open(temp, "wb")
    if not file then return false, err end
    local ok, write_err = file:write(data)
    local closed, close_err = file:close()
    if not ok or not closed then
        os.remove(temp)
        return false, write_err or close_err or "写入缓存失败"
    end
    local renamed, rename_err = os.rename(temp, path)
    if not renamed then
        os.remove(temp)
        return false, rename_err
    end
    return true
end

Cache.writeFile = writeFile

function Cache:path(key)
    key = tostring(key):gsub("[^%w_%-]", "_")
    return self.root .. "/" .. key .. ".json"
end

function Cache:put(key, value)
    if not self.available then return false, self.error end
    local ok, encoded = pcall(JSON.encode, {
        saved_at = os.time(),
        value = value,
    })
    if not ok then return false, encoded end
    return writeFile(self:path(key), encoded)
end

function Cache:get(key)
    if not self.available then return nil end
    local raw = readFile(self:path(key))
    if not raw then return nil end
    local ok, wrapper = pcall(JSON.decode, raw)
    if not ok or type(wrapper) ~= "table" then return nil end
    return wrapper.value, wrapper.saved_at
end

function Cache:saveTopic(topic)
    if type(topic) ~= "table" or not topic.topic_id then return false end
    return self:put("topic_" .. tostring(topic.topic_id), topic)
end

function Cache:getTopic(topic_id)
    return self:get("topic_" .. tostring(topic_id))
end

function Cache:listTopics()
    local topics = {}
    if not self.available then return topics end
    for entry in lfs.dir(self.root) do
        if entry:match("^topic_[%w_%-]+%.json$") then
            local key = entry:gsub("%.json$", "")
            local topic, saved_at = self:get(key)
            if type(topic) == "table" and topic.topic_id then
                topic._cached_at = saved_at
                table.insert(topics, topic)
            end
        end
    end
    table.sort(topics, function(a, b)
        return tostring(a.create_time or "") > tostring(b.create_time or "")
    end)
    return topics
end

function Cache:articlePath(url, extension)
    extension = extension or "html"
    return self.root .. "/articles/" .. Content.hash(url) .. "." .. extension
end

function Cache:saveArticle(url, body, extension)
    if not self.available then return nil, self.error end
    local path = self:articlePath(url, extension)
    local ok, err = writeFile(path, body)
    if not ok then return nil, err end
    writeFile(path .. ".meta", JSON.encode({ url = url, saved_at = os.time() }))
    return path
end

function Cache:getArticle(url)
    if not self.available then return nil end
    for _, extension in ipairs({ "html", "pdf", "txt", "jpg", "jpeg", "png" }) do
        local path = self:articlePath(url, extension)
        if lfs.attributes(path, "mode") == "file" then return path end
    end
    return nil
end

function Cache:purge(max_age_seconds)
    if not self.available then return 0 end
    local removed = 0
    local threshold = os.time() - max_age_seconds
    local function scan(directory, is_articles)
        for entry in lfs.dir(directory) do
            if entry ~= "." and entry ~= ".." then
                local path = directory .. "/" .. entry
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" then
                    scan(path, entry == "articles")
                elseif mode == "file" and (is_articles or (entry:match("%.json$") and entry ~= "highlights.json")) then
                    local modified = lfs.attributes(path, "modification") or 0
                    if modified < threshold and os.remove(path) then
                        removed = removed + 1
                    end
                end
            end
        end
    end
    scan(self.root, false)
    return removed
end

function Cache:stats()
    local topics = #self:listTopics()
    local articles, bytes = 0, 0
    if not self.available then return topics, articles, bytes end
    for entry in lfs.dir(self.root .. "/articles") do
        if not entry:match("%.meta$") then
            local path = self.root .. "/articles/" .. entry
            local size = lfs.attributes(path, "size")
            if size then
                articles = articles + 1
                bytes = bytes + size
            end
        end
    end
    return topics, articles, bytes
end

-- ============ 划线（高亮） ============

function Cache:highlightsPath()
    return self.root .. "/highlights.json"
end

-- 帖子正文 HTML（CREngine 渲染源）。
-- 放在 articles/ 目录，与缓存图片同目录，HTML 里的 <img> 可用相对文件名引用。
function Cache:topicHTMLPath(topic_id)
    return self.root .. "/articles/topic_" .. tostring(topic_id):gsub("[^%w_%-]", "_") .. ".html"
end

function Cache:saveTopicHTML(topic_id, html)
    if not self.available then return nil, self.error end
    local path = self:topicHTMLPath(topic_id)
    local ok, err = writeFile(path, html)
    if not ok then return nil, err end
    return path
end

function Cache:listHighlights(topic_id)
    local result = {}
    if not self.available then return result end
    local raw = readFile(self:highlightsPath())
    if not raw then return result end
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" or type(data.highlights) ~= "table" then return result end
    for _, highlight in ipairs(data.highlights) do
        if not topic_id or tostring(highlight.topic_id) == tostring(topic_id) then
            table.insert(result, highlight)
        end
    end
    table.sort(result, function(a, b)
        return (a.created or 0) > (b.created or 0)
    end)
    return result
end

function Cache:addHighlight(topic_id, topic_title, text, location)
    if not self.available then return false, self.error end
    text = Content.trim(text)
    if text == "" then return false, "划线内容为空" end
    local data = { highlights = {} }
    local raw = readFile(self:highlightsPath())
    if raw then
        local ok, decoded = pcall(JSON.decode, raw)
        if ok and type(decoded) == "table" and type(decoded.highlights) == "table" then
            data = decoded
        end
    end
    for _, highlight in ipairs(data.highlights) do
        if tostring(highlight.topic_id) == tostring(topic_id) and highlight.text == text then
            -- 重复保存时补齐定位信息（CRE XPointer 等）
            if location then
                highlight.xp = highlight.xp or location.xp
                highlight.end_xp = highlight.end_xp or location.end_xp
                highlight.html_hash = highlight.html_hash or location.html_hash
                local ok, encoded = pcall(JSON.encode, data)
                if ok then writeFile(self:highlightsPath(), encoded) end
            end
            return true, highlight
        end
    end
    local item = {
        id = os.time() .. "_" .. Content.hash(text),
        topic_id = tostring(topic_id),
        topic_title = topic_title or "",
        text = text,
        created = os.time(),
    }
    if location then
        item.xp = location.xp
        item.end_xp = location.end_xp
        item.html_hash = location.html_hash
    end
    table.insert(data.highlights, item)
    local ok, encoded = pcall(JSON.encode, data)
    if not ok then return false, encoded end
    if not writeFile(self:highlightsPath(), encoded) then return false, "写入划线文件失败" end
    return true, item
end

function Cache:deleteHighlight(id)
    if not self.available then return false, self.error end
    local raw = readFile(self:highlightsPath())
    if not raw then return false, "没有划线记录" end
    local ok, data = pcall(JSON.decode, raw)
    if not ok or type(data) ~= "table" or type(data.highlights) ~= "table" then
        return false, "划线记录已损坏"
    end
    local kept, removed = {}, 0
    for _, highlight in ipairs(data.highlights) do
        if tostring(highlight.id) == tostring(id) then
            removed = removed + 1
        else
            table.insert(kept, highlight)
        end
    end
    data.highlights = kept
    local encoded_ok, encoded = pcall(JSON.encode, data)
    if not encoded_ok then return false, encoded end
    if not writeFile(self:highlightsPath(), encoded) then return false, "写入划线文件失败" end
    return removed > 0
end

return Cache
