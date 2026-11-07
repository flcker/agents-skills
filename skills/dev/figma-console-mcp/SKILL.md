---
name: figma-console-mcp
updated: 2026-11-07
description: 接入或使用 southleft figma-console-mcp（把 Figma 设计系统变成 Agent 可调用的 API）时使用。解决「Figma 变量/组件/状态/无障碍无法结构化核对、设计稿→代码 token 与组件状态容易漏、需要双向同步或 design-code parity 检查」的问题。触发场景：要给 Agent 接 Figma 设计系统 API、做 Figma 变量/组件的双向同步、设计稿交付前端时核对 token 与组件状态、跑 WCAG 无障碍检查、设计代码一致性对比、或用户提到 figma-console-mcp / Figma MCP / design system as API。
---

# Figma Console MCP 接入与使用指南

把 Figma 设计系统（variables、components、styles、states）变成 Agent 可调用的结构化 API，支持双向（Figma ⇄ code）读写与确定性检查。面向 **southleft `figma-console-mcp`**（不是 Framelink `figma-developer-mcp`，也不是官方 Figma MCP Server）。

> 相关技能分工：
> - 要**按 Figma 设计稿还原 UI**（Web/桌面端）→ 用 `figma-ui-web` / `figma-ui-desktop`（双通道阅读 + 验证闭环）。
> - 要**把设计系统当 API 调用**（token 同步、组件/变量/状态管理、无障碍、parity）→ 用本 skill。

## 它能做什么

| 能力 | 说明 |
|---|---|
| 设计系统提取 | 拉取 Figma variables / components / styles 为结构化数据 |
| 代码库 → 设计系统 | 扫描生产代码库，挖掘事实样式为 DTCG token（带出处溯源），脚手架设计系统包 + Storybook，再回写 Figma |
| 双向 token 同步 | 导出 Figma 变量到 DTCG JSON（legacy / 2025.10 方言）等 10 种格式；代码侧改动 push 回 Figma（增/改名/别名重定向/替换门控删除），替代 Style Dictionary 与 Tokens Studio 导出管线 |
| 视觉调试 | 截图供上下文 |
| 设计创建 | 直接在 Figma 建 UI 组件/Frame/布局，含「变体轴矩阵一键创建组件集」 |
| 变量管理 | 创建/更新/重命名/删除 design token |
| 版本历史 | 列版本、diff 快照、生成 markdown changelog、二分 blame 追溯属性/变体引入 |
| 实时监控 | 监听 Desktop Bridge 插件 console 日志 |
| FigJam / Slides | 建便签/流程图/表格/代码块；程序化管理 Figma Slides |
| 无障碍扫描 | 14 项 WCAG 设计检查（带合规级别标记）、组件 scorecard、axe-core 代码扫描 |
| design-code parity | 确定性对比 Figma 组件与其代码实现（视觉/间距/排版/token/组件 API/无障碍），生成组件文档 |
| 设计系统健康审计 | Lighthouse 式打分审计（命名/token/组件元数据/无障碍/一致性/覆盖率） |

## 四种连接方式与能力差异

| 能力 | NPX / Local Git | Cloud Mode | Remote SSE |
|---|:---:|:---:|:---:|
| 读设计数据 | ✅ | ✅ | ✅ |
| 创建组件 & Frame | ✅ | ✅ | ❌ |
| 编辑已有设计 | ✅ | ✅ | ❌ |
| 管理 token/variables | ✅ | ✅ | ❌ |
| FigJam 板 | ✅ | ✅ | ❌ |
| 实时监控（console/selection） | ✅ | ❌ | ❌ |
| 代码库 → 设计系统提取（`figma_ds_*`） | ✅ | ❌ | ❌ |
| Desktop Bridge 插件 | ✅ | ✅ | ❌ |
| 需要 Node.js | 是 | 否 | 否 |
| **工具总数** | **130** | **105（配对后）** | **只读子集** |
| 接入耗时 | ~10~15 min | ~5 min | ~2 min |

**选型原则**：

- 只想**读**设计数据 → Remote SSE，最快。
- Web AI 客户端（Claude.ai / v0 / Replit / Lovable）无 Node 又要**写** → Cloud Mode。
- 本机完整能力（写 + 实时监控 + 代码库提取）→ NPX（推荐）或 Local Git（要参与贡献）。
- **完整写入需要 Figma Desktop + Desktop Bridge 插件 + 访问令牌；先跑只读检查，确认无误再开放写权限。**

## 接入步骤（NPX，推荐）

### 前置条件

- Node.js 18+（`node --version` 确认）
- Figma Desktop（不是 web 版）
- 一个 MCP 客户端（Claude Code / Cursor / Windsurf / Claude Desktop 等）

### Step 1：拿 Figma Token

1. 打开 Figma → Manage personal access tokens。
2. 新建 token，description 填 `Figma Console MCP`。
3. scopes（除 Variables 外均为 Read）：File content、File versions、Library content、Library assets、Comments（Read and write）、Current user、Variables（仅 Enterprise，可选）。
4. 复制 token（以 `figd_` 开头，只显示一次）。

### Step 2：配置 MCP 客户端

Claude Code（CLI）：

```bash
claude mcp add figma-console -s user \
  -e FIGMA_ACCESS_TOKEN=figd_YOUR_TOKEN_HERE \
  -e ENABLE_MCP_APPS=true \
  -- npx -y figma-console-mcp@latest
```

OpenAI Codex（CLI）：

```bash
codex mcp add figma-console \
  --env FIGMA_ACCESS_TOKEN=figd_YOUR_TOKEN_HERE \
  --env ENABLE_MCP_APPS=true \
  -- npx -y figma-console-mcp@latest
```

> Codex 默认 10s/60s 超时太短，需在 `~/.codex/config.toml` 设 `startup_timeout_sec = 60`、`tool_timeout_sec = 300`。

Gemini CLI：

```bash
gemini mcp add -s user \
  -e FIGMA_ACCESS_TOKEN=figd_YOUR_TOKEN_HERE \
  -e ENABLE_MCP_APPS=true \
  figma-console npx -y figma-console-mcp@latest
```

Cursor / Windsurf / Claude Desktop：在 MCP 配置文件加：

```json
{
  "mcpServers": {
    "figma-console": {
      "command": "npx",
      "args": ["-y", "figma-console-mcp@latest"],
      "env": {
        "FIGMA_ACCESS_TOKEN": "figd_YOUR_TOKEN_HERE",
        "ENABLE_MCP_APPS": "true"
      }
    }
  }
}
```

### Step 3：验证

1. 本地启动日志确认 MCP 服务、WebSocket 桥、写入工具均已注册。
2. 先跑只读检查（拉变量/组件列表），确认数据能正确读回。
3. 再逐步开放写权限（token 同步、组件创建）。

## 使用原则

1. **先只读后写**。写操作（创建/编辑/删 token、建组件）会改设计系统，先确认读到的数据正确再写。
2. **写操作不可轻率**。删 token、重命名、别名重定向等是全设计系统范围的动作，动手前核对影响面。
3. **token 同步用导出/导入闭环**。导出 DTCG JSON 看现状 → 代码侧改 → push 回 Figma，别跳过导出直接盲写。
4. **parity 与无障碍作为交付门槛**。设计稿交前端前，用 parity 检查 + 14 项 WCAG 检查逐项核对，别只靠肉眼查布局。

## 参考来源

- 仓库：https://github.com/southleft/figma-console-mcp（MIT 协议，可商用）
- 本 skill 提炼自该仓库 README（130 工具、四连接方式能力差异、接入步骤、先只读后写原则）。
