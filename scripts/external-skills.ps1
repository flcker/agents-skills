# external-skills.ps1
#
# 管理"外部 git 仓库技能"：读 external-skills.yaml 清单（事实源），把声明的外部技能源
# 克隆/更新到用户级缓存，再挂载到各 Agent skill 根目录，与本仓库内建技能物理隔离、
# 互不覆盖。挂载名规则：
#   - 多 skill 仓库（SKILL.md 在子目录）：<namespace>.<技能名>
#   - 单 skill 仓库（SKILL.md 在仓库根）：namespace 本身（无点）
#
# 仅适用于 Windows（PowerShell 5.1+ 或 PowerShell 7+）。macOS / Linux / WSL 请用
# external-skills.sh。
#
# 边界：本脚本只管理 external-skills 机制；`npx skills`（skills.sh 生态）是独立的
# 个人本机包管理器，不归本脚本处理，两套机制不互通。
#
# 用法（在 agent-skills 仓库根目录执行）：
#   powershell -ExecutionPolicy Bypass -File .\scripts\external-skills.ps1 apply
#   powershell -ExecutionPolicy Bypass -File .\scripts\external-skills.ps1 add <source-ref> -Namespace N
#   powershell -ExecutionPolicy Bypass -File .\scripts\external-skills.ps1 remove <namespace> -Prune
#   powershell -ExecutionPolicy Bypass -File .\scripts\external-skills.ps1 update [-Namespace N]
#   powershell -ExecutionPolicy Bypass -File .\scripts\external-skills.ps1 list
#
# source-ref 语法：
#   github:owner/repo@v1.2.0        → https://github.com/owner/repo.git + ref v1.2.0
#   gitlab:owner/repo@abc1234        → https://gitlab.com/owner/repo.git + ref abc1234
#   https://host/owner/repo.git@v1.2.0 → 原 URL + ref 取最后一个 @ 之后
#   省略 @ref 时 ref 缺省为 HEAD（跟随远程默认分支，兼容 main/master 等命名）。
#   完整 URL 形式不得内嵌 userinfo/密码（凭据请走 git credential helper）：
#   解析按最后一个 @ 切分 ref，URL 内 @ 会造成歧义。
#
# namespace 规则：
#   - 清单内每行 "namespace: source-ref"（YAML 受限子集，支持 # 整行注释）。
#   - 清单另含 host-aliases: 段（可省），格式 "host: 别名"，覆盖内置默认
#     github.com→gh、gitlab.com→glab。
#   - 清单另含 skill-filters: 段（可省），格式 "namespace: 逗号分隔的 skill 名白名单"，
#     仅作用于多 skill 仓库（SKILL.md 在子目录），被筛选 namespace 须为 sources: 显式指定。
#   - namespace 写 "auto" 表示自动推导：优先读源仓库根目录 REPO_ID；无则按 host别名.owner.repo
#     推导（host 查 host-aliases 段 → 内置默认 → 仍无则回退按 URL 生成 slug）。
#   - namespace 是"每源一个"的挂载前缀；同 namespace 下同名技能视为冲突（fail-fast，
#     本轮不挂载任何外部技能，并打印改 namespace 的修复指引）。

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'apply',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$CommandArgs = @()
)

$ErrorActionPreference = 'Stop'

# 仓库根目录 = 本脚本所在目录的上一级
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Manifest = Join-Path $RepoRoot 'external-skills.yaml'
$CacheRoot = if ($env:EXTERNAL_SKILLS_HOME) { $env:EXTERNAL_SKILLS_HOME } else { Join-Path $env:USERPROFILE '.agents\external-skills' }

# 各 Agent 的「用户级」skill 根目录（与 install-skills.ps1 保持一致）。
$agentSkillRoots = @(
    "$env:USERPROFILE\.agents\skills",   # dsh（user-agents，兼容 Claude/skills 生态）
    "$env:USERPROFILE\.dsh\skills",      # dsh（user-dsh）
    "$env:USERPROFILE\.claude\skills",   # Claude Code
    "$env:USERPROFILE\.codex\skills"     # OpenAI Codex
)

