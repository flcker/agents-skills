<#
.SYNOPSIS
  管理 mcp-servers.yaml 清单：登记、移除、列出、校验 MCP。
  与 mcp-servers.sh 契约一致。退出码：0 成功 / 1 有错误 / 2 用法错误。

  用法（在仓库根目录执行）：
    powershell -ExecutionPolicy Bypass -File .\scripts\mcp-servers.ps1 check
    powershell -ExecutionPolicy Bypass -File .\scripts\mcp-servers.ps1 add <name> -Docs <d> -Pattern <p> [-Cmd <c>] [-Env <e>]
    powershell -ExecutionPolicy Bypass -File .\scripts\mcp-servers.ps1 remove <name>
    powershell -ExecutionPolicy Bypass -File .\scripts\mcp-servers.ps1 list
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'check',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path $repoRoot 'mcp-servers.yaml'

$script:errors = 0

function Write-Err([string]$Msg) { Write-Host "错误：$Msg" -ForegroundColor Red; $script:errors++ }
function Write-Warn([string]$Msg) { Write-Host "警告：$Msg" -ForegroundColor Yellow }

function Test-Placeholder([string]$Line) {
    return $Line -match 'YOUR_|PLACEHOLDER|placeholder|example\.com|xxx|<[A-Za-z]+>'
}

$secretRegexes = @(
    'sk-[A-Za-z0-9_\-]{16,}',
    'gh[pousr]_[A-Za-z0-9]{20,}',
    'glpat-[A-Za-z0-9_\-]{16,}',
    'AKIA[0-9A-Z]{16}',
    'BEGIN [A-Z ]*PRIVATE KEY',
    'xox[baprs]-[A-Za-z0-9\-]{10,}',
    '(?i)bearer\s+[A-Za-z0-9._\-]{20,}'
)

function Test-Secret([string]$Value, [string]$Where) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    foreach ($rx in $secretRegexes) {
        if ($Value -match $rx) {
            if (-not (Test-Placeholder $Value)) {
                Write-Err "$Where：疑似含凭证（$Value）"
            }
            return
        }
    }
}

function Test-Docs([string]$Name, [string]$Docs) {
    if ($Docs -match '^https?://') {
        try {
            Invoke-WebRequest -Uri $Docs -Method Head -UseBasicParsing -TimeoutSec 15 | Out-Null
        } catch {
            Write-Err "$Name：docs URL 不可达（$Docs）"
        }
    } else {
        $target = Join-Path $repoRoot ($Docs -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $target)) {
            Write-Err "$Name：docs 路径不存在（$Docs）"
        }
    }
}

# 解析清单 → 输出对象数组 @{Name;Field;Value}；格式错误抛异常
function Read-Manifest {
    if (-not (Test-Path -LiteralPath $manifest)) { return @() }
    $rows = New-Object System.Collections.ArrayList
    $name = ''
    $lineno = 0
    foreach ($raw in Get-Content -LiteralPath $manifest -Encoding UTF8) {
        $lineno++
        $line = $raw
        $hashIdx = $line.IndexOf(' #')
        if ($hashIdx -ge 0) { $line = $line.Substring(0, $hashIdx) }
        $line = $line.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }

        if ($line.StartsWith('    ')) { $indent = 4; $body = $line.Substring(4) }
        elseif ($line.StartsWith('  ')) { $indent = 2; $body = $line.Substring(2) }
        else { $indent = 0; $body = $line }

        switch ($indent) {
            0 {
                if ($body -ne 'servers:') { throw "第 $lineno 行：顶层只允许 servers:，遇到「$body」" }
            }
            2 {
                if ($body.EndsWith(':')) { $name = $body.TrimEnd(':') }
                else { throw "第 $lineno 行：server 名应以 : 结尾（$body）" }
            }
            4 {
                $ci = $body.IndexOf(':')
                if ($ci -lt 0) { throw "第 $lineno 行：字段应为 key: value（$body）" }
                $key = $body.Substring(0, $ci).TrimEnd()
                $val = $body.Substring($ci + 1).Trim()
                if ([string]::IsNullOrWhiteSpace($name)) { throw "第 $lineno 行：字段出现在 server 之前（$body）" }
                [void]$rows.Add(@{ Name = $name; Field = $key; Value = $val })
            }
            default {
                throw "第 $lineno 行：非法缩进（应为 0/2/4 空格）：$body"
            }
        }
    }
    return $rows
}

