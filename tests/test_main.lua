local workspace = arg[1]
assert(workspace, "workspace path required")
package.path = workspace .. "/zsxq.koplugin/?.lua;" .. package.path
package.preload["json"] = function() return dofile("/tmp/zsxq-test-json.lua") end

-- ===== UIManager stub：窗口栈 + on_destroy 联动 =====
local shown, closed = {}, {}
local scheduled = {}
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, widget) shown[#shown + 1] = widget end,
        close = function(_, widget)
            closed[#closed + 1] = widget
            if widget and widget.on_destroy then widget.on_destroy() end
        end,
        setDirty = function() end,
        forceRePaint = function() end,
        scheduleIn = function(_, _, fn) scheduled[#scheduled + 1] = fn end,
    }
end

local function widget(kind)
    return {
        new = function(_, args)
            args = args or {}
            args._kind = kind
            args.onShowKeyboard = args.onShowKeyboard or function() end
            return args
        end,
    }
end
package.preload["ui/widget/buttondialog"] = function() return widget("ButtonDialog") end
package.preload["ui/widget/confirmbox"] = function() return widget("ConfirmBox") end
package.preload["ui/widget/infomessage"] = function() return widget("InfoMessage") end
package.preload["ui/widget/inputdialog"] = function() return widget("InputDialog") end
package.preload["ui/widget/menu"] = function() return widget("Menu") end
package.preload["ui/widget/qrmessage"] = function() return widget("QRMessage") end
package.preload["ui/widget/textviewer"] = function() return widget("TextViewer") end
package.preload["datastorage"] = function() return { getSettingsDir = function() return "/tmp" end } end
package.preload["device"] = function()
    return { screen = {
        getWidth = function() return 758 end,
        getHeight = function() return 1024 end,
        scaleBySize = function(_, value) return value end,
    } }
end
package.preload["ui/network/manager"] = function()
    return { runWhenOnline = function(_, callback) callback() end }
end
local opened_files = {}
local ReaderUIStub
package.preload["apps/reader/readerui"] = function()
    ReaderUIStub = { showReader = function(_, path) opened_files[#opened_files + 1] = path end }
    return ReaderUIStub
end
local rendered_image_paths = {}
package.preload["ui/renderimage"] = function()
    return {
        renderImageFile = function(_, path)
            rendered_image_paths[#rendered_image_paths + 1] = path
            return { from = path }
        end,
    }
end
package.preload["ui/widget/imageviewer"] = function() return widget("ImageViewer") end
-- qrencode / blitbuffer stub：验证自绘全屏二维码
local qr_painted = {}
package.preload["ffi/qrencode"] = function()
    return { qrcode = function(text)
        return "ok", { -1, 1, 1, -1 }, 2 -- 2x2 矩阵，(1,1) 和 (2,2) 为深色模块
    end }
end
package.preload["ffi/blitbuffer"] = function()
    local bbmeta = {}
    bbmeta.__index = bbmeta
    function bbmeta.paintRect(self, x, y, w, h, color)
        qr_painted[#qr_painted + 1] = { x = x, y = y, w = w, h = h, color = color }
    end
    return {
        new = function(w, h) return setmetatable({ w = w, h = h }, bbmeta) end,
        COLOR_WHITE = "white",
    }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(_, value) return value end }
end
package.preload["logger"] = function() return { err = function() end } end
package.preload["gettext"] = function() return function(text) return text end end
package.preload["ui/event"] = function()
    return { new = function(_, name) return { name = name } end }
end

-- ===== cache stub =====
local store, saved_topics, articles = {}, {}, {}
local cache = {}
function cache:purge() return 0 end
function cache:put(key, value) store[key] = value return true end
function cache:get(key) return store[key] end
function cache:saveTopic(topic) saved_topics[topic.topic_id] = topic return true end
function cache:getTopic(topic_id) return saved_topics[topic_id] end
function cache:listTopics()
    local result = {}
    for _, topic in pairs(saved_topics) do result[#result + 1] = topic end
    table.sort(result, function(a, b) return tostring(a.topic_id) < tostring(b.topic_id) end)
    return result
end
function cache:getArticle(url) return articles[url] end
function cache:saveArticle(url, _, extension)
    local path = "/tmp/article." .. (extension or "html")
    articles[url] = path
    return path
end
function cache:stats() return 1, 1, 100 end
function cache:topicHTMLPath(topic_id) return "/tmp/zsxq_topic_" .. tostring(topic_id) .. ".html" end
function cache:saveTopicHTML(topic_id, html)
    local path = self:topicHTMLPath(topic_id)
    local file = io.open(path, "wb")
    if file then file:write(html) file:close() end
    return path
end
local highlights = {}
function cache:addHighlight(topic_id, title, text)
    local item = { id = tostring(topic_id) .. "_" .. #highlights, topic_id = tostring(topic_id),
        topic_title = title, text = text, created = os.time() }
    highlights[#highlights + 1] = item
    return true, item
end
function cache:listHighlights(topic_id)
    local result = {}
    for _, h in ipairs(highlights) do
        if not topic_id or h.topic_id == tostring(topic_id) then result[#result + 1] = h end
    end
    return result
end
function cache:deleteHighlight(id)
    for index, h in ipairs(highlights) do
        if h.id == id then table.remove(highlights, index) return true end
    end
    return false
end
package.preload["zsxq_cache"] = function()
    return { new = function() return cache end, writeFile = function() return true end }
end

local saved_settings = {}
G_reader_settings = {
    readSetting = function(_, key, default)
        local value = saved_settings[key]
        if value ~= nil then return value end
        return default
    end,
    saveSetting = function(_, key, value) saved_settings[key] = value end,
}

local Zsxq = require("main")
Zsxq.ui = { menu = { registerToMainMenu = function() end } }
Zsxq.loadToken = function() return "test-token" end

local passed = 0
local function check(condition, message)
    assert(condition, message)
    passed = passed + 1
end
local function last(kind)
    for i = #shown, 1, -1 do
        if shown[i]._kind == kind then return shown[i] end
    end
    return nil
end
local function last_notify()
    return last("InfoMessage")
end

Zsxq:init()
local menu_items = {}
Zsxq:addToMainMenu(menu_items)
check(menu_items.zsxq and menu_items.zsxq.text == "星球墨读", "plugin must be renamed to 星球墨读")
check(menu_items.zsxq.sorting_hint == "tools", "plugin must live in the tools first-level menu")
check(#menu_items.zsxq.sub_item_table == 4, "online, offline, highlights and settings entries expected")
check(#menu_items.zsxq.sub_item_table[4].sub_item_table == 6, "settings submenu should have six entries")

-- ===== 测试数据 =====
local group = { group_id = "g1", name = "测试星球" }
local offline_group = { group_id = "g2", name = "离线星球" }
local function make_topic(id, content, topic_group)
    return {
        topic_id = id,
        content = content,
        create_time = "2026-11-04T09:00:00.000+0800",
        owner = { name = "作者" },
        group = topic_group or group,
        counts = { comments = 1 },
    }
end

-- ===== 离线阅读：星球列表 → 星球内帖子（上一篇/下一篇可用） =====
local offline_a = make_topic("offline1", "离线正文A", offline_group)
local offline_b = make_topic("offline2", "离线正文B", offline_group)
cache:saveTopic(offline_a)
cache:saveTopic(offline_b)

Zsxq:showOfflineGroups()
local offline_groups = Zsxq.list_menu
check(offline_groups ~= nil and #offline_groups.item_table == 1, "offline groups should list cached groups")
check(offline_groups.item_table[1].text == "离线星球", "offline group name shown")
offline_groups.item_table[1].callback()
local offline_list = Zsxq.list_menu
check(offline_list ~= nil and #offline_list.item_table == 2, "per-group offline list shows both topics")
offline_list.item_table[1].callback() -- 第一篇
local offline_viewer = last("TextViewer")
check(offline_viewer ~= nil and offline_viewer.text:match("离线正文A") ~= nil, "offline topic opens")
check(offline_viewer.buttons_table[2][1].enabled ~= true, "prev disabled on first offline topic")
check(offline_viewer.buttons_table[2][3].enabled == true, "offline next button enabled")
check(type(offline_viewer.page_turn_callback_next) == "function",
    "page-turn-past-end callback must be wired")
offline_viewer.page_turn_callback_next() -- 翻到底再按翻页键
local offline_next_viewer = last("TextViewer")
check(offline_next_viewer ~= offline_viewer and offline_next_viewer.text:match("离线正文B") ~= nil,
    "page-turn past end must load the next offline topic")
check(offline_next_viewer.buttons_table[2][1].enabled == true, "prev enabled on second topic")
offline_next_viewer.buttons_table[2][1].callback() -- ‹ 上一篇
check(last("TextViewer").text:match("离线正文A") ~= nil, "prev button navigates back")
-- 关闭阅读页 → 回离线帖子列表 → 关闭 → 回离线星球列表
local back_viewer = last("TextViewer") -- 上一篇后是新实例
back_viewer.buttons_table[3][4].callback()
check(Zsxq.topic_viewer == nil and Zsxq.list_menu == offline_list, "closing offline reader returns to offline list")
offline_list.close_callback() -- 模拟 Back 键关闭
check(Zsxq.list_menu ~= offline_list and Zsxq.list_menu.title == "我的星球 · 离线",
    "closing offline topic list must return to offline groups, not KOReader")

-- ===== 在线：列表层级 + Back 键逐层返回 =====
local topics = {
    make_topic("t1", "帖子一 正文"),
    make_topic("t2", "帖子二 正文"),
    make_topic("t3", "帖子三 正文"),
}
Zsxq.getAPI = function()
    return {
        getGroups = function() return true, { groups = { group } } end,
        getTopics = function() return true, { topics_brief = topics, has_more = false } end,
        getTopic = function(_, topic_id)
            for _, topic in ipairs(topics) do
                if topic.topic_id == topic_id then return true, { topic = topic } end
            end
            return false, "not found"
        end,
    }
end
Zsxq:showGroups()
local groups_menu = Zsxq.list_menu
check(groups_menu ~= nil and groups_menu.title == "我的星球", "groups list opens")
groups_menu.item_table[1].callback()
local group_menu = Zsxq.list_menu
check(group_menu ~= groups_menu and group_menu.title == "测试星球", "group page opens")
group_menu.item_table[1].callback() -- 最新帖子
local topics_menu = Zsxq.list_menu
-- Back 键关闭帖子列表 → 星球主页
topics_menu.close_callback()
local back_group_menu = Zsxq.list_menu
check(back_group_menu ~= topics_menu and back_group_menu.title == "测试星球",
    "closing topics list must return to group page")
-- Back 键关闭星球主页 → 我的星球
back_group_menu.close_callback()
check(Zsxq.list_menu ~= back_group_menu and Zsxq.list_menu.title == "我的星球",
    "closing group page must return to groups list")

-- 重新进入：我的星球 → 星球主页 → 帖子列表
Zsxq.list_menu.item_table[1].callback() -- 打开星球主页
Zsxq.list_menu.item_table[1].callback() -- 最新帖子
topics_menu = Zsxq.list_menu
check(topics_menu ~= nil and #topics_menu.item_table == 4, "topics list reopens")

-- 帖子导航：prev/next 按钮 + 单例阅读页 + 翻页连读
topics_menu.item_table[3].callback() -- 打开第 2 篇
local viewer = last("TextViewer")
check(viewer ~= nil and viewer.text:match("帖子二") ~= nil, "topic 2 should render")
check(viewer.buttons_table[2][1].text == "‹ 上一篇" and viewer.buttons_table[2][1].enabled == true,
    "prev button enabled for topic 2")
check(viewer.buttons_table[2][3].text == "下一篇 ›" and viewer.buttons_table[2][3].enabled == true,
    "next button enabled for topic 2")
viewer.buttons_table[3][4].callback() -- 关闭 → 回帖子列表
check(Zsxq.list_menu == topics_menu, "closing reader returns to topic list, not KOReader")

viewer = last("TextViewer")
viewer.page_turn_callback_next() -- 滚到底再按翻页
check(last("TextViewer") ~= viewer and last("TextViewer").text:match("帖子三") ~= nil,
    "page-turn past end loads next topic")
viewer = last("TextViewer")
check(viewer.buttons_table[2][3].enabled ~= true, "next disabled on the last topic")
viewer.buttons_table[2][1].callback()
check(last("TextViewer").text:match("帖子二") ~= nil, "prev button navigates back to topic 2")

-- ===== Markdown 转换 =====
local md_topic = make_topic("md1", "# 晨读笔记\n**重点**内容\n- 第一条\n- 第二条")
Zsxq:openTopic(md_topic, nil)
local md_viewer = last("TextViewer")
check(md_viewer.text:match("■ 晨读笔记") ~= nil, "markdown h1 should render as styled prefix")
check(md_viewer.text:match("%*%*") == nil, "bold markers should be stripped")
check(md_viewer.text:match("• 第一条") ~= nil, "markdown list should become bullet")
md_viewer.buttons_table[3][4].callback()

-- ===== 图片：签名压缩图下载 → ImageViewer 弹窗（完全不经过阅读器） =====
local signed_thumb = "https://images.zsxq.com/Fabc?imageMogr2/auto-orient/thumbnail/380x/format/jpg/blur/1x0/quality/75&e=1798732799&token=xyz"
local signed_large = "https://images.zsxq.com/Fabc?imageMogr2/auto-orient/thumbnail/800x/format/jpg&e=1798732799&token=xyz2"
local signed_topic = make_topic("img1", "纯文字帖子")
signed_topic.images = { { thumbnail = { url = signed_thumb }, large = { url = signed_large } } }
local topic_images = require("zsxq_content").topicImages(signed_topic)
check(#topic_images == 1 and topic_images[1].thumbnail == signed_thumb,
    "signed thumbnail URL must be used verbatim")
local downloaded = {}
Zsxq.getAPI = function()
    return {
        download = function(_, url)
            downloaded[#downloaded + 1] = url
            return true, "JPEGDATA", { ["Content-Type"] = "image/jpeg" }
        end,
    }
end
local files_before_img = #opened_files
Zsxq:showImages(signed_topic, topic_images)
check(#downloaded == 1 and downloaded[1] == signed_thumb,
    "images must download the official compressed thumbnail URL")
check(#opened_files == files_before_img, "image viewing must not open any reader document")
local image_viewer = last("ImageViewer")
check(image_viewer ~= nil, "images open in an ImageViewer popup")
check(type(image_viewer.image) == "table" and #image_viewer.image == 1 and image_viewer.image.image_disposable == true,
    "image list should be a lazily-loaded disposable table")
local rendered_bb = image_viewer.image[1]()
check(rendered_bb ~= nil and rendered_image_paths[#rendered_image_paths] == "/tmp/article.jpg",
    "lazy loader must render the cached image file")
-- 第二次打开：命中图片缓存，不再下载
Zsxq:showImages(signed_topic, topic_images)
check(#downloaded == 1, "second image open must hit the image cache")

-- ===== 点选段落划线（纯插件界面） =====
local hl2_topic = make_topic("hl2", "第一段划线目标\n\n第二段划线目标")
Zsxq:showTopicParagraphs(hl2_topic)
local paragraph_menu = Zsxq.list_menu
check(paragraph_menu ~= nil and #paragraph_menu.item_table == 2, "both paragraphs should be pickable")
local hl_before = #highlights
paragraph_menu.item_table[1].callback()
check(Zsxq.list_menu == nil, "picker must be closed via closeListMenu")
local hl_confirm = last("ConfirmBox")
check(hl_confirm ~= nil and hl_confirm.text:match("第一段划线目标") ~= nil,
    "highlight confirmation shows the exact paragraph")
hl_confirm.ok_callback()
check(#highlights == hl_before + 1 and highlights[#highlights].topic_id == "hl2",
    "confirmed highlight must persist to cache")

-- ===== 图文模式（可选高级入口）：手动进阅读器滑动划线 =====
local hl_topic = make_topic("hl1", "第一段划线目标\n\n第二段划线目标")
Zsxq:openHighlightReader(hl_topic)
local hl_html_path = "/tmp/zsxq_topic_hl1.html"
check(opened_files[#opened_files] == hl_html_path, "图文 mode opens generated HTML in ReaderUI")
local hl_file = io.open(hl_html_path)
local hl_html = hl_file and hl_file:read("*a") or ""
if hl_file then hl_file:close() end
check(hl_html:match("第一段划线目标") ~= nil, "HTML contains topic body")
check(hl_html:match("<html") ~= nil, "HTML document is well formed")
check(saved_settings.default_highlight_action == "highlight",
    "swipe-select should default to saving highlights")
local embedded_toggle = nil
local patch_events = {}
ReaderUIStub.instance = {
    document = {
        file = hl_html_path,
        configurable = { embedded_css = 0 },
        setEmbeddedStyleSheet = function(self, toggle) embedded_toggle = toggle end,
    },
    ui = { handleEvent = function(_, ev) patch_events[#patch_events + 1] = ev.name end },
}
for _, fn in ipairs(scheduled) do fn() end
check(type(ReaderUIStub.instance.showFileManager) == "function",
    "图文 mode must patch showFileManager for return to the plugin")
check(embedded_toggle == 1 and ReaderUIStub.instance.document.configurable.embedded_css == 1,
    "embedded styles must be auto-enabled for topic documents")
check(patch_events[#patch_events] == "UpdatePos", "embedded style change must trigger re-layout")
ReaderUIStub.instance = nil
-- 已有自定义行为时不覆盖
saved_settings.default_highlight_action = "note"
Zsxq:openHighlightReader(hl_topic)
check(saved_settings.default_highlight_action == "note",
    "user-customized highlight action must be preserved")

-- 导航锁：点选条目（打开帖子）后 Menu 原生触发的 close_callback 不得重建上一层。
-- （前面划线段已关闭所有列表菜单，先重建帖子列表再模拟 Menu 的原生时序）
Zsxq.getAPI = function()
    return {
        getGroups = function() return true, { groups = { group } } end,
        getTopics = function() return true, { topics_brief = topics, has_more = false } end,
        getTopic = function()
            return true, { topic = topics[2] }
        end,
    }
end
Zsxq:showGroups()
Zsxq.list_menu.item_table[1].callback() -- 星球主页
Zsxq.list_menu.item_table[1].callback() -- 最新帖子
topics_menu = Zsxq.list_menu
check(topics_menu ~= nil and #topics_menu.item_table == 4,
    "topics list rebuilt for navigation-lock test")
topics_menu.onMenuChoice(topics_menu, topics_menu.item_table[3]) -- 模拟 Menu 点选流程
check(last("TextViewer") ~= nil and last("TextViewer").text:match("帖子二") ~= nil,
    "topic opens from menu choice")
check(Zsxq.list_menu == topics_menu, "item callback must keep the parent list intact")
topics_menu.close_callback() -- Menu 在条目回调后必然调用
check(Zsxq.list_menu == topics_menu,
    "close_callback right after item navigation must NOT rebuild the parent list")

-- ===== 功能页直读（默认）+ 图文模式（可选入口）+ 翻页连读（EndOfBook） =====
Zsxq.getAPI = function()
    return {
        getTopic = function(_, topic_id)
            for _, topic in ipairs(topics) do
                if topic.topic_id == topic_id then return true, { topic = topic } end
            end
            return false, "not found"
        end,
    }
end
local files_before_open = #opened_files
topics_menu.item_table[3].callback() -- 打开第 2 篇 → 直接显示功能页
check(last("TextViewer") ~= nil and last("TextViewer").text:match("帖子二") ~= nil,
    "openTopic should show the feature page directly")
check(#opened_files == files_before_open,
    "openTopic must NOT open any reader document by default")
-- 可选图文入口：📖 图文按钮 → 生成 HTML 并用阅读器打开（正文 + 内嵌评论）
local t2_comments = {
    { comment_id = "c1", text = "第一条评论", owner = { name = "甲" },
      likes_count = 3, create_time = 1730000000 },
    { comment_id = "c2", text = "带回复的评论", owner = { name = "乙" },
      likes_count = 0, create_time = 1730000001,
      replied_comments = {
          { comment_id = "c2r", text = "楼中楼回复", owner = { name = "丙" },
            create_time = 1730000002, repliee = { name = "乙" } },
      } },
}
cache:put("comments_t2_first", { success = true, comments = t2_comments, has_more = false })
local feature_page = last("TextViewer")
local files_before_html = #opened_files
feature_page.buttons_table[3][3].callback() -- 📖 图文
check(#opened_files > files_before_html and opened_files[#opened_files] == "/tmp/zsxq_topic_t2.html",
    "feature-page 图文 button opens the rendered topic HTML")
local t2_file = io.open("/tmp/zsxq_topic_t2.html")
local t2_html = t2_file and t2_file:read("*a") or ""
if t2_file then t2_file:close() end
check(t2_html:match('<meta name="author" content="作者"') ~= nil,
    "document metadata must carry the author")
check(t2_html:match("<h1>帖子二 正文</h1>") ~= nil,
    "document h1 must carry the topic title")
check(t2_html:match('帖子二 正文') ~= nil and t2_html:match("</html>") ~= nil,
    "document body must be synced with the topic content")
check(t2_html:match("h1 { font%-size: 1em; font%-weight: bold; }") ~= nil,
    "h1 should be body-sized and bold")
-- 评论内嵌样式断言
check(t2_html:match("评论 2") ~= nil, "comments section must follow the body with top-level count")
check(t2_html:match('<span class="c%-author">甲</span>') ~= nil,
    "comment author must render as bold c-author span")
check(t2_html:match('<span class="c%-meta">♥ 3</span>') ~= nil,
    "likes icon and count must use the small gray meta span")
check(t2_html:match("color: #888888; font%-size: 0%.5em") ~= nil,
    "meta style must be gray and half-size")
local Content = require("zsxq_content")
local reply_body_pos = t2_html:find("楼中楼回复", 1, true)
local parent_time_pos = t2_html:find(Content.longTime(1730000001), 1, true)
check(reply_body_pos ~= nil and parent_time_pos ~= nil and parent_time_pos < reply_body_pos,
    "comment time must sit in the head right after the nickname")
check(t2_html:match("回复 @乙") ~= nil, "reply must annotate its repliee")
check(t2_html:find(Content.longTime(1730000002), 1, true) == nil,
    "replies must not show date or time")
-- 无评论缓存且接口不可用 → 静默跳过评论区
Zsxq:openHighlightReader(make_topic("noc", "无评论帖子正文"))
local noc_file = io.open("/tmp/zsxq_topic_noc.html")
local noc_html = noc_file and noc_file:read("*a") or ""
if noc_file then noc_file:close() end
check(noc_html ~= "" and noc_html:match("评论 %d") == nil,
    "missing comments must be skipped silently")
-- 翻过最后一页：EndOfBook → 两段式切换（出事件栈：先关当前文档，再开下一篇）
Zsxq.ui = { document = { file = "/tmp/zsxq_topic_t2.html" } }
local files_before_eob = #opened_files
check(Zsxq:onEndOfBook() == true, "EndOfBook with reading context should handle the event")
for _ = 1, 3 do -- 执行延迟回调（关闭文档 → 打开下一篇，可能多轮）
    for i = 1, #scheduled do scheduled[i]() end
end
check(#opened_files > files_before_eob and opened_files[#opened_files] == "/tmp/zsxq_topic_t3.html",
    "EndOfBook must load the next topic's rendered HTML (deferred switch)")
-- 普通书不受影响
Zsxq.ui = { document = { file = "/mnt/us/books/other.epub" } }
check(Zsxq:onEndOfBook() == false, "EndOfBook on unrelated documents must be ignored")
-- 本页最后一帖：给用户可见反馈而不是静默失败
Zsxq.ui = { document = { file = "/tmp/zsxq_topic_t3.html" } }
check(Zsxq:onEndOfBook() == false, "EndOfBook on the last topic should not navigate")
check(last_notify() ~= nil and last_notify().text:match("最后一帖") ~= nil,
    "last topic must notify the user instead of failing silently")

-- ===== 功能页正文+评论连续显示（楼中楼单行、无序号、无时间） =====
local fp_comments = {
    { comment_id = "d1", text = "顶层评论内容", owner = { name = "甲" },
      likes_count = 3, create_time = "2026-11-04T09:01:00.000+0800" },
    { comment_id = "d2", text = "父评论内容", owner = { name = "乙" },
      create_time = "2026-11-04T09:02:00.000+0800",
      replied_comments = {
          { comment_id = "d2r", text = "楼中楼回复内容", owner = { name = "丙" },
            create_time = "2026-11-04T09:03:00.000+0800", repliee = { name = "乙" } },
      } },
}
cache:put("comments_fp1_first", { success = true, comments = fp_comments, has_more = false })
Zsxq:openTopic(make_topic("fp1", "功能页正文"))
local fp_viewer = last("TextViewer")
check(fp_viewer.text:match("功能页正文") ~= nil, "feature page shows the body")
check(fp_viewer.text:match("^作者 2026%-11%-04 09:00\n") ~= nil,
    "header must be a single line: name and time without labels")
check(fp_viewer.text:match("↳ 丙 回复 @乙：楼中楼回复内容") ~= nil,
    "feature page comments continue after the body with single-line replies")
check(fp_viewer.text:match("1%.1") == nil, "feature page replies must not use numeric numbering")
check(fp_viewer.text:match("09:03") == nil, "feature page replies must not show time")
-- v14：正文后多留几行空白，评论标题夹在两条分割线之间
check(fp_viewer.text:match("\n\n\n\n\n────────────────\n【评 论】\n────────────────\n") ~= nil,
    "comment section must be introduced by blank lines and a double-ruled title")
-- v14：「回复某条评论」按钮回到功能页第一行按钮排
local fp_reply_btn = fp_viewer.buttons_table[1][2]
check(fp_reply_btn ~= nil and fp_reply_btn.text == "回复某条评论" and fp_reply_btn.enabled == true,
    "reply-to-comment button must sit in the first button row and be enabled")
-- 评论未拉全时（接口失败中断）给出部分显示提示
cache:put("comments_fp2_first", { success = true,
    comments = { { comment_id = "e1", text = "第一条", owner = { name = "甲" } } },
    has_more = true, index = "next-idx" })
Zsxq:openTopic(make_topic("fp2", "更多评论正文"))
check(last("TextViewer").text:match("已显示前 1 条（上限 2000）") ~= nil,
    "feature page must hint when comments were only partially loaded")

-- ===== 口径统一：楼层号 vs 含楼中楼总数 =====
cache:put("comments_cal_first", { success = true,
    comments = {
        { comment_id = "k1", text = "一楼内容", owner = { name = "甲" } },
        { comment_id = "k2", text = "二楼内容", owner = { name = "乙" } },
    },
    has_more = false })
local cal_topic = make_topic("cal", "口径正文")
cal_topic.counts = { comments = 504 }
Zsxq:openTopic(cal_topic)
local cal_viewer = last("TextViewer")
check(cal_viewer.text:match("已显示 2 楼 · 合计 504 条（含楼中楼）") ~= nil,
    "comment stats must distinguish floor count from reply-inclusive total")
check(cal_viewer.buttons_table[1][1].text == "评论 504 条",
    "comments button must use the total-count wording")
Zsxq:openHighlightReader(cal_topic)
local cal_file = io.open("/tmp/zsxq_topic_cal.html")
local cal_html = cal_file and cal_file:read("*a") or ""
if cal_file then cal_file:close() end
check(cal_html:match("含楼中楼合计 504 条") ~= nil,
    "图文 comments title must show the reply-inclusive total")

-- ===== v14 静默加载：评论 ≤30 条全程无「正在加载」弹窗，>30 条才提示 =====
local function count_loading_msgs()
    local n = 0
    for _, w in ipairs(shown) do
        if w._kind == "InfoMessage" and type(w.text) == "string" and w.text:match("正在加载") then
            n = n + 1
        end
    end
    return n
end
local quiet_before = count_loading_msgs()
cache:put("comments_quiet1_first", { success = true,
    comments = { { comment_id = "q1", text = "静默评论", owner = { name = "甲" } } },
    has_more = false })
Zsxq.getAPI = function()
    return {
        getTopic = function() return true, { topic = make_topic("quiet1", "静默正文") } end,
        getComments = function() return true, { comments = {}, has_more = false } end,
    }
end
Zsxq:openTopic(make_topic("quiet1", "静默正文"))
check(count_loading_msgs() == quiet_before,
    "quiet topics (<=30 comments) must load without any loading popup")
check(last("TextViewer").text:match("静默评论") ~= nil,
    "quiet topic still shows its comments")
-- 评论多的帖子（>30 条）保留「正在加载」提示
local loud_before = count_loading_msgs()
cache:put("comments_loud1_first", { success = true,
    comments = { { comment_id = "l1", text = "第一批", owner = { name = "甲" } } },
    has_more = true, index = "lidx" })
Zsxq.getAPI = function()
    return {
        getTopic = function() return true, { topic = make_topic("loud1", "响亮正文") } end,
        getComments = function()
            return true, { comments = { { comment_id = "l2", text = "第二批", owner = { name = "乙" } } },
                has_more = false, index = nil }
        end,
    }
end
local loud_topic = make_topic("loud1", "响亮正文")
loud_topic.counts = { comments = 100 }
Zsxq:openTopic(loud_topic)
check(count_loading_msgs() > loud_before,
    "loud topics (>30 comments) must show loading popups")
check(last("TextViewer").text:match("第二批") ~= nil,
    "loud topic comments are still fully fetched")

-- ===== 图文模式：加载更多评论 =====
local lm_closed = false
local lm_api_index = nil
Zsxq.ui = { document = { file = "/tmp/zsxq_topic_lm.html" },
    onClose = function() lm_closed = true end }
cache:put("comments_lm_first", { success = true,
    comments = { { comment_id = "m1", text = "第一批", owner = { name = "甲" } } },
    has_more = true, index = "idx-1" })
Zsxq.getAPI = function()
    return {
        getComments = function(_, topic_id, index)
            lm_api_index = index
            return true, { comments = { { comment_id = "m2", text = "第二批", owner = { name = "乙" } } },
                has_more = false, index = nil }
        end,
    }
end
-- ===== 打开帖子即加载全部评论（缓存未拉全时从游标续拉） =====
Zsxq.ui = { document = { file = "/tmp/zsxq_topic_lm.html" } }
cache:put("comments_lm_first", { success = true,
    comments = { { comment_id = "m1", text = "第一批", owner = { name = "甲" } } },
    has_more = true, index = "idx-1" })
Zsxq.getAPI = function()
    return {
        getComments = function(_, topic_id, index)
            lm_api_index = index
            return true, { comments = { { comment_id = "m2", text = "第二批", owner = { name = "乙" } } },
                has_more = false, index = nil }
        end,
    }
end
Zsxq:openTopic(make_topic("lm", "加载更多正文"))
check(lm_api_index == "idx-1", "opening a topic with partial cache must resume from the cursor")
local lm_data = store["comments_lm_first"]
check(#lm_data.comments == 2 and lm_data.has_more == false,
    "top-up must append the new page and clear has_more")
local lm_viewer = last("TextViewer")
check(lm_viewer ~= nil and lm_viewer.text:match("第一批") ~= nil
    and lm_viewer.text:match("第二批") ~= nil,
    "feature page must show all comments after top-up")
-- 新帖首次打开：多页循环直到 has_more 为 false
cache:put("comments_lm2_first", { success = true,
    comments = { { comment_id = "p1", text = "第1页", owner = { name = "甲" } } },
    has_more = true, index = "p1" })
local lm2_pages = {
    p1 = { comments = { { comment_id = "p2", text = "第2页", owner = { name = "乙" } } },
        has_more = true, index = "p2" },
    p2 = { comments = { { comment_id = "p3", text = "第3页", owner = { name = "丙" } } },
        has_more = false, index = nil },
}
Zsxq.getAPI = function()
    return { getComments = function(_, topic_id, index) return true, lm2_pages[index] end }
end
Zsxq:openTopic(make_topic("lm2", "fetch-all 正文"))
local lm2_data = store["comments_lm2_first"]
check(#lm2_data.comments == 3 and lm2_data.has_more == false,
    "first open must loop pages until has_more is false")
check(last("TextViewer").text:match("第2页") ~= nil
    and last("TextViewer").text:match("第3页") ~= nil,
    "feature page must show all fetched comments")

-- ===== markdown 长文图片：默认视图占位 + 图文原位内嵌 =====
local md_img_topic = make_topic("mdi", "标题行\n\n![图表](https://images.zsxq.com/Fpicabc)\n\n正文段落")
cache:saveTopic(md_img_topic)
Zsxq.getAPI = function()
    return {
        download = function()
            return true, "fakejpegdata", { ["content-type"] = "image/jpeg" }
        end,
    }
end
Zsxq:openTopic(md_img_topic)
local mdi_viewer = last("TextViewer")
check(mdi_viewer.text:match("%[图片1%]") ~= nil, "markdown image should become an inline placeholder")
check(mdi_viewer.text:match("images%.zsxq%.com") == nil, "raw image URL should not leak into the body")
Zsxq:openHighlightReader(md_img_topic)
local mdi_file = io.open("/tmp/zsxq_topic_mdi.html")
local mdi_html = mdi_file and mdi_file:read("*a") or ""
if mdi_file then mdi_file:close() end
local img_pos = mdi_html:find('<img src="article%.jpg"', 1)
local body_pos = mdi_html:find("正文段落", 1, true)
check(img_pos ~= nil and body_pos ~= nil and img_pos < body_pos,
    "markdown image must embed at its placeholder position, before the following text")

-- ===== 离线缓存进度 + 列表缓存计数 =====
Zsxq.getAPI = function()
    return {
        getTopic = function()
            return true, { topic = { topic_id = "ct1", content = "缓存正文", group = group,
                create_time = "2026-11-04T09:00:00.000+0800", owner = { name = "作者" },
                counts = { comments = 0 } } }
        end,
        getComments = function() return false, "offline" end,
    }
end
Zsxq:cacheTopics({ { topic_id = "ct1", group = group } })
check(last_notify() ~= nil and last_notify().text:match("正文 1/1 篇") ~= nil,
    "cacheTopics must report the final result")
local seen_progress = false
for _, w in ipairs(shown) do
    if w._kind == "InfoMessage" and w.text and w.text:match("正在缓存 1/1 篇") then
        seen_progress = true
    end
end
check(seen_progress, "cacheTopics must show per-topic progress")
Zsxq:showOfflineGroups()
local offline_menu = Zsxq.list_menu
local offline_count_ok = false
for _, item in ipairs(offline_menu.item_table) do
    if item.text == "测试星球" and item.mandatory and item.mandatory:match("%d 帖") then
        offline_count_ok = true
    end
end
check(offline_count_ok, "offline group list must show cached topic counts")

-- ===== 自绘全屏二维码 =====
qr_painted = {} -- 清空计数
Zsxq:showQRCode("https://example.com/very/long/link")
local qr_viewer = last("ImageViewer")
check(qr_viewer ~= nil and qr_viewer.title_text == "手机扫码打开",
    "QR should render via ImageViewer with a scan-friendly title")
check(#qr_painted == 2, "dark QR modules must be painted")
check(qr_painted[1].w == 341, "module size must scale with screen width (floor(758*0.9/2))")

-- ===== 阅读菜单功能组（轻触屏幕顶部调出，Kindle 无 Home 键的退出路径） =====
local reader_ui = { document = { file = "/tmp/zsxq_topic_t2.html" } }
reader_ui.onClose = function() reader_ui.closed = true end
Zsxq.ui = reader_ui
local reader_menu_items = {}
Zsxq:addToMainMenu(reader_menu_items)
check(reader_menu_items.zsxq ~= nil and #reader_menu_items.zsxq.sub_item_table == 5,
    "reader menu should register the topic feature group (next/prev/jump/comments/return)")
check(reader_menu_items.zsxq.sub_item_table[3].text:match("跳转开头") ~= nil,
    "reader menu must offer a jump-to-top entry")
check(reader_menu_items.zsxq.sub_item_table[1].enabled_func() == true,
    "next-topic should be enabled while reading a topic with context")
local files_before_menu_next = #opened_files
reader_menu_items.zsxq.sub_item_table[1].callback()
check(#opened_files > files_before_menu_next and opened_files[#opened_files] == "/tmp/zsxq_topic_t3.html",
    "reader menu next-topic must stay in 图文 mode (render next topic HTML)")
reader_menu_items.zsxq.sub_item_table[5].callback() -- 返回帖子列表
check(reader_ui.closed == true, "return-to-list must close the document (feature page shows underneath)")
-- 普通文档：功能项回调兜底提示，不报错、不切文档
Zsxq.ui = { document = { file = "/mnt/us/books/other.epub" } }
reader_menu_items = {}
Zsxq:addToMainMenu(reader_menu_items)
local files_before_menu = #opened_files
reader_menu_items.zsxq.sub_item_table[1].callback()
check(#opened_files == files_before_menu, "next-topic on unrelated document must be a no-op")

-- ===== 轻点屏幕上部功能菜单（Kindle 无 Home 键） =====
saved_settings.activate_menu = nil
local registered_zones = nil
local reader_ctx_ui = {
    document = { file = "/tmp/zsxq_topic_t2.html" },
    menu = { registerToMainMenu = function() end },
    registerTouchZones = function(_, zones) registered_zones = zones end,
    handleEvent = function() end,
}
reader_ctx_ui.onClose = function() reader_ctx_ui.closed = true end
Zsxq.ui = reader_ctx_ui
Zsxq:init()
check(saved_settings.activate_menu == "swipe",
    "KOReader menu must be swipe-only so top tap is reserved for the feature menu")
check(registered_zones ~= nil and #registered_zones == 1 and registered_zones[1].id == "zsxq_top_tap",
    "plugin must register a top tap zone in reader context")
check(registered_zones[1].handler() == true, "top tap on a topic document must be consumed")
local feature_dialog = last("ButtonDialog")
check(feature_dialog ~= nil and #feature_dialog.buttons == 6,
    "feature menu should list next/prev/jump/reply/return/close actions")
-- 跳转开头：当前 stub 文档无 rolling/paging，应兜底提示而不是报错
local jump_row_found = false
for _, row in ipairs(feature_dialog.buttons) do
    if row[1].text:match("跳转开头") then
        jump_row_found = true
        row[1].callback()
        break
    end
end
check(jump_row_found, "feature menu must offer a jump-to-top entry")
check(last_notify() ~= nil and last_notify().text:match("跳转") ~= nil,
    "jump-to-top on an unsupported document must notify instead of failing")
Zsxq.getAPI = function()
    return {
        getComments = function()
            return true, { comments = { { comment_id = "c1", text = "评论内容", owner = { name = "甲" } } }, has_more = false }
        end,
    }
end
-- 写评论：评论已内嵌正文后，菜单提供写评论入口
for _, row in ipairs(feature_dialog.buttons) do
    if row[1].text == "写评论" then row[1].callback() break end
end
check(last("InputDialog") ~= nil, "写评论 should open the reply dialog from the feature menu")
-- 返回帖子列表：必须先关闭菜单本体（修复：菜单残留屏幕），再关文档并重建列表
local closed_before_return = #closed
for _, row in ipairs(feature_dialog.buttons) do
    if row[1].text == "返回帖子列表" then row[1].callback() break end
end
check(reader_ctx_ui.closed == true, "return-to-list from feature menu must close the document")
local dialog_closed = false
for i = closed_before_return + 1, #closed do
    if closed[i] == feature_dialog then dialog_closed = true end
end
check(dialog_closed, "feature menu must close itself before performing the action")
check(Zsxq.list_menu ~= nil and Zsxq.list_menu.title == "测试星球 · 最新",
    "return-to-list must rebuild the topics list")
-- ✕ 关闭图文：仅关闭文档，不重建列表
local list_after_return = Zsxq.list_menu
for _, row in ipairs(feature_dialog.buttons) do
    if row[1].text == "✕ 关闭图文" then row[1].callback() break end
end
check(reader_ctx_ui.closed == true and Zsxq.list_menu == list_after_return,
    "关闭图文 closes the document without rebuilding the list")
-- 普通文档：轻点顶部不弹功能菜单（KOReader 菜单走下滑手势）
local other_zones = nil
local other_ui = {
    document = { file = "/mnt/us/books/other.epub" },
    menu = { registerToMainMenu = function() end },
    registerTouchZones = function(_, zones) other_zones = zones end,
}
Zsxq.ui = other_ui
Zsxq:init()
local function count_dialogs()
    local n = 0
    for _, w in ipairs(shown) do if w._kind == "ButtonDialog" then n = n + 1 end end
    return n
end
local dialogs_before_tap = count_dialogs()
other_zones[1].handler()
check(count_dialogs() == dialogs_before_tap,
    "top tap on unrelated documents must not open the feature menu")

Zsxq.ui = { menu = { registerToMainMenu = function() end } }

-- ===== 我的划线：历史记录查看/删除 =====
local hl_total_before = #highlights -- 前面点选段落划线段已写入过记录，这里用增量断言
cache:addHighlight("hl1", "测试标题", "历史划线内容")
Zsxq:showHighlights()
local hl_list = Zsxq.list_menu
check(hl_list ~= nil and #hl_list.item_table == hl_total_before + 1,
    "highlights list should show saved highlight")
hl_list.item_table[#hl_list.item_table].callback() -- 刚保存的一条
local hl_viewer = last("TextViewer")
check(hl_viewer ~= nil and hl_viewer.title:match("测试标题") ~= nil,
    "highlight detail should open")
hl_viewer.buttons_table[1][1].callback() -- 删除
local delete_confirm = last("ConfirmBox")
delete_confirm.ok_callback()
check(#highlights == hl_total_before, "delete must remove the highlight")

-- ===== 星球列表加载失败且无缓存：真实错误保留 =====
store["groups"] = nil
Zsxq.getAPI = function()
    return { getGroups = function() return false, "网络连接失败：无法解析主机 mcp.zsxq.com" end }
end
Zsxq:showGroups()
local error_viewer = last("TextViewer")
check(error_viewer and error_viewer.text:match("无法解析主机") ~= nil,
    "failure without cache must keep the real error message")

-- ===== 回复确认：确认前不发送 =====
local sent = {}
Zsxq.getAPI = function()
    return {
        createComment = function(_, topic_id, text, reply_id)
            sent = { topic_id = topic_id, text = text, reply_id = reply_id }
            return true, { success = true, comment_id = "new-c" }
        end,
    }
end
Zsxq:showReplyDialog(topics[1])
local input = last("InputDialog")
input.getInputText = function() return "确认后的测试评论" end
input.buttons[1][2].callback()
local confirmation = last("TextViewer")
check(confirmation and confirmation.text:match("确认后的测试评论") ~= nil, "full reply should require confirmation")
check(sent.text == nil, "reply must not be sent before confirmation")
confirmation.buttons_table[1][2].callback()
check(sent.topic_id == "t1" and sent.text == "确认后的测试评论", "confirmed reply should use official API")

-- ===== 发帖：预览零 API 调用，确认后发布；返回编辑保留草稿 =====
local create_calls = {}
Zsxq.getAPI = function()
    return {
        createTopic = function(_, group_id, title, content)
            create_calls[#create_calls + 1] = { group_id = group_id, title = title, content = content }
            return true, { success = true, topic_id = "new-topic-9" }
        end,
    }
end
local refreshed = false
Zsxq:confirmCreateTopic(group, "标题", "正文", function() refreshed = true end)
check(#create_calls == 0, "no API call before confirmation")
local preview = last("TextViewer")
check(preview ~= nil and preview.text:match("正文") ~= nil, "preview shows full content")
preview.buttons_table[1][1].callback() -- 返回编辑
local content_dialog = last("InputDialog")
check(content_dialog ~= nil and content_dialog.input == "正文", "edit must restore the draft")
content_dialog.getInputText = function() return "正文" end
content_dialog.buttons[1][2].callback() -- 再次预览
preview = last("TextViewer")
check(preview ~= nil and preview ~= content_dialog, "preview recreated after editing")
Zsxq.posting = true
preview.buttons_table[1][2].callback() -- 确认发布（posting 守卫生效）
check(#create_calls == 0, "posting guard must block duplicate submission")
Zsxq.posting = nil
preview.buttons_table[1][2].callback()
check(#create_calls == 1 and create_calls[1].group_id == "g1" and create_calls[1].title == "标题",
    "confirmed publish calls createTopic with group/title/content")
check(refreshed, "successful publish should refresh the topic list")

print(string.format("test_main: %d assertions passed", passed))