function Invoke-Git([string[]]$GitArgs) {
    $out = & git @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("git " + ($GitArgs -join ' ') + " 失败：`n" + ($out -join "`n"))
    }
    return ($out -join "`n")
}

# 把 URL 转成缓存 key / 兜底 namespace：去协议、去 .git、非字母数字压成单个 -
function ConvertTo-Slug([string]$S) {
    $s = $S -replace '^https?://', '' -replace '^ssh://', '' -replace '^git@', ''
    $s = $s -replace '\.git$', ''
    $s = [regex]::Replace($s, '[^A-Za-z0-9]+', '-')
    return $s.Trim('-')
}

# 从 https URL 推导缩写 namespace：host别名.owner.repo（per-repo 唯一）。
# $AliasMap 是 @{ host = 别名 }（配置覆盖内置默认）；host 未命中则回退内置默认，仍无返回 $null。
function Derive-Namespace([string]$Url, [hashtable]$AliasMap) {
    $u = $Url -replace '\.git$', ''
    if ($u -notmatch '^https://([^/]+)/([^/]+)/([^/]+)$') { return $null }
    $hName = $Matches[1]; $owner = $Matches[2]; $repo = $Matches[3]
    $builtin = @{ 'github.com' = 'gh'; 'gitlab.com' = 'glab' }
    if ($AliasMap -and $AliasMap.ContainsKey($hName)) { $abbr = $AliasMap[$hName] }
    elseif ($builtin.ContainsKey($hName)) { $abbr = $builtin[$hName] }
    else { return $null }
    return "$abbr.$owner.$repo"
}

# 读 YAML 清单（受限子集）→ 输出 @{ Sources; Aliases; Filters; Lineno }，单遍解析：
#   - 段头 host-aliases: / skill-filters: / sources: 切换状态，后续 "k: v" 条目归入当前段
#   - 整行注释（# 起）、行尾注释（空格+# 起）、空行忽略；条目按第一个 ": " 切分 key/value
#   - 段顺序自由；host-aliases: / skill-filters: 段可省略（Aliases/Filters 为空）
function Read-Manifest {
    $srcs = New-Object System.Collections.ArrayList
    $aliases = @{}
    $filters = @{}
    $mode = $null
    $lineno = 0
    foreach ($raw in (Get-Content -LiteralPath $Manifest -Encoding UTF8 -ErrorAction Stop)) {
        $lineno++
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        # 段头（允许 ":" 后无内容，如 "sources"）
        if ($line -match '^host-aliases\s*:?\s*$') { $mode = 'alias'; continue }
        if ($line -match '^skill-filters\s*:?\s*$') { $mode = 'filter'; continue }
        if ($line -match '^sources\s*:?\s*$') { $mode = 'src'; continue }
        # 行尾注释：剥掉 " #" 及其后
        $hashIdx = $line.IndexOf(' #')
        if ($hashIdx -ge 0) { $line = $line.Substring(0, $hashIdx).TrimEnd() }
        if ($line -eq '' -or $line.StartsWith('#')) { continue }

        $sep = $line.IndexOf(': ')
        if ($sep -lt 0) { throw "第 $lineno 行格式错误（需 key: value）：$line" }
        $key = $line.Substring(0, $sep).Trim()
        $val = $line.Substring($sep + 2).Trim()
        if (-not $key -or -not $val) { throw "第 $lineno 行缺 key 或 value：$line" }

        if ($mode -eq 'alias') {
            $aliases[$key] = $val
        }
        elseif ($mode -eq 'filter') {
            $filters[$key] = $val
        }
        elseif ($mode -eq 'src') {
            [void]$srcs.Add([pscustomobject]@{ Ns = $key; Src = $val; Lineno = $lineno })
        }
        else {
            throw "第 $lineno 行条目缺少段头（需先 host-aliases: / skill-filters: / sources:）：$line"
        }
    }
    return [pscustomobject]@{ Sources = $srcs; Aliases = $aliases; Filters = $filters }
}

