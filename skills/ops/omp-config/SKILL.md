---
name: omp-config
updated: 2026-11-26
description: 配置、排查、修改 omp（Oh My Pi）自身时使用——config.yml 设置键、modelRoles 与自定义 provider、models.yml、MCP/LSP/keybindings、技能发现与安装、工具审批策略、profile 隔离、env 覆盖、文档路由。触发词："omp 配置""omp config""改模型""modelRoles""models.yml""自定义 provider""加 MCP""keybindings""profile""设置不生效""omp 文档""omp 怎么配"。不用于普通编码任务。
---

# omp 配置

做任何修改前先探测现状：omp 的配置分成 6 层，**看到的值不等于 config.yml 里的值**。

## 1. 探测三件套（只读，先跑）

```bash
read cfg://<namespace>                  # 生效值 + source(env/runtime/overlay/project/global/default) + 可选值 + 描述
omp config get <key> --json             # 单键生效值 {key,value,type,description}
omp config list --scope global --json   # 只看 config.yml 真写了的键
```

- `read cfg://`（如 `cfg://tools`、`cfg://theme`）最省事：直接给出 `source:`，一眼看出是默认值还是被哪层压住。
- `omp config list`（无参数，全量 schema）是**键名的唯一权威**。键名写错只会得到 `Unknown setting: xxx` + 提示跑 list，没有模糊匹配、没有简写。

## 2. 文件地图

| 用途 | 路径 | 备注 |
|------|------|------|
| 全局设置 | `~/.omp/agent/config.yml`（旧的 `config.yaml` 原地更新） | `omp config set` / `/settings` 的唯一写入目标 |
| 全局模型与 provider | `~/.omp/agent/models.yml` | 与 config.yml 分工：provider/模型元数据在这里，角色在 config.yml |
| 项目设置 | `<repo>/.omp/config.yml` | **omp 不写这层**，只读；不向上遍历祖先目录 |
| 项目旧格式 | `<repo>/.omp/settings.json` | 仍读，config.yml 覆盖它 |
| MCP | `.omp/mcp.json`（项目）/ `~/.omp/agent/mcp.json`（用户） | 兼容读 `.mcp.json`；改完需重启 |
| LSP | `<cwd>/.omp/lsp.json` / `~/.omp/agent/lsp.json` | 也可 `lsp.yaml`；改完调 lsp 工具 `action:"reload"` |
| Keybindings | `~/.omp/agent/keybindings.yml` | **不在 config.yml 里**，无嵌套 `keybindings` 对象 |
| Profile | `~/.omp/profiles/<name>/agent/` | settings/auth/sessions/caches 整套隔离 |
| 一次性覆盖 | `--config <file>`（可重复）/ `PI_CONFIG_FILES` | 进程级，永不落盘 |

## 3. 优先级（高 → 低）

```
setting env var > runtime override > --config overlay > 项目设置 > 全局设置 > 内置默认
```

- runtime override = `--smol` / `--slow` / `--plan` / `--approval-mode` / `--yolo` / `--advisor` / `--hide-thinking` 等，永不持久化。
- 合并语义：**对象深合并，标量与数组整体替换**。项目里写 `disabledProviders: [groq]` 会把全局的整条数组清掉，要写全量。
- 配置的 `null` 一般视为「未设置」；`modelRoles` 的项目层 null 回落到全局。
- settings 这一能力**不做去重**，逐层深合并；模型角色还有一条额外通道：原生 `.omp/config.yml` 的 `modelRoles` 会被再应用一次作为权威项目层。

## 4. 写入陷阱（全部实测过）

1. **`omp config set` 只写全局层。** project 层必须手工编辑 `<repo>/.omp/config.yml`。`modelRoleStorage: project` 是唯一例外（只写 modelRoles）。
2. **点号键只在「叶子本身是注册 setting」时有效。**
   - ✅ `theme.dark`、`compaction.methodOrder`、`skills.ignoredSkills`、`tools.approvalMode`
   - ❌ `modelRoles.smol`、`tools.approval.bash` → `Unknown setting`

   record 类型必须整条写，且**整条写会覆盖该 record 的其它条目**，写前先 `omp config get <record>` 拿全量再改：
   ```bash
   omp config set modelRoles '{"default":"p/m","smol":"p/f","plan":"p/p"}'
   omp config set tools.approval '{"bash":"prompt","read":"allow"}'
   ```
3. 值按 schema 类型解析：boolean 认 `true/false/yes/no/on/off/1/0`；array/record 必须传 JSON 字符串；string 的多词参数会用空格拼接。
4. 直接编辑 `config.yml` 会被 watch 热加载，但写错只让**该层**停在 last-good（启动期非法文件会被改名 `.broken-*` 然后退出）。能用 `omp config set` 就别手编。
5. `omp config set` 若被更高层压住会提示 `overriddenBy`（env 变量名 / project / overlay / runtime）。env 变量永远赢过 config.yml，`/settings` 面板看不到它。
6. 想删除某个键让默认值回归：`omp config reset <key>`（不是 set 空值）。

