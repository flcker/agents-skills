---
name: figma-ui-desktop
updated: 2026-11-05
description: 用 Figma 设计稿开发桌面端 UI（Qt Widget / QML / WinUI / Flutter 等非 Web 框架）时使用，解决「直接照抄画布数据导致还原度差」的问题。核心是「框架无关的数据→目标框架翻译方法论」：同时调用 get_figma_data（精确坐标/色值/字号/间距）和 download_figma_images（视觉截图）双通道阅读、禁止单通道写码、用确切值不做视觉估算、结构分析后按「画布概念→目标框架」映射表翻译（布局/颜色/间距/圆角/阴影等）、实现后实际运行程序截图对比设计稿自查 + 人工挑刺迭代。适用于接入 Framelink figma-developer-mcp（工具为 get_figma_data / download_figma_images）的桌面端环境。触发场景：用户给 Figma 链接让实现 Qt/QML/WinUI/Flutter 界面、抱怨 Figma 还原效果差、要求"按设计稿精确还原桌面界面/控件"。
---

# Figma 桌面端 UI 开发规范（Framelink MCP 版）

解决用 Figma 设计稿开发**桌面端** UI 时还原度差的问题。根因是：把 Figma 的「画布数据」（绝对坐标、内联色值、像素图层堆叠）当成了「实现数据」，直接照抄导致布局僵死、颜色字体不准、资源缺失。

> **为什么桌面端用 Framelink 而非官方 Figma MCP Server**：官方 MCP 的核心工具 `get_design_context` 默认只产 Web 代码（React/Tailwind，可切 Vue/HTML/iOS），**不支持 Qt Widget / QML / WinUI / Flutter**，且需付费。Framelink 定位「只喂框架无关的 Figma 数据、翻译交给模型」——这个「短板」在桌面端多框架场景下恰是优势：模型拿到画布数据后可翻译成任意目标框架，而不是被锁死在 Web。

本 skill 面向 **Framelink `figma-developer-mcp`** 的两个工具：

| 工具 | 通道 | 作用 |
|------|------|------|
| `get_figma_data` | 精确通道 | 按 `fileKey` + `nodeId` 拉画布数据：布局、内容、视觉、组件信息 |
| `download_figma_images` | 视觉通道 | 按节点 ID 导出 SVG/PNG/GIF 到本地目录 |

> 若目标是 Web 前端（React/Vue/HTML），用 `figma-ui-web` 而非本 skill。

## 核心原则

1. **双通道并行，禁止单通道写码**。精确通道给确切数值，视觉通道给整体布局与文案。只用其一必然还原失真。
2. **用确切值，不做视觉估算**。颜色、字号、字重、间距、圆角、边框、阴影，一律取设计稿确切值。
3. **先索要设计稿，不自发写 UI**。
4. **实现后必须验证闭环**：实际运行程序截图对比设计稿 → 发现缺陷自动修 → 人工挑刺再迭代。

## 工作流

### 阶段一：粗读（理解需求与结构）

设计稿过大时先粗读，避免一次拉全量导致上下文过载：

1. 用 `get_figma_data` 拉顶层结构（`depth` 控制遍历层级，先从浅层开始），搞清有哪些页面/区块/控件。
2. 用 `download_figma_images` 导出整体界面图，理解布局与文案。

### 阶段二：精读（实现前拿精确数据）

针对具体要实现的区块/控件，**同时**调用：

- `get_figma_data`（带 `nodeId`，逐节点读坐标、色值、字号、间距、圆角、边框）
- `download_figma_images`（导出该区块图，确认控件相对位置关系）

拿到后先做**结构分析**再写码：

- 哪些节点是**重复模式**（列表项、卡片、按钮）→ 抽成目标框架的自定义控件/组件
- 哪些绝对定位其实是**布局**（横向排列、居中、两端对齐、网格）→ 按下方映射表转成对应框架的布局
- 哪些是**语义角色**（导航/表单/列表）→ 映射目标框架已有控件库
- 图片/图标节点 → 用 `download_figma_images` 下载原文件落地到资源目录，不手绘

### 阶段三：实现（框架无关翻译）

颜色/字号/间距用设计稿确切值。翻译时查下面的「画布概念 → 目标框架」映射表，**不要臆造控件**——目标框架有标准布局/控件就用标准的，绝对坐标只在「确实需要精确像素定位」时才保留。