# 解析 source-ref → @{ Url = ...; Ref = ... }；失败返回 $null
function Resolve-SourceRef([string]$Src) {
    $src = $Src
    if ($src -match '^github:' -or $src -match '^gitlab:') {
        $hName = ($src -split ':', 2)[0]
        $rest = ($src -split ':', 2)[1]
        $hName = if ($hName -eq 'github') { 'github.com' } else { 'gitlab.com' }
        $repo = $rest; $ref = 'HEAD'
        if ($rest -match '^(.*?)@(.*)$') { $repo = $Matches[1]; $ref = $Matches[2] }
        return @{ Url = "https://${hName}/${repo}.git"; Ref = $ref }
    }
    if ($src -match '^https?://|^ssh://|^file://') {
        $url = $src; $ref = 'HEAD'
        $idx = $src.LastIndexOf('@')
        if ($idx -ge 0) { $url = $src.Substring(0, $idx); $ref = $src.Substring($idx + 1) }
        return @{ Url = $url; Ref = $ref }
    }
    return $null
}

# 同步一个源到缓存目录（clone / fetch / checkout detach）
function Sync-Source([string]$Url, [string]$Ref, [string]$Cache) {
    if (-not (Test-Path -LiteralPath (Join-Path $Cache '.git'))) {
        # 缓存目录残留但 .git 缺失（半损坏）→ 先清掉再重建
        if ((Test-Path -LiteralPath $Cache) -and -not (Test-IsLink $Cache)) {
            Remove-Item -LiteralPath $Cache -Force -Recurse
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $Cache) -Force | Out-Null
        Invoke-Git @('clone', '--quiet', '--depth', '1', $Url, $Cache)
    }
    if ($Ref -eq 'HEAD') {
        # 缺省：跟随远程默认分支（clone 已落在其上）。更新 = fetch 默认分支 + 重置。
        try {
            Invoke-Git @('-C', $Cache, 'fetch', '--quiet', '--depth', '1', 'origin', 'HEAD')
        }
        catch {
            Write-Warning "fetch HEAD 失败（$Url），尝试完整 fetch..."
            Invoke-Git @('-C', $Cache, 'fetch', '--quiet', 'origin')
        }
        Invoke-Git @('-C', $Cache, 'checkout', '--quiet', '--detach', 'FETCH_HEAD')
        return
    }
    try {
        Invoke-Git @('-C', $Cache, 'fetch', '--quiet', '--depth', '1', 'origin', $Ref)
    }
    catch {
        Write-Warning "浅 fetch 失败（$Url @ $Ref），尝试完整 fetch..."
        Invoke-Git @('-C', $Cache, 'fetch', '--quiet', 'origin', $Ref)
    }
    Invoke-Git @('-C', $Cache, 'checkout', '--quiet', '--detach', 'FETCH_HEAD')
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

# 挂载一个外部技能到目标根目录；返回 created/ok/conflict/failed
function Mount-External([string]$Name, [string]$Abs, [string]$Root) {
    $linkPath = Join-Path $Root $Name
    if (-not (Test-Path -LiteralPath $linkPath)) {
        try {
            New-Item -ItemType Junction -Path $linkPath -Target $Abs | Out-Null
            return 'created'
        }
        catch {
            Write-Warning "挂载失败：$linkPath（$($_.Exception.Message)）"
            return 'failed'
        }
    }
    if (-not (Test-IsLink $linkPath)) {
        Write-Warning "已存在真实目录（非链接），保护不覆盖：$linkPath"
        return 'conflict'
    }
    # 已是链接：目标一致 → ok；指向别处 → 保护不覆盖
    try {
        $item = Get-Item -LiteralPath $linkPath -Force
        $target = [System.IO.Path]::GetFullPath((($item.Target -join ' ')))
        if ($target -eq [System.IO.Path]::GetFullPath($Abs)) { return 'ok' }
    } catch { }
    Write-Warning "已存在指向别处的同名链接，保护不覆盖：$linkPath"
    return 'conflict'
}

# apply：同步 + 冲突预检 + 挂载（幂等）
function Invoke-Apply {
    if (-not (Test-Path -LiteralPath $Manifest)) {
        Write-Host "无清单 $Manifest，没有外部技能，跳过。"
        return
    }

    $manifest = Read-Manifest
    $aliasMap = $manifest.Aliases
    $filterMap = $manifest.Filters
    $entries = New-Object System.Collections.ArrayList
    foreach ($m in $manifest.Sources) {
        $pr = Resolve-SourceRef $m.Src
        if (-not $pr) { throw "第 $($m.Lineno) 行解析失败：$($m.Src)" }
        $explicit = 1; if ($m.Ns -eq 'auto') { $explicit = 0 }
        $cache = Join-Path $CacheRoot (ConvertTo-Slug $pr.Url)
        [void]$entries.Add([pscustomobject]@{
            ns = $m.Ns; explicit = $explicit; url = $pr.Url; ref = $pr.Ref;
            cache = $cache; lineno = $m.Lineno
        })
    }

    if ($entries.Count -eq 0) {
        Write-Host "清单为空，没有外部技能，跳过。"
        return
    }

    # 阶段1：同步所有源
    foreach ($e in $entries) {
        Write-Host "同步外部源：$($e.url) @ $($e.ref)"
        Sync-Source $e.url $e.ref $e.cache
    }

    # 阶段2：确定 namespace + 扫描技能（宽松发现：任意含 SKILL.md 的目录）
    $names = New-Object System.Collections.ArrayList
    foreach ($e in $entries) {
        if ($e.explicit -eq 1) {
            $nsResolved = $e.ns
        }
        else {
            $ridFile = Join-Path $e.cache 'REPO_ID'
            $rid = $null
            if (Test-Path -LiteralPath $ridFile) {
                $rid = (Get-Content -LiteralPath $ridFile -Raw).Trim()
            }
            if (-not [string]::IsNullOrWhiteSpace($rid)) { $nsResolved = $rid }
            else {
                $derived = Derive-Namespace $e.url $aliasMap
                if ($derived) { $nsResolved = $derived }
                else { $nsResolved = ConvertTo-Slug $e.url }
            }
        }
        if ([string]::IsNullOrWhiteSpace($nsResolved)) { throw "第 $($e.lineno) 行 namespace 为空" }

        # 白名单筛选（仅多 skill 仓库）：skill-filters 段里该 namespace 的逗号分隔名单
        $whitelist = $null
        if ($filterMap -and $filterMap.ContainsKey($nsResolved)) {
            $whitelist = @($filterMap[$nsResolved] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        }

        $skillMds = Get-ChildItem -LiteralPath $e.cache -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\\.git\\' }

        # 收集实际 skillName（仅多 skill 仓库的目录 leaf），用于白名单未命中告警
        $actualNames = @()
        foreach ($md in $skillMds) {
            $d = Split-Path -Parent $md.FullName
            if ($d -ne $e.cache) { $actualNames += (Split-Path -Leaf $d) }
        }
        if ($whitelist) {
            foreach ($w in $whitelist) {
                if ($actualNames -notcontains $w) {
                    Write-Warning "skill-filters 名单中的 '$w' 在 $($e.url) 未找到，已跳过"
                }
            }
        }

        foreach ($md in $skillMds) {
            $skillDir = Split-Path -Parent $md.FullName
            if ($skillDir -eq $e.cache) {
                # 单 skill 仓库（SKILL.md 在根）：挂载名 = namespace 本身（无点），不参与筛选
                [void]$names.Add([pscustomobject]@{
                    name = "$nsResolved"; desc = "$($e.url) @ $($e.ref)"; abs = $skillDir
                })
            }
            else {
                $skillName = Split-Path -Leaf $skillDir
                if ($whitelist -and ($whitelist -notcontains $skillName)) { continue }
                [void]$names.Add([pscustomobject]@{
                    name = "$nsResolved.$skillName"; desc = "$($e.url) @ $($e.ref)"; abs = $skillDir
                })
            }
        }
    }

    if ($names.Count -eq 0) {
        Write-Host "未发现任何外部技能（各源下均无 SKILL.md）。"
        return
    }

    # 阶段3：冲突预检（同挂载名重复 → fail-fast，整轮不挂载）
    $dupes = $names | Group-Object name | Where-Object { $_.Count -gt 1 }
    if ($dupes) {
        Write-Host ""
        Write-Host "== 外部技能冲突（同 namespace 下同名技能），本轮不挂载任何外部技能 =="
        foreach ($d in $dupes) {
            Write-Host "[冲突] $($d.Name)："
            foreach ($m in $d.Group) { Write-Host "  - $($m.desc)" }
            Write-Host "  处理：给其中一源指定不同 namespace。编辑 $Manifest 改首列，或"
            Write-Host "        .\scripts\external-skills.ps1 remove <旧namespace> 后 add <source-ref> -Namespace <新>"
        }
        throw "存在外部技能命名冲突"
    }

    # 阶段4：挂载
    $mounted = 0; $skipped = 0; $failed = 0
    foreach ($n in $names) {
        foreach ($root in $agentSkillRoots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            $st = Mount-External $n.name $n.abs $root
            switch ($st) {
                'created' { Write-Host "已挂载：$(Join-Path $root $n.name)  ->  $($n.abs)"; $mounted++ }
                'ok'      { $skipped++ }
                'conflict' { $skipped++ }
                'failed'  { $failed++ }
            }
        }
    }

    Write-Host ""
    Write-Host "完成。外部技能：同步 $($entries.Count) 个源，挂载 $mounted 个，跳过 $skipped 个，失败 $failed 个。"
    Write-Host "缓存目录：$CacheRoot"
}

function Invoke-Add([string[]]$CmdArgs) {
    $src = ''; $ns = 'auto'
    for ($i = 0; $i -lt $CmdArgs.Count; $i++) {
        $a = $CmdArgs[$i]
        if ($a -eq '-Namespace') { $i++; if ($i -ge $CmdArgs.Count) { throw "-Namespace 需要一个值" }; $ns = $CmdArgs[$i]; continue }
        if ($a.StartsWith('-Namespace=')) { $ns = $a.Substring('-Namespace='.Length); continue }
        if ($a.StartsWith('-')) { throw "未知参数：$a" }
        $src = $a
    }
    if (-not $src) { throw "缺少 source-ref" }
    if (-not (Resolve-SourceRef $src)) { throw "无法识别的 source-ref：$src" }

    if (-not (Test-Path -LiteralPath $Manifest)) {
        # 新建清单：写 sources: 头（无 BOM，跨平台可读）
        [System.IO.File]::WriteAllLines($Manifest, @('sources:'), (New-Object System.Text.UTF8Encoding($false)))
    }
    # 去重：按归一化后的 url+ref 比较
    $newPr = Resolve-SourceRef $src
    foreach ($m in (Read-Manifest).Sources) {
        $existPr = Resolve-SourceRef $m.Src
        if ($existPr -and $existPr.Url -eq $newPr.Url -and $existPr.Ref -eq $newPr.Ref) {
            Write-Warning "已存在同一源：$($m.Src)"
            return
        }
    }
    $line = "${ns}: ${src}"
    [System.IO.File]::AppendAllLines($Manifest, [string[]]@($line), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "已添加：$ns  <-  $src"
    Invoke-Apply
}

function Invoke-Remove([string[]]$CmdArgs) {
    if ($CmdArgs.Count -lt 1) { throw "remove 需要 namespace" }
    $target = $CmdArgs[0]
    $prune = $CmdArgs.Contains('-Prune')
    if (-not (Test-Path -LiteralPath $Manifest)) { throw "无清单 $Manifest" }

    $cacheToPrune = $null
    if ($prune) {
        foreach ($m in (Read-Manifest).Sources) {
            if ($m.Ns -ne $target) { continue }
            $pr = Resolve-SourceRef $m.Src
            if ($pr) { $cacheToPrune = Join-Path $CacheRoot (ConvertTo-Slug $pr.Url) }
        }
    }

    foreach ($root in $agentSkillRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        # 匹配两类挂载名：
        #   1) 单 skill 仓库（SKILL.md 在根）：挂载名 = namespace 本身（无点，如 gh.owner.repo）
        #   2) 多 skill 仓库：挂载名 = "<namespace>.<技能名>"，namespace = 去掉最后一个 "." 及其后
        $patterns = @("$target.*", "$target")
        foreach ($pat in $patterns) {
            Get-ChildItem -LiteralPath $root -Filter $pat -Force -ErrorAction SilentlyContinue |
                Where-Object { Test-IsLink $_.FullName } |
                ForEach-Object {
                    $base = $_.Name
                    if ($base -eq $target) {
                        Remove-Item -LiteralPath $_.FullName -Force
                        Write-Host "已卸载：$($_.FullName)"
                    }
                    else {
                        $dot = $base.LastIndexOf('.')
                        if ($dot -ge 0 -and $base.Substring(0, $dot) -eq $target) {
                            Remove-Item -LiteralPath $_.FullName -Force
                            Write-Host "已卸载：$($_.FullName)"
                        }
                    }
                }
        }
    }

    $keep = Get-Content -LiteralPath $Manifest -Encoding UTF8 | Where-Object {
        $line = $_.TrimEnd()
        $sep = $line.IndexOf(': ')
        if ($sep -lt 0) { return $true }   # 注释/空行/sources: 头一律保留
        -not ($line.Substring(0, $sep).Trim() -eq $target)
    }
    [System.IO.File]::WriteAllLines($Manifest, @($keep), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "已移除 namespace：$target"

    if ($prune -and $cacheToPrune -and (Test-Path -LiteralPath $cacheToPrune)) {
        Remove-Item -LiteralPath $cacheToPrune -Force -Recurse
        Write-Host "已删除缓存：$cacheToPrune"
    }
}

function Invoke-Update([string[]]$CmdArgs) {
    # update 等价全量 apply（幂等同步所有源）。-Namespace 仅存在性提示，不改变同步范围。
    if ($CmdArgs.Count -ge 1 -and $CmdArgs[0] -ne '-Namespace' -and -not $CmdArgs[0].StartsWith('-Namespace=')) {
        $ns = $CmdArgs[0]
        if ($ns -ne '--all' -and -not (Select-String -LiteralPath $Manifest -Encoding UTF8 -Pattern "^[ \t]*${ns}[ \t]*:" -Quiet -ErrorAction SilentlyContinue)) {
            Write-Warning "清单中无显式 namespace '$ns'；仍执行全量同步。"
        }
    }
    Invoke-Apply
}

function Invoke-List {
    if (-not (Test-Path -LiteralPath $Manifest)) { Write-Host "无清单（$Manifest）"; return }
    Write-Host "namespace`tsource-ref`tURL`tref"
    foreach ($m in (Read-Manifest).Sources) {
        $pr = Resolve-SourceRef $m.Src
        if ($pr) { $url = $pr.Url; $ref = $pr.Ref } else { $url = '<解析失败>'; $ref = '' }
        Write-Host "$($m.Ns)`t$($m.Src)`t$url`t$ref"
    }
}

switch ($Command) {
    'apply'  { Invoke-Apply }
    'add'    { Invoke-Add $CommandArgs }
    'remove' { Invoke-Remove $CommandArgs }
    'update' { Invoke-Update $CommandArgs }
    'list'   { Invoke-List }
    default  {
        Write-Host "用法：external-skills.ps1 <apply|add|remove|update|list> [参数...]"
        Write-Host "  apply                              同步 + 冲突预检 + 挂载（缺省）"
        Write-Host "  add <source-ref> [-Namespace N]    新增外部源"
        Write-Host "  remove <namespace> [-Prune]        移除外部源（-Prune 连缓存一起删）"
        Write-Host "  update [-Namespace N]              重新同步（全量）"
        Write-Host "  list                               列出清单与解析结果"
        exit 2
    }
}
