local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local ImageViewer = require("ui/widget/imageviewer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local QRMessage = require("ui/widget/qrmessage")
local ReaderUI = require("apps/reader/readerui")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local API = require("zsxq_api")
local Cache = require("zsxq_cache")
local Content = require("zsxq_content")
local Html = require("zsxq_html")
local RenderImage = require("ui/renderimage")

local unpack = table.unpack or unpack
local Screen = Device.screen

-- 图文阅读连读上下文：key = 生成的 HTML 路径，value = { prev_topic, next_topic }。
-- KOReader 插件在 FileManager / ReaderUI 各有一个实例，跨实例数据必须放模块级。
local READING_CONTEXTS = {}

local Zsxq = WidgetContainer:extend{
    name = "zsxq",
    is_doc_only = false,
}

function Zsxq:init()
    self.cache = Cache.new()
    self.cache_days = tonumber(G_reader_settings:readSetting("zsxq_cache_days")) or 7
    if self.cache_days < 1 then self.cache_days = 1 end
    self.cache:purge(self.cache_days * 86400)
    self.ui.menu:registerToMainMenu(self)
    -- ReaderUI 上下文（图文阅读）：
    -- ① KOReader 菜单改为仅从顶部下滑调出（activate_menu=swipe）
    -- ② 轻点屏幕上部 → 弹出星球墨读功能菜单（下一篇/上一篇/评论/返回帖子列表）
    if self.ui and self.ui.document then
        if G_reader_settings:readSetting("activate_menu") ~= "swipe" then
            G_reader_settings:saveSetting("activate_menu", "swipe")
        end
        self.ui:registerTouchZones({
            {
                id = "zsxq_top_tap",
                ges = "tap",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 / 8 },
                overrides = { "readermenu_tap", "readermenu_ext_tap" },
                handler = function(ges) return self:onTopTap(ges) end,
            },
        })
    end
end

-- 轻点屏幕上部：星球帖子里弹功能菜单；其他文档无动作（菜单走下滑手势）
function Zsxq:onTopTap(ges)
    local doc = self.ui and self.ui.document
    if not doc or not READING_CONTEXTS[doc.file] then return true end
    self:showFeatureMenu()
    return true
end

-- 阅读中的功能菜单（ButtonDialog，点击外部即关闭 = 返回正文）。
-- 每个条目先关闭菜单再执行动作，否则执行后菜单仍停留在屏幕上。
function Zsxq:showFeatureMenu()
    local doc = self.ui and self.ui.document
    local ctx = doc and READING_CONTEXTS[doc.file] or nil
    local dialog
    local function act(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    local rows = {}
    if ctx then
        if ctx.next_topic then
            table.insert(rows, {{ text = "下一篇 ›", callback = act(ctx.next_topic) }})
        end
        if ctx.prev_topic then
            table.insert(rows, {{ text = "‹ 上一篇", callback = act(ctx.prev_topic) }})
        end
    end
    table.insert(rows, {{ text = "⤒ " .. _("跳转开头"), callback = act(function()
        self:jumpToDocTop()
    end) }})
    if ctx.topic then
        local topic = ctx.topic
        table.insert(rows, {{ text = _("写评论"), callback = act(function()
            self:showReplyDialog(topic)
        end) }})
    end
    table.insert(rows, {{ text = _("返回帖子列表"), callback = act(function()
        if self.ui and self.ui.onClose then self.ui:onClose() end
        if ctx and ctx.rebuild then ctx.rebuild() end
    end) }})
    table.insert(rows, {{ text = "✕ " .. _("关闭图文"), callback = act(function()
        if self.ui and self.ui.onClose then self.ui:onClose() end
    end) }})
    dialog = require("ui/widget/buttondialog"):new{
        title = "星球墨读 · 功能",
        buttons = rows,
    }
    UIManager:show(dialog)
end

-- 图文文档跳转开头（CRE 滚动/翻页都走 rolling 的 gotoPage，pcall 防版本差异）
function Zsxq:jumpToDocTop()
    local ui = self.ui
    local ok, err = pcall(function()
        if ui.rolling then
            ui.rolling:onGotoPage(1)
        elseif ui.paging then
            ui.paging:onGotoPage(1)
        else
            self:notify("当前文档不支持跳转。", 3)
        end
    end)
    if not ok then self:notify("跳转失败：" .. tostring(err), 4) end
end

function Zsxq:addToMainMenu(menu_items)
    -- ReaderUI 上下文：图文阅读时轻触屏幕顶部调出阅读菜单，里面有星球墨读功能组。
    -- Kindle 无 Home 键，退出阅读走「返回帖子列表」。
    if self.ui and self.ui.document then
        local function current_context()
            local doc = self.ui and self.ui.document
            return doc and READING_CONTEXTS[doc.file] or nil
        end
        menu_items.zsxq = {
            text = _("星球墨读"),
            sub_item_table = {
                {
                    text = "下一篇 ›",
                    enabled_func = function()
                        local ctx = current_context()
                        return ctx ~= nil and ctx.next_topic ~= nil
                    end,
                    callback = function()
                        local ctx = current_context()
                        if ctx and ctx.next_topic then
                            ctx.next_topic()
                        else
                            self:notify("没有下一篇。", 3)
                        end
                    end,
                },
                {
                    text = "‹ 上一篇",
                    enabled_func = function()
                        local ctx = current_context()
                        return ctx ~= nil and ctx.prev_topic ~= nil
                    end,
                    callback = function()
                        local ctx = current_context()
                        if ctx and ctx.prev_topic then
                            ctx.prev_topic()
                        else
                            self:notify("没有上一篇。", 3)
                        end
                    end,
                },
                {
                    text = "⤒ " .. _("跳转开头"),
                    callback = function() self:jumpToDocTop() end,
                },
                {
                    text = _("评论"),
                    enabled_func = function()
                        local ctx = current_context()
                        return ctx ~= nil and ctx.topic ~= nil
                    end,
                    callback = function()
                        local ctx = current_context()
                        if ctx and ctx.topic then
                            self:showComments(ctx.topic, nil, nil, nil, false)
                        end
                    end,
                },
                {
                    text = _("返回帖子列表"),
                    callback = function()
                        if self.ui and self.ui.onClose then self.ui:onClose() end
                        local ctx = current_context()
                        if ctx and ctx.rebuild then ctx.rebuild() end
                    end,
                },
            },
        }
        return
    end
    -- FileManager 上下文：插件主菜单
    menu_items.zsxq = {
        text = _("星球墨读"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("在线阅读"),
                callback = function() self:showGroups() end,
            },
            {
                text = _("离线阅读"),
                callback = function() self:showOfflineGroups() end,
            },
            {
                text = _("我的划线"),
                callback = function() self:showHighlights() end,
            },
            {
                text = _("缓存与账号设置"),
                sub_item_table = {
                    {
                        text = _("设置 MCP Token"),
                        callback = function() self:showTokenDialog() end,
                    },
                    {
                        text = _("连接诊断"),
                        callback = function() self:diagnose() end,
                    },
                    {
                        text_func = function()
                            return string.format(_("缓存保留天数：%d 天"), self.cache_days)
                        end,
                        callback = function() self:showCacheDaysDialog() end,
                    },
                    {
                        text = _("缓存概况"),
                        callback = function() self:showCacheStats() end,
                    },
                    {
                        text = _("清理过期缓存"),
                        callback = function() self:confirmPurge() end,
                    },
                    {
                        text = _("使用说明"),
                        callback = function() self:showHelp() end,
                    },
                },
            },
        },
    }
end

