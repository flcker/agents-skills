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
├── external-skills.yaml   # 外部 git 技能清单（事实源，见下文「外部技能」）
├── mcp-servers.yaml       # MCP 登记清单（事实源，见下文「MCP 登记」）
├── tools.yaml             # 工具依赖声明（事实源，见下文「工具依赖」）
├── scripts/           # 分发/安装脚本 + 脱敏自检
│   ├── install-skills.ps1   # Windows 安装脚本（PowerShell）
│   ├── install-skills.sh    # macOS / Linux / WSL 安装脚本（bash）
│   ├── external-skills.ps1  # Windows 外部技能管理（clone/更新/挂载）
│   ├── external-skills.sh   # macOS / Linux / WSL 外部技能管理
│   ├── pack-skill.ps1       # Windows 打包脚本（IM 分发 zip）
│   ├── pack-skill.sh        # macOS / Linux 打包脚本（bash）
│   ├── check-sanitize.ps1   # 发布前脱敏自检（Windows）
│   ├── check-sanitize.sh    # 发布前脱敏自检（macOS / Linux / WSL）
│   ├── mcp-servers.ps1      # MCP 清单管理/校验（Windows）
│   └── mcp-servers.sh       # MCP 清单管理/校验（macOS / Linux / WSL）
└── skills/            # 技能存放目录（按用途分类组织，分类规则见 AGENTS.md）
    ├── dev/           # 工程开发类（目标：开发电脑）
    │   └── <skill-name>/
    │       ├── SKILL.md        # 技能说明与指令（核心文件）
    │       └── references/     # 技能参考资源（可选，按需加载）
    ├── ops/           # 运维操作类（目标：开发电脑）
    │   └── <skill-name>/
    │       ├── SKILL.md
    │       └── references/     # 技能参考资源（可选，按需加载）
    └── tool/          # 业务无关的操作工具类（目标：开发电脑）
        └── <skill-name>/
            ├── SKILL.md
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
- [`qt-docs`](skills/dev/qt-docs/) — Qt 官方文档查询：curl/Invoke-WebRequest 直抓 doc.qt.io，支持 Qt 6.8/6.12/5.15 版本切换，枚举 C++ 类 / QML 类型 / 模块清单（classes/qmltypes/modules-cpp/modules-qml），抓取类与 QML 类型的签名、成员、属性说明转 markdown，sh/ps1 双脚本零依赖跨平台，免认证免 MCP server。

### ops/ —— 运维操作

- [`external-skill-manager`](skills/ops/external-skill-manager/) — 外部技能管理编排：用户给外部 skill 的 git 仓库 URL、GitHub/GitLab 仓库页或介绍网页，把输入识别为 source-ref、决定 ref 与 namespace，调用 `scripts/external-skills.{sh,ps1}` 写入 `external-skills.yaml` 并同步挂载到各 Agent；网页反爬时配合 `cdp-search-fetch` 抓取提取仓库地址。
- [`mcp-server-manager`](skills/ops/mcp-server-manager/) — MCP 登记管理编排：用户给 MCP 名称、官方文档 URL、npx 启动命令或介绍网页，识别为 name + docs + pattern（guide/usage/direct）+ 可选 command/env，调用 `scripts/mcp-servers.{sh,ps1}` 写入 `mcp-servers.yaml` 并校验；只登记不接入，凭证只记环境变量名。

### tool/ —— 业务无关的操作工具类

- [`nvidia-driver-check`](skills/tool/nvidia-driver-check/) — 查询 NVIDIA GeForce 驱动版本问题、选取版本、获取 release notes 下载地址：抓取官方 release notes PDF（内置 `Referer: https://www.nvidia.com/` 绕过 `Zen/4.3` 反爬，否则 403）并自提取 "3.2 Open Issues" 小节条目（纯 Node 内置 `node:zlib` 解压 + 文本矩阵坐标聚类，无 pdftotext、零 npm 依赖），内置版本选取决策框架（证据分级 + 伤硬件/同路径崩溃/良性 open issue 三判定维度），**明确警告官方 open issue 写 N/A 不可信**（实测 621.14 官方写 N/A 但真实写盘+崩溃）；`references/version-notes.md` 沉淀已核对结论（617.42/610.88 各仅 6007998 一条、621.14 官方列表不可信）；只写 mjs 单版，理由见 SKILL.md。

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