### 阶段四：验证闭环

桌面端无 Playwright 这类浏览器自动化，验证方式：**实际编译运行程序截图，与设计稿截图并排对比**，发现明显缺陷自动修；人工挑刺识别更细问题（间距、字重、颜色微差），主动抛给 AI 精准修复，进入下一轮迭代。

## 画布概念 → 目标框架映射表

Figma 画布是绝对坐标 + 像素图层，实现要翻译成各框架的布局语义。翻译时查此表：

| 画布/设计概念 | Qt Widget | QML (Qt Quick) | WinUI 3 (XAML) | Flutter |
|---|---|---|---|---|
| 横向排列 | `QHBoxLayout` | `Row` | `StackPanel` (Orientation=Horizontal) | `Row` |
| 纵向排列 | `QVBoxLayout` | `Column` | `StackPanel` (Orientation=Vertical) | `Column` |
| 网格布局 | `QGridLayout` | `Grid` / `GridLayout` | `Grid` | `GridView` / `Table` |
| 绝对定位 | `setGeometry` / `move` | `Item` + `x`/`y` | `Canvas` + `Canvas.Left`/`Top` | `Stack` + `Positioned` |
| 层叠/覆盖 | 子 widget 叠加 / `raise()` | `z` 属性 / `Stack` | `Canvas.ZIndex` | `Stack` |
| 居中 | `addStretch` / `setAlignment` | `anchors.centerIn` | `HorizontalAlignment`/`VerticalAlignment=Center` | `Center` / `Align` |
| 两端对齐 | 两侧 `addStretch` | `anchors.left`/`right` + margins | 边距分配 | `MainAxisAlignment.spaceBetween` |
| 间距 | `QSpacerItem` / layout `spacing` | `spacing` 属性 | `Margin` / `Padding` | `SizedBox` / `Padding` / `Spacer` |
| 颜色 | `QPalette` / stylesheet | Theme / 属性绑定 | 资源字典 `ResourceDictionary` | `ThemeData` / `ColorScheme` |
| 字号/字体 | `QFont` | `font.pixelSize` | `FontSize` | `TextStyle.fontSize` |
| 圆角 | stylesheet `border-radius` | `Rectangle` `radius` | `CornerRadius` | `BorderRadius` |
| 阴影 | `QGraphicsDropShadowEffect` | `DropShadow` | `ThemeShadow` / `DropShadow` | `BoxShadow` |
| 图标 | `QIcon` / 资源 | `Image` / 图标字体 | `FontIcon` / `SymbolIcon` | `Icon` |
| 组件复用 | 自定义 `QWidget` 子类 | 自定义 QML `Component` | `UserControl` / 自定义控件 | `Widget` |
| 状态/变体 | 枚举 + `update()` | `State` / 属性驱动 | `VisualStateManager` | `setState` / `AnimatedWidget` |

## 防偷懒铁律

AI 会倾向只用一种通道就写码，必须明确要求：

- 「同时调用 get_figma_data 和 download_figma_images 阅读设计稿」
- 「不允许只用图片/截图阅读设计稿就写代码」
- 「逐行读 get_figma_data 的确切值，对比颜色/字号/间距，不做视觉估算」
- 「按映射表翻译到目标框架的标准布局/控件，不臆造」

## 还原度自检清单

生成后逐项核对（比"整体像不像"可靠）：

- [ ] 颜色（是否用了确切值，而非近似）
- [ ] 字号 / 字重
- [ ] 间距 / 边距 / 内边距
- [ ] 圆角 / 边框 / 阴影
- [ ] 布局（是否翻译成目标框架标准布局，而非照抄绝对坐标）
- [ ] 层级 / 层叠顺序
- [ ] 图标/图片是否用原文件，而非手绘
- [ ] 重复模式是否抽成了组件/自定义控件

## 参考来源

方法论借鉴自官方 Figma MCP + Playwright 的 UI 开发流程（见「使用 Figma mcp 和 Playwright mcp 提升 UI 开发与调试效率」），核心思想「双通道 + 验证闭环 + 防偷懒明确要求」保留，工具名适配 Framelink `figma-developer-mcp`，映射表扩展覆盖桌面端多框架。
