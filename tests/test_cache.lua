local workspace = arg[1]
assert(workspace, "workspace path required")
package.path = workspace .. "/zsxq.koplugin/?.lua;" .. package.path
package.preload["json"] = function() return dofile("/tmp/zsxq-test-json.lua") end
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/tmp" end }
end
package.preload["util"] = function()
    return {
        makePath = function(path)
            return os.execute("mkdir -p '" .. path .. "'") == 0
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    local function command_output(command)
        local pipe = io.popen(command)
        local output = pipe:read("*a")
        pipe:close()
        return (output:gsub("%s+$", ""))
    end
    return {
        attributes = function(path, attribute)
            local quoted = "'" .. path .. "'"
            local mode = command_output("if [ -d " .. quoted .. " ]; then echo directory; elif [ -f " .. quoted .. " ]; then echo file; fi")
            if mode == "" then return nil end
            if attribute == "mode" or not attribute then
                if not attribute then
                    return {
                        mode = mode,
                        size = tonumber(command_output("stat -f %z " .. quoted)),
                        modification = tonumber(command_output("stat -f %m " .. quoted)),
                    }
                end
                return mode
            elseif attribute == "size" then
                return tonumber(command_output("stat -f %z " .. quoted))
            elseif attribute == "modification" then
                return tonumber(command_output("stat -f %m " .. quoted))
            end
        end,
        dir = function(path)
            local pipe = io.popen("ls -1 '" .. path .. "'")
            local names = {}
            for name in pipe:lines() do table.insert(names, name) end
            pipe:close()
            local index = 0
            return function()
                index = index + 1
                return names[index]
            end
        end,
    }
end

local Cache = require("zsxq_cache")
local root = "/tmp/zsxq-cache-test-" .. tostring(os.time())
local cache = Cache.new(root)
local passed = 0
local function check(condition, message)
    assert(condition, message)
    passed = passed + 1
end

check(cache:put("sample", { value = 42 }), "JSON cache write should succeed")
local sample = cache:get("sample")
check(sample and sample.value == 42, "JSON cache should round-trip")

local topic = {
    topic_id = "topic1",
    title = "离线帖子",
    content = "离线正文",
    create_time = "2026-11-04T09:00:00.000+0800",
    group = { group_id = "group1", name = "星球" },
}
check(cache:saveTopic(topic), "topic cache should save")
check(cache:getTopic("topic1").content == "离线正文", "topic cache should load")
check(#cache:listTopics() == 1, "offline library should index topics")

local path = cache:saveArticle("https://example.com/article", "<html>长文</html>", "html")
check(path ~= nil, "article should save")
check(cache:getArticle("https://example.com/article") == path, "article should be found offline")
local file = io.open(path, "rb")
check(file:read("*a") == "<html>长文</html>", "article bytes should round-trip")
file:close()

local topics, articles = cache:stats()
check(topics == 1 and articles == 1, "cache stats should count content")

-- 划线（高亮）存储
local saved, item = cache:addHighlight("topic1", "离线帖子", "  重要划线内容  ")
check(saved and item.text == "重要划线内容", "highlight should trim and save")
check(#cache:listHighlights() == 1, "highlight should be listed")
local dup_saved, dup_item = cache:addHighlight("topic1", "离线帖子", "重要划线内容")
check(dup_saved and dup_item.id == item.id, "duplicate highlight should dedupe")
cache:addHighlight("topic1", "离线帖子", "第二条划线")
check(#cache:listHighlights("topic1") == 2, "second highlight should be saved")
check(#cache:listHighlights("other") == 0, "filter by topic should work")
check(cache:deleteHighlight(item.id) == true, "highlight should be deletable")
check(#cache:listHighlights() == 1, "remaining highlight should survive delete")

-- 划线定位信息（CRE XPointer）：保存、旧记录补齐、兼容
local xp_saved, xp_item = cache:addHighlight("topic1", "离线帖子", "带坐标的划线", {
    xp = "/body/p[3]/text().12", end_xp = "/body/p[3]/text().40", html_hash = "abc123",
})
check(xp_saved and xp_item.xp == "/body/p[3]/text().12" and xp_item.html_hash == "abc123",
    "highlight should store xp/end_xp/html_hash")
local listed = cache:listHighlights("topic1")
local found_xp
for _, h in ipairs(listed) do if h.id == xp_item.id then found_xp = h end end
check(found_xp and found_xp.end_xp == "/body/p[3]/text().40", "xp should round-trip through JSON")
-- 纯文本旧记录重复保存时补齐坐标
local text_only = cache:addHighlight("topic1", "离线帖子", "第二条划线", {
    xp = "/body/p[1]/text().0", end_xp = "/body/p[1]/text().9", html_hash = "abc123",
})
local filled
for _, h in ipairs(cache:listHighlights("topic1")) do
    if h.text == "第二条划线" then filled = h end
end
check(filled and filled.xp == "/body/p[1]/text().0", "duplicate save should backfill xp on legacy record")

-- 帖子 HTML 写入
local html_path = cache:saveTopicHTML("topic1", "<html><body>正文</body></html>")
check(html_path ~= nil, "topic html should save")
local html_file = io.open(html_path, "rb")
check(html_file and html_file:read("*a") == "<html><body>正文</body></html>", "topic html bytes round-trip")
if html_file then html_file:close() end

os.execute("touch -t 200001010000 '" .. cache:path("sample") .. "'")
local removed = cache:purge(86400)
check(removed >= 1, "expired cache should be purged")
check(cache:get("sample") == nil, "purged cache should not load")
check(cache:getTopic("topic1") ~= nil, "fresh cache should survive purge")
check(#cache:listHighlights() == 2, "purge must never delete highlights.json")

-- 图片缓存：jpg/png 也要能通过 getArticle 找回（否则每次打开都重新下载）
local img_path = cache:saveArticle("https://images.zsxq.com/Fimg1", "JPEGDATA", "jpg")
check(img_path ~= nil and img_path:match("%.jpg$") ~= nil, "jpg article should be saved")
check(cache:getArticle("https://images.zsxq.com/Fimg1") == img_path,
    "getArticle must find cached jpg images")
-- 帖子 HTML 与图片同目录（articles/），保证 <img> 相对引用可用
local html_path = cache:saveTopicHTML("t-html", "<html></html>")
check(html_path:match("/articles/") ~= nil, "topic HTML must live in articles dir next to images")

print(string.format("test_cache: %d assertions passed (%s)", passed, root))
