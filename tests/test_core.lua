local workspace = arg[1]
assert(workspace, "workspace path required")
package.path = workspace .. "/zsxq.koplugin/?.lua;" .. package.path
package.preload["json"] = function()
    return dofile("/tmp/zsxq-test-json.lua")
end

local JSON = require("json")
local Content = require("zsxq_content")
local API = require("zsxq_api")

local passed = 0
local function check(condition, message)
    assert(condition, message)
    passed = passed + 1
end

local raw = "📄 顶尖晨报\\n\\n点此阅读：<e type=\"web\" href=\"https%3A%2F%2Farticles.zsxq.com%2Fid_test.html\" title=\"%E9%A1%B6%E5%B0%96%E6%99%A8%E6%8A%A5\" />"
local clean, links = Content.parse(raw)
check(clean:match("顶尖晨报") ~= nil, "Chinese title should be decoded")
check(clean:match("%[链接1%]") ~= nil, "link marker should be readable")
check(#links == 1, "one article link expected")
check(links[1].url == "https://articles.zsxq.com/id_test.html", "article URL should be decoded")

-- 图片提取：e img 标签与 images.zsxq.com 链接
local img_clean, img_links, images = Content.parse("看图：<e type=\"img\" data-src=\"https://images.zsxq.com/Fabc\" /> 完")
check(img_clean:match("%[图片1%]") ~= nil, "image tag should become a readable marker")
check(#images == 1 and images[1] == "https://images.zsxq.com/Fabc", "image URL should be extracted")
check(#img_links == 0, "image url should not be treated as web link")

-- 缩略图：官方 images 数组优先（带签名 URL，禁止再拼参数破坏签名）
local signed_thumb = "https://images.zsxq.com/Fabc?imageMogr2/auto-orient/thumbnail/380x/format/jpg/blur/1x0/quality/75&e=1798732799&token=xyz"
local signed_large = "https://images.zsxq.com/Fabc?imageMogr2/auto-orient/thumbnail/800x/format/jpg&e=1798732799&token=xyz2"
local api_images = Content.topicImages({
    content = "经不起推敲啊",
    images = {
        { thumbnail = { url = signed_thumb }, large = { url = signed_large } },
        { large = { url = signed_large } },
    },
})
check(#api_images == 2, "API images array should be used")
check(api_images[1].thumbnail == signed_thumb, "official thumbnail URL must be kept verbatim (signature intact)")
check(api_images[1].url == signed_large, "large URL used as full image")
check(api_images[2].thumbnail == signed_large, "missing thumbnail falls back to large URL")

-- 缩略图回退：正文 <e type="img"> 拼压缩参数
local topic_images = Content.topicImages({ content = "<e type=\"img\" data-src=\"https://images.zsxq.com/Fabc\" />" })
check(topic_images[1].thumbnail:match("imageMogr2/auto%-orient/thumbnail/1080x") ~= nil,
    "thumbnail url should use imageMogr2 compression params")

-- Markdown 识别：转为阅读友好文本
local md = Content.formatMarkdown("# 大标题\n**加粗** 和 `代码`\n- 列表项\n> 引用一句")
check(md:match("■ 大标题") ~= nil, "h1 should become styled prefix")
check(md:match("加粗") ~= nil and md:match("%*%*") == nil, "bold markers should be removed")
check(md:match("• 列表项") ~= nil, "dash list should become bullet")
check(md:match("┃ 引用一句") ~= nil, "quote should be prefixed")
check(Content.formatMarkdown("[点这里](https://example.com)"):match("点这里（https://example.com）") ~= nil,
    "markdown link should keep label and url")

local tagged = "8-5<e type=\"hashtag\" hid=\"1\" title=\"%23%E8%B5%84%E8%AE%AF%23\" /> 美股 &amp; A股"
local tagged_clean = Content.parse(tagged)
check(tagged_clean == "8-5#资讯# 美股 & A股", "hashtag and entities should be decoded")

local plain, plain_links = Content.parse("参考 https://example.com/a?x=1&amp;y=2。")
check(plain:match("https://example.com") ~= nil, "plain URL should remain in text")
check(#plain_links == 1, "plain URL should be extracted")

local topic = {
    topic_id = "1",
    title = "测试帖子...",
    content = "测试帖子完整第一行\n第二行正文",
    create_time = "2026-11-04T09:00:00.000+0800",
    owner = { name = "作者" },
    group = { name = "星球" },
    counts = { comments = 2, likes = 3, readers = 4 },
}
check(Content.topicTitle(topic) == "测试帖子完整第一行", "full title should replace API truncation")
local topic_text = Content.topicText(topic)
check(topic_text:match("评论 2 · 点赞 3 · 阅读 4") ~= nil, "topic metadata should be rendered")
check(topic_text:match("第二行正文") ~= nil, "topic body should be rendered")

local comments = {
    {
        comment_id = "c1",
        text = "顶层评论",
        create_time = "2026-11-04T09:01:00.000+0800",
        owner = { name = "甲" },
        replied_comments = {
            {
                comment_id = "c2",
                text = "楼中楼回复",
                create_time = "2026-11-04T09:02:00.000+0800",
                owner = { name = "乙" },
                repliee = { name = "甲" },
            },
        },
    },
}
local comments_text, flat = Content.commentsText(comments)
check(#flat == 2, "nested reply should be flattened for reply picker")
check(comments_text:match("楼中楼回复") ~= nil, "nested reply should be visible")
check(comments_text:match("回复 @甲") ~= nil, "reply target should be visible with @")
check(comments_text:match("↳ 乙 回复 @甲：楼中楼回复") ~= nil,
    "reply must be a single line: name, repliee and content together")
check(comments_text:match("1%.1") == nil, "replies must not use numeric numbering")
check(comments_text:match("09:02") == nil, "replies must not show date or time")

local tool_data = { success = true, groups = { { group_id = "g1", name = "测试星球" } } }
local envelope = {
    jsonrpc = "2.0",
    id = 1,
    result = {
        content = { { type = "text", text = JSON.encode(tool_data) } },
    },
}
local sse = "event: message\ndata: " .. JSON.encode(envelope) .. "\n\n"
local ok, unwrapped = API.unwrap(API.parseTransport(sse))
check(ok and unwrapped.groups[1].group_id == "g1", "SSE MCP response should be unwrapped")

local direct_ok, direct = API.unwrap(API.parseTransport(JSON.encode({
    jsonrpc = "2.0", id = 2, result = { structuredContent = tool_data },
})))
check(direct_ok and direct.groups[1].name == "测试星球", "structuredContent response should work")

local error_ok = API.unwrap({ error = { message = "unauthorized" } })
check(error_ok == false, "MCP errors should be returned as failures")

local api = API.new("secret")
local captured_tool, captured_args
api.call = function(self, tool, args)
    captured_tool, captured_args = tool, args
    return true, { success = true, comment_id = "new-comment" }
end
local comment_ok = api:createComment("topic1", "回复内容", "comment1")
check(comment_ok == true, "confirmed new comment ID should mean success")
check(captured_tool == "create_topic_comment", "reply should use official comment tool")
check(captured_args.topic_id == "topic1" and captured_args.replied_comment_id == "comment1",
    "nested reply should include replied_comment_id")
api.call = function() return true, { success = true } end
check(api:createComment("topic1", "无 ID") == false, "empty comment confirmation must not report success")
check(API.unwrap({ id = 2, result = { success = true } }, 1) == false, "mismatched RPC ID must fail")
check(API.unwrap({ id = 1, result = {} }, 1) == false, "empty RPC result must fail")

local session_api = API.new("token")
local notification_sent = false
session_api.rpc = function(self, method)
    if method == "initialize" then
        return true, { jsonrpc = "2.0", id = 1, result = { protocolVersion = API.PROTOCOL_VERSION } },
            { ["Mcp-Session-Id"] = "session-1" }, 1
    end
    check(self.session_id == "session-1", "initialized notification should carry session ID")
    notification_sent = method == "notifications/initialized"
    return true, { accepted = true }, {}, nil
end
check(session_api:ensureSession() == true and session_api.initialized, "MCP session should initialize")
check(notification_sent, "MCP initialized notification should be sent")

-- 回归：get_user_groups 要求必填 user_id，getGroups 必须先经 get_self_info 获取
local groups_api = API.new("token")
local call_sequence = {}
groups_api.call = function(self, tool, args)
    table.insert(call_sequence, { tool = tool, args = args })
    if tool == "get_self_info" then
        return true, { success = true, user = { user_id = "28845811488251", name = "测试用户" } }
    end
    return true, { success = true, groups = { { group_id = "g1", name = "测试星球" } } }
end
local groups_ok, groups_data = groups_api:getGroups(20)
check(groups_ok and groups_data.groups[1].group_id == "g1", "getGroups should succeed with resolved user_id")
check(call_sequence[1].tool == "get_self_info", "getGroups must resolve user_id via get_self_info first")
check(call_sequence[2].tool == "get_user_groups" and call_sequence[2].args.user_id == "28845811488251",
    "get_user_groups must carry the resolved user_id")
check(call_sequence[2].args.limit == 20, "getGroups limit should be forwarded")
local user_ok, user_id = groups_api:getUserID()
check(user_ok and user_id == "28845811488251" and #call_sequence == 2,
    "resolved user_id should be cached without extra calls")
local bad_api = API.new("token")
bad_api.call = function() return false, "Authentication failed" end
local bad_ok, bad_err = bad_api:getGroups(10)
check(bad_ok == false and bad_err == "Authentication failed",
    "self-info failure should surface the real error")

-- createTopic：业务成功 + 新 topic ID 才算发布成功
local post_api = API.new("token")
local post_tool, post_args
post_api.call = function(self, tool, args)
    post_tool, post_args = tool, args
    return true, { success = true, topic = { topic_id = "new-topic-1" } }
end
local post_ok, post_result = post_api:createTopic("g1", "  标题  ", "正文")
check(post_ok and post_tool == "create_topic", "createTopic should use create_topic tool")
check(post_args.group_id == "g1" and post_args.title == "标题" and post_args.content == "正文",
    "createTopic should trim and forward title/content")
check(post_args.type == "talk" and post_args.text_type == "plain", "createTopic should use plain talk")
post_api.call = function(self, tool, args)
    post_args = args
    return true, { success = true, topic_id = "new-topic-2" }
end
check(select(1, post_api:createTopic("g1", "", "仅正文")) == true, "top-level topic_id also accepted")
check(post_args.title == nil, "empty title must be omitted")
post_api.call = function() return true, { success = true } end
check(post_api:createTopic("g1", "标题", "正文") == false, "missing topic id must not report success")
post_api.call = function() return true, { success = false, error = "无权限" } end
check(post_api:createTopic("g1", "标题", "正文") == false, "business failure must not report success")
check(post_api:createTopic("", "标题", "正文") == false, "empty group id rejected")
check(post_api:createTopic("g1", "  ", "  ") == false, "blank title and content rejected")

local article_text, article_links = Content.topicText({
    content = "",
    talk = { article = { inline_article_url = "https://articles.zsxq.com/id_inline.html", title = "内嵌长文" } },
})
check(#article_links == 1 and article_links[1].url:match("id_inline") ~= nil, "nested inline article should be extracted")
check(article_text:match("内嵌长文") ~= nil, "inline article title should be visible")

check(Content.hash("https://example.com") == Content.hash("https://example.com"), "article cache key should be stable")
check(Content.truncate("中文标题", 6) == "中文…", "UTF-8 truncation should not split a character")

print(string.format("test_core: %d assertions passed", passed))
