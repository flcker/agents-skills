# install-skills.ps1
#
# 把本仓库 skills/ 下的所有技能，以"目录联接（Junction）"方式挂载到本机各 Agent 的
# skill 根目录，实现"一处维护（本仓库）、多处即时生效、git pull 即同步"的机制。
#
# 仅适用于 Windows（PowerShell 5.1+ 或 PowerShell 7+）。
# macOS / Linux / WSL 请使用同目录下的 install-skills.sh。
#
# 用法（在 agent-skills 仓库根目录执行）：
#   # 默认：挂载新增的技能 + 修正"指向别处"的同名错挂链接 + 清理本仓库悬空链接（幂等）
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-skills.ps1
#
#   # 只挂载某一分类目录下的技能（分类 = skills\ 下的子目录，如 dev；
#   # 本轮只挂该分类，不卸载已挂载的其他分类——profile 是安装期选择，非运行态隔离）
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-skills.ps1 -Profile dev
#
#   # -Sync 为兼容别名（清理悬空链接已并入默认行为）
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-skills.ps1 -Sync
#
# 身份识别（解决"同名技能来自不同仓库"的歧义）：
#   - 仓库根目录有一个 REPO_ID 文件，保存本仓库的稳定命名空间标识，
#     如 io.github.flcker.agents-skills。
#   - REPO_ID 值不允许包含任何空白字符（空格/制表符/换行），读取时会被 Trim。
#   - 每个技能的身份 = REPO_ID + "." + 技能名，例如
#     io.github.flcker.agents-skills.qt6-rhi。
#   - 挂载点下"同名技能链接"是否归属本仓库，依据其链接目标的所属仓库 REPO_ID
#     是否等于本仓库 REPO_ID 来判断，而非仅凭技能名。
#
# 说明：
#   - Junction（目录联接）在 Windows 下无需管理员权限，优于 SymbolicLink。
#   - 只挂载到"确实存在"的 Agent skill 根目录，未安装的 Agent 自动跳过。
#   - 挂载阶段（幂等且自愈）：
#       * 目标不存在 → 新建 Junction。
#       * 已存在同名 junction，其目标归属本仓库（REPO_ID 一致）→ 跳过。
#       * 已存在同名 junction，其目标归属"别的仓库"或无法识别 → 视为错挂，
#         删除后重挂到本仓库。
#       * 已存在同名"真实目录"（非链接）→ 尊重用户数据，跳过并警告，绝不覆盖。
#   - 清理阶段（默认执行，-Sync 为兼容别名）：只删除"目标归属本仓库（REPO_ID 一致）且
#     目标已不存在"的悬空链接；指向其他仓库的外部技能链接、仍有效的链接、真实目录/文件
#     一律保留。置于挂载之前：目录结构变更（如分类迁移）后，一次运行即可完成「清旧+挂新」。

[CmdletBinding()]
param(
    [switch]$Sync,
    [string]$Profile = ''
)

$ErrorActionPreference = 'Stop'

# 仓库根目录 = 本脚本所在目录的上一级
$RepoRoot = Split-Path -Parent $PSScriptRoot
$SkillsSrc = Join-Path $RepoRoot 'skills'
$RepoIdFile = Join-Path $RepoRoot 'REPO_ID'

Write-Host "== agent-skills 技能挂载（Windows / Junction）=="
Write-Host "技能源：$SkillsSrc"
if ($Profile) { Write-Host "模式：只挂载分类 $Profile 下的技能（挂载新增 + 修正错挂 + 清理悬空链接）" }
else          { Write-Host "模式：挂载新增 + 修正错挂 + 清理悬空链接（幂等；-Sync 为兼容别名）" }

if (-not (Test-Path $SkillsSrc)) {
    Write-Error "未找到 skills 目录：$SkillsSrc"
    exit 1
}

# 分类校验：-Profile 必须是 skills\ 下真实存在的目录（大小写敏感性取决于文件系统）
if ($PSBoundParameters.ContainsKey('Profile') -and -not $Profile) {
    Write-Error "-Profile 需要一个分类名参数"
    exit 1
}
if ($Profile -and -not (Test-Path -LiteralPath (Join-Path $SkillsSrc $Profile) -PathType Container)) {
    $available = (Get-ChildItem -LiteralPath $SkillsSrc -Directory | ForEach-Object { $_.Name }) -join ' '
    Write-Error "分类不存在：$Profile（可用分类：$available）"
    exit 1
}