### 外部技能（external skills）

除本仓库 `skills/` 下的内建技能外，还能声明式管理**来自外部 git 仓库**的技能。

- **事实源**：`external-skills.yaml`，YAML 受限子集，`sources:` 下每行一条 `namespace: source-ref`，支持 `#` 注释。
- **host 别名**：清单可含 `host-aliases:` 段（可省，顺序自由），格式 `host: 别名`，覆盖内置默认 `github.com`→`gh`、`gitlab.com`→`glab`；仅 auto 推导 namespace 时使用。
- **source-ref 语法**（ref 缺省 `HEAD`，即跟随远程默认分支）：
  - `github:owner/repo@v1.2.0` → `https://github.com/owner/repo.git` + ref `v1.2.0`
  - `gitlab:owner/repo@abc1234` → `https://gitlab.com/owner/repo.git` + ref `abc1234`
  - `https://host/owner/repo.git@v1.2.0` → 原 URL + ref 取最后一个 `@` 之后
- **namespace**：每源一个挂载前缀，外部技能以 `<namespace>.<技能名>` 挂载，与本仓库内建技能（`<技能名>`）物理隔离、互不覆盖。写 `auto` 表示自动推导（优先读源仓库 `REPO_ID`；无则按 `host别名.owner.repo` 推导，host 查 `host-aliases` 段 → 内置默认 → 未知 host 回退 URL slug）。单 skill 仓库（SKILL.md 在仓库根）挂载名 = namespace 本身（无点）。
- **ref 纪律**：生产/CI 用 tag 或 commit SHA；branch 仅开发期使用。

管理命令（`bash scripts/external-skills.sh`，Windows 用 `external-skills.ps1` 同名子命令）：

```bash
bash scripts/external-skills.sh apply                                # 同步 + 冲突预检 + 挂载（缺省）
bash scripts/external-skills.sh add github:alice/skills@v1.2.0 --namespace foo
bash scripts/external-skills.sh remove foo [--prune]                 # --prune 连缓存一起删
bash scripts/external-skills.sh update [<namespace>|--all]
bash scripts/external-skills.sh list
```

行为要点：

