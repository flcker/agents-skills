---
name: mcp-server-manager
updated: 2026-11-09
description: 用户给 MCP 名称、官方文档 URL、npx 启动命令或介绍网页，要求「登记/接入/管理这个 MCP」时使用。负责把输入识别为 mcp-servers.yaml 里的一条记录（name + docs + pattern + 可选 command/env），调用本仓库 scripts/mcp-servers.{sh,ps1} 写入清单并校验。触发场景：用户说「把 xxx 这个 MCP 记下来」「登记 MCP」「这个 MCP 怎么管理」，或贴 MCP 官方文档/npm 页，或要查/移除已登记的 MCP。
---

# MCP 登记管理

把「用户给的文本消息」翻译成 MCP 登记清单（`mcp-servers.yaml`）里的一条记录，并调用仓库脚本完成写入与校验。本 skill 是**编排层**：所有实际动作复用 `scripts/mcp-servers.{sh,ps1}`，不复制脚本、不手写 yaml。

## 前置：定位 agents-skills 仓库根

脚本靠 `REPO_ROOT` 定位 `mcp-servers.yaml`，必须先找到仓库根。按序尝试，命中即停：

1. **git rev-parse**（当前 cwd 在仓库内时最可靠）：
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
   ```
2. **从本 skill 挂载点反推**（symlink/junction 安装时有效）：找到含 `REPO_ID` 且含 `mcp-servers.yaml` 的目录。
3. **都不行** → 问用户仓库路径，不要猜。

## 输入识别 → 四个字段

| 用户给什么 | 怎么处理 |
|---|---|
| **npx 启动命令**（`npx -y xxx@latest`、`npx -y xxx`） | `command` 直接取原命令；`name` 取包名（去 `npx -y` 前缀与版本号）；再补 `docs` |
| **官方文档 URL**（`*.md`、GitHub 仓库、npm 页） | `docs` 取 URL；`name` 取包名/仓库名；`command` 从文档/npm 页提取（读得到才填） |
| **只有 MCP 名称** | `name` 直接用；`docs` 和 `command` 需搜官方仓库/npm 补全 |
| **普通网页**（文章/博客/聚合页） | 提取其中的 MCP 名称与官方地址；JS 渲染/反爬用 `skill://cdp-search-fetch` 抓正文 |

## 决策规则

| 决策 | 规则 |
|---|---|
| **pattern 三分法** | 有公开无认证 HTTP 端点 → `direct`；必须真挂 server 才能用 → `guide`；server 已接入、只是约定用法 → `usage`。**拿不准就问用户**，给出三选一并说明取舍，不臆测 |
| **docs 指向** | 仓库已有对应 skill（接入/使用指南）→ 填仓库内 `skills/...` 相对路径；没有 → 填官方文档 URL |
| **command** | `direct` 型省略；`guide`/`usage` 型必须填。只记命令本身，不含 `--api-key=xxx` 这类凭证（凭证走 `env` 环境变量名） |
| **env** | 只记**环境变量名**（如 `FIGMA_ACCESS_TOKEN`），逗号分隔；**永不记值**。凭证值不入清单、不入 skill 文件 |

## 执行

```bash
# Linux/macOS/WSL
bash "$REPO_ROOT/scripts/mcp-servers.sh" add "<name>" --docs "<docs>" --pattern "<pattern>" [--command "<cmd>"] [--env "<ENV1,ENV2>"]

# Windows（注意：单横线参数，与 bash 侧 -- 不同）
powershell -ExecutionPolicy Bypass -File "$REPO_ROOT\scripts\mcp-servers.ps1" add "<name>" -Docs "<docs>" -Pattern "<pattern>" [-Cmd "<cmd>"] [-Env "<ENV1,ENV2>"]
```

`add` 会写清单并立即跑 `check` 校验；失败（重复、缺字段、docs 不可达、疑似凭证）会非零退出并打印原因，按提示修正或向用户确认。

## 验证

```bash
bash "$REPO_ROOT/scripts/mcp-servers.sh" list      # 确认新条目出现
bash "$REPO_ROOT/scripts/mcp-servers.sh" check     # 校验通过
# Windows 等价：powershell -File ...\mcp-servers.ps1 list / check
```

## 子命令速查

| 子命令 | 作用 |
|---|---|
| `check`（缺省） | 校验清单：格式、docs/pattern 必填、pattern 合法、guide/usage 需 command、docs 可达、无凭证 |
| `add <name> --docs … --pattern … [--command …] [--env …]` | 登记一条（按 name 去重，重复报错） |
| `remove <name>` | 移除一条 |
| `list` | 列出 name / docs / pattern |

## 关键行为（回答用户前需知道）

- **只登记、不接入**：清单是「有哪些 MCP + 去哪查 + 什么姿势」的索引，**不**执行 `mcp add` 接入动作。真正接入按 `docs` 指向的 skill 文档在各自客户端手配，凭证用户手填。
- **安全红线**：MCP server 本体、凭证值、内网端点、客户端配置一律不入仓库；`env` 只记环境变量名。
- **去重**：按 `name` 判断，同名登记报错。

## 兜底

- 提取不到官方文档地址 / 不确定 pattern / 不确定 command → 明确列出「已知信息 + 缺失项」，向用户提问，不要自行假设。
- 脚本报错 → 把脚本原样错误呈现给用户，按提示处理（如 docs URL 不可达改用官方主文档地址）。