function Test-One([string]$Name, [string]$Docs, [string]$Pattern, [string]$Command) {
    if ([string]::IsNullOrWhiteSpace($Docs)) { Write-Err "$Name：缺 docs 字段" }
    if ([string]::IsNullOrWhiteSpace($Pattern)) { Write-Err "$Name：缺 pattern 字段" }
    elseif ($Pattern -notin @('guide','usage','direct')) { Write-Err "$Name：pattern 非法（$Pattern，应为 guide/usage/direct）" }
    if ($Pattern -in @('guide','usage') -and [string]::IsNullOrWhiteSpace($Command)) {
        Write-Err "$Name：$Pattern 型需 command 字段"
    }
    Test-Secret $Command "$Name command"
    if (-not [string]::IsNullOrWhiteSpace($Docs)) { Test-Docs $Name $Docs }
}

function Invoke-Check {
    if (-not (Test-Path -LiteralPath $manifest)) { Write-Err "清单不存在：$manifest"; return 1 }
    $rows = Read-Manifest
    $script:errors = 0
    $name = ''; $docs = ''; $pattern = ''; $command = ''
    foreach ($r in $rows) {
        if (-not [string]::IsNullOrWhiteSpace($name) -and $r.Name -ne $name) {
            Test-One $name $docs $pattern $command
            $docs = ''; $pattern = ''; $command = ''
        }
        $name = $r.Name
        switch ($r.Field) {
            'docs'    { $docs = $r.Value }
            'pattern' { $pattern = $r.Value }
            'command' { $command = $r.Value }
            'env'     { Test-Secret $r.Value "$name env" }
            default   { Write-Err "未知字段 $($r.Field)（$name）" }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($name)) { Test-One $name $docs $pattern $command }

    if ($script:errors -gt 0) {
        Write-Host "$($script:errors) 个问题，请修复 mcp-servers.yaml" -ForegroundColor Red
        return 1
    }
    Write-Host "mcp-servers.yaml 校验通过" -ForegroundColor Green
    return 0
}

function Invoke-Add {
    $name = $null; $docs = $null; $pattern = $null; $command = $null; $env = $null
    for ($i = 0; $i -lt $Rest.Count; $i++) {
        $arg = $Rest[$i]
        if ($arg -eq '-Docs')           { $docs = $Rest[++$i] }
        elseif ($arg.StartsWith('-Docs='))       { $docs = $arg.Substring(6) }
        elseif ($arg -eq '-Pattern')     { $pattern = $Rest[++$i] }
        elseif ($arg.StartsWith('-Pattern='))     { $pattern = $arg.Substring(9) }
        elseif ($arg -eq '-Cmd')         { $command = $Rest[++$i] }
        elseif ($arg.StartsWith('-Cmd='))         { $command = $arg.Substring(5) }
        elseif ($arg -eq '-Env')         { $env = $Rest[++$i] }
        elseif ($arg.StartsWith('-Env='))         { $env = $arg.Substring(5) }
        elseif ($arg.StartsWith('-'))    { Write-Err "未知参数：$arg"; return 1 }
        else {
            if ($null -eq $name) { $name = $arg }
            else { Write-Err "多余参数：$arg"; return 1 }
        }
    }

    if ([string]::IsNullOrWhiteSpace($name)) { Write-Err "add 需要 <name>"; return 1 }
    if ([string]::IsNullOrWhiteSpace($docs)) { Write-Err "add 需要 --docs <docs>"; return 1 }
    if ([string]::IsNullOrWhiteSpace($pattern)) { Write-Err "add 需要 --pattern <pattern>"; return 1 }
    if ($pattern -notin @('guide','usage','direct')) { Write-Err "pattern 非法：$pattern（应为 guide/usage/direct）"; return 1 }
    if ($pattern -in @('guide','usage') -and [string]::IsNullOrWhiteSpace($command)) { Write-Err "$pattern 型需 --command <command>"; return 1 }
    if ($docs.Contains('#') -or ($command -and $command.Contains('#')) -or ($env -and $env.Contains('#'))) {
        Write-Err "字段值不得内嵌 #（会被当注释剥离）"; return 1
    }

    # 去重
    if (Test-Path -LiteralPath $manifest) {
        foreach ($r in (Read-Manifest)) {
            if ($r.Name -eq $name) { Write-Err "已存在同名 MCP：$name"; return 1 }
        }
    }

    $sb = New-Object System.Text.StringBuilder
    if (-not (Test-Path -LiteralPath $manifest)) { [void]$sb.AppendLine('servers:') }
    [void]$sb.AppendLine("  ${name}:")
    [void]$sb.AppendLine("    docs: $docs")
    [void]$sb.AppendLine("    pattern: $pattern")
    if (-not [string]::IsNullOrWhiteSpace($command)) { [void]$sb.AppendLine("    command: $command") }
    if (-not [string]::IsNullOrWhiteSpace($env)) { [void]$sb.AppendLine("    env: $env") }
    [void]$sb.AppendLine('')

    # 追加到清单（保留 UTF-8 无 BOM，跨平台可读）
    $content = [System.IO.File]::ReadAllText($manifest)
    $newContent = $content.TrimEnd() + "`r`n" + $sb.ToString()
    [System.IO.File]::WriteAllText($manifest, $newContent, (New-Object System.Text.UTF8Encoding($false)))

    Write-Host "已添加：$name" -ForegroundColor Green
    return (Invoke-Check)
}

function Invoke-Remove {
    if ($Rest.Count -lt 1 -or [string]::IsNullOrWhiteSpace($Rest[0])) { Write-Err "remove 需要 <name>"; return 1 }
    $name = $Rest[0]
    if (-not (Test-Path -LiteralPath $manifest)) { Write-Err "无清单 $manifest"; return 1 }

    $lines = Get-Content -LiteralPath $manifest -Encoding UTF8
    $out = New-Object System.Collections.ArrayList
    $inBlock = $false; $removed = $false
    foreach ($line in $lines) {
        if ($line.StartsWith('    ')) { $indent = 4 }
        elseif ($line.StartsWith('  ')) { $indent = 2 }
        else { $indent = 0 }

        if ($indent -eq 2) {
            $key = $line.Substring(2).TrimEnd().TrimEnd(':')
            if ($key -eq $name) { $inBlock = $true; $removed = $true; continue }
            else { $inBlock = $false }
        }
        elseif ($indent -eq 4) {
            if ($inBlock) { continue }
        }
        [void]$out.Add($line)
    }

    if (-not $removed) { Write-Err "清单中无此 MCP：$name"; return 1 }

    # 写回时去掉尾随空行堆叠，保留 UTF-8 无 BOM
    $text = ($out -join "`r`n").TrimEnd() + "`r`n"
    [System.IO.File]::WriteAllText($manifest, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "已移除：$name" -ForegroundColor Green
    return 0
}

function Invoke-List {
    if (-not (Test-Path -LiteralPath $manifest)) { Write-Host "无清单（$manifest）"; return 0 }
    $rows = Read-Manifest
    Write-Host "name`tdocs`tpattern"
    $name = ''; $docs = ''; $pattern = ''
    foreach ($r in $rows) {
        if (-not [string]::IsNullOrWhiteSpace($name) -and $r.Name -ne $name) {
            Write-Host "$name`t$docs`t$pattern"
            $docs = ''; $pattern = ''
        }
        $name = $r.Name
        switch ($r.Field) {
            'docs'    { $docs = $r.Value }
            'pattern' { $pattern = $r.Value }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($name)) { Write-Host "$name`t$docs`t$pattern" }
    return 0
}

$exitCode = switch ($Command) {
    'check'  { Invoke-Check }
    'add'    { Invoke-Add }
    'remove' { Invoke-Remove }
    'list'   { Invoke-List }
    default {
        Write-Host "用法：mcp-servers.ps1 <check|add|remove|list> [参数...]" -ForegroundColor Red
        Write-Host "  check                                  校验清单（缺省）" -ForegroundColor Red
        Write-Host "  add <name> -Docs <d> -Pattern <p> [-Cmd <c>] [-Env <e>]" -ForegroundColor Red
        Write-Host "  remove <name>                          移除一个 MCP" -ForegroundColor Red
        Write-Host "  list                                   列出清单" -ForegroundColor Red
        2
    }
}
exit $exitCode
