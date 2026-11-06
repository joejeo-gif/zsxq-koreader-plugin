local Content = {}

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

Content.trim = trim

local function percentDecode(text)
    return (tostring(text or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

Content.percentDecode = percentDecode

local function utf8Char(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000),
        0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local function decodeEntities(text)
    local entities = {
        amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    }
    text = tostring(text or ""):gsub("&#x(%x+);", function(hex)
        local code = tonumber(hex, 16)
        return code and utf8Char(code) or ""
    end):gsub("&#(%d+);", function(dec)
        local code = tonumber(dec)
        return code and utf8Char(code) or ""
    end):gsub("&([%a]+);", function(name)
        return entities[name] or "&" .. name .. ";"
    end)
    return text
end

Content.decodeEntities = decodeEntities

local function addLink(links, seen, url, title)
    url = decodeEntities(trim(url))
    if url == "" or seen[url] then return end
    seen[url] = true
    table.insert(links, {
        url = url,
        title = trim(title) ~= "" and trim(title) or url,
    })
end

-- 解析帖子正文：返回 text, links, images。
-- image_base：占位序号偏移（帖子顶层 images 数组数量），保证 [图片n] 全局编号一致。
-- markdown 长文的 ![alt](url) 图片会提取进 images 并替换为 [图片n] 占位。
function Content.parse(raw, image_base)
    local links, seen = {}, {}
    local images, images_seen = {}, {}
    local base = tonumber(image_base) or 0
    local text = tostring(raw or "")
    text = text:gsub("!%[(.-)%]%((.-)%)", function(alt, url)
        url = trim(url)
        if url == "" then return alt end
        if not images_seen[url] then
            images_seen[url] = true
            table.insert(images, url)
        end
        local n = base
        for index, known in ipairs(images) do
            if known == url then n = base + index break end
        end
        return "[图片" .. n .. "]"
    end)
    text = text:gsub("<e%s+[^>]->", function(tag)
        local kind = tag:match("type=[\"'](.-)[\"']") or ""
        local href = tag:match("href=[\"'](.-)[\"']")
        local title = tag:match("title=[\"'](.-)[\"']")
        title = percentDecode(title or "")
        if kind == "img" then
            local src = percentDecode(tag:match("data%-src=[\"'](.-)[\"']") or
                tag:match("src=[\"'](.-)[\"']") or "")
            if src ~= "" and not images_seen[src] then
                images_seen[src] = true
                table.insert(images, src)
            end
            return "[图片" .. (base + #images) .. "]"
        end
        if kind == "web" and href then
            local url = percentDecode(href)
            addLink(links, seen, url, title)
            return title .. " [链接" .. #links .. "]"
        end
        return title
    end)
    text = decodeEntities(text)
    text = text:gsub("<br%s*/?>", "\n")
    text = text:gsub("</[pP]>", "\n")
    text = text:gsub("<[^>]->", "")
    for url in text:gmatch("https?://[%w%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=%%]+") do
        url = url:gsub("[%.%,;:!?]+$", "")
        if url:match("^https?://images%.zsxq%.com/") or url:match("%.jpe?g") or url:match("%.png") then
            if not images_seen[url] then
                images_seen[url] = true
                table.insert(images, url)
            end
        end
        addLink(links, seen, url, url)
    end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[ \t]+\n", "\n"):gsub("\n[ \t]+", "\n")
    text = text:gsub("\n\n\n+", "\n\n")
    return trim(text), links, images
end

-- 轻量 Markdown → 阅读友好纯文本（去除/转换常见标记，不改内容）
function Content.formatMarkdown(text)
    text = tostring(text or "")
    -- 行内：图片/链接/加粗/斜体/行内代码/删除线
    text = text:gsub("!%[(.-)%]%((.-)%)", function(alt, url)
        if trim(alt) ~= "" then return alt .. "（" .. url .. "）" end
        return "（" .. url .. "）"
    end)
    text = text:gsub("%[([^%]]*)%]%(([^)]+)%)", function(label, url)
        if trim(label) ~= "" then return label .. "（" .. url .. "）" end
        return "（" .. url .. "）"
    end)
    text = text:gsub("%*%*(.-)%*%*", "%1")
    text = text:gsub("__(.-)__", "%1")
    text = text:gsub("~~(.-)~~", "%1")
    text = text:gsub("`(.-)`", "%1")
    text = text:gsub("%*(%S[^*]*)%*", "%1")
    -- 块级：标题、引用、分隔线、列表
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local hashes, rest = line:match("^(#+)%s*(.-)%s*$")
        if hashes then
            local prefix = (#hashes == 1 and "■ ") or (#hashes == 2 and "◆ ") or "· "
            line = prefix .. rest
        elseif line:match("^%s*>%s?") then
            line = "┃ " .. line:gsub("^%s*>%s?", "")
        elseif line:match("^%s*%-%-%-%s*$") or line:match("^%s*%*%*%*%s*$") then
            line = "────────────────"
        elseif line:match("^%s*[-*+]%s+") then
            line = line:gsub("^%s*[-*+]%s+", "• ")
        elseif line:match("^%s*%d+%.%s+") then
            line = line:gsub("^(%s*)(%d+)%.%s+", function(sp, num) return sp .. num .. ". " end)
        end
        table.insert(lines, line)
    end
    return trim(table.concat(lines, "\n"):gsub("\n\n\n+", "\n\n"))
end

-- 帖子内图片（缩略加载：不走原图）
function Content.topicImages(topic)
    topic = topic or {}
    local result = {}
    -- 优先：API 顶层 images 数组（官方已给带签名的压缩 URL，直接用，勿再拼参数以免破坏签名）
    if type(topic.images) == "table" then
        for _, image in ipairs(topic.images) do
            if type(image) == "table" then
                local thumb = (image.thumbnail and image.thumbnail.url)
                    or (image.large and image.large.url)
                local full = (image.large and image.large.url)
                    or (image.original and image.original.url)
                    or thumb
                if thumb and thumb ~= "" then
                    table.insert(result, { url = full, thumbnail = thumb })
                end
            end
        end
    end
    if #result > 0 then return result end
    -- 回退：从正文解析 <e type="img"> / 裸图片 URL / markdown ![](url)，自行拼压缩参数
    local raw = topic.content or topic.text or ""
    local _, _, images = Content.parse(raw)
    for _, url in ipairs(images) do
        -- 已带签名（e/token）或压缩参数的 URL 原样使用，拼参数会破坏签名
        local thumbnail = url
        if not url:find("token=", 1, true) and not url:find("imageMogr2", 1, true) then
            local separator = url:find("?", 1, true) and "&" or "?"
            thumbnail = url .. separator .. "imageMogr2/auto-orient/thumbnail/1080x/format/jpg"
        end
        table.insert(result, { url = url, thumbnail = thumbnail })
    end
    return result
end

function Content.shortTime(value)
    value = tostring(value or "")
    return value:match("(%d%d%d%d%-%d%d%-%d%d)T?") or value:sub(1, 16)
end

function Content.longTime(value)
    value = tostring(value or "")
    local date, time = value:match("(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")
    if date then return date .. " " .. time end
    return value
end

function Content.singleLine(text)
    return trim(tostring(text or ""):gsub("%s+", " "))
end

function Content.truncate(text, max_bytes)
    text = tostring(text or "")
    max_bytes = max_bytes or 120
    if #text <= max_bytes then return text end
    local cut_length = max_bytes
    while cut_length > 0 do
        local next_byte = string.byte(text, cut_length + 1)
        if not next_byte or next_byte < 0x80 or next_byte >= 0xC0 then break end
        cut_length = cut_length - 1
    end
    return text:sub(1, cut_length) .. "…"
end

function Content.topicTitle(topic)
    topic = topic or {}
    local title = Content.singleLine(topic.title)
    local content = Content.formatMarkdown(Content.parse(topic.content))
    local first_line = Content.singleLine(content:match("^([^\n]+)") or content)
    if title == "" or (title:match("%.%.%.$") and #first_line > #title) then
        title = first_line
    end
    if title == "" then title = "无标题帖子" end
    return Content.truncate(title, 150)
end

function Content.topicText(topic)
    topic = topic or {}
    local raw = topic.content or topic.text
    if trim(raw) == "" and type(topic.question) == "table" then
        raw = topic.question.text or topic.question.content
    end
    local body, links = Content.parse(raw)
    body = Content.formatMarkdown(body)
    if type(topic.answer) == "table" then
        local answer = Content.formatMarkdown(Content.parse(topic.answer.text or topic.answer.content))
        if answer ~= "" then body = body .. "\n\n【回答】\n" .. answer end
    end

    local seen = {}
    for _, link in ipairs(links) do seen[link.url] = true end
    local article = (topic.talk and topic.talk.article) or topic.article
    local article_url = article and (article.inline_article_url or article.url)
    if article_url then
        addLink(links, seen, article_url, article.title or "知识星球长文")
        if body == "" then body = "【长文】" .. (article.title or "请点击下方链接阅读") end
    end

    local owner = topic.owner or {}
    local counts = topic.counts or {}
    local lines = {}
    -- 头部一行：名字 [位置] 时间（不显示标签）
    local head = { owner.alias or owner.name or "未知" }
    local location = owner.location or topic.location
    if location and location ~= "" then table.insert(head, location) end
    table.insert(head, Content.longTime(topic.create_time))
    table.insert(lines, table.concat(head, " "))
    if topic.digested then table.insert(lines, "精华") end
    table.insert(lines, string.format("评论 %s · 点赞 %s · 阅读 %s",
        tostring(counts.comments or 0), tostring(counts.likes or 0), tostring(counts.readers or 0)))
    table.insert(lines, "\n────────────────\n")
    table.insert(lines, body ~= "" and body or "（此帖子没有文字正文）")
    if #links > 0 then
        table.insert(lines, "\n\n────────────────\n链接：")
        for i, link in ipairs(links) do
            table.insert(lines, string.format("[%d] %s\n%s", i, link.title, link.url))
        end
    end
    return table.concat(lines, "\n"), links
end

local function commentHeader(comment, number, indent)
    local owner = comment.owner or {}
    return string.format("%s%s. %s · %s · ♥ %s", indent or "", tostring(number),
        owner.name or owner.alias or "未知", Content.longTime(comment.create_time),
        tostring(comment.likes_count or 0))
end

-- 评论 → 纯文本。total_count：API 给的含楼中楼总数（口径提示用，可为 nil）；
-- first_number：本批第一楼的编号（分层批次显示时保持全局楼层号）
function Content.commentsText(comments, total_count, first_number)
    local output, flat = {}, {}
    local floors = #comments or 0 -- 顶层楼数（楼中楼不编号）
    local from = (tonumber(first_number) or 1)
    if floors > 0 and from <= 1 then
        if total_count and total_count > floors then
            table.insert(output, string.format(
                "已显示 %d 楼 · 合计 %d 条（含楼中楼）", floors, total_count))
        else
            table.insert(output, string.format("评论 %d 楼", floors))
        end
        table.insert(output, "")
    end
    for i, comment in ipairs(comments or {}) do
        local num = from + i - 1
        local body = Content.parse(comment.text)
        table.insert(output, commentHeader(comment, num, ""))
        table.insert(output, body)
        table.insert(flat, { comment = comment, depth = 0, label = body })
        for j, reply in ipairs(comment.replied_comments or {}) do
            local reply_body = Content.parse(reply.text)
            local repliee = reply.repliee and reply.repliee.name
            -- 楼中楼：单行格式，无序号、无时间（↳ 昵称 回复 @某人：正文）
            table.insert(output, string.format("  ↳ %s%s：%s",
                (reply.owner and reply.owner.name) or "未知",
                repliee and (" 回复 @" .. repliee) or "",
                Content.singleLine(reply_body)))
            table.insert(flat, { comment = reply, depth = 1, label = reply_body })
        end
        table.insert(output, "\n────────────────\n")
    end
    if #output == 0 then return "暂无评论。", flat end
    return table.concat(output, "\n"), flat
end

function Content.hash(text)
    local hash = 5381
    for i = 1, #tostring(text or "") do
        hash = (hash * 33 + string.byte(text, i)) % 2147483647
    end
    return string.format("%010d", hash)
end

return Content