function Zsxq:tokenPath()
    return DataStorage:getSettingsDir() .. "/zsxq_token.txt"
end

-- 密钥获取指引（Token 输入框 / 未配置提示 / 401 诊断共用）
local TOKEN_HELP = "知识星球密钥管理（获取知识星球访问凭证，让 AI 助手以你的身份访问星球）\nhttps://garden.zsxq.com/jasmine/"

-- 图文阅读（CRE 文档）翻过最后一页再翻页 → 自动进下一篇。
-- KOReader ReaderPaging 在翻越末页时广播 EndOfBook 事件；普通书无上下文，不受影响。
function Zsxq:onEndOfBook()
    local ui = self.ui
    if not ui or not ui.document then return false end
    local file = ui.document.file
    if not file then return false end
    local context = READING_CONTEXTS[file]
    if not context then return false end
    if not context.next_topic then
        -- 给用户可见反馈，而不是静默失败
        self:notify("已是本页最后一帖。", 3)
        return false
    end
    self:notify("已到末页，正在打开下一篇…", 2)
    self:switchToNextReading(context)
    return true
end

-- 下一篇切换：两段式（先关当前文档，再走干净的 showReader 路径）。
-- ① 推迟到 EndOfBook 事件栈之外执行：事件栈内 showReader 会同步拆除
--    当前阅读器，返回后 ReaderRolling 访问已释放文档导致切换被中断。
-- ② 先关后开：部分 KOReader 版本在"阅读器已打开"时调 showReader 不生效，
--    先关闭当前文档（已补丁不弹文件管理器）再打开，走验证过的干净路径。
-- 每一步都有可见诊断，失败会提示具体原因。
function Zsxq:switchToNextReading(context)
    UIManager:scheduleIn(0.3, function()
        local ok, err = pcall(function()
            if self.ui and self.ui.onClose then
                self:notify("正在关闭当前文档…", 2)
                self.ui:onClose()
            end
        end)
        if not ok then
            self:notify("关闭当前文档失败：" .. tostring(err), 6)
            return
        end
        UIManager:scheduleIn(0.5, function()
            local ok2, err2 = pcall(function() context.next_topic() end)
            if not ok2 then
                self:notify("切换下一篇失败：" .. tostring(err2), 6)
            end
        end)
    end)
end

function Zsxq:loadToken()
    local file = io.open(self:tokenPath(), "rb")
    if file then
        local token = file:read("*a")
        file:close()
        token = Content.trim(token)
        if token ~= "" then return token end
    end
    return Content.trim(G_reader_settings:readSetting("zsxq_mcp_token"))
end

function Zsxq:getAPI()
    local token = self:loadToken()
    if not self.api or self.api_token ~= token then
        self.api = API.new(token)
        self.api_token = token
    end
    return self.api
end

function Zsxq:ensureToken()
    if self:loadToken() ~= "" then return true end
    UIManager:show(InfoMessage:new{
        text = _("请先设置知识星球 MCP Token。") .. "\n\n" .. TOKEN_HELP ..
            _("\n\n也可通过 USB 将 Token 写入：\nkoreader/settings/zsxq_token.txt"),
        timeout = 6,
    })
    self:showTokenDialog()
    return false
end

function Zsxq:notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = tostring(text), timeout = timeout or 4 })
end

function Zsxq:withLoading(text, fn, quiet)
    if quiet then
        -- 静默模式：不弹加载提示，直接执行（评论少的帖子秒开）
        local result = { pcall(fn) }
        if not result[1] then return false, result[2] end
        return unpack(result, 2)
    end
    local loading = InfoMessage:new{ text = text }
    UIManager:show(loading)
    UIManager:forceRePaint()
    local result = { pcall(fn) }
    UIManager:close(loading)
    if not result[1] then
        logger.err("ZSxq plugin error:", result[2])
        self:notify("操作失败：" .. tostring(result[2]), 6)
        return false, result[2]
    end
    return unpack(result, 2)
end

-- 列表菜单：同一时间只保留一个实例，避免叠加。
-- close_callback：用户主动关闭菜单（Back 键/返回箭头）时恢复上一层列表。
-- KOReader 的 Menu 在点选叶子条目后也会调用 close_callback——用导航锁区分：
-- 条目回调内的导航（打开帖子/下级列表）不触发"重建上一层"。
function Zsxq:showMenu(title, items, subtitle, close_callback)
    self:closeListMenu()
    local menu
    menu = Menu:new{
        title = title,
        subtitle = subtitle,
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuChoice = function(_, item)
            self._nav_in_progress = true
            if item.callback then item.callback(menu) end
        end,
        close_callback = function()
            if self._nav_in_progress then
                self._nav_in_progress = nil
                return
            end
            if self.list_menu ~= menu then return end -- 已被导航替换，跳过
            self.list_menu = nil
            if close_callback then close_callback() end
        end,
    }
    self.list_menu = menu
    UIManager:show(menu)
    return menu
end

function Zsxq:closeListMenu()
    if self.list_menu then
        local menu = self.list_menu
        self.list_menu = nil
        UIManager:close(menu)
    end
end

function Zsxq:showTokenDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("知识星球 MCP Token"),
        description = TOKEN_HELP .. "\n\n" .. _("只粘贴 api-key/token 本身，不要带网址或 Bearer。"),
        input = self:loadToken(),
        input_hint = _("MCP Bearer Token"),
        text_type = "password",
        width = Screen:getWidth() - Screen:scaleBySize(24),
        text_height = Screen:scaleBySize(80),
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("保存"),
                callback = function()
                    local token = Content.trim(dialog:getInputText())
                    if token == "" then
                        self:notify("Token 不能为空。")
                        return
                    end
                    local ok, err = Cache.writeFile(self:tokenPath(), token)
                    if ok then
                        G_reader_settings:saveSetting("zsxq_mcp_token", token)
                        UIManager:close(dialog)
                        self:notify("Token 已保存，可开始在线阅读。")
                    else
                        self:notify("保存失败：" .. tostring(err))
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Zsxq:showCacheDaysDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("缓存保留天数"),
        description = _("过期缓存会在启动插件或手动清理时删除；断网时会尽量使用已缓存内容。划线不会清理。"),
        input = tostring(self.cache_days),
        input_type = "number",
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("保存"),
                callback = function()
                    local days = dialog:getInputValue()
                    if not days or days < 1 or days > 365 then
                        self:notify("请输入 1–365 之间的天数。")
                        return
                    end
                    self.cache_days = math.floor(days)
                    G_reader_settings:saveSetting("zsxq_cache_days", self.cache_days)
                    UIManager:close(dialog)
                    self:notify("缓存保留天数已保存。")
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Zsxq:showCacheStats()
    local topics, articles, bytes = self.cache:stats()
    local highlights = #self.cache:listHighlights()
    self:notify(string.format("已缓存 %d 篇帖子、%d 个长文文件。\n长文占用 %.1f MB。\n划线 %d 条。\n缓存保留 %d 天。",
        topics, articles, bytes / 1024 / 1024, highlights, self.cache_days), 6)
end

function Zsxq:confirmPurge()
    UIManager:show(ConfirmBox:new{
        text = string.format("确定清理超过 %d 天的帖子、评论和长文缓存吗？\n\n划线不会删除。\n此操作不会影响知识星球云端内容。", self.cache_days),
        ok_text = _("清理"),
        ok_callback = function()
            local removed = self.cache:purge(self.cache_days * 86400)
            self:notify(string.format("已清理 %d 个过期文件。", removed))
        end,
    })
end

