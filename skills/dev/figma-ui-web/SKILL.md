---
name: figma-ui-web
updated: 2026-11-05
description: 用 Figma 设计稿开发 Web 前端 UI 时使用，解决「直接照抄画布数据导致还原度差」的问题。核心是「双通道阅读 + 验证闭环」：同时调用 get_figma_data（拿精确坐标/色值/字号/间距）和 download_figma_images（导出节点图片让模型"看见"布局与文案），禁止只用单一通道就写代码；实现后用 Playwright 截图对比设计稿自查、人工挑刺再迭代。适用于接入 Framelink figma-developer-mcp（工具为 get_figma_data / download_figma_images）的 Web 前端环境（React/Vue/HTML 等）。触发场景：用户给 Figma 链接/fileKey/nodeId 让实现 Web 页面、抱怨 Figma 还原效果差、或要求"按设计稿精确还原页面/组件"。
---

# Figma Web UI 开发规范（Framelink MCP 版）

解决用 Figma 设计稿开发 **Web 前端** UI 时还原度差的问题。根因是：把 Figma 的「画布数据」（绝对坐标、内联色值、像素图层堆叠）当成了「实现数据」，直接照抄导致响应式失效、颜色字体不准、资源缺失。

本 skill 面向 **Framelink `figma-developer-mcp`** 的两个工具：

| 工具 | 通道 | 作用 |
|------|------|------|
| `get_figma_data` | 精确通道 | 按 `fileKey` + `nodeId` 拉画布数据：布局、内容、视觉、组件信息 |
| `download_figma_images` | 视觉通道 | 按节点 ID 导出 SVG/PNG/GIF 到本地目录 |

> 注意：这是 Framelink 版，不是官方 Figma MCP Server（官方工具为 `get_design_context`/`get_variable_defs`/`download_assets`）。本 skill 的方法论对两者通用，但工具名按 Framelink 写。
>
> 若目标是桌面端（Qt Widget / QML / WinUI / Flutter），用 `figma-ui-desktop` 而非本 skill。

## 核心原则

1. **双通道并行，禁止单通道写码**。精确通道给确切数值，视觉通道给整体布局与文案。只用其一必然还原失真——尤其只用视觉通道（等于看截图猜），或只用数据通道（等于盲写）。
2. **用确切值，不做视觉估算**。颜色、字号、行高、字重、间距、圆角、边框、阴影，一律取设计稿确切值。
3. **先索要设计稿，不自发写 UI**。
4. **实现后必须验证闭环**：截图对比设计稿 → 发现缺陷自动修 → 人工挑刺再迭代。没有一次性到 100% 的魔法，还原到 7~8 成靠流程，剩下的靠验证循环补齐。

## 工作流

### 阶段一：粗读（理解需求与结构）

设计稿过大时先粗读，避免一次拉全量导致上下文过载：

1. 用 `get_figma_data` 拉顶层结构（`depth` 控制遍历层级，先从浅层开始），搞清有哪些页面/区块/组件。
2. 用 `download_figma_images` 导出整体页面图，理解布局与文案。

### 阶段二：精读（实现前拿精确数据）

针对具体要实现的组件/区块，**同时**调用：

- `get_figma_data`（带 `nodeId`，逐节点读坐标、色值、字号、间距、圆角、边框）
- `download_figma_images`（导出该区块图，确认组件相对位置关系）

拿到后先做**结构分析**再写码：

- 哪些节点是**重复模式**（卡片、列表项、按钮）→ 抽成组件
- 哪些绝对定位其实是**布局**（横向排列、居中、两端对齐）→ 转 flex/grid
- 哪些是**语义角色**（导航/表单/列表）→ 映射目标框架已有组件库
- 图片/图标节点 → 用 `download_figma_images` 下载原文件落地到 assets，不手绘

### 阶段三：实现

- 颜色/字号/间距用设计稿确切值，不"看起来差不多"
- 优先使用项目已有组件库，先查组件 props（theme/size/variant），避免重复定义样式
- 图标用项目图标库，不用第三方图标
- 样式文件命名、CSS 类名规范、嵌套层级遵循项目约定

### 阶段四：验证闭环

用 Playwright MCP 打开本地页面截图，与设计稿截图并排对比，发现明显缺陷自动修；人工挑刺：人识别更细的问题（间距、字重、颜色微差），主动抛给 AI 精准修复，进入下一轮迭代。

## 防偷懒铁律

AI 会倾向只用一种通道就写码，必须明确要求：

- 「同时调用 get_figma_data 和 download_figma_images 阅读设计稿」
- 「不允许只用图片/截图阅读设计稿就写代码」
- 「逐行读 get_figma_data 的确切值，对比颜色/字号/间距，不做视觉估算」

## 组件规范（按项目替换）

以下是模板，落地到具体项目时替换为该项目约定：

- 优先使用项目组件库（如 `@notta/components`），存疑主动询问用户
- 先查组件库 props，避免重复定义样式
- 图标用项目图标库
- 样式文件命名、CSS 类名规范、嵌套层数遵循项目约定

## 还原度自检清单

生成后逐项核对（比"整体像不像"可靠）：

- [ ] 颜色（是否用了确切 hex，而非近似）
- [ ] 字号 / 行高 / 字重
- [ ] 间距 / 边距 / 内边距
- [ ] 圆角 / 边框 / 阴影
- [ ] 布局（flex/grid 是否等价于设计稿排列）
- [ ] z-index / 层级
- [ ] 图标/图片是否用原文件，而非手绘

## 参考来源

方法论借鉴自官方 Figma MCP + Playwright 的 UI 开发流程（见「使用 Figma mcp 和 Playwright mcp 提升 UI 开发与调试效率」），核心思想是「双通道 + 验证闭环 + 防偷懒明确要求」，工具名已适配 Framelink `figma-developer-mcp`。
