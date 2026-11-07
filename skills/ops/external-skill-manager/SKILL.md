---
name: external-skill-manager
updated: 2026-11-07
description: 用户给外部 skill 的 git 仓库 URL、GitHub/GitLab 仓库页、或提到某 skill 的网页，要求「接入/导入/安装/管理这个外部 skill」时使用。负责把输入识别为 source-ref、决定 ref 与 namespace、调用本仓库 scripts/external-skills.{sh,ps1} 写入清单并同步挂载到各 Agent。触发场景：用户贴 skill 仓库地址或介绍网页、说「把 xxx 这个 skill 装进来」「导入/接入外部技能」「管理外部 skill」，或要查/移除已接入的外部技能。
---

# 外部技能管理

把「用户给的 URL 或网页」翻译成外部技能清单（`external-skills.yaml`）里的一条 source-ref，并调用仓库脚本完成同步与挂载。本 skill 是**编排层**：所有实际动作复用 `scripts/external-skills.{sh,ps1}`，不复制脚本、不手写 clone/挂载逻辑。

## 前置：定位 agents-skills 仓库根

脚本靠 `REPO_ROOT` 定位 `external-skills.yaml`，必须先找到仓库根。按序尝试，命中即停：

1. **git rev-parse**（当前 cwd 在仓库内时最可靠）：
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
   ```
2. **从本 skill 挂载点反推**（symlink/junction 安装时有效）：
   - Linux/macOS：`readlink -f ~/.claude/skills/external-skill-manager` 得真实路径，往上走到含 `REPO_ID` 且含 `external-skills.yaml` 的目录。
   - Windows：`(Get-Item "$env:USERPROFILE\.claude\skills\external-skill-manager").Target` 得真实路径，同样往上找含 `REPO_ID` 的目录。
3. **都不行** → 问用户仓库路径，不要猜。

## 工作流

1. **识别输入类型**：
   - 已是 git 仓库地址 / source-ref（`github:owner/repo`、`gitlab:owner/repo`、`https://…git`、`ssh://`、`file://`）→ 跳到第 3 步。
   - 普通网页（文章、博客、聚合页、GitHub/GitLab 仓库主页）→ 第 2 步。

2. **从网页提取仓库地址**：
   - 静态可读：用 `read`（能拿到正文即可）。
   - JS 渲染 / 反爬（微信公众号、知乎、百度百科等）：用 `skill://cdp-search-fetch` 的 `fetch --selector` 抓正文。
   - 提取目标：GitHub/GitLab 仓库地址（`github.com/owner/repo`、`gitlab.com/owner/repo`）。优先取仓库主页明确的 clone 地址或 `og:url`。
   - **提取失败 → 问用户确认仓库地址**，不要臆测。

3. **决定 ref 与 namespace**（见下「决策规则」）。

4. **执行**：
   ```bash
   # Linux/macOS/WSL
   bash "$REPO_ROOT/scripts/external-skills.sh" add "<source-ref>" [--namespace N]
   # Windows
   powershell -ExecutionPolicy Bypass -File "$REPO_ROOT\scripts\external-skills.ps1" add "<source-ref>" [-Namespace N]
   ```
   `add` 会写清单并立即 `apply`（clone + 挂载）。

5. **验证**：
   ```bash
   bash "$REPO_ROOT/scripts/external-skills.sh" list
   ls ~/.agents/skills/          # 应出现 <namespace>.<技能名>
   ```
   Windows 等价：`list` 子命令 + `ls "$env:USERPROFILE\.agents\skills\"`。

## 决策规则

| 决策 | 规则 |
|---|---|
| **URL → source-ref** | git 地址直接用；GitHub 仓库页 `github.com/owner/repo` 规整为 `github:owner/repo`；GitLab 同理 |
| **ref 选择** | 优先锁 tag（仓库页/网页能读到 release/tag 版本号时用 `@tag`）；读不到 tag 用 `HEAD`（跟随默认分支）。**禁止无依据写 `main`** |
| **namespace** | 默认 `auto`（脚本自动读源仓库 `REPO_ID`，无则 URL slug）。**只有在脚本报「同 namespace 冲突」时**才显式指定不同 namespace |

## 子命令速查（脚本已实现）

- `apply`（缺省）：读清单 → clone/更新缓存 → 冲突预检 → 挂载（幂等）
- `add <source-ref> [--namespace N]`：追加条目并立即 apply
- `remove <namespace> [--prune]`：卸载链接并删清单条目；`--prune` 连缓存一起删
- `update`：等价全量 apply
- `list`：列出清单与解析结果

## 关键行为（回答用户前需知道）

- **挂载位置**：缓存 `~/.agents/external-skills/<url-slug>/`（Windows `%USERPROFILE%\.agents\external-skills\`，可 `EXTERNAL_SKILLS_HOME` 覆盖）；挂载点各 Agent 根目录下 `<namespace>.<技能名>` 链接。
- **冲突**：同 namespace 下同名技能 → 整轮 fail-fast，打印「改 namespace」指引，不做半成品挂载。
- **ref 纪律**：生产/CI 用 tag 或 commit SHA；branch 仅开发期。
- **安全**：外部仓库不经 `check-sanitize` 校验，内容安全由使用方自担；清单内不放凭据（凭据走 git credential helper）。

## 兜底

- 网页提取不到仓库地址、或 ref/namespace 无法确定 → 明确列出「已知信息 + 缺失项」，向用户提问，不要自行假设。
- 脚本报错（克隆失败、ref 拉不到、冲突）→ 把脚本原样错误呈现给用户，按脚本提示处理（如 ref 拉不到改用 tag）。