function Zsxq:showHelp()
    self:notify("星球墨读 · 出品人：简单的舟\n\n在线阅读：点帖子直接显示全文（秒开，不打开阅读器、不联网下载）。\n\n图片：点「图片」弹窗浏览压缩图，点屏幕左右翻页，关闭立即返回。\n\n划线：点「划线」→ 点选段落 → 确认保存；「我的划线」中查看删除。\n\n翻帖：功能页「上一篇/下一篇」按钮；翻到末尾再按翻页键自动进下一篇。\n\n评论/发帖：支持评论、楼中楼回复与发帖，发送前需确认。\n\n📖 图文（可选）：进排版文档（标题加粗、图片内嵌），长按滑动选中即划线，点已划线文字可删除/编辑，AI助手等高亮插件按钮也在其中；轻点屏幕上部可弹功能菜单，含跳转开头。\n\n进度条：图文阅读时轻点屏幕底部边缘可呼出/隐藏底部状态栏（含进度条），样式可在 KOReader「设置 → 状态栏」调整。\n\nMarkdown：加粗、标题、列表等标记自动转为阅读友好的样式。", 30)
end

-- ============ 连接诊断 ============

function Zsxq:diagnose()
    if not self:ensureToken() then return end
    NetworkMgr:runWhenOnline(function()
        local api = self:getAPI()
        local report = {
            "知识星球连接诊断",
            "目标：" .. api.endpoint,
            string.format("Token 长度：%d 字符（应为 32 位左右）", #api.token),
            "",
        }
        api.initialized = false
        api.session_id = nil
        api.negotiated_version = nil
        local ok, err = api:ensureSession()
        if ok then
            table.insert(report, "✔ MCP 握手成功（initialize + initialized）")
            local g_ok, groups = api:getGroups(5)
            if g_ok then
                local count = groups.groups and #groups.groups or 0
                table.insert(report, string.format("✔ 获取星球成功（返回 %d 个）", count))
                table.insert(report, "")
                table.insert(report, "结论：连接正常，可直接使用「在线阅读」。")
            else
                table.insert(report, "✘ 获取星球失败：" .. tostring(groups))
            end
        else
            table.insert(report, "✘ MCP 握手失败：" .. tostring(err))
            table.insert(report, "")
            table.insert(report, "常见原因：")
            table.insert(report, "· 网络连接失败 → Kindle Wi-Fi 未连通或 DNS 异常")
            table.insert(report, "· HTTP 401 → Token 无效或已过期，请在密钥管理页重新获取：")
            table.insert(report, "  " .. TOKEN_HELP:gsub("^[^\n]*\n", ""))
            table.insert(report, "· HTTP 4xx/5xx → 官方接口异常，稍后再试")
            table.insert(report, "· module not found → KOReader 安装不完整")
        end
        local viewer
        viewer = TextViewer:new{
            title = "连接诊断",
            text = table.concat(report, "\n"),
            text_type = "general",
            buttons_table = {{
                {
                    text = _("关闭"),
                    callback = function() UIManager:close(viewer) end,
                },
            }},
        }
        UIManager:show(viewer)
    end)
end

-- ============ 错误显示 ============

function Zsxq:showError(title, detail)
    local viewer
    viewer = TextViewer:new{
        title = title,
        text = tostring(detail or "未知错误。") ..
            "\n\n排查建议：\n1. 确认 Wi-Fi 已连接且能上网；\n2. 在「缓存与账号设置 → 连接诊断」运行逐步检测；\n3. 提示 HTTP 401 表示 Token 已失效，请重新获取。",
        text_type = "general",
        buttons_table = {{
            {
                text = _("关闭"),
                callback = function() UIManager:close(viewer) end,
            },
        }},
    }
    UIManager:show(viewer)
end

-- ============ 星球 / 标签 / 帖子列表 ============

function Zsxq:openGroupsList(data, from_cache)
    local items = {}
    for _, group in ipairs(data.groups) do
        local g = group
        table.insert(items, {
            text = g.name or g.group_id,
            callback = function()
                self:openGroupPage(g, function() self:openGroupsList(data, from_cache) end)
            end,
        })
    end
    self:showMenu("我的星球", items, from_cache and "网络失败 · 使用离线列表" or "选择星球")
end

function Zsxq:openGroupPage(group, back)
    -- 子页面（帖子列表/标签列表）关闭时应回到星球主页本身
    local function reopen_page()
        self:openGroupPage(group, back)
    end
    local items = {
        {
            text = _("最新帖子"),
            callback = function() self:showTopics(group, nil, nil, reopen_page) end,
        },
        {
            text = _("按标签阅读"),
            callback = function() self:showHashtags(group, reopen_page) end,
        },
        {
            text = _("离线阅读此星球"),
            callback = function()
                self:showOfflineTopics(group.group_id, reopen_page)
            end,
        },
        {
            text = "✎ " .. _("发帖"),
            callback = function() self:showCreateTopicDialog(group, reopen_page) end,
        },
    }
    -- 关闭星球主页 → 回我的星球列表
    self:showMenu(group.name or group.group_id, items, "星球", back)
end

function Zsxq:showGroups()
    if not self:ensureToken() then return end
    NetworkMgr:runWhenOnline(function()
        local ok, data = self:withLoading("正在加载我的星球…", function()
            return self:getAPI():getGroups(100)
        end)
        local error_message = nil
        local from_cache = false
        if ok then
            self.cache:put("groups", data)
        else
            error_message = data
            data = self.cache:get("groups")
            from_cache = data ~= nil
        end
        if not data or type(data.groups) ~= "table" then
            if ok then
                self:notify("没有可显示的星球。", 6)
            else
                self:showError("星球列表加载失败，且无离线缓存", error_message)
            end
            return
        end
        self:openGroupsList(data, from_cache)
    end)
end

function Zsxq:openHashtagsList(group, data, from_cache, back)
    local function reopen_tags()
        self:openHashtagsList(group, data, from_cache, back)
    end
    local items = {}
    for _, tag in ipairs(data.hashtags) do
        local t = tag
        table.insert(items, {
            text = t.title or t.hashtag_id,
            mandatory = tostring(t.topics_count or 0),
            callback = function() self:showTopics(group, t, nil, reopen_tags) end,
        })
    end
    -- 关闭标签列表 → 回星球主页
    self:showMenu(group.name .. " · 标签", items, from_cache and "离线标签" or "按帖子数排序", back)
end

function Zsxq:showHashtags(group, back)
    if not self:ensureToken() then return end
    NetworkMgr:runWhenOnline(function()
        local cache_key = "hashtags_" .. group.group_id
        local ok, data = self:withLoading("正在加载标签…", function()
            return self:getAPI():getHashtags(group.group_id)
        end)
        local error_message = nil
        local from_cache = false
        if ok then
            self.cache:put(cache_key, data)
        else
            error_message = data
            data = self.cache:get(cache_key)
            from_cache = data ~= nil
        end
        if not data or type(data.hashtags) ~= "table" then
            if ok then
                self:notify("此星球没有可显示的标签。", 6)
            else
                self:showError("标签加载失败，且没有可用缓存", error_message)
            end
            return
        end
        self:openHashtagsList(group, data, from_cache, back)
    end)
end

function Zsxq:topicCacheKey(group, hashtag, end_time)
    return "topics_" .. tostring(group.group_id) .. "_" ..
        tostring(hashtag and hashtag.hashtag_id or "all") .. "_" .. Content.hash(end_time or "first")
end

function Zsxq:openTopicsList(group, hashtag, end_time, data, topics, from_cache, back)
    local function reopen_topics()
        self:openTopicsList(group, hashtag, end_time, data, topics, from_cache, back)
    end
    local function topic_context(index)
        return {
            topic = topics[index],
            rebuild = reopen_topics,
            prev_topic = topics[index - 1] and function()
                self:openTopic(topics[index - 1], topic_context(index - 1))
            end or nil,
            next_topic = topics[index + 1] and function()
                self:openTopic(topics[index + 1], topic_context(index + 1))
            end or nil,
            -- 阅读器内连读（EndOfBook / 阅读菜单）：直接以图文模式渲染相邻帖子
            prev_reading = topics[index - 1] and function()
                self:openHighlightReader(topics[index - 1], topic_context(index - 1))
            end or nil,
            next_reading = topics[index + 1] and function()
                self:openHighlightReader(topics[index + 1], topic_context(index + 1))
            end or nil,
        }
    end
    local items = {
        {
            text = "✎ " .. _("发帖"),
            callback = function() self:showCreateTopicDialog(group, reopen_topics) end,
        },
    }
    for index, topic in ipairs(topics) do
        local t = topic
        local ctx = topic_context(index)
        table.insert(items, {
            text = Content.topicTitle(t),
            mandatory = "💬" .. tostring(t.counts and t.counts.comments or 0),
            callback = function() self:openTopic(t, ctx) end,
        })
    end
    if data.has_more and data.next_end_time and data.next_end_time ~= "" then
        table.insert(items, {
            text = _("下一页 →"),
            callback = function() self:showTopics(group, hashtag, data.next_end_time, back) end,
        })
    end
    local title = group.name .. (hashtag and (" · " .. hashtag.title) or " · 最新")
    local subtitle = from_cache and "网络失败 · 离线本页"
        or string.format("本页 %d 篇 · 关闭阅读页回到此列表", #topics)
    -- 关闭帖子列表 → 回星球主页
    self:showMenu(title, items, subtitle, back)
end

function Zsxq:showTopics(group, hashtag, end_time, back)
    if not self:ensureToken() then return end
    NetworkMgr:runWhenOnline(function()
        local cache_key = self:topicCacheKey(group, hashtag, end_time)
        local ok, data = self:withLoading("正在加载帖子…", function()
            return self:getAPI():getTopics(group.group_id, hashtag and hashtag.hashtag_id, end_time, 20)
        end)
        local error_message = nil
        local from_cache = false
        if ok then
            self.cache:put(cache_key, data)
        else
            error_message = data
            data = self.cache:get(cache_key)
            from_cache = data ~= nil
        end
        if not data or type(data.topics_brief) ~= "table" then
            if ok then
                self:notify("此星球还没有可显示的帖子。", 6)
            else
                self:showError("帖子加载失败，且没有本页离线缓存", error_message)
            end
            return
        end
        local topics = data.topics_brief
        for _, topic in ipairs(topics) do self.cache:saveTopic(topic) end
        self:openTopicsList(group, hashtag, end_time, data, topics, from_cache, back)
    end)
end

function Zsxq:confirmCacheTopics(topics)
    if #topics == 0 then return end
    UIManager:show(ConfirmBox:new{
        text = string.format("将联网下载本页 %d 篇帖子的完整正文和评论，用于离线阅读。\n\n请保持 Wi-Fi 连接，帖子较多时需要一些时间。是否继续？", #topics),
        ok_text = _("开始缓存"),
        ok_callback = function()
            NetworkMgr:runWhenOnline(function() self:cacheTopics(topics) end)
        end,
    })
end

function Zsxq:cacheTopics(topics)
    local api = self:getAPI()
    local completed, comments_completed = 0, 0
    -- 逐篇更新进度提示，让用户知道缓存到第几篇
    local loading = InfoMessage:new{ text = string.format("正在缓存 1/%d 篇…", #topics) }
    UIManager:show(loading)
    UIManager:forceRePaint()
    local ok, err = pcall(function()
        for i, brief in ipairs(topics) do
            UIManager:close(loading)
            loading = InfoMessage:new{ text = string.format("正在缓存 %d/%d 篇…", i, #topics) }
            UIManager:show(loading)
            UIManager:forceRePaint()
            local detail_ok, detail = api:getTopic(brief.topic_id)
            local topic = detail_ok and detail.topic or brief
            if self.cache:saveTopic(topic) then completed = completed + 1 end
            local comments_ok, comments = api:getComments(topic.topic_id, nil, 30)
            if comments_ok and self.cache:put("comments_" .. topic.topic_id .. "_first", comments) then
                comments_completed = comments_completed + 1
            end
        end
    end)
    UIManager:close(loading)
    if ok then
        self:notify(string.format("离线缓存完成：正文 %d/%d 篇，评论 %d/%d 篇。\n已在“离线阅读”中可用。",
            completed, #topics, comments_completed, #topics), 7)
    else
        self:notify("缓存中断：" .. tostring(err), 6)
    end
end

-- ============ 阅读页 ============

-- 评论数少的帖子全程静默秒开（≤30 条），多的才显示逐页进度
local function isQuietTopic(topic)
    return (topic.counts and topic.counts.comments or 0) <= 30
end

-- 拉取完整帖子（失败回退缓存）后回调。评论少的帖子静默加载（不弹提示）
function Zsxq:fetchTopicDetail(topic, callback)
    NetworkMgr:runWhenOnline(function()
        local ok, data = self:withLoading("正在加载完整帖子…", function()
            return self:getAPI():getTopic(topic.topic_id)
        end, isQuietTopic(topic))
        if ok and data.topic then
            topic = data.topic
            self.cache:saveTopic(topic)
        else
            topic = self.cache:getTopic(topic.topic_id) or topic
        end
        callback(topic)
    end)
end

-- 图文阅读（正文+内嵌压缩图+评论 → CRE 排版文档）：
-- 长按滑动选中即划线，点已划线文字可删除/编辑，AI助手等高亮插件按钮原生可用。
-- context 存在时登记翻页连读（翻过最后一页自动进下一篇）。
-- 直接打开、不弹提示；操作说明见「使用说明」。
-- 评论数少的帖子全程静默秒开（≤30 条），多的才显示逐页进度

-- 评论获取（默认视图/图文/单篇缓存共用）：
-- 打开帖子即一次拉取全部评论（每页进度提示，缓存未拉全时从游标续拉）。
-- 失败静默返回已拉到的部分。返回 comments, has_more
function Zsxq:commentsForHtml(topic)
    local cache_key = "comments_" .. tostring(topic.topic_id) .. "_first"
    local cached = self.cache:get(cache_key)
    local data = (cached and type(cached.comments) == "table") and cached
        or { success = true, comments = {}, has_more = true, index = nil }
    if data.has_more then
        pcall(function()
            self:fetchCommentsMore(topic, data, 2000, isQuietTopic(topic))
        end)
    end
    if type(data.comments) == "table" and #data.comments > 0 then
        self.cache:put(cache_key, data)
        return data.comments, data.has_more
    end
    return nil
end

-- 拉取评论：循环翻页直到全部拉完（或达到目标条数）。
-- 首次尝试 100 条/页（接口拒绝则回退 30/页），页大小记忆在缓存数据中；
-- 追加式写缓存，中断后从游标断点续拉。quiet=true 时不弹加载提示。返回是否成功。
function Zsxq:fetchCommentsMore(topic, data, target_total, quiet)
    local cache_key = "comments_" .. tostring(topic.topic_id) .. "_first"
    local function fetch_page(limit)
        return self:withLoading(
            string.format("正在加载评论（已有 %d 条）…", #data.comments),
            function()
                return self:getAPI():getComments(topic.topic_id, data.index, limit)
            end, quiet)
    end
    while data.has_more and (not target_total or #data.comments < target_total) do
        local limit = tonumber(data.page_limit) or 100
        local ok, resp = fetch_page(limit)
        if not ok and limit ~= 30 then
            -- 大页被接口拒绝：回退 30/页重试
            data.page_limit = 30
            ok, resp = fetch_page(30)
        end
        if not ok or type(resp) ~= "table" or type(resp.comments) ~= "table" then
            self.cache:put(cache_key, data)
            return false
        end
        local prev_index = data.index
        for _, c in ipairs(resp.comments) do table.insert(data.comments, c) end
        data.has_more = resp.has_more
        data.index = resp.index
        if #resp.comments == 0
            or (data.has_more and data.index == prev_index and prev_index ~= nil) then
            data.has_more = false -- 接口游标未前进或空页，防止死循环
        end
        if data.has_more and data.index == nil then
            data.has_more = false -- 无下一页游标
        end
    end
    self.cache:put(cache_key, data)
    return true
end

function Zsxq:openTopicHtml(topic, context)
    local images = Content.topicImages(topic)
    local resolved = self:resolveImages(images, true)
    -- 评论内嵌：缓存优先，失败静默跳过（不打断图文打开）
    local comments = self:commentsForHtml(topic)
    local html = Html.topicToHtml(topic, resolved, comments)
    -- 长按选中默认划线（仅当用户仍在默认「每次询问」时才改，不覆盖自定义行为）
    if G_reader_settings:readSetting("default_highlight_action", "ask") == "ask" then
        G_reader_settings:saveSetting("default_highlight_action", "highlight")
    end
    -- 阅读菜单功能组（下一篇/上一篇/评论）需要的上下文
    local reader_context = nil
    if context then
        reader_context = {
            prev_topic = context.prev_topic,
            next_topic = context.next_topic,
            prev_reading = context.prev_reading,
            next_reading = context.next_reading,
            rebuild = context.rebuild,
            topic = topic,
        }
    end
    self:openReaderHtml(tostring(topic.topic_id), html, nil, reader_context)
end

-- 点开帖子：直接显示文字功能页（秒开，不联网下载、不生成文档）。
-- 图片走 ImageViewer 弹窗、划线走点选段落；「📖 图文」为可选高级入口（进阅读器滑动划线）。
function Zsxq:openTopic(topic, context)
    self:fetchTopicDetail(topic, function(full_topic)
        self:renderTopic(full_topic, context, false)
    end)
end

-- 阅读页（TextViewer）：同一时间只保留一个实例，下一篇直接替换
function Zsxq:showTopicViewer(viewer)
    if self.topic_viewer then
        local old = self.topic_viewer
        self.topic_viewer = nil
        UIManager:close(old)
    end
    self.topic_viewer = viewer
    UIManager:show(viewer)
end

function Zsxq:renderTopic(topic, context, offline)
    local text, links = Content.topicText(topic)
    -- 正文和评论连续显示：缓存优先，联网静默更新
    local comments, comments_has_more = self:commentsForHtml(topic)
    local comment_flat = nil
    if comments then
        local c_text, flat = Content.commentsText(comments, topic.counts and topic.counts.comments)
        comment_flat = flat
        -- 正文结束后多留几行空白，评论标题夹在两条分割线之间
        text = text .. "\n\n\n\n\n────────────────\n【评 论】\n────────────────\n" .. c_text
        if comments_has_more then
            text = text .. string.format(
                "\n…评论过多，已显示前 %d 条（上限 2000）", #comments)
        end
    elseif (topic.counts and topic.counts.comments or 0) > 0 then
        text = text .. "\n\n────────────────\n评论：暂无缓存，联网后重新打开本帖可加载。"
    end
    local images = Content.topicImages(topic)
    local comment_count = topic.counts and topic.counts.comments or 0
    local viewer
    local row1 = {
        {
            text = string.format("评论 %d 条", comment_count),
            callback = function() self:showComments(topic, nil, nil, nil, offline) end,
        },
        {
            text = _("回复某条评论"),
            enabled = comment_flat ~= nil and #comment_flat > 0 and not offline,
            callback = function() self:showCommentPicker(topic, comment_flat) end,
        },
        {
            text = _("写评论"),
            enabled = not offline,
            callback = function() self:showReplyDialog(topic) end,
        },
    }
    if #images > 0 then
        table.insert(row1, {
            text = string.format("图片 %d", #images),
            callback = function() self:showImages(topic, images) end,
        })
    else
        table.insert(row1, {
            text = string.format("长文/链接 %d", #links),
            callback = function() self:showLinks(links) end,
        })
    end
    viewer = TextViewer:new{
        title = Content.truncate(Content.topicTitle(topic), 90),
        text = text,
        text_type = "general",
        -- 滚到顶/底后再按翻页键 → 自动切换上一篇/下一篇
        page_turn_callback_prev = function()
            if context and context.prev_topic then context.prev_topic() end
        end,
        page_turn_callback_next = function()
            if context and context.next_topic then context.next_topic() end
        end,
        buttons_table = {
            row1,
            {
                {
                    text = "‹ 上一篇",
                    enabled = context ~= nil and context.prev_topic ~= nil,
                    callback = function()
                        if context and context.prev_topic then context.prev_topic() end
                    end,
                },
                {
                    text = _("划线"),
                    callback = function() self:showTopicParagraphs(topic) end,
                },
                {
                    text = "下一篇 ›",
                    enabled = context ~= nil and context.next_topic ~= nil,
                    callback = function()
                        if context and context.next_topic then context.next_topic() end
                    end,
                },
            },
            {
                {
                    text = _("刷新"),
                    enabled = not offline,
                    callback = function()
                        self:fetchTopicDetail(topic, function(full_topic)
                            self:renderTopic(full_topic, context, false)
                        end)
                    end,
                },
                {
                    text = _("缓存"),
                    enabled = not offline,
                    callback = function() self:cacheSingleTopic(topic) end,
                },
                {
                    text = "📖 " .. _("图文"),
                    callback = function() self:openHighlightReader(topic, context) end,
                },
                {
                    text = _("关闭"),
                    callback = function()
                        if self.topic_viewer == viewer then self.topic_viewer = nil end
                        UIManager:close(viewer) -- 回到下层的帖子列表
                    end,
                },
            },
        },
    }
    self:showTopicViewer(viewer)
end

function Zsxq:cacheSingleTopic(topic)
    NetworkMgr:runWhenOnline(function()
        local ok, data = self:withLoading("正在缓存正文和评论…", function()
            return self:getAPI():getComments(topic.topic_id, nil, 30)
        end)
        local topic_saved = self.cache:saveTopic(topic)
        local comments_saved = false
        if ok and type(data) == "table" and type(data.comments) == "table" then
            local cached = {
                success = true,
                comments = data.comments,
                has_more = data.has_more,
                index = data.index,
            }
            if self.cache:put("comments_" .. tostring(topic.topic_id) .. "_first", cached) then
                -- 单篇缓存：拉取全部评论（循环翻页，上限 2000 条）
                comments_saved = self:fetchCommentsMore(topic, cached, 2000)
            end
        end
        if topic_saved and comments_saved then
            self:notify("正文和全部评论已缓存。")
        elseif topic_saved then
            self:notify("正文已缓存，但评论未完整写入缓存。", 6)
        else
            self:notify("缓存写入失败，请检查存储空间或缓存目录权限。", 7)
        end
    end)
end

-- ============ 评论 ============

function Zsxq:showComments(topic, index, accumulated, has_more, offline)
    local function showCached()
        local data = self.cache:get("comments_" .. topic.topic_id .. "_first")
        if data then
            self:renderComments(topic, data.comments or {}, data.has_more, data.index, true)
        else
            self:notify("此帖子还没有离线评论缓存。", 5)
        end
    end
    if offline then
        showCached()
        return
    end
    NetworkMgr:runWhenOnline(function()
        local ok, data = self:withLoading("正在加载评论…", function()
            return self:getAPI():getComments(topic.topic_id, index, 30)
        end)
        if not ok then
            if not accumulated then showCached() else self:notify("更多评论加载失败。", 4) end
            return
        end
        local comments = accumulated or {}
        for _, comment in ipairs(data.comments or {}) do table.insert(comments, comment) end
        self.cache:put("comments_" .. topic.topic_id .. "_first", {
            success = true,
            comments = comments,
            has_more = data.has_more,
            index = data.index,
        })
        self:renderComments(topic, comments, data.has_more, data.index, false)
    end)
end

function Zsxq:renderComments(topic, comments, has_more, index, offline)
    local text, flat = Content.commentsText(comments, topic.counts and topic.counts.comments)
    local viewer
    local buttons = {
        {
            {
                text = _("回复帖子"),
                enabled = not offline,
                callback = function() self:showReplyDialog(topic) end,
            },
            {
                text = _("回复某条评论"),
                enabled = #flat > 0 and not offline,
                callback = function() self:showCommentPicker(topic, flat) end,
            },
            {
                text = _("关闭"),
                callback = function() UIManager:close(viewer) end,
            },
        },
    }
    if has_more and index and index ~= "" and not offline then
        table.insert(buttons, {{
            text = _("加载更多评论"),
            callback = function()
                UIManager:close(viewer)
                self:showComments(topic, index, comments)
            end,
        }})
    end
    viewer = TextViewer:new{
        title = "评论 · " .. Content.truncate(Content.topicTitle(topic), 60),
        text = text,
        text_type = "general",
        buttons_table = buttons,
    }
    UIManager:show(viewer)
end

function Zsxq:showCommentPicker(topic, flat)
    local items = {}
    for _, entry in ipairs(flat) do
        local comment = entry.comment
        table.insert(items, {
            text = (entry.depth > 0 and "↳ " or "") ..
                ((comment.owner and comment.owner.name) or "未知") .. "：" .. Content.truncate(Content.singleLine(comment.text), 100),
            callback = function()
                self:closeListMenu()
                self:showReplyDialog(topic, comment)
            end,
        })
    end
    self:showMenu("选择要回复的评论", items, "支持楼中楼回复")
end

function Zsxq:showReplyDialog(topic, comment)
    if not self:ensureToken() then return end
    local dialog
    local target = comment and ("回复 " .. ((comment.owner and comment.owner.name) or "评论者")) or "评论帖子"
    dialog = InputDialog:new{
        title = target,
        description = "帖子：" .. Content.topicTitle(topic) .. "\n发送前还会要求确认完整内容。",
        input_hint = _("输入评论内容，支持换行"),
        allow_newline = true,
        fullscreen = true,
        condensed = true,
        use_available_height = true,
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("预览并确认"),
                callback = function()
                    local text = Content.trim(dialog:getInputText())
                    if text == "" then
                        self:notify("评论内容不能为空。")
                        return
                    end
                    UIManager:close(dialog)
                    self:confirmReply(topic, comment, text)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Zsxq:confirmReply(topic, comment, text)
    local target = comment and ("楼中楼回复 " .. ((comment.owner and comment.owner.name) or "评论者")) or "帖子顶层评论"
    local viewer
    viewer = TextViewer:new{
        title = _("确认发送评论"),
        text = string.format("请核对知识星球评论：\n\n帖子：%s\n类型：%s\n\n──────── 完整内容 ────────\n%s",
            Content.topicTitle(topic), target, text),
        buttons_table = {{
            {
                text = _("取消"),
                callback = function() UIManager:close(viewer) end,
            },
            {
                text = _("确认发送"),
                callback = function()
                    UIManager:close(viewer)
                    NetworkMgr:runWhenOnline(function()
                        local ok, result = self:withLoading("正在发送评论…", function()
                            return self:getAPI():createComment(topic.topic_id, text, comment and comment.comment_id)
                        end)
                        if ok then
                            self:notify("评论已发送。重新打开评论列表即可刷新。", 6)
                        else
                            self:notify("发送失败，云端内容未确认变更：\n" .. tostring(result), 8)
                        end
                    end)
                end,
            },
        }},
    }
    UIManager:show(viewer)
end

-- ============ 发帖（纯文本：可选标题 + 正文，预览确认） ============

function Zsxq:showCreateTopicDialog(group, refresh)
    if not self:ensureToken() then return end
    local dialog
    dialog = InputDialog:new{
        title = _("发帖 · 标题（可留空）"),
        description = "星球：" .. (group.name or group.group_id) .. "\n下一步输入正文，发送前会预览确认。",
        input_hint = _("帖子标题，可留空"),
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("下一步"),
                callback = function()
                    local title = Content.trim(dialog:getInputText())
                    UIManager:close(dialog)
                    self:showCreateTopicContentDialog(group, title, refresh)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Zsxq:showCreateTopicContentDialog(group, title, refresh, draft)
    local dialog
    dialog = InputDialog:new{
        title = _("发帖 · 正文"),
        description = (title ~= "" and ("标题：" .. title .. "\n") or "") .. "支持多行文本。",
        input = draft or "",
        input_hint = _("输入帖子正文"),
        allow_newline = true,
        fullscreen = true,
        condensed = true,
        use_available_height = true,
        buttons = {{
            {
                text = _("取消"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("预览"),
                callback = function()
                    local content = Content.trim(dialog:getInputText())
                    if content == "" and title == "" then
                        self:notify("标题和正文不能同时为空。")
                        return
                    end
                    UIManager:close(dialog)
                    self:confirmCreateTopic(group, title, content, refresh)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Zsxq:confirmCreateTopic(group, title, content, refresh)
    local viewer
    viewer = TextViewer:new{
        title = _("预览发布"),
        text = string.format("目标星球：%s\n\n标题：%s\n\n──────── 正文 ────────\n%s",
            group.name or group.group_id, title ~= "" and title or "（无标题）", content),
        buttons_table = {{
            {
                text = _("返回编辑"),
                callback = function()
                    UIManager:close(viewer)
                    self:showCreateTopicContentDialog(group, title, refresh, content)
                end,
            },
            {
                text = _("确认发布"),
                callback = function()
                    if self.posting then return end
                    self.posting = true
                    UIManager:close(viewer)
                    NetworkMgr:runWhenOnline(function()
                        local ok, result = self:withLoading("正在发布…", function()
                            return self:getAPI():createTopic(group.group_id, title, content)
                        end)
                        self.posting = false
                        if ok then
                            self:notify("发布成功，已刷新帖子列表。", 5)
                            if refresh then refresh() end
                        else
                            self:notify("发布失败：" .. tostring(result) .. "\n\n草稿已保留，重新进入发帖可见。", 8)
                        end
                    end)
                end,
            },
        }},
    }
    UIManager:show(viewer)
end

-- ============ 划线 ============

-- 点选段落划线（纯插件界面，不经过阅读器）：列出正文段落 → 点选 → 确认保存
function Zsxq:showTopicParagraphs(topic)
    local full_text = Content.topicText(topic)
    -- 只取正文部分（跳过元数据头）
    local body = full_text:match("────────────────\n(.*)$") or full_text
    local paragraphs = {}
    local current = {}
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        if line == "" then
            if #current > 0 then
                table.insert(paragraphs, table.concat(current, "\n"))
                current = {}
            end
        else
            table.insert(current, line)
        end
    end
    if #current > 0 then table.insert(paragraphs, table.concat(current, "\n")) end
    local items = {}
    for _, paragraph in ipairs(paragraphs) do
        local p = paragraph
        local first_word = Content.singleLine(p)
        if first_word ~= "" and not first_word:match("^%[图片%d+%]$") and not first_word:match("^%[链接%d+%]$") then
            table.insert(items, {
                text = Content.truncate(first_word, 110),
                callback = function()
                    self:closeListMenu()
                    self:confirmHighlight(topic, p)
                end,
            })
        end
    end
    if #items == 0 then
        self:notify("此帖子没有可划线的文字段落。", 5)
        return
    end
    self:showMenu("选择要划线的段落", items, "点选段落保存划线 · 可连续划多条")
end

function Zsxq:confirmHighlight(topic, paragraph)
    UIManager:show(ConfirmBox:new{
        text = "保存以下划线？\n\n" .. Content.truncate(paragraph, 300),
        ok_text = _("保存划线"),
        ok_callback = function()
            local saved, result = self.cache:addHighlight(topic.topic_id, Content.topicTitle(topic), paragraph)
            if saved then
                self:notify("划线已保存，可继续点选其他段落。\n主菜单「我的划线」中可查看。", 5)
            else
                self:notify("划线保存失败：" .. tostring(result), 6)
            end
        end,
    })
end

-- 图文模式（可选高级入口）：正文+内嵌压缩图 → CRE 排版文档。
-- 长按滑动选中即划线，点已划线文字可删除/编辑，AI助手等高亮插件按钮原生可用。
-- context 存在时登记翻页连读（翻过最后一页自动进下一篇）。
function Zsxq:openHighlightReader(topic, context)
    NetworkMgr:runWhenOnline(function()
        self:openTopicHtml(topic, context)
    end)
end

function Zsxq:showHighlights(topic_id)
    local highlights = self.cache:listHighlights(topic_id)
    if #highlights == 0 then
        self:notify("还没有划线记录。\n阅读帖子时点「划线」，点选段落即可保存。", 8)
        return
    end
    local items = {}
    for _, highlight in ipairs(highlights) do
        local h = highlight
        table.insert(items, {
            text = Content.truncate(Content.singleLine(h.text), 110),
            mandatory = Content.truncate(h.topic_title or "", 16),
            callback = function()
                self:closeListMenu()
                self:showHighlight(h, topic_id)
            end,
        })
    end
    self:showMenu(topic_id and "本帖划线" or "我的划线（历史记录）", items,
        string.format("%d 条 · 点查看或删除", #items))
end

function Zsxq:showHighlight(highlight, topic_id)
    local viewer
    viewer = TextViewer:new{
        title = Content.truncate(highlight.topic_title or "划线", 60),
        text = highlight.text,
        text_type = "general",
        buttons_table = {{
            {
                text = _("删除"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = "确定删除这条划线吗？",
                        ok_text = _("删除"),
                        ok_callback = function()
                            self.cache:deleteHighlight(highlight.id)
                            self:notify("已删除。")
                            self:showHighlights(topic_id)
                        end,
                    })
                end,
            },
            {
                text = _("返回列表"),
                callback = function()
                    UIManager:close(viewer)
                    self:showHighlights(topic_id)
                end,
            },
            {
                text = _("关闭"),
                callback = function() UIManager:close(viewer) end,
            },
        }},
    }
    UIManager:show(viewer)
end

-- ============ 图片 / 链接 / 长文 ============

-- 全屏二维码：直接用 KOReader 内置 qrencode 生成矩阵，按屏幕宽度绘制，
-- 保证长链接（高版本 QR 矩阵）下码面尽量大、模块清晰可扫。
-- qrencode 不可用（极旧 KOReader）时回退自带 QRMessage。
function Zsxq:showQRCode(url)
    local ok, qrencode = pcall(require, "ffi/qrencode")
    if ok and qrencode and type(qrencode.qrcode) == "function" then
        local gen_ok, res_or_err, matrix, size = pcall(qrencode.qrcode, url)
        if gen_ok and matrix and size and size > 0 then
            local bb_ok, Blitbuffer = pcall(require, "ffi/blitbuffer")
            if bb_ok and Blitbuffer and type(Blitbuffer.new) == "function" then
                local scale = math.floor(Screen:getWidth() * 0.9 / size)
                if scale < 1 then scale = 1 end
                local grid = scale * size
                local bb = Blitbuffer.new(grid, grid)
                local white = Blitbuffer.COLOR_WHITE
                for y = 1, size do
                    for x = 1, size do
                        if matrix[(y - 1) * size + x] < 0 then
                            bb:paintRect((x - 1) * scale, (y - 1) * scale, scale, scale, white)
                        end
                    end
                end
                UIManager:show(ImageViewer:new{
                    image = bb,
                    fullscreen = false,
                    with_title_bar = true,
                    title_text = _("手机扫码打开"),
                    image_disposable = true,
                })
                return
            end
        end
    end
    UIManager:show(QRMessage:new{ title = _("手机打开链接"), text = url })
end

-- 用 KOReader 阅读器打开生成的 HTML（正文/图片册），并保证"退出阅读"后回到星球墨读：
-- ReaderUI 关闭时默认会新建文件管理器（表现为"没有返回"），
-- 这里覆盖实例的 showFileManager，让退出后直接露出下层菜单。
-- context（可选）：翻页连读上下文，登记后翻过最后一页自动进下一篇。
function Zsxq:openReaderHtml(key, html, note, context)
    local path = self.cache:saveTopicHTML(key, html)
    if not path then
        self:notify("生成阅读文档失败，请检查存储空间。", 6)
        return
    end
    -- 阅读器内的连读上下文统一走图文模式：翻页/顶部菜单/阅读菜单的
    -- 下一篇都直接渲染相邻帖子的 HTML，而不是退回功能页。
    if context then
        READING_CONTEXTS[path] = {
            topic = context.topic,
            rebuild = context.rebuild,
            prev_topic = context.prev_reading or context.prev_topic,
            next_topic = context.next_reading or context.next_topic,
        }
    end
    if note then self:notify(note, 6) end
    ReaderUI:showReader(path)
    -- 等文档真正打开后打补丁（ReaderUI 用协程异步创建实例）
    local attempts = 0
    local function patch_reader()
        local reader = ReaderUI.instance
        if reader and reader.document then
            if reader.document.file == path then
                reader.showFileManager = function() end
                -- 自动开启「内嵌样式」：帖子 HTML 的排版样式（标题加粗、字号、图片布局）全在这里
                if reader.document.setEmbeddedStyleSheet then
                    if reader.document.configurable then
                        reader.document.configurable.embedded_css = 1
                    end
                    reader.document:setEmbeddedStyleSheet(1)
                    if reader.ui and reader.ui.handleEvent then
                        reader.ui:handleEvent(Event:new("UpdatePos"))
                    end
                end
            end
            return
        end
        attempts = attempts + 1
        if attempts < 15 then UIManager:scheduleIn(1, patch_reader) end
    end
    UIManager:scheduleIn(1, patch_reader)
end

-- 解析帖子图片：优先用已缓存文件，缺失的联网下载压缩图（不下载原图）
function Zsxq:resolveImages(images, download_missing)
    local resolved = {}
    local pending = {}
    for _, image in ipairs(images or {}) do
        local cached = self.cache:getArticle(image.thumbnail)
        if cached then
            table.insert(resolved, { path = cached })
        else
            table.insert(pending, { index = #resolved + 1, image = image })
            table.insert(resolved, { note = "未加载" })
        end
    end
    if download_missing and #pending > 0 then
        local api = self:getAPI()
        local ok, err = self:withLoading(string.format("正在加载 %d 张图片（压缩版）…", #pending), function()
            for _, item in ipairs(pending) do
                local down_ok, body, headers = api:download(item.image.thumbnail)
                if down_ok then
                    local content_type = tostring((headers and (headers["content-type"] or headers["Content-Type"])) or ""):lower()
                    local extension = "jpg"
                    if content_type:match("png") or body:sub(1, 8) == "\137PNG" then extension = "png" end
                    local path = self.cache:saveArticle(item.image.thumbnail, body, extension)
                    if path then resolved[item.index] = { path = path } end
                end
            end
            return true
        end)
        if not ok then self:notify("部分图片加载失败：" .. tostring(err), 5) end
    end
    for index, entry in ipairs(resolved) do
        if entry.note then
            resolved[index] = { note = "未能加载，可稍后重试" }
        end
    end
    return resolved
end

-- 阅读页「图片」入口：下载压缩图（已缓存跳过）→ ImageViewer 弹窗浏览。
-- 多图点击屏幕左/右翻页、带进度条；点关闭立即回到功能页，完全不经过阅读器。
function Zsxq:showImages(topic, images)
    if not images or #images == 0 then
        self:notify("此帖子没有解析到图片。")
        return
    end
    NetworkMgr:runWhenOnline(function()
        local resolved = self:resolveImages(images, true)
        local image_list = {}
        for _, entry in ipairs(resolved) do
            if entry.path then
                local path = entry.path
                -- 惰性渲染：翻到该图才加载，省内存
                table.insert(image_list, function()
                    return RenderImage:renderImageFile(path)
                end)
            end
        end
        if #image_list == 0 then
            self:notify("图片未能加载，请检查网络后重试。", 6)
            return
        end
        image_list.image_disposable = true
        UIManager:show(ImageViewer:new{
            image = image_list,
            fullscreen = true,
            with_title_bar = true,
            title_text = string.format("%d 张图片 · 点屏幕左右翻页", #image_list),
        })
    end)
end

function Zsxq:showLinks(links)
    if not links or #links == 0 then
        self:notify("此帖子没有识别到网页或长文链接。")
        return
    end
    local items = {}
    for i, link in ipairs(links) do
        table.insert(items, {
            text = string.format("[%d] %s", i, link.title),
            callback = function(menu)
                UIManager:close(menu)
                self:showLinkOptions(link)
            end,
        })
    end
    self:showMenu("帖子链接与长文", items, "下载阅读或扫码到手机")
end

function Zsxq:showLinkOptions(link)
    local cached = self.cache:getArticle(link.url)
    local dialog
    local buttons = {}
    if cached then
        table.insert(buttons, {{
            text = _("打开已缓存长文"),
            callback = function()
                UIManager:close(dialog)
                ReaderUI:showReader(cached)
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("下载并用 KOReader 阅读"),
        callback = function()
            UIManager:close(dialog)
            self:downloadArticle(link)
        end,
    }})
    table.insert(buttons, {{
        text = _("二维码（手机打开）"),
        callback = function()
            UIManager:close(dialog)
            self:showQRCode(link.url)        end,
    }})
    table.insert(buttons, {{
        text = _("查看完整网址"),
        callback = function()
            UIManager:close(dialog)
            UIManager:show(TextViewer:new{ title = link.title, text = link.url })
        end,
    }})
    dialog = require("ui/widget/buttondialog"):new{ title = link.title, buttons = buttons }
    UIManager:show(dialog)
end

function Zsxq:downloadArticle(link)
    NetworkMgr:runWhenOnline(function()
        local ok, body, headers = self:withLoading("正在下载长文…", function()
            return self:getAPI():download(link.url)
        end)
        if not ok then
            local cached = self.cache:getArticle(link.url)
            if cached then
                self:notify("在线下载失败，将打开已缓存版本。", 4)
                ReaderUI:showReader(cached)
            else
                self:notify("长文下载失败：\n" .. tostring(body) .. "\n\n可改用二维码在手机上打开。", 8)
            end
            return
        end
        local content_type = tostring((headers and (headers["content-type"] or headers["Content-Type"])) or ""):lower()
        local extension = "html"
        if content_type:match("application/pdf") or body:sub(1, 4) == "%PDF" then
            extension = "pdf"
        elseif not content_type:match("html") and not body:lower():match("<html") then
            extension = "txt"
        end
        local path, err = self.cache:saveArticle(link.url, body, extension)
        if path then
            ReaderUI:showReader(path)
        else
            self:notify("长文保存失败：" .. tostring(err))
        end
    end)
end

-- ============ 离线阅读 ============

-- 第一级：离线星球列表（从缓存帖子中提取）；关闭 → 回 KOReader
function Zsxq:showOfflineGroups()
    local topics = self.cache:listTopics()
    local seen, groups, group_counts = {}, {}, {}
    for _, topic in ipairs(topics) do
        local group = topic.group or {}
        local key = tostring(group.group_id)
        if group.group_id then
            group_counts[key] = (group_counts[key] or 0) + 1
            if not seen[key] then
                seen[key] = true
                table.insert(groups, group)
            end
        end
    end
    if #groups == 0 then
        self:notify("还没有离线帖子。\n请先在线阅读，或使用「缓存含评论」保存帖子。", 8)
        return
    end
    table.sort(groups, function(a, b) return tostring(a.name) < tostring(b.name) end)
    local items = {}
    for _, group in ipairs(groups) do
        local g = group
        table.insert(items, {
            text = g.name or g.group_id,
            mandatory = string.format("%d 帖", group_counts[tostring(g.group_id)] or 0),
            callback = function()
                self:showOfflineTopics(g.group_id, function() self:showOfflineGroups() end)
            end,
        })
    end
    self:showMenu("我的星球 · 离线", items, string.format("%d 个星球有缓存 · 选择进入", #groups))
end

-- 第二级：星球内离线帖子列表，带上一篇/下一篇；关闭 → 回离线星球列表
function Zsxq:showOfflineTopics(group_id, back)
    local topics = self.cache:listTopics()
    local filtered = {}
    for _, topic in ipairs(topics) do
        if not group_id or tostring(topic.group and topic.group.group_id) == tostring(group_id) then
            table.insert(filtered, topic)
        end
    end
    if #filtered == 0 then
        self:notify("此星球还没有离线帖子。\n请先在线阅读，或使用「缓存含评论」保存帖子。", 8)
        return
    end
    local function reopen()
        self:showOfflineTopics(group_id, back)
    end
    local function topic_context(index)
        return {
            rebuild = reopen,
            prev_topic = filtered[index - 1] and function()
                self:renderTopic(filtered[index - 1], topic_context(index - 1), true)
            end or nil,
            next_topic = filtered[index + 1] and function()
                self:renderTopic(filtered[index + 1], topic_context(index + 1), true)
            end or nil,
        }
    end
    local items = {}
    for index, topic in ipairs(filtered) do
        local t = topic
        local ctx = topic_context(index)
        table.insert(items, {
            text = Content.topicTitle(t),
            mandatory = "💬" .. tostring(t.counts and t.counts.comments or 0),
            callback = function() self:renderTopic(t, ctx, true) end,
        })
    end
    local group_name = (filtered[1].group and filtered[1].group.name) or group_id or "离线阅读"
    self:showMenu(group_name .. " · 离线", items,
        string.format("%d 篇 · 无需 Wi-Fi · 支持上一篇/下一篇", #filtered), back)
end

return Zsxq