# 读取本仓库的稳定身份标识；缺失则报错退出（避免在无身份时做出危险判断）
if (-not (Test-Path -LiteralPath $RepoIdFile)) {
    Write-Error "未找到仓库标识文件：$RepoIdFile。请先在仓库根目录创建 REPO_ID（内容为命名空间标识，如 io.github.flcker.agents-skills）。"
    exit 1
}
$RepoId = (Get-Content -LiteralPath $RepoIdFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($RepoId)) {
    Write-Error "REPO_ID 内容为空：$RepoIdFile"
    exit 1
}
Write-Host "仓库身份：$RepoId"

# 各 Agent 的「用户级」skill 根目录（只挂载到存在的目录）。
# dsh 另会扫描项目级 <project>\.dsh\skills 与 <project>\.agents\skills，无需本脚本处理。
# 如需新增 Agent，在下面追加一行即可。
$agentSkillRoots = @(
    "$env:USERPROFILE\.agents\skills",   # dsh（user-agents，兼容 Claude/skills 生态）
    "$env:USERPROFILE\.dsh\skills",      # dsh（user-dsh）
    "$env:USERPROFILE\.claude\skills",   # Claude Code
    "$env:USERPROFILE\.codex\skills"     # OpenAI Codex
)

$mounted  = 0
$skipped  = 0
$remounted = 0   # 错挂后重挂
$failed   = 0
$cleaned  = 0

# --- 工具函数 ---

# 解析链接（junction / symlink）的真实目标绝对路径；失败返回 $null。
function Get-LinkTarget([string]$Path) {
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        return $null
    }
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $null }
    $target = $item.Target
    if (-not $target) { return $null }
    return [System.IO.Path]::GetFullPath((($target -join ' ')))
}

# 判断路径是否为链接（ReparsePoint）。
function Test-IsLink([string]$Path) {
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch {
        return $false
    }
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

# 从给定的技能绝对路径向上查找其所属仓库的 REPO_ID。
# 搜索范围：从该路径向上遍历，遇到含 REPO_ID 文件的目录即返回其内容。
# 找不到则返回 $null。
function Get-RepoIdOf([string]$SkillPath) {
    $dir = [System.IO.Path]::GetFullPath($SkillPath)
    while ($true) {
        $f = Join-Path $dir 'REPO_ID'
        if (Test-Path -LiteralPath $f -PathType Leaf) {
            $v = (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue).Trim()
            if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
        }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { return $null }
        $dir = $parent
    }
}

# 挂载一个技能到目标根目录；返回状态字符串：created / ok / remounted / conflict / failed
function Mount-IntoRoot([string]$SkillName, [string]$SkillAbs, [string]$Root) {
    $linkPath = Join-Path $Root $SkillName

    if (-not (Test-Path -LiteralPath $linkPath)) {
        try {
            New-Item -ItemType Junction -Path $linkPath -Target $SkillAbs | Out-Null
            return 'created'
        }
        catch {
            Write-Warning "挂载失败：$linkPath（$($_.Exception.Message)）"
            return 'failed'
        }
    }

    # 已存在：区分 真实目录 / 链接
    if (-not (Test-IsLink $linkPath)) {
        Write-Warning "已存在真实目录（非链接），跳过且不覆盖：$linkPath"
        return 'conflict'
    }

    $target = Get-LinkTarget $linkPath
    if (-not $target) {
        Write-Warning "跳过（无法解析现有链接目标，避免误动）：$linkPath"
        return 'conflict'
    }

    # 目标归属本仓库（REPO_ID 一致）→ 正确，跳过
    $targetRepoId = Get-RepoIdOf $target
    if ($targetRepoId -eq $RepoId) {
        return 'ok'
    }

    # 目标无法归到任何带 REPO_ID 的仓库（外部散装技能）→ 保护，绝不重挂/覆盖
    if ([string]::IsNullOrWhiteSpace($targetRepoId)) {
        Write-Warning "已存在指向外部（无 REPO_ID）的同名链接，保护并跳过：$linkPath"
        return 'conflict'
    }

    # 目标归属"别的仓库"（REPO_ID 非空且 ≠ 本仓库）→ 错挂，删掉重挂到本仓库
    try {
        Remove-Item -LiteralPath $linkPath -Force -Recurse
        New-Item -ItemType Junction -Path $linkPath -Target $SkillAbs | Out-Null
        return 'remounted'
    }
    catch {
        Write-Warning "修正错挂失败：$linkPath（$($_.Exception.Message)）"
        return 'failed'
    }
}

# --- 清理阶段（已并入默认行为，-Sync 为兼容别名） ---

# 只删除「目标归属本仓库（REPO_ID 一致）且目标已不存在」的悬空链接；
# 其它（外部仓库、仍有效、真实目录/文件）一律保留。
# 置于挂载之前：目录结构变更（如分类迁移）后，一次运行即可完成「清旧 + 挂新」。
foreach ($root in $agentSkillRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }

    # 枚举所有条目（不限定 -Directory，确保悬空 junction 也能被枚举到）
    Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $item = $_

        # 只看链接；真实目录/文件一律保留
        if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return }

        $target = Get-LinkTarget $item.FullName
        if (-not $target) {
            Write-Warning "跳过（无法解析链接目标）：$($item.FullName)"
            return
        }

        $targetRepoId = Get-RepoIdOf $target
        # 目标仓库标识 != 本仓库 → 外部技能链接，保护，绝不删
        if ($targetRepoId -ne $RepoId) { return }

        # 归属本仓库，但目标已不存在 → 悬空残留，清理
        if (-not (Test-Path -LiteralPath $target)) {
            try {
                Remove-Item -LiteralPath $item.FullName -Force -Recurse
                Write-Host "已清理悬空链接：$($item.FullName)"
                $cleaned++
            }
            catch {
                Write-Warning "清理失败：$($item.FullName)（$($_.Exception.Message)）"
            }
        }
    }
}

