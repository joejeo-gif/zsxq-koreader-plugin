-- 帖子 → 简洁 HTML（供 KOReader ReaderUI 打开：原生划线/高亮/AI助手插件，图片内嵌）
local Content = require("zsxq_content")

local Html = {}

local function escape(text)
    return (tostring(text or "")
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

local function file_name(path)
    return tostring(path or ""):match("([^/]+)$") or ""
end

local STYLE = [[
<style>
body { line-height: 1.6; }
h1 { font-size: 1em; font-weight: bold; }
.meta { font-style: italic; }
.images { font-style: italic; }
.links { font-size: 0.9em; }
img { max-width: 100%; }
figcaption { font-style: italic; font-size: 0.85em; }
.c-head { margin-top: 0.4em; }
.c-author { font-weight: bold; }
.c-meta { color: #888888; font-size: 0.5em; }
.c-reply { margin-left: 1.2em; }
</style>]]

-- 纯文本正文 → <p> 段落；空行分段。
-- inline_image（可选）：[图片n] 占位 → 原位内嵌的 HTML（在文本转义后替换，避免被转义）。
local function textToParagraphs(text, inline_image)
    local blocks = {}
    local current = {}
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^%s*$") then
            if #current > 0 then
                table.insert(blocks, table.concat(current, "<br/>"))
                current = {}
            end
        else
            local escaped = escape(line)
            if inline_image then
                escaped = escaped:gsub("%[图片(%d+)%]", function(num)
                    return inline_image[tonumber(num)] or ("[图片" .. num .. "]")
                end)
            end
            table.insert(current, escaped)
        end
    end
    if #current > 0 then table.insert(blocks, table.concat(current, "<br/>")) end
    local out = {}
    for _, block in ipairs(blocks) do
        table.insert(out, "<p>" .. block .. "</p>")
    end
    if #out == 0 then table.insert(out, "<p>（此帖子没有文字正文）</p>") end
    return table.concat(out, "\n")
end

-- resolved_images: { { path = 本地文件路径（相对引用文件名） } 或 { note = 占位说明 } }
local function imagesSection(resolved_images)
    local parts = {}
    for i, image in ipairs(resolved_images or {}) do
        if image.path then
            table.insert(parts, string.format(
                '<figure><img src="%s" alt="图片%d"/><figcaption>图 %d</figcaption></figure>',
                escape(file_name(image.path)), i, i))
        elseif image.note then
            table.insert(parts, string.format(
                '<p class="images">[图片%d：%s]</p>', i, escape(image.note)))
        end
    end
    return table.concat(parts, "\n")
end

-- 评论 → HTML。样式规则：
-- 昵称加粗；时间紧跟昵称，与 ♥ 点赞数一起灰色、半号（.c-meta）；
-- 楼中楼单行：↳ 昵称 回复 @某人：内容（无序号、无时间）。
local function metaSpan(text)
    return string.format('<span class="c-meta">%s</span>', escape(text))
end

local function commentBody(comment)
    local body = select(1, Content.parse(comment.text))
    return textToParagraphs(body)
end

local function repliesToHtml(comment)
    local parts = {}
    for _, reply in ipairs(comment.replied_comments or {}) do
        local owner = reply.owner or {}
        local repliee = reply.repliee and reply.repliee.name
        local head = string.format('<span class="c-author">%s</span>',
            escape(owner.alias or owner.name or "未知"))
        if repliee then
            head = head .. metaSpan(" 回复 @" .. repliee)
        end
        table.insert(parts, string.format(
            '<div class="c-reply">↳ %s：%s</div>',
            head, escape(Content.singleLine(select(1, Content.parse(reply.text))))))
    end
    return table.concat(parts, "\n")
end

local function commentToHtml(comment)
    local owner = comment.owner or {}
    local head = {
        string.format('<span class="c-author">%s</span>',
            escape(owner.alias or owner.name or "未知")),
        metaSpan(Content.longTime(comment.create_time)),
        metaSpan("♥ " .. tostring(comment.likes_count or 0)),
    }
    local parts = {
        '<div class="comment"><div class="c-head">' .. table.concat(head, " ") .. '</div>',
        commentBody(comment),
    }
    if #(comment.replied_comments or {}) > 0 then
        table.insert(parts, repliesToHtml(comment))
    end
    table.insert(parts, '</div>')
    return table.concat(parts, "\n")
end

function Html.commentsToHtml(comments, total_count)
    if not comments or #comments == 0 then
        return '<p class="c-meta">暂无评论</p>'
    end
    local title = string.format('<span class="c-author">评论 %d 楼</span>', #comments)
    if total_count and total_count > 0 and total_count ~= #comments then
        title = title .. " " ..
            metaSpan(string.format("含楼中楼合计 %d 条", total_count))
    end
    local parts = { string.format('<div class="c-head">%s</div>', title) }
    for _, comment in ipairs(comments) do
        table.insert(parts, commentToHtml(comment))
        table.insert(parts, '<hr/>')
    end
    return table.concat(parts, "\n")
end

-- resolved_images 可为 nil（无图/未解析）；含本地路径的图以内嵌方式呈现
-- comments 可为 nil（不加载评论）；传入时正文后连续显示评论区
-- 正文中的 [图片n] 占位在原位内嵌对应图片；无占位的图片仍排在文末
function Html.topicToHtml(topic, resolved_images, comments)
    topic = topic or {}
    local text, links = Content.topicText(topic)
    -- 只保留正文（跳过元数据头）
    local body = text:match("────────────────\n(.*)$") or text

    local owner = topic.owner or {}
    local author = owner.alias or owner.name or "未知"
    local meta = { escape(author) }
    local location = owner.location or topic.location
    if location and location ~= "" then table.insert(meta, escape(location)) end
    table.insert(meta, escape(Content.longTime(topic.create_time)))
    if topic.digested then table.insert(meta, "精华") end
    local description = table.concat(meta, " · ")

    -- [图片n] 占位 → 原位内嵌（替换发生在 textToParagraphs 转义之后）
    local inline_image, placed = {}, {}
    for i, image in ipairs(resolved_images or {}) do
        local pattern = "%[图片" .. i .. "%]"
        if body:find(pattern) then
            if image.path then
                inline_image[i] = string.format(
                    '<figure><img src="%s" alt="图片%d"/><figcaption>图 %d</figcaption></figure>',
                    escape(file_name(image.path)), i, i)
                placed[i] = true
            elseif image.note then
                inline_image[i] = string.format(
                    '<span class="images">[图片%d：%s]</span>', i, escape(image.note))
                placed[i] = true
            end
        end
    end
    local rest = {}
    for i, image in ipairs(resolved_images or {}) do
        if not placed[i] then table.insert(rest, image) end
    end

    local parts = {
        '<!DOCTYPE html>',
        '<html><head><meta charset="utf-8"/>',
        '<title>' .. escape(Content.topicTitle(topic)) .. '</title>',
        '<meta name="author" content="' .. escape(author) .. '"/>',
        '<meta name="description" content="' .. escape(description) .. '"/>',
        STYLE,
        '</head><body>',
        '<h1>' .. escape(Content.topicTitle(topic)) .. '</h1>',
        '<p class="meta">' .. description .. '</p>',
        '<hr/>',
        textToParagraphs(body, inline_image),
    }
    local image_html = imagesSection(rest)
    if image_html ~= "" then
        table.insert(parts, '<hr/>')
        table.insert(parts, image_html)
    end
    if #links > 0 then
        local link_lines = {}
        for i, link in ipairs(links) do
            table.insert(link_lines, string.format("[%d] %s<br/>%s",
                i, escape(link.title), escape(link.url)))
        end
        table.insert(parts,
            '<hr/><p class="links"><b>链接：</b><br/>' .. table.concat(link_lines, "<br/>") .. '</p>')
    end
    if comments then
        table.insert(parts, '<hr/>')
        table.insert(parts, Html.commentsToHtml(comments, topic.counts and topic.counts.comments))
    end
    table.insert(parts, '</body></html>')
    return table.concat(parts, "\n")
end

-- 图片册：帖子全部图片在一个 HTML 里翻看
function Html.imagesToHtml(topic, resolved_images)
    topic = topic or {}
    local owner = topic.owner or {}
    local title = escape(Content.topicTitle(topic))
    local parts = {
        '<!DOCTYPE html>',
        '<html><head><meta charset="utf-8"/>',
        '<title>图片 · ' .. title .. '</title>',
        '<meta name="author" content="' .. escape(owner.alias or owner.name or "未知") .. '"/>',
        STYLE,
        '</head><body>',
        '<h1>图片 · ' .. title .. '</h1>',
        imagesSection(resolved_images),
        '</body></html>',
    }
    return table.concat(parts, "\n")
end

return Html
