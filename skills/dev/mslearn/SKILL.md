---
name: mslearn
updated: 2026-09-15
description: 查询微软官方技术文档（Windows/Win32 API、MSVC、DirectX、.NET、Azure、PowerShell 等）时使用。通过 curl 直调 Microsoft Learn MCP HTTP 端点，语义搜索官方文档、搜官方代码示例、抓取整篇文档转 markdown，让答案基于权威最新的官方内容而非训练记忆。触发场景：用户提到 MSDN、微软文档、Win32 API、Windows SDK、MSVC、DirectX、.NET、Azure，或问"这个 Windows API 怎么用/参数什么含义/最低系统版本"等微软系技术事实性问题，或贴出 learn.microsoft.com / docs.microsoft.com 链接。涉及微软系技术细节时优先用本 skill 查证，不要凭记忆回答。
---

# Microsoft Learn 官方文档查询

封装了 Microsoft Learn 的公共 MCP 端点（`https://learn.microsoft.com/api/mcp`，Streamable HTTP，无需认证，免费）。之所以用脚本直调而不是挂 MCP server，是因为 MCP 工具 schema 会常驻上下文（约 1.5~2K token），而本 skill 只在触发时加载（常驻仅 description 一行）。

## 用法

双脚本功能完全一致，按平台/可用工具任选。`SKILL_DIR` 取本 skill 挂载后的实际路径（示例为 Claude Code 默认挂载点；其他 Agent 换成各自 skill 根目录，或直接用本仓库 `skills/mslearn`）：

**bash 版**（macOS / Linux / Windows Git Bash）：

```bash
SKILL_DIR=~/.claude/skills/mslearn

bash "$SKILL_DIR/scripts/mslearn.sh" search "<query>"           # 搜文档
bash "$SKILL_DIR/scripts/mslearn.sh" code "<query>" [language] # 搜官方代码示例
bash "$SKILL_DIR/scripts/mslearn.sh" fetch "<learn-url>"       # 抓整篇文档
```

**PowerShell 版**（Windows，兼容 PowerShell 5.1 和 7+，不依赖 Git Bash / curl）：

```powershell
$SkillDir = "$env:USERPROFILE\.claude\skills\mslearn"

& "$SkillDir\scripts\mslearn.ps1" search "<query>"           # 搜文档
& "$SkillDir\scripts\mslearn.ps1" code "<query>" [language] # 搜官方代码示例
& "$SkillDir\scripts\mslearn.ps1" fetch "<learn-url>"       # 抓整篇文档
```

## 三个子命令

| 子命令 | 对应官方工具 | 何时用 |
|--------|--------------|--------|
| `search` | microsoft_docs_search | 第一步。语义搜索，返回最多 10 个内容块（每块 ≤500 token），含标题、URL、摘要。适合快速确认 API 签名、参数含义、系统行为 |
| `code` | microsoft_code_sample_search | 需要官方代码示例时。`language` 可选值：`cpp csharp javascript typescript python powershell azurecli al sql java kusto go rust ruby php`。查 C/C++ Windows API 用法时传 `cpp` 能显著提升结果质量 |
| `fetch` | microsoft_docs_fetch | search 结果不够深、需要完整步骤/前提条件/故障排除时，把 search 返回的 `contentUrl` 传进来，得到整篇 markdown |

## 工作流

1. 先 `search` 拿概览和相关页面 URL。查询词用英文效果最好（文档主体是英文）。
2. 摘要够用就直接引用作答；需要全文再 `fetch` 那个 URL。
3. 回答时给出关键事实（参数、版本要求、注意事项）并附文档链接。用户用中文提问就用中文回答，但查询词保持英文。

## 输出格式说明

脚本已剥掉 SSE 外壳，输出是一个 JSON 对象：

- `search`：`result.content[0].text` 是**再嵌一层的 JSON 字符串**，解开是 `{"results": [{"title", "content", "contentUrl", ...}]}`。
- `code`：同上，解开是 `{"results": [{"description", "codeSnippet", "link", "language"}]}`。
- `fetch`：`result.content[0].text` 直接是 markdown 文本。
- 若输出含 `"isError": true` 或 `"error"` 字段，说明调用失败——检查参数（如 fetch 的 URL 必须是 microsoft.com 域的文档页，不能是 PDF/图片）后重试。

## 注意事项

- 端点不能从浏览器直接访问（405 是正常现象），必须走脚本的 POST 调用。
- search 每块内容上限 500 token，截断的摘要不够判断时用 fetch 拿全文。
- 文档每天增量刷新，内容是官方最新版本——遇到训练记忆与查询结果冲突时，以查询结果为准并在回答中指出。
- 脚本零依赖（bash 版只要 curl；PowerShell 版用 Invoke-WebRequest），跨 Windows/macOS/Linux 可用。
- Windows 下 bash 版的 JSON body 必须走 stdin（脚本已内置）：mingw curl 从 `-d` 命令行参数接收非 ASCII 会编码损坏，中文查询会静默返回空结果。

## 资源文件

- `scripts/mslearn.sh` — bash 版查询脚本（Git Bash / macOS / Linux）
- `scripts/mslearn.ps1` — PowerShell 版查询脚本（Windows，PS 5.1 / 7+）
