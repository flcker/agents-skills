---
name: nvidia-driver-check
updated: 2026-11-20
description: 查询 NVIDIA 驱动（GeForce / RTX Enterprise-Quadro 两分支）版本问题、选取驱动版本、获取 release notes 下载地址。抓取 NVIDIA 官方 release notes PDF（内置 Referer 绕过反爬）并自提取 "Open Issues" 小节条目，用于判断某版本是否有伤硬件 bug、是否有同路径崩溃报告。零依赖（Node 22+ 内置 fetch + node:zlib），无 pdftotext、无 npm 依赖。触发场景：用户提到"NVIDIA 驱动""GeForce 驱动版本""RTX/Quadro 驱动""驱动更新要不要装""驱动下载地址""open issue""写盘 bug""nvoglv64 崩溃"等。
---

# NVIDIA 驱动版本检查

查询 GeForce 驱动某个版本的官方 Open Issues、协助选取驱动版本、获取 release notes 下载地址。

**本 skill 只做三件事：抓取官方 release notes PDF → 提取 Open Issues → 输出。不做论坛/媒体反爬源抓取**（那是宿主 Agent 内置 `web_search` 的兜底，见「边界」）。

## 用法

脚本在 skill 目录下的 `scripts/fetch-release-notes.mjs`，用绝对路径调用：

```bash
node <skill>/scripts/fetch-release-notes.mjs 617.42
node <skill>/scripts/fetch-release-notes.mjs 617.42 --json
```

- 默认 stdout 打印：版本号、分支、发布日期、驱动 exe 直链、Open Issues 列表（每行一条，含 `[bug id]`）。
- `--json` 输出结构化 `{version, pdfUrl, releaseDate, branch, driverUrl, openIssues: [...]}`。
- 退出码：`0` 成功 / `1` 参数错误 / `2` 抓取或 PDF 无效 / `3` 网络失败。

## URL 规律与探测

- 基址：`https://us.download.nvidia.com/Windows/`
- 文件名后缀不固定，按顺序探测（实测结论）：
  1. GeForce Studio/NSD 版：`<版本>/<版本>-win10-win11-nsd-release-notes.pdf`
  2. GeForce Game Ready 版：`<版本>/<版本>-win11-win10-release-notes.pdf`
  3. RTX Enterprise/Quadro 版（专业卡）：`Quadro_Certified/<版本>/<版本>-win10-win11-nvidia-rtx-quadro-release-notes.pdf`
- 命中判定：HTTP 200 + `Content-Type: application/pdf` + 首 5 字节 `%PDF-`，才算命中，否则换下一个候选。

> ⚠️ **两条分支**：GeForce 家用卡走前两条；RTX A 系列 / RTX PRO / Quadro 等**专业卡走第 3 条 Quadro 分支**，release notes 在 `Quadro_Certified/` 子目录。脚本按顺序探测，命中哪条就标注哪个分支（输出里 `分支: GeForce` 或 `分支: RTX Enterprise/Quadro`）。

**Open Issues 标题差异**（脚本已适配）：

| 分支 | Open Issues 小节标题 |
|---|---|
| GeForce | `3.2 Open Issues in Version <v> WHQL` |
| Quadro | `2.2.2 Open Issues in Version <v>` |

**驱动 exe 直链命名**（脚本探测 `driverUrl`，缺失返回 `未找到`/`null` 不阻塞）：

| 分支 | exe 文件名 |
|---|---|
| GeForce | `<v>-desktop-win10-win11-64bit-international-dch-whql.exe`（缺则 `<v>-desktop-win10-win11-64bit-international-nsd-dch-whql.exe`） |
| Quadro | `<v>-quadro-rtx-desktop-notebook-win10-win11-64bit-international-dch-whql.exe` |

## Referer 绕过（已实测）

裸请求（无 Referer）会被 NVIDIA `Zen/4.3` 反爬拦回 403。必须带：

```
Referer: https://www.nvidia.com/
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36
```

Referer 是关键，UA 兜底。脚本已内置，无需额外传参。

## PDF 自提取原理（零依赖，无 pdftotext）

脚本不引第三方 PDF 库，只用 `node:zlib`：

