# AGENTS.md

本文件指导 AI 编码 Agent 在本仓库中的行为方式、约定与工作流程。所有在此仓库内执行代码修改、新增技能、审查或维护任务的 Agent 均应遵循本文件。

## 仓库定位

`agents-skills` 是一个用于**集中管理、维护和分发可复用 Agent 技能（skills）**的公开仓库。每个技能是一组任务特定的指令，Agent 可按需加载并执行。

- 主要语言：中文（文档、说明均使用简体中文）。
- 仓库类型：内容/文档型仓库，以 Markdown 为主，不含构建流程。
- **公开仓库**：只放通用、可公开的技能；任何含内网域名/API/凭证/公司业务标识的内容都不得入库（发布前跑 `scripts/check-sanitize.sh` 自检）。

## 目录结构

```
agents-skills/
├── AGENTS.md          # 本文件：指导 Agent 行为
├── README.md          # 仓库总览说明
├── REPO_ID            # 仓库唯一命名空间标识（脚本识别用，禁止删除/改名）
├── LICENSE            # MIT
├── .gitignore         # Git 忽略规则
├── external-skills.yaml   # 外部 git 技能清单（事实源，见「外部技能」）
├── scripts/           # 安装/打包/脱敏脚本目录
│   ├── install-skills.ps1   # Windows 安装脚本（PowerShell）
│   ├── install-skills.sh    # macOS/Linux/WSL 安装脚本（Bash）
│   ├── external-skills.ps1  # Windows 外部技能管理（clone/更新/挂载）
│   ├── external-skills.sh   # macOS/Linux/WSL 外部技能管理
│   ├── pack-skill.ps1       # Windows 打包脚本（IM 分发 zip）
│   ├── pack-skill.sh        # macOS/Linux 打包脚本（bash）
│   ├── check-sanitize.ps1   # Windows 脱敏自检
│   └── check-sanitize.sh    # macOS/Linux 脱敏自检
└── skills/            # 技能存放目录（按用途分类组织，见「分类目录」）
    └── dev/           # 工程开发类（目标环境：开发电脑）
        └── <skill-name>/
            ├── SKILL.md   # 技能说明与指令（核心文件）
            └── ...        # 技能相关资源
```

## 工作约定

### 分类目录

skills/ 按用途分二级目录，叶子目录名 = 技能名：

- `dev/` —— 工程开发类，目标环境：开发电脑
- `ops/` —— 运维操作类，目标环境：开发电脑。存放「管理/维护技能集自身」的操作性技能（如导入、同步、卸载外部 skill），与 `dev/`（写代码、查文档等工程开发）区分

放置规则：

- 新增技能按**主要使用场景**归类；拿不准放 `dev/` 并在 MR 里说明
- 分类目录即分发单元：`pack-skill.sh --profile <分类>` 批量打包该分类全部技能到 `dist/<分类>/`
- 新增分类需说明：目标环境、与其他分类的边界、install/pack 脚本的适配（脚本动态枚举分类目录，新增分类通常零改动）

### 命名规范
- 技能目录名：小写、短横线分隔（kebab-case），清晰描述用途，例如 `figma-console-mcp`、`qt5-to-qt6`。
- 每个技能独立成目录，且必须位于分类目录下（`skills/<分类>/<skill-name>/`）；禁止在 `skills/` 根或分类目录下直接堆放文件（README.md 指针文件除外）。

### 技能文件要求
- 每个技能必须包含 `SKILL.md`，说明该技能的：
  - 用途与适用场景；
  - 具体执行步骤；
  - 所需的资源文件或依赖。
- 技能所需的脚本、模板、示例等资源放在技能自己的目录内，不散落在仓库根目录。
- `SKILL.md` 的 frontmatter 必须包含 `updated: YYYY-MM-DD` 字段（该技能最近一次实质变更日期）。内容有实质修改时必须同步更新该日期——这是 skill 通过 IM 等渠道分发给远程 agent 后，接收方判断新旧版本的唯一依据。
- Node ESM 脚本（`.mjs`）若需「直接运行进 CLI、被 import 只导出模块」的双模式，入口判断必须两侧 `realpathSync` 归一化：`realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))`。禁止直接比较 `import.meta.url === pathToFileURL(process.argv[1]).href`——技能经 junction 挂载运行时，`import.meta.url` 已被 node 解析为真实路径而 `argv[1]` 是链接路径，直接比较恒不等，CLI 模式会静默不执行。

