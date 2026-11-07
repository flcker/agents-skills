# agents-skills

通用 Agent 技能（skills）集合仓库。公开、可复用、与具体公司业务无关。

## 简介

本仓库集中管理、维护和分发可复用的 Agent 技能。每个技能是一组任务特定的指令，Agent 可以按需加载并执行。与公司内部业务仓库（含内网 API/域名/凭证）物理隔离，本仓库只放可公开的通用技能。

## 目录结构

```
agents-skills/
├── README.md          # 本文件
├── AGENTS.md          # 指导 Agent 行为的规范
├── LICENSE            # MIT
├── .gitignore         # Git 忽略规则
├── REPO_ID            # 本仓库的稳定命名空间标识（见下文「身份识别」）
├── scripts/           # 分发/安装脚本 + 脱敏自检
│   ├── install-skills.ps1   # Windows 安装脚本（PowerShell）
│   ├── install-skills.sh    # macOS / Linux / WSL 安装脚本（bash）
│   ├── pack-skill.ps1       # Windows 打包脚本（IM 分发 zip）
│   ├── pack-skill.sh        # macOS / Linux 打包脚本（bash）
│   ├── check-sanitize.ps1   # 发布前脱敏自检（Windows）
│   └── check-sanitize.sh    # 发布前脱敏自检（macOS / Linux / WSL）
└── skills/            # 技能存放目录（按用途分类组织，分类规则见 AGENTS.md）
    └── dev/           # 工程开发类（目标：开发电脑）
        └── <skill-name>/
            ├── SKILL.md        # 技能说明与指令（核心文件）
            └── references/     # 技能参考资源（可选，按需加载）
```

## 身份识别（REPO_ID）

本仓库根目录有一个 `REPO_ID` 文件，保存唯一命名空间标识（`io.github.flcker.agents-skills`）。每个技能的身份由 `REPO_ID + "." + 技能名` 构成。

`REPO_ID` 用于解决「不同仓库存在同名技能」时的歧义：安装脚本据此判断 Agent 挂载点下「同名技能链接」是否真正来自本仓库——识别「错挂到别的仓库」并自动修正，同时保护「指向外部（无 REPO_ID）的技能」不被误删或覆盖。

## 已有技能

### dev/ —— 工程开发

- [`figma-console-mcp`](skills/dev/figma-console-mcp/) — 把 Figma 设计系统变成 Agent 可调用的 API（southleft `figma-console-mcp`）：四种连接方式能力差异（Remote SSE 只读 / Cloud Mode 105 工具 / NPX / Local Git 130 工具）、双向 token 同步、组件与变量创建、14 项 WCAG 无障碍检查、design-code parity、设计系统健康审计；接入需 Figma Desktop + Desktop Bridge 插件 + 访问令牌，先只读后写权限。
- [`figma-ui-web`](skills/dev/figma-ui-web/) — 用 Figma 设计稿开发 Web 前端 UI 的规范：双通道阅读（`get_figma_data` 精确数据 + `download_figma_images` 视觉截图并行，禁止单通道写码）、用确切值不做视觉估算、结构分析（重复模式→组件/绝对定位→flex·grid/语义角色→框架组件）、资源下载不手绘、实现后用 Playwright 截图对比设计稿自查 + 人工挑刺迭代的验证闭环，适配 Framelink `figma-developer-mcp`。
- [`figma-ui-desktop`](skills/dev/figma-ui-desktop/) — 用 Figma 设计稿开发桌面端 UI（Qt Widget / QML / WinUI / Flutter）的规范：框架无关的「数据→目标框架翻译」方法论，双通道阅读 + 用确切值 + 结构分析 + 「画布概念→目标框架」映射表（布局/颜色/间距/圆角/阴影/图标/状态 13 类，覆盖 Qt Widget/QML/WinUI/Flutter 四框架）+ 实际运行截图对比设计稿的验证闭环，适配 Framelink `figma-developer-mcp`。
- [`mslearn`](skills/dev/mslearn/) — 微软官方技术文档查询：curl 直调 Microsoft Learn 公共 MCP 端点，语义搜索官方文档、搜官方代码示例（支持 cpp 等语言过滤）、抓取整篇文档转 markdown，免认证零依赖，sh/ps1 双脚本跨 Windows/macOS/Linux，替代挂 MCP server 省 1.5~2K 常驻 token。

## 快速开始

1. 克隆本仓库：

   ```bash
   git clone git@github.com:flcker/agents-skills.git
   ```

2. 浏览或添加技能：

   - 查看已有技能：`skills/<分类>/` 目录下每个子目录即一个技能（分类见 `AGENTS.md`）。
   - 新增技能：在对应分类目录下新建 `skills/<分类>/<skill-name>/` 并编写 `SKILL.md`（规范见 `AGENTS.md`）。

## 安装到各 Agent（分发机制）

每个技能是自包含的 `skills/<分类>/<skill-name>/` 目录（`SKILL.md` + 可选 `references/`），与具体 Agent 无关。各 Agent（dsh、Claude Code、Codex、OpenCode 等）通过各自约定的 skill 根目录发现技能。

推荐用**目录链接/符号链接**把本仓库的技能挂载到各 Agent 根目录，实现"一处维护、多处生效、`git pull` 即同步"，而非复制。

### 安装脚本

| 脚本 | 平台 | 链接类型 | 选择安装参数 | 兼容别名 |
| --- | --- | --- | --- | --- |
| `scripts/install-skills.ps1` | Windows | Junction（免管理员） | `-Profile <分类>` | `-Sync` |
| `scripts/install-skills.sh` | macOS / Linux / WSL | symlink | `--profile <分类>` | `--sync` |

**用法（在仓库根目录执行）：**

```powershell
# Windows：默认全量挂载（挂载新增 + 修正错挂 + 清理悬空链接，幂等）
powershell -ExecutionPolicy Bypass -File .\scripts\install-skills.ps1
```

```bash
# macOS / Linux / WSL：默认全量挂载（挂载新增 + 修正错挂 + 清理悬空链接，幂等）
bash scripts/install-skills.sh
```

脚本只清理**链接（junction/symlink）**，且仅清理「目标归属本仓库（REPO_ID 一致）且目标已不存在」的悬空链接；**绝不删除**指向其他仓库/外部目录（无 REPO_ID）的技能链接，也**不覆盖**非链接的真实目录/文件。

### IM 分发（打包）

远程 agent 无法通过 git 同步、IM 又只能传压缩包时，用打包脚本把 skill 打成 zip 发送：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\pack-skill.ps1 figma-ui-web   # 单个；all 打包全部；-Profile <分类> 批量
```

单技能产出 `dist/<skill名>-<updated日期>.zip`（日期取自 SKILL.md frontmatter，**文件名即版本号**）。自动排除 `.env`、`__pycache__`、`*.pyc`、`.DS_Store`。

## 发布前脱敏

提交到公开远程前，先跑脱敏自检（扫 skills/ 与 scripts/ 的密钥与内网标识）：

```bash
bash scripts/check-sanitize.sh
```

内网域名后缀（如 `corp.example`）维护在本地 `internal-domains.txt`（已被 .gitignore 忽略，不入库）。CI（`.github/workflows/check.yml`）会在每次 push 时自动跑脱敏 + 结构校验。

## 贡献指南

- 每个技能应独立成目录，命名清晰（小写、短横线分隔）。
- `SKILL.md` 需说明技能的用途、适用场景和具体执行步骤，frontmatter 必含 `updated: YYYY-MM-DD`。
- 提交前保持仓库整洁，遵循 `AGENTS.md` 约定，先跑脱敏自检。

## License

[MIT](LICENSE)