1. 扫描 `stream … endstream` 提取所有流，去首尾 CR/LF 后 `zlib.inflate` 解压（实测 126 个流、121 个可解）。
2. 解析两类文本：`(text) Tj` 单串，`[ (a) -5 (b) ] TJ` 数组（字间距偏移忽略）。
3. 对象流 ObjStm：字体字典被压进 `<</Type/ObjStm/N 6>>`，`x 0 obj` 明文找不到，需识别 ObjStm 解压取出对象。
4. 字符级排版：每字符独立 + `Tm`/`Td` 坐标移动拼出，按文本矩阵坐标聚类成行/段落还原。
5. 字体编码：ToUnicode 出现 0 次，字体为内嵌 TrueType；原始 PDF 是 WinAnsi/CP1252 编码，用 `TextDecoder('windows-1252')` 覆盖 ASCII（open issues 是纯英文）。非 ASCII 场景未处理，遇到乱码是已知限制。
6. 目标小节：定位 Open Issues 正文标题（排除目录页的 `..` 点线行）——GeForce 是 `3.2 Open Issues in Version <v> WHQL`，Quadro 是 `2.2.2 Open Issues in Version <v>`——提取 `>` 缩进条目。

## 版本选取决策框架（不是写死结论）

**证据分级**：官方 release notes PDF > NVIDIA 官方论坛 > 权威媒体 > 社区博客。

**判定维度**（逐条核对）：

| 维度 | 关注点 |
|---|---|
| 伤硬件 bug | 是否有写盘/写 flash 类 bug（严重，直接规避该版本） |
| 同路径崩溃报告 | 是否有 OpenGL/`nvoglv64` 崩溃报告（影响稳定性） |
| 官方 open issue 是否良性 | 功耗调优类（如 "Prefer Maximum Performance"）算良性，可接受 |

**⚠️ 官方 open issue 写 N/A 不可信**：实测 621.14 官方列表写 `N/A`，但真实存在写盘 bug + 崩溃，媒体实锤。官方"无 open issue" ≠ 该版本安全。

**结论必须带日期**，并标注"可能过期"——驱动与问题列表持续更新。

## 边界

- 论坛/媒体反爬源本 skill **不自动抓**（零依赖硬边界）。需要时用宿主 Agent 内置 `web_search` 兜底——那是宿主工具不是 skill，不算违反零依赖。
- 本 skill 只做「官方 release notes 的 open issues」，不做 GPU 型号兼容性查询、不下载驱动本体。

## 为什么只写 mjs 单版（不写 sh/ps1/py）

按本仓库选型表，开发电脑工具默认「sh + ps1 成对」。本 skill 只写 mjs 单版，理由如下（2026-11-20 实测核实）：

1. **解压能力不是分水岭，选型不取决于「有没有 inflate」**：NVIDIA 这批 PDF 的 FlateDecode 流全是 **raw deflate（无 zlib 头）**，实测 126 个流无一 0x78 头。据此：
   - Node `zlib.inflateSync` ✅ 原生支持（含 raw deflate）
   - PowerShell 5.1 的 `DeflateStream` ✅ 也能解 raw deflate（无 `ZLibStream`，但用不上 zlib 头）
   - bash ❌ 无任何 inflate 能力，只能调外部命令，**直接违反零依赖**，故 sh 版排除

2. **真正的成本在解压之后**：ObjStm 对象流解析、`Tm`/`Td` 文本矩阵坐标聚类、逐页合并防 footer 串页、GeForce/Quadro 双分支标题识别、页脚过滤——约 400 行已写透验证的逻辑。用 ps1 重写一遍需额外处理 PS 5.1/7 双版本差异与二进制/正则的笨拙，维护成本高、收益低。

3. **宿主前提**：查驱动是开发机任务，本仓库（含 cdp-search-fetch 等同类）已以 Node 22+ 为前提；开发机没有 Node 的场景几乎不存在。

**结论**：只写 mjs 单版是**维护成本取舍**，不是被技术硬约束逼出来的。若后续出现「只有 PowerShell、无 Node」的真实宿主需求，可补 ps1 版（用 `DeflateStream` 解 raw deflate），届时与 mjs 契约一致（参数/JSON 字段/退出码）。

## 资源文件

- `scripts/fetch-release-notes.mjs` — 核心脚本（单文件、零依赖、可直接 `node … <版本>` 跑）。
- `references/version-notes.md` — 已核对版本结论记录表（可追加，非权威结论）。