### 文档语言
- 本仓库所有说明性文档使用**简体中文**。

## 常见任务指引

### 新增一个技能
1. 按用途选分类，在该分类下新建目录 `skills/<分类>/<skill-name>/`。
2. 编写 `SKILL.md`，覆盖用途、适用场景与执行步骤（见上文要求）。
3. 如有资源文件，一并放入该目录。
4. 在根 `README.md` 中登记该技能，格式与既有条目一致。

### 修改现有技能
- 先阅读该技能的 `SKILL.md` 及相关文件，理解现有约定后再修改。
- 保持文档风格与结构一致，不破坏既有技能结构。

### 外部技能（external skills）

除 `skills/` 下的内建技能外，仓库支持声明式管理**来自外部 git 仓库**的技能。事实源是 `external-skills.yaml`（清单），管理入口是 `scripts/external-skills.{sh,ps1}`。

- **清单格式**：YAML 受限子集，`sources:` 下每行 `namespace: source-ref`；`#` 注释、空行忽略。
- **source-ref**：`github:owner/repo@v1.2.0`、`gitlab:owner/repo@abc1234`、`https://host/owner/repo.git@v1.2.0`；ref 缺省 `HEAD`（跟随远程默认分支）。
- **namespace**：每源一个挂载前缀，外部技能以 `<namespace>.<技能名>` 挂载，与内建技能隔离；写 `auto` 自动推导（优先源 `REPO_ID`，否则 URL slug）。
- **冲突**：同 namespace 下同名技能 → `apply` fail-fast（整轮不挂载、打印改 namespace 指引），禁止静默覆盖或半成品挂载。
- **ref 纪律**：生产/CI 用 tag 或 commit SHA；branch 仅开发期。
- **安全**：外部仓库不经 `check-sanitize` 校验，内容安全由使用方自担；清单内不得放凭据（凭据走 git credential helper）。

修改外部技能机制（脚本或清单语义）时，须同步更新 `README.md` 的「外部技能」章节与本节。

### 维护与审查
- 保持仓库整洁，不提交临时文件（遵循 `.gitignore`）。
- **公开仓库安全底线**：提交前跑 `bash scripts/check-sanitize.sh` 确认无密钥/内网标识；内网域名后缀维护在本地 `internal-domains.txt`（不入库）。
- 修改前确认不影响其他技能与根目录说明的一致性。

### 安装脚本的编码与验证约定
`scripts/` 下的两个安装脚本含中文注释与输出，修改后必须遵守以下约定，避免「语法校验通过但实际运行失败」：

- **`install-skills.ps1`**：必须保存为 **UTF-8 带 BOM**。Windows PowerShell 5.1 读取无 BOM 的 `.ps1` 时按 GBK 解析，会导致中文乱码、语法破裂。
  - 验证方式：用 `powershell -ExecutionPolicy Bypass -File .\scripts\install-skills.ps1` **实际运行**，而非仅用 `Parser::ParseFile` 做静态语法检查（后者会用正确编码解码，掩盖真实执行环境的问题）。
- **`install-skills.sh`**：必须保存为 **UTF-8 无 BOM**（shebang `#!` 必须是文件首字节，加 BOM 会破坏 shebang）。
  - 验证方式：用 `bash -n scripts/install-skills.sh` 做语法检查，并对核心函数（如 `get_repo_id_of`）做单元级实测。
- 涉及身份识别（`REPO_ID`）或链接清理逻辑的改动，须同时验证三种场景：错挂修正、外部（无 REPO_ID）保护、本仓库悬空清理。

## 约束与禁止事项

- 不要在 `skills/` 根目录下创建散落的非目录文件；技能目录不得直接位于 `skills/` 根（必须在分类目录下）。
- 不要用大写或含空格/特殊字符的目录名创建技能。
- 不要删除或改写其他技能目录的独立性与可移植性。
- **不要把含内网域名/内部 API/凭证/公司业务标识的内容提交进本公开仓库。**

## 完成标准

- 涉及文档修改时，内容完整、结构清晰、使用简体中文。
- 涉及技能新增时，技能目录结构与 `SKILL.md` 完整，符合本文件规范。
- 发布前脱敏自检通过（`bash scripts/check-sanitize.sh` 返回 clean）。
