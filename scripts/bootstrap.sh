#!/usr/bin/env bash
#
# bootstrap.sh
#
# 新设备/新环境一条命令把技能集投影到本机：挂载技能（内建 + 外部）+ 校验 MCP 清单，
# 然后集中提示还需手动完成的部分（装工具、填凭证、注册 MCP）。
#
# 幂等：每一步都复用已有幂等脚本，可重复执行。
# 只编排 + 提示，不自动装工具、不自动注册 MCP、不探测版本、不存凭证。
#
# 适用于 macOS / Linux / WSL / Git Bash。Windows 原生 PowerShell 用 bootstrap.ps1。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== 1/3 挂载技能（内建 + 外部，幂等）=="
bash "$REPO_ROOT/scripts/install-skills.sh"

echo ""
echo "== 2/3 校验 MCP 清单 =="
bash "$REPO_ROOT/scripts/mcp-servers.sh" check

echo ""
echo "== 3/3 仍需手动完成 =="
echo "  · 工具依赖：见 tools.yaml（基础前提需已装；用到才装的按需）"
echo "  · MCP 凭证：见 mcp-servers.yaml 含 env 的条目，凭证值手填到各客户端本机"
echo "  · MCP 注册：按对应 skill 文档在各自客户端 mcp add（本脚本不代注册）"
