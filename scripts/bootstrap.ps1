<#
.SYNOPSIS
  新设备/新环境一条命令把技能集投影到本机：挂载技能（内建 + 外部）+ 校验 MCP 清单，
  然后集中提示还需手动完成的部分（装工具、填凭证、注册 MCP）。

  幂等：每一步都复用已有幂等脚本，可重复执行。
  只编排 + 提示，不自动装工具、不自动注册 MCP、不探测版本、不存凭证。

  适用于 Windows（PowerShell 5.1+ / 7+）。macOS / Linux / WSL 用 bootstrap.sh。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

Write-Host '== 1/3 挂载技能（内建 + 外部，幂等）==' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install-skills.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ''
Write-Host '== 2/3 校验 MCP 清单 ==' -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'mcp-servers.ps1') check
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ''
Write-Host '== 3/3 仍需手动完成 ==' -ForegroundColor Yellow
Write-Host '  · 工具依赖：见 tools.yaml（基础前提需已装；用到才装的按需）'
Write-Host '  · MCP 凭证：见 mcp-servers.yaml 含 env 的条目，凭证值手填到各客户端本机'
Write-Host '  · MCP 注册：按对应 skill 文档在各自客户端 mcp add（本脚本不代注册）'
