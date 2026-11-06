# 星球墨读 · zsxq.koplugin

> 在 Kindle / KOReader 上安静地读知识星球。
>
> 出品人：简单的舟 · 当前版本 v14

[KOReader](https://github.com/koreader/koreader) 插件，把知识星球的帖子、评论、图片搬进墨水屏：正文与评论连续显示、图片内嵌、原生滑动划线、离线缓存、翻页连读，还能确认后回复评论。

**这是个人开发的非官方插件，与知识星球官方无关。**

---

## ✨ 功能

**阅读**
- 在线阅读：星球 → 帖子列表，点开即显示全文（正文 + 评论连续排版，评论标题夹在分割线之间）
- 按标签阅读、翻页加载更多帖子
- **打开即拉取全部评论**（分页续拉，上限 2000 条，支持断点续拉）；≤30 条评论的帖子全程静默秒开，>30 条才显示进度提示
- 评论楼中楼单行显示，昵称加粗、时间灰小字、点赞数同步
- 图片弹窗浏览（左右翻页），Markdown 图片自动识别
- 长文 / 长链接一键生成**全屏二维码**，手机扫码打开
- 评论数量口径统一：按钮显示「含楼中楼总条数」，列表区分「楼层数 / 合计条数」

**图文模式（可选高级视图）**
- 生成排版 HTML 交给 KOReader CRE 阅读器：标题加粗、图片原位内嵌、评论内嵌
- 长按滑动选中即**原生划线**，点已划线文字可删除/编辑，AI 助手等高亮插件照常可用
- 轻点屏幕上部呼出功能菜单：下一篇 / 上一篇 / ⤒ 跳转开头 / 写评论 / 返回帖子列表 / 关闭图文
- 轻点屏幕底部边缘呼出/隐藏状态栏（进度条），样式在 KOReader「设置 → 状态栏」调整

**离线与交互**
- 离线阅读：星球 → 帖子 → 评论三级缓存，逐篇缓存进度提示，星球名带「N 帖」计数
- 翻页连读：翻到末尾自动进下一篇（默认视图与图文模式均支持）
- 评论回复：写评论、回复某条评论（楼中楼），发送前二次确认
- 纯文本发帖、点选段落划线、「我的划线」管理
- Token 缺失 / HTTP 401 / 网络异常均有明确诊断与引导

---

## 📦 安装

1. 从 [Releases](../../releases) 下载 `zsxq-koreader-plugin.zip`（或直接克隆本仓库）。
2. 解压得到 `zsxq.koplugin/` 目录。
3. 用 USB 把整个目录拷到 KOReader 的插件目录：
   - Kindle：`/mnt/us/koreader/plugins/`
   - 其他设备：KOReader 安装目录下的 `plugins/`
   最终路径形如 `.../koreader/plugins/zsxq.koplugin/main.lua`。
4. 完全退出并重启 KOReader。
5. 菜单「工具（Tools）→ 星球墨读」即可打开。

> 需要 KOReader 较新版本（用到 ImageViewer、TextViewer、ButtonDialog、CRE 高亮等组件）。

---

## 🔑 配置 Token

插件通过知识星球官方 MCP 网关读取数据，需要你自己的访问凭证：

> **知识星球密钥管理**（获取访问凭证，让 AI 助手以你的身份访问星球）
> https://garden.zsxq.com/jasmine/

两种写入方式，任选其一：

| 方式 | 操作 |
| --- | --- |
| 设备上输入（推荐） | 「缓存与账号设置 → 设置 MCP Token」，粘贴 token 本身（不带网址、不带 `Bearer `） |
| USB 写入 | 在 `koreader/settings/` 下新建 `zsxq_token.txt`，只放一行 token |

Token 会同时写入 KOReader 的 `G_reader_settings`（`zsxq_mcp_token`）。

🔒 **安全说明**
- 本仓库**不含任何真实 Token**，也不含你的星球数据；Token 只保存在你自己的设备上。
- 请不要把 `zsxq_token.txt`、设备 `settings/` 目录或任何包含 token 的文件提交/上传到公开仓库（仓库已用 `.gitignore` 拦截常见文件名）。
- 如果 Token 曾意外泄露，请立即到密钥管理页作废并重新生成。
- 遇到 HTTP 401 通常表示 Token 失效，插件内的「连接诊断」可逐项排查。

---

## 🧭 使用提示

- Kindle 没有 Home 键：在图文模式**轻点屏幕上部**调出功能菜单，用「返回帖子列表」退出。
- 默认视图是纯文字功能页（不打开阅读器、不下载文档），按钮排第一行是「评论 N 条 / 回复某条评论 / 写评论」。
- 「📖 图文」是可选的排版阅读入口，划线体验更好，但会生成 HTML 文档。
- 缓存有效期默认 7 天，可在「缓存与账号设置」调整。
- 离线列表显示的是**已缓存**的帖子数量；想读新的帖子，先联网打开一次或点「缓存」。

---

## 🛠 开发

源码为 Lua 5.1，六个模块：

| 文件 | 职责 |
| --- | --- |
| `main.lua` | 界面、菜单、阅读流程、缓存调度、二维码、评论交互 |
| `zsxq_api.lua` | 知识星球 MCP 网关 HTTP 客户端 |
| `zsxq_content.lua` | Markdown / 正文 / 评论纯文本格式化 |
| `zsxq_html.lua` | 图文模式 HTML 排版与样式 |
| `zsxq_cache.lua` | 帖子、评论、图片、划线的本地缓存 |
| `_meta.lua` | 插件元数据 |

测试（Lua 5.1，工作区路径作为参数）：

```bash
lua tests/test_main.lua .
lua tests/test_core.lua .
lua tests/test_cache.lua .
```

v14 基线：**223 个断言全部通过**（main 135 / core 60 / cache 28）。

打包：

```bash
zip -qr zsxq-koreader-plugin.zip zsxq.koplugin -x "*.DS_Store"
```

---

## 📄 许可证

[MIT](LICENSE) · Copyright (c) 2026 简单的舟

本项目为独立插件，不隶属于知识星球；使用本插件即表示你自行负责所持凭证的安全与合规使用。
