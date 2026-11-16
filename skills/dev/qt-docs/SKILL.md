---
name: qt-docs
updated: 2026-11-16
description: 查询 Qt 官方文档（doc.qt.io）时使用。支持 Qt 6.8 / 6.12 / 5.15 等版本切换，枚举 C++ 类 / QML 类型 / 模块清单，抓取类、QML 类型、模块页的签名与说明转 markdown。触发场景：问「某个 Qt 类/接口/QML 类型怎么用、有哪些成员、属于哪个模块、头文件/CMake 引入」或贴出 doc.qt.io 链接。涉及 Qt API 细节时优先用本 skill 查证官方文档，不要凭记忆回答。
---

# Qt 官方文档查询

封装了 doc.qt.io（Qt 官方在线文档）的结构化浏览与精确抓取。本质是**目录页枚举 + 直接抓取文档页并转 markdown**，不是全文搜索——Qt 官方不提供公开的搜索索引 JSON（官方前端搜索走 Vertex AI 云函数，未公开、不可依赖），因此本 skill 用官方目录页（`classes.html`、`qmltypes.html`、`modules-cpp.html`、`modules-qml.html`）拿清单，再按清单里的 href 直接抓取文档页。零第三方依赖（bash 版只要 curl，PowerShell 版用 Invoke-WebRequest），免认证、不挂 MCP server。

## 版本映射

脚本与本文档写死同一规则，`--version V` / `-v V` 或环境变量 `QTDOCS_VERSION` 覆盖，默认 `6.8`：

| 版本参数 | 基准 URL |
|---|---|
| `6.8` | `https://doc.qt.io/qt-6.8/` |
| `6.12` | `https://doc.qt.io/qt-6.12/` |
| `5.15` | `https://doc.qt.io/archives/qt-5.15/` |
| 任意 `X.Y`，主版本 ≥6 | `https://doc.qt.io/qt-X.Y/` |
| 任意 `X.Y`，主版本 ≤5 | `https://doc.qt.io/archives/qt-X.Y/` |

主版本 ≥6 直接走 `/qt-X.Y/`（6.7~6.12 均有效）；≤5 走 `/archives/qt-X.Y/`（`/qt-5.15/` 会 301 跳 archives，脚本跟随但默认直接拼 archives 更稳）。

## 用法

双脚本功能完全一致，按平台任选。`SKILL_DIR` 取本 skill 挂载后的实际路径：

**bash 版**（macOS / Linux / WSL / Windows Git Bash）：

```bash
SKILL_DIR=~/.claude/skills/qt-docs

bash "$SKILL_DIR/scripts/qtdocs.sh" classes                       # 枚举 C++ 类清单
bash "$SKILL_DIR/scripts/qtdocs.sh" qmltypes                      # 枚举 QML 类型清单
bash "$SKILL_DIR/scripts/qtdocs.sh" modules                       # 枚举 C++ 模块清单
bash "$SKILL_DIR/scripts/qtdocs.sh" qmlmodules                    # 枚举 QML 模块清单
bash "$SKILL_DIR/scripts/qtdocs.sh" module core                   # 某 C++ 模块下的类
bash "$SKILL_DIR/scripts/qtdocs.sh" qmlmodule quick               # 某 QML 模块下的类型
bash "$SKILL_DIR/scripts/qtdocs.sh" class QString                 # 类整页说明
bash "$SKILL_DIR/scripts/qtdocs.sh" class QString simplified      # 类成员签名与说明
bash "$SKILL_DIR/scripts/qtdocs.sh" type Rectangle color          # QML 类型成员（属性/方法/信号）
bash "$SKILL_DIR/scripts/qtdocs.sh" fetch qstring.html            # 抓任意页转 markdown
bash "$SKILL_DIR/scripts/qtdocs.sh" --version 5.15 class QString  # 切版本
```

**PowerShell 版**（Windows，PS 5.1 / 7+，不依赖 Git Bash / curl）：

```powershell
$SkillDir = "$env:USERPROFILE\.claude\skills\qt-docs"

& "$SkillDir\scripts\qtdocs.ps1" classes
& "$SkillDir\scripts\qtdocs.ps1" class QString
& "$SkillDir\scripts\qtdocs.ps1" class QString simplified
& "$SkillDir\scripts\qtdocs.ps1" -Version 5.15 class QString
```

## 9 个子命令

| 子命令 | 参数 | 抓取页 | 输出 JSON |
|--------|------|--------|-----------|
| `classes` | 无 | `classes.html` | `{"version","count","items":[{"name","href"}]}` |
| `qmltypes` | 无 | `qmltypes.html` | 同上 |
| `modules` | 无 | `modules-cpp.html` | `{"version","count","items":[{"name","href","description"}]}` |
| `qmlmodules` | 无 | `modules-qml.html` | 同上 |
| `module` | `<name>` | 模块页 | `{"module","href","count","classes":[{"name","href"}]}` |
| `qmlmodule` | `<name>` | 模块页 | `{"module","href","count","types":[{"name","href"}]}` |
| `class` | `<name> [member]` | 类页 | 无 member：`{"class","title","url","markdown"}`；有 member：`{"class","member","signature","markdown","url"}` |
| `type` | `<name> [member]` | QML 类型页 | 同 `class`，字段名 `type` |
| `fetch` | `<path-or-url>` | 任意页 | `{"url","title","markdown"}` |

## 工作流

1. 先 `classes` / `qmltypes` / `modules` / `qmlmodules` 拿清单（返回 JSON，用 name 定位）。
2. 需要某模块全貌时 `module` / `qmlmodule`；需要某类 / QML 类型的细节时 `class` / `type`（可选带成员名精确到某个成员）。
3. 需要整页（含「Detailed Description」等长说明）时 `fetch`。
4. 回答时给关键事实（签名、头文件、CMake/qmake 引入、版本要求）并附文档链接。用户中文提问就用中文答，但查询词保持英文 / 类名原样。

## 输出格式与退出码

输出是单个 JSON 对象（含 `markdown` 字符串字段，已做 JSON 转义）。退出码：`0` 成功；`1` 参数/用法错误；`2` 无匹配或歧义；`3` 网络/HTTP 错误。

注意：

- 类名区分大小写：`class qstring` 不会命中 `QString`（清单按锚文本精确匹配，见下）。类页成员精确匹配 `<h3 class="fn" id="MEMBER">`。
- QML 类型按裸名精确匹配。带命名空间后缀的条目（如 `Abstract3DSeries: QtDataVis3D`）锚文本不等于裸名，`type` 会 0 命中 exit 2——这是预期行为（避免歧义），不模糊匹配。
- `module` / `qmlmodule` 的名称解析是确定性的（见脚本，名称先归一化尝试 href 模式、再退到锚文本精确匹配），`core` / `quick` / `qtquick3d` 均唯一命中不歧义。

## 资源文件

- `scripts/qtdocs.sh` — bash 版查询脚本（macOS / Linux / WSL / Git Bash，仅依赖 curl）
- `scripts/qtdocs.ps1` — PowerShell 版查询脚本（Windows，PS 5.1 / 7+，仅依赖 Invoke-WebRequest）