## 5. 模型与 provider

**角色在 `config.yml` 的 `modelRoles`，不在 `models.yml`。**

- Chat 角色：`default` `smol` `slow` `vision` `plan` `commit` `tiny` `memory` `task` `advisor` `widget`
- 模型类角色：`image` `web` `speech` `dictation` `judge`
- 选择器 `provider/modelId`；可加思考档 `:minimal|:low|:medium|:high|:xhigh|:max|:auto`；可逗号并列多个候选（取第一个可用，**不是**重试链）；可用 `@smol` 别名（YAML 里要引号：`plan: "@slow"`）。
- 请求失败回退独立配置在 `retry.fallbackChains.<role>`；`[]` = 明确不回退。未设则走该角色的内置优先级表。
- `modelRoleStorage: global|project` 决定 `/model` 里改角色写哪层。
- **回落链**（不是失败重试，是「未配置时解析到谁」）：
  - `tiny` 未设 → `@smol`
  - `memory` 未设 → `@tiny`
  - `widget` 未设 → 同 `tiny` 路径
  - `smol` / `slow` 未设 → 先继承**显式配置的** `default`，再走各自内置优先级表
  - `advisor` 例外：走 `@slow` 且 `configuredOnly`，未显式配 `slow` 时不继承 `default`，改走自身强模型优先级链
- 别把「回落链」和 `retry.fallbackChains` 混为一谈：前者是角色未设时选谁，后者是请求**失败**后换谁。`retry.fallbackChains.<role>: []` 表示明确不回退，未设则用该角色内置优先级表。

**自定义 provider 写在 `models.yml` 的 `providers.<id>`：**

```yaml
providers:
  my-gateway:
    baseUrl: https://api.example.com/v1
    api: openai-completions        # 或 openai-responses / anthropic-messages / google-generative-ai / bedrock-converse-stream …
    apiKey: MY_KEY_ENV             # 建议填环境变量名而非明文
    models:
      - id: some-model
        name: Some Model
        contextWindow: 1000000
        maxTokens: 131072
```

- `api` 完整取值、`modelOverrides`、`compat`、`discovery`、`compactionModel` 等见 `read omp://docs/models.md`。
- 查模型：`omp models --kind chat|tiny|image|tts|stt|search|judge|all`、`omp models find <substr>`、`omp models refresh`。

## 6. MCP / LSP / Keybindings

**MCP**：顶层 `mcpServers` + `disabledServers`；`type: stdio` 配 `command`/`args`。项目条目先于同名用户条目（项目 `enabled:false` 能压掉用户侧同名 server）。首次写入会自动加 `$schema` 头。改完要重启进程。`/mcp add|enable|disable|reauth` 会写当前 profile 的文件。

**LSP**：默认无需配置（rootMarkers + 二进制自动检测，只查 cwd 不递归父目录）。覆盖写在 `.omp/lsp.json`，`servers` 包裹或扁平两种写法二选一，**shallow merge**——`settings`/`initOptions`/`capabilities` 整体替换。改完 `lsp` 工具 `action: "reload"`。

**Keybindings**：`actionId: chord` 或 `actionId: [chord, ...]`；空数组禁用：

```yaml
app.model.cycleForward: Ctrl+P
app.stt.pushToTalk: []
```

`/hotkeys` 看当前生效表；动作 ID 前缀 `app.*` / `tui.editor.*` / `tui.input.*` / `tui.select.*`。

## 7. 技能（skill）发现

Provider 优先级（高 → 低）：`native .omp`(100) > `skillshare`(95) > `omp-plugins`(90) > `claude`(80) > `agent-plugins`(75) > `claude-plugins`/`agents`/`codex`(70) > `opencode`(55) > `github`(30) > `omp-managed`(5)

- 本机实际生效的根目录见 `read cfg://skills` 的 `skills.customDirectories` / provider 开关（如 `skills.enableAgentsUser`）。默认用户级根目录通常是 `~/.agents/skills/<name>/SKILL.md`。
- 新增 skill：建 `<root>/<name>/SKILL.md`，frontmatter 必须有 `name` + `description`，不用注册。
- 若根目录是 junction/symlink 挂载点，真实内容在源仓库——新增/修改 skill 请落源仓库再跑安装脚本，直接在挂载点建实体目录会被判为「用户数据」而跳过。
- 布局非递归：只认 `<root>/<name>/SKILL.md`，嵌套要指 `skills.customDirectories`。
- 过滤：`skills.ignoredSkills` / `skills.includeSkills` / `skills.customDirectories` / `disabledExtensions` 的 `skill:<name>`；一次性的 `--no-skills`、`--skills=glob`。
- `skill://<name>` 读正文；`/skill:<name>` 当命令调（`skills.enableSkillCommands`）。
- `omp skill search|install` 走 registry `skills.omp.sh`；不可达时换 `npx skills add <repo> --skill <name>`（公网 skills.sh 镜像）。

## 8. Profile

