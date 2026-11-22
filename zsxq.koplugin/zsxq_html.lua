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
.ref-head { font-weight: bold; }
.ref-title { font-weight: bold; }
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

-- 标题去重：知识星球 API 的 title 常是正文首行的截断版（"xxx..."），
-- topicTitle 会把它提升成正文首行；若 HTML 再写 <h1>、正文又保留首行、
-- 链接区再列一次同名标题，同一句话会出现三四次。这里统一收口。
-- 全程用 plain 比较，避免 Lua 5.1 按字节解析 UTF-8 字符类时误伤汉字。
local function sameTitle(a, b)
    local na = Content.singleLine(Content.stripBlockPrefix(a))
    local nb = Content.singleLine(Content.stripBlockPrefix(b))
    if na == "" or nb == "" then return false end
    if na == nb then return true end
    local short, long
    if #na <= #nb then short, long = na, nb else short, long = nb, na end
    return #short >= 8 and #short / #long >= 0.55
        and long:find(short, 1, true) ~= nil
end

local function stripLeadingTitle(body, title)
    local first, rest = body:match("^([^\n]+)\n(.*)$")
    if not first then first, rest = body, "" end
    if not sameTitle(first, title) then return body end
    return (rest:gsub("^[\n\r]+", ""))
end

-- <e type="web" title="同名长文标题"/> 解析后会变成 "同名标题 [链接1]"，去掉重复的标题文字
local function stripInlineTitleLinks(body, title)
    local out = {}
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("(.-) %[链接(%d+)%]", function(label, num)
            if sameTitle(label, title) then return "[链接" .. num .. "]" end
        end)
        table.insert(out, line)
    end
    -- gmatch 会多出一个尾部空行，去掉以免正文尾部多空段
    if #out > 0 and out[#out] == "" then table.remove(out) end
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
            escape(Content.displayName(owner)))
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
            escape(Content.displayName(owner))),
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

-- 转载原帖区块：标题 / 作者 / 星球 / 时间 / 正文。原帖链接统一在 links 区，
-- 这样默认视图的「长文/链接」按钮与图文模式的链接区都能扫码打开。
function Html.referencedToHtml(topic)
    local ref = Content.referencedTopic(topic)
    if not ref then return "" end
    local meta = { escape(ref.author) }
    if ref.group ~= "" then table.insert(meta, escape(ref.group)) end
    if ref.time ~= "" then table.insert(meta, escape(ref.time)) end
    local parts = {
        '<hr/>',
        '<p class="ref-head">【转载原帖】</p>',
        '<p class="ref-title">' .. escape(ref.title) .. '</p>',
        '<p class="meta">' .. table.concat(meta, " · ") .. '</p>',
        textToParagraphs(ref.content ~= "" and ref.content or "（原帖无文字正文）"),
    }
    return table.concat(parts, "\n")
end

-- resolved_images 可为 nil（无图/未解析）；含本地路径的图以内嵌方式呈现
-- comments 可为 nil（不加载评论）；传入时正文后连续显示评论区
-- 正文中的 [图片n] 占位在原位内嵌对应图片；无占位的图片仍排在文末
function Html.topicToHtml(topic, resolved_images, comments)
    topic = topic or {}
    -- 直接用纯正文，不再从 topicText 的字符串里切：旧的切法会把「链接：」区
    -- 一起切进正文，末尾又追加一次，造成链接和长文标题重复。
    local body, links = Content.topicBody(topic)
    local title = Content.topicTitle(topic)
    body = stripLeadingTitle(body, title)
    body = stripInlineTitleLinks(body, title)

    local owner = topic.owner or {}
    local author = Content.displayName(owner)
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
        '<title>' .. escape(title) .. '</title>',
        '<meta name="author" content="' .. escape(author) .. '"/>',
        '<meta name="description" content="' .. escape(description) .. '"/>',
        STYLE,
        '</head><body>',
        '<h1>' .. escape(title) .. '</h1>',
        '<p class="meta">' .. description .. '</p>',
        '<hr/>',
        textToParagraphs(body, inline_image),
    }
    local image_html = imagesSection(rest)
    if image_html ~= "" then
        table.insert(parts, '<hr/>')
        table.insert(parts, image_html)
    end
    local ref_html = Html.referencedToHtml(topic)
    if ref_html ~= "" then table.insert(parts, ref_html) end
    if #links > 0 then
        local link_lines = {}
        for i, link in ipairs(links) do
            -- 与文档标题同名的长文链接只列 URL，标题已在 <h1> 出现，不再重复
            if sameTitle(link.title, title) then
                table.insert(link_lines, string.format("[%d] %s", i, escape(link.url)))
            else
                table.insert(link_lines, string.format("[%d] %s<br/>%s",
                    i, escape(link.title), escape(link.url)))
            end
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
        '<meta name="author" content="' .. escape(Content.displayName(owner)) .. '"/>',
        STYLE,
        '</head><body>',
        '<h1>图片 · ' .. title .. '</h1>',
        imagesSection(resolved_images),
        '</body></html>',
    }
    return table.concat(parts, "\n")
end

return Html
