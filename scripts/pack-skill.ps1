# 打包 skill 为 zip（IM 分发用，如发给 openclaw）：文件名带 SKILL.md 的 updated 日期，接收方据此判断版本
# 用法: powershell -ExecutionPolicy Bypass -File .\scripts\pack-skill.ps1 <skill名> [更多...] | all | -Profile <分类>
# 产出: 单技能 dist/<skill名>-<updated日期>.zip；-Profile <分类> 批量打包该分类全部技能到 dist\<分类>\（逐技能独立 zip，各带版本号）
#       zip 顶层为 <分类>\<skill名>\…，解压到 skills\ 下即恢复目录结构完成安装
# 排除敏感/垃圾文件: .env（含凭证，绝不打包）、__pycache__、*.pyc、.DS_Store；.env.example 保留
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Skills = @(),
    [string]$Profile = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot   # scripts/ 的上级 = 仓库根
$skillsDir = Join-Path $repoRoot 'skills'
$distDir = Join-Path $repoRoot 'dist'
$distRel = 'dist'   # 输出目录的仓库相对路径（Pack-Profile 切换到 dist\<分类>\ 时同步更新，供消息显示）

if ($PSBoundParameters.ContainsKey('Profile') -and -not $Profile) {
    Write-Host "-Profile 需要一个分类名参数" -ForegroundColor Yellow
    exit 1
}

# 在 skills\<分类>\<name>\ 两级结构中按名定位技能；返回分类名，找不到返回 $null
function Locate-Skill([string]$Name) {
    foreach ($c in (Get-ChildItem $skillsDir -Directory)) {
        if (Test-Path (Join-Path $c.FullName "$Name\SKILL.md")) { return $c.Name }
    }
    return $null
}

# 复制到临时目录（保留分类层级 <分类>\<name>），剔除排除项后压缩；返回 zip 路径
function Invoke-Pack([string]$Cat, [string[]]$Names, [string]$ZipName) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pack-skill-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $tmp | Out-Null
    $catTmp = Join-Path $tmp $Cat
    New-Item -ItemType Directory $catTmp -Force | Out-Null
    foreach ($n in $Names) {
        Copy-Item -Recurse (Join-Path $skillsDir "$Cat\$n") $catTmp
    }
    try {
        # 排除分两趟：先删匹配的文件，再删 __pycache__ 目录——
        # 单趟父子同删会在 Stop 偏好下因子项已随父目录消失而中止
        Get-ChildItem $tmp -Recurse -Force -File |
            Where-Object { $_.Name -eq '.env' -or $_.Name -eq '.DS_Store' -or $_.Name -like '*.pyc' } |
            Remove-Item -Force
        Get-ChildItem $tmp -Recurse -Force -Directory |
            Where-Object { $_.Name -eq '__pycache__' } |
            Remove-Item -Recurse -Force
        $zip = Join-Path $distDir $ZipName
        Compress-Archive -Path $catTmp -DestinationPath $zip -Force
    }
    finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    return $zip
}

$script:failCount = 0

function Pack-One([string]$Name) {
    $cat = Locate-Skill $Name
    if (-not $cat) {
        Write-Host "跳过 ${Name}：skills/<分类>/${Name}/SKILL.md 不存在" -ForegroundColor Yellow
        $script:failCount++
        return
    }
    $skillDir = Join-Path $skillsDir "$cat\$Name"

    # 读 frontmatter 的 updated（仓库约定必填；缺失视为不合规，打包文件名也依赖它）
    $updated = ''
    $m = Select-String -Path (Join-Path $skillDir 'SKILL.md') -Pattern '^updated:\s*(\S+)'
    if ($m) { $updated = $m.Matches[0].Groups[1].Value }
    if (-not $updated) {
        Write-Host "跳过 ${Name}：SKILL.md 缺少 updated 字段（仓库约定必填）" -ForegroundColor Yellow
        $script:failCount++
        return
    }

    $zip = Invoke-Pack $cat @($Name) "$Name-$updated.zip"
    $size = '{0:N1} KB' -f ((Get-Item $zip).Length / 1KB)
    Write-Host "已打包 $Name → $script:distRel/$Name-$updated.zip（$size）"
}

# 分类批量打包：该分类下全部含 SKILL.md 的技能 → dist\<分类>\ 下逐技能 zip（文件名带各自 updated 版本号）
function Pack-Profile([string]$Cat) {
    if (-not (Test-Path (Join-Path $skillsDir $Cat) -PathType Container)) {
        $available = (Get-ChildItem $skillsDir -Directory | ForEach-Object { $_.Name }) -join ' '
        Write-Host "错误：分类不存在：${Cat}（可用分类：$available）" -ForegroundColor Yellow
        $script:failCount++
        return
    }
    $names = @(Get-ChildItem (Join-Path $skillsDir $Cat) -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } |
        Select-Object -ExpandProperty Name)
    if ($names.Count -eq 0) {
        Write-Host "跳过分类 ${Cat}：其下没有技能目录" -ForegroundColor Yellow
        $script:failCount++
        return
    }
    # 产出目录切换到 dist\<分类>\，逐技能复用 Pack-One（文件名带各自 updated 版本号）
    $script:distDir = Join-Path $script:distDir $Cat
    $script:distRel = "dist\$Cat"
    New-Item -ItemType Directory -Force $script:distDir | Out-Null
    foreach ($n in $names) { Pack-One $n }
    Write-Host "分类 $Cat 批量打包完成：$($names.Count) 个 → $script:distRel\"
}

New-Item -ItemType Directory -Force $distDir | Out-Null

if ($Profile) {
    Pack-Profile $Profile
} elseif ($Skills.Count -eq 1 -and $Skills[0] -eq 'all') {
    # 两级枚举：skills\<分类>\<技能>\
    Get-ChildItem $skillsDir -Directory | ForEach-Object {
        Get-ChildItem $_.FullName -Directory | ForEach-Object {
            if (Test-Path (Join-Path $_.FullName 'SKILL.md')) { Pack-One $_.Name }
        }
    }
} elseif ($Skills.Count -eq 0) {
    Write-Host "用法: powershell -ExecutionPolicy Bypass -File .\scripts\pack-skill.ps1 <skill名> [更多...] | all | -Profile <分类>"
    exit 1
} else {
    foreach ($name in $Skills) { Pack-One $name }
}
if ($script:failCount -gt 0) { exit 1 }