```bash
omp --profile work             # 整套隔离到 ~/.omp/profiles/work/agent/
omp --profile work --alias ow # 生成 shell 快捷方式
OMP_PROFILE=work              # 环境变量等价；--profile 命令行更优先
omp --profile work config path # 确认打到了哪个目录
```

keybindings 是唯一例外：默认 profile 的 `keybindings.*` 会合并进来，profile 内的逐条覆盖。
**排查「改了没生效」第一步永远是 `omp config path`** —— 十有八九写进了另一个 profile 或 default。

## 9. 会话运行模式（/plan /goal /vibe）

三个互斥的**会话内运行模式**（同一时间只能开一个，切换前先退出当前模式）。注意与「模型角色」区分：`modelRoles` 里的 `plan` 是**角色名**，`--plan` flag 是选该角色，跟 plan 模式无关。`tools.approvalMode`（yolo/write/…）是**审批档位**，不是这三者之一，可与任意模式叠加。

| 命令 | 模式 | 本质 | 进入 | 退出 |
|------|------|------|------|------|
| `/plan` | Plan 模式 | 只读探索→产出方案文档，不碰工作树 | `/plan` 或 `Alt+Shift+P`（`app.plan.toggle`） | 再按 `Alt+Shift+P` / 审阅 overlay 批准或取消 |
| `/goal` | Goal 模式 | 给目标，模型自拆解→执行→验证循环 | `/goal` 或 `omp --goal "objective"` | `/goal` 再发一次 |
| `/vibe` | Vibe 模式 | 顶层变「导演」只派活，worker 子代理执行 | `/vibe`（可带首个指令 `/vibe <prompt>`） | `/vibe` 再发一次 |

- **Plan**：运行时工作树/系统只读，规划产物写 `local://<slug>-plan.md`；审阅重开用 `/plan-review`。批准后 `mode_change` 记 `none`，恢复写权限。启动 flag：`--plan-yolo`（读规划→自动批方案→转执行，`--plan-yolo-into @smol` 指定执行模型）。配置：`plan.enabled`（默认 true）、`plan.defaultOnStartup`（默认 false；true 则 `/new` 新会话自动进 plan——这是唯一会「自动重进」的模式）。
- **Goal**：隐藏 goal 工具循环推进。配置：`goal.enabled`（默认 true）。无独立文档，只有 settings 的 `goal.*` 组 + `--goal` flag 描述。
- **Vibe**：导演只剩 `read`/可选 `todo`/`vibe_*`（spawn/send/wait/kill/list）；worker 分 `fast`(sonic/@smol) 与 `good`(task/@task) 两档。完整文档见 `omp://docs/vibe-mode.md`。

退出 ≠ 丢状态：plan 方案留在 `local://<slug>-plan.md`，goal/vibe 已完成步骤保留。

## 10. 文档路由

`read omp://docs` 列出全部文档（需自己拼 `omp://docs/<file>.md`，通配不展开）。按主题取：

| 主题 | 文档 |
|------|------|
| 配置发现、source 顺序、provider 优先级、profile 全流程 | `omp://docs/config-usage.md` |
| 设置分层/合并/子命令/完整 catalog/故障排查 | `omp://docs/settings.md` |
| models.yml 全 schema、角色与别名、preset、认证顺序 | `omp://docs/models.md` |
| 内置与自定义 provider、密钥解析 | `omp://docs/providers.md` |
| MCP 文件格式与发现顺序 | `omp://docs/mcp-config.md` |
| LSP 文件格式与字段 | `omp://docs/lsp-config.md` |
| 快捷键动作 ID 全表 | `omp://docs/keybindings.md` |
| 全部 CLI flag 与子命令 | `omp://docs/cli-reference.md` |
| 环境变量全表 | `omp://docs/environment-variables.md` |
| 技能发现/冲突/命名空间 | `omp://docs/skills.md` |
| 上下文文件（AGENTS.md/CLAUDE.md/.omp） | `omp://docs/context-files.md` |
| 审批模式与 bash 规则 | `omp://docs/approval-mode.md` |
| 会话运行模式（plan/goal/vibe） | `omp://docs/vibe-mode.md`（plan 见 `settings.md` `plan.*` 与 `keybindings.md` `app.plan.toggle`；goal 无独立文档） |
| 压缩、记忆、主题、插件市场、扩展、hook | `omp://docs/compaction.md` `memory.md` `theme.md` `marketplace.md` `extensions.md` `hooks.md` |
| 魔法关键字（ultrathink/orchestrate/…） | `omp://docs/magic-keywords.md` |
| 本地模型（Ollama/llama.cpp/LM Studio） | `omp://docs/local-models.md` |

`read cfg://` 是运行时的**活** schema（含 description 与 source）；文档是解释。两者冲突时以 `cfg://` + `omp config list` 为准。

## 本机现状

本机的具体 provider/modelRoles 选型、模型能力与价格实测、基准数据见本机私有目录 `~/.omp/agent/omp-private-config/`（`local-state.md`、`model-roles.md`、`model-roles-bench-results.md`）。这些内容含内网 provider 与本机路径，不进公开仓库。