# --- 挂载阶段 ---

# 提示一级散放（skills\<name>\ 直接含 SKILL.md）——技能须位于分类目录下，不会被挂载
Get-ChildItem -LiteralPath $SkillsSrc -Directory | ForEach-Object {
    if (Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md')) {
        Write-Warning "跳过（skill 须位于分类目录下：skills/<分类>/<skill-name>/，当前在 skills/$($_.Name)/）：$($_.Name)"
    }
}

# 扫描技能：skills/<分类>/<技能>/（两级）；-Profile 时只扫该分类
if ($Profile) {
    $categories = @(Get-Item -LiteralPath (Join-Path $SkillsSrc $Profile))
} else {
    $categories = @(Get-ChildItem -LiteralPath $SkillsSrc -Directory)
}
foreach ($cat in $categories) {
    Get-ChildItem -LiteralPath $cat.FullName -Directory | ForEach-Object {
        $skillName = $_.Name
        $skillAbs  = $_.FullName

        # 跳过没有 SKILL.md 的目录（非技能目录）
        if (-not (Test-Path -LiteralPath (Join-Path $skillAbs 'SKILL.md'))) {
            Write-Warning "跳过（不是技能目录，无 SKILL.md）：$skillName"
            return
        }

        foreach ($root in $agentSkillRoots) {
            # Agent 未安装，静默跳过
            if (-not (Test-Path -LiteralPath $root)) { continue }

            $status = Mount-IntoRoot $skillName $skillAbs $root
            switch ($status) {
                'created'   { Write-Host "已挂载：$(Join-Path $root $skillName)  ->  $skillAbs"; $mounted++ }
                'ok'        { $skipped++ }
                'remounted' { Write-Host "已修正错挂并重挂：$(Join-Path $root $skillName)  ->  $skillAbs"; $remounted++ }
                'conflict'  { $skipped++ }
                'failed'    { $failed++ }
            }
        }
    }
}

Write-Host ""
Write-Host "完成。本次挂载 $mounted 个，跳过 $skipped 个，修正错挂 $remounted 个，失败 $failed 个，清理悬空链接 $cleaned 个。"
Write-Host "提示：本仓库 git pull 后，所有已挂载的技能自动更新，无需重装。"
Write-Host "新增技能后重跑本脚本即可挂载；悬空链接自动清理（-Sync 为兼容别名）。"