- **同步**：克隆/更新到用户级缓存 `~/.agents/external-skills/<url-slug>/`（Windows：`%USERPROFILE%\.agents\external-skills\`），与仓库解耦、可重建。
- **发现**：宽松扫描源内任意含 `SKILL.md` 的目录（不强求 `skills/<分类>/` 两级布局）。
- **冲突**：同 namespace 下同名技能视为冲突，`apply` **fail-fast**——打印冲突清单与「改 namespace」指引，本轮不挂载任何外部技能，绝不做半成品挂载或静默覆盖。
- **接入**：`install-skills.{sh,ps1}` 会在清单非空时自动委托 `apply`（内建技能挂载完成后执行）。
- **安全**：外部仓库不经本仓库 `check-sanitize` 校验，`apply` 也不做脱敏检查，内容安全由使用方自担。

### 与通用 Skills CLI（npx skills）的边界

本仓库只通过 `external-skills.yaml` 管理外部技能，这是「声明式清单、随仓库分发、团队共享」的机制。`npx skills`（skills.sh 生态）是个人本机包管理器：装到本机 skill 根目录，不进本仓库清单，也不随仓库分发。要团队共享、进仓库 → external-skills；只要自己本机用 → `npx skills`。两者不互通，不要混用。

### 三层模型：skill / mcp / tools

仓库管理三类资源，各归其位、互不合并：

| 层 | 文件 | 管什么 |
|---|---|---|
| skill | `skills/**/SKILL.md` | 指令文本（教 agent 怎么做） |
| MCP | `mcp-servers.yaml` | 常驻进程的注册元数据 |
| tool | `tools.yaml` | CLI/运行时依赖声明 |

依赖只记单向：skill → MCP（写在 skill 的 description 里），MCP → tool（`mcp-servers.yaml` 的 `requires` 字段）。

### MCP 登记

MCP 是常驻进程（server），与 skill（静态文件）不同，**不通过 external-skills 分发**；仓库只登记 MCP 的元数据与文档地址，接入与使用规范仍以对应 skill 文档承载（三分法：guide 接入指南型 / usage 使用规范型 / direct 脚本直调型）。

- **事实源**：`mcp-servers.yaml`，`servers:` 下每个 MCP 一个缩进块，字段：
  - `docs`（必填）——文档地址（仓库内 `skills/...` 相对路径，或外部 http(s) URL）
  - `pattern`（必填）——`guide` / `usage` / `direct`
  - `command`（guide/usage 必填）——启动命令，不含凭证
  - `requires`（可选）——该 MCP 运行需要的工具名列表，指向 `tools.yaml`
  - `env`（可选）——所需凭证环境变量名，只记名字，值永不入库
- **安全底线**：MCP server 本体、凭证、内网端点、客户端配置一律不入仓库。

管理命令（`scripts/mcp-servers.{sh,ps1}`，`check` 为缺省子命令）：

```bash
bash scripts/mcp-servers.sh check                                # 校验清单（格式/字段/文档可达/无凭证）
bash scripts/mcp-servers.sh add <name> --docs <d> --pattern <p> [--command <c>] [--env <e>]
bash scripts/mcp-servers.sh remove <name>                        # 移除一个 MCP
bash scripts/mcp-servers.sh list                                 # 列出清单
```

Windows 等价：`powershell -ExecutionPolicy Bypass -File .\scripts\mcp-servers.ps1 <check|add|remove|list>`（`add` 参数用单横线：`-Docs` / `-Pattern` / `-Cmd` / `-Env`）。

新增流程：agent 收到文本输入（MCP 名称 / 官方文档 URL / npx 命令）→ 按 `mcp-server-manager` skill 识别字段与 pattern → 调 `add` 写清单 → `check` 校验。拿不准 pattern 时**问用户**，不臆测。

### 工具依赖

技能集需要的运行时/CLI 工具（node、bun、uv、ghidra 等）声明在 `tools.yaml`（事实源）。组织方式借鉴 mise 的 `[tools]` 段：顶层 `tools:` 下每个工具一个缩进块。

- **字段**：
  - `version`（可选）——版本约束，如 `>=22`、`6.5.0`；省略 = 无约束
  - `optional`（bool）——`true` 用到才装 / `false` 整套技能集的基础前提
  - `purpose`（可选）——用途说明
- **只放工具/运行时**：MCP server 不在此清单（进 `mcp-servers.yaml`）。
- **只声明版本，不写 manager**：获取方式由设备自决（nvm/fnm/npm/bun/uv…各自已有）。
- **只声明不自动装**：需 license 手装的工具（Ghidra/IDA/JADX）标 `optional: true`，不自动装。
- 凭证与引擎二进制不入仓库，脱敏由 `check-sanitize` 覆盖。

### 新设备引导（bootstrap）

新设备/新环境用一条命令把技能集投影到本机（挂载内建+外部技能、校验 MCP 清单），再集中提示需手动完成的部分：

```bash
bash scripts/bootstrap.sh          # macOS / Linux / WSL / Git Bash
powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap.ps1   # Windows
```

幂等，可重复执行。**只编排 + 提示，不自动装工具、不自动注册 MCP、不存凭证**——装工具看 `tools.yaml`、填凭证看 `mcp-servers.yaml` 的 `env`、注册 MCP 按对应 skill 文档。

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
