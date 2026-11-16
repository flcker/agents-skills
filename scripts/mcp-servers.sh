#!/usr/bin/env bash
#
# mcp-servers.sh
#
# 管理 mcp-servers.yaml 清单（事实源）：登记、移除、列出、校验 MCP。
# 与 mcp-servers.ps1 契约一致。退出码：0 成功 / 1 有错误 / 2 用法错误。
# 适用于 macOS / Linux / WSL / Git Bash。Windows 原生 PowerShell 用 mcp-servers.ps1。
#
# 用法（在仓库根目录执行）：
#   bash scripts/mcp-servers.sh check                                  # 校验清单（缺省）
#   bash scripts/mcp-servers.sh add <name> --docs <d> --pattern <p> [--command <c>] [--env <e>]
#   bash scripts/mcp-servers.sh remove <name>
#   bash scripts/mcp-servers.sh list
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFEST="$REPO_ROOT/mcp-servers.yaml"

err()  { echo "错误：$*" >&2; }
warn() { echo "警告：$*" >&2; }

errors=0

# 明显占位符不视为凭证（与 check-sanitize 对齐）
is_placeholder() {
    printf '%s' "$1" | grep -qiE 'YOUR_|PLACEHOLDER|placeholder|example\.com|xxx|<\w+>' && return 0 || return 1
}

# 对字段值跑关键密钥正则（与 check-sanitize.sh 对齐的子集）
check_secret() {
    local val="$1" where="$2" hit
    hit=$(printf '%s' "$val" | grep -nEi 'sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|xox[baprs]-[A-Za-z0-9-]{10,}|bearer[[:space:]]+[A-Za-z0-9._-]{20,}' || true)
    if [ -n "$hit" ] && ! is_placeholder "$val"; then
        err "$where：疑似含凭证（$val）"
        errors=$((errors+1))
    fi
}

# docs 指向仓库路径则须存在，指向外部 URL 则须可达
check_docs() {
    local name="$1" docs="$2" target
    case "$docs" in
        http://*|https://*)
            if ! curl -fsSI --max-time 15 "$docs" >/dev/null 2>&1; then
                err "$name：docs URL 不可达（$docs）"
                errors=$((errors+1))
            fi
            ;;
        *)
            target="$REPO_ROOT/$docs"
            if [ ! -d "$target" ] && [ ! -f "$target" ]; then
                err "$name：docs 路径不存在（$docs）"
                errors=$((errors+1))
            fi
            ;;
    esac
}

# 解析清单 → 输出 "name<TAB>field<TAB>value"（忽略注释/空行/servers: 头）。
# 格式错误时向 stderr 报错并返回 1。调用方须整体捕获（写临时文件）后再循环，
# 切勿直接在进程替换 < <(read_manifest) 里依赖其退出码。
read_manifest() {
    local line body indent key val name lineno
    name=""
    lineno=0
    while IFS= read -r line; do
        lineno=$((lineno+1))
        line="${line%% #*}"
        line="$(printf '%s' "$line" | sed 's/[[:space:]]*$//')"
        case "$line" in ''|'#'*) continue ;; esac

        case "$line" in
            '    '*) indent=4; body="${line#    }" ;;
            '  '*)   indent=2; body="${line#  }" ;;
            *)       indent=0; body="$line" ;;
        esac

        case "$indent" in
            0)
                [ "$body" = "servers:" ] || { err "第 $lineno 行：顶层只允许 servers:，遇到「$body」"; return 1; }
                ;;
            2)
                case "$body" in
                    *:) name="${body%:}" ;;
                    *) err "第 $lineno 行：server 名应以 : 结尾（$body）"; return 1 ;;
                esac
                ;;
            4)
                key="${body%%:*}"; val="${body#*:}"
                key="$(printf '%s' "$key" | sed 's/[[:space:]]*$//')"
                val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
                if [ -z "$name" ]; then
                    err "第 $lineno 行：字段出现在 server 之前（$body）"
                    return 1
                fi
                printf '%s\t%s\t%s\n' "$name" "$key" "$val"
                ;;
            *)
                err "第 $lineno 行：非法缩进（应为 0/2/4 空格）：$body"
                return 1
                ;;
        esac
    done < "$MANIFEST"
}

# 校验单个 server 的字段组合
check_one() {
    local name="$1" docs="$2" pattern="$3" command="$4"
    if [ -z "$docs" ]; then err "$name：缺 docs 字段"; errors=$((errors+1)); fi
    if [ -z "$pattern" ]; then
        err "$name：缺 pattern 字段"; errors=$((errors+1))
    elif [ "$pattern" != guide ] && [ "$pattern" != usage ] && [ "$pattern" != direct ]; then
        err "$name：pattern 非法（$pattern，应为 guide/usage/direct）"; errors=$((errors+1))
    fi
    if { [ "$pattern" = guide ] || [ "$pattern" = usage ]; } && [ -z "$command" ]; then
        err "$name：${pattern} 型需 command 字段"; errors=$((errors+1))
    fi
    [ -n "$command" ] && check_secret "$command" "$name command"
    [ -n "$docs" ] && check_docs "$name" "$docs"
}

cmd_check() {
    local tmp ename efield eval name docs pattern command
    [ -f "$MANIFEST" ] || { err "清单不存在：$MANIFEST"; return 1; }
    tmp="$(mktemp)"
    if ! read_manifest > "$tmp"; then rm -f "$tmp"; return 1; fi

    errors=0
    name=""; docs=""; pattern=""; command=""
    while IFS=$'\t' read -r ename efield eval; do
        if [ -n "$name" ] && [ "$ename" != "$name" ]; then
            check_one "$name" "$docs" "$pattern" "$command"
            docs=""; pattern=""; command=""
        fi
        name="$ename"
        case "$efield" in
            docs)    docs="$eval" ;;
            pattern) pattern="$eval" ;;
            command) command="$eval" ;;
            requires) : ;;  # 只识别，不做跨文件校验（指向 tools.yaml，避免 mini-mise）
            env)     check_secret "$eval" "$name env" ;;
            *) err "未知字段 $efield（$name）"; errors=$((errors+1)) ;;
        esac
    done < "$tmp"
    [ -n "$name" ] && check_one "$name" "$docs" "$pattern" "$command"
    rm -f "$tmp"

    if [ "$errors" -gt 0 ]; then
        echo "$errors 个问题，请修复 mcp-servers.yaml" >&2
        return 1
    fi
    echo "mcp-servers.yaml 校验通过"
}

cmd_add() {
    local name="" docs="" pattern="" command="" env="" tmp ename efield eval
    name="${1:-}"; shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --docs)      docs="$2"; shift ;;
            --docs=*)    docs="${1#--docs=}" ;;
            --pattern)   pattern="$2"; shift ;;
            --pattern=*) pattern="${1#--pattern=}" ;;
            --command)   command="$2"; shift ;;
            --command=*) command="${1#--command=}" ;;
            --env)       env="$2"; shift ;;
            --env=*)     env="${1#--env=}" ;;
            -*) err "未知参数：$1"; return 1 ;;
            *)  err "多余参数：$1"; return 1 ;;
        esac
        shift
    done

    [ -n "$name" ]    || { err "add 需要 <name>"; return 1; }
    [ -n "$docs" ]    || { err "add 需要 --docs <docs>"; return 1; }
    [ -n "$pattern" ] || { err "add 需要 --pattern <pattern>"; return 1; }
    case "$pattern" in
        guide|usage|direct) ;;
        *) err "pattern 非法：$pattern（应为 guide/usage/direct）"; return 1 ;;
    esac
    if { [ "$pattern" = guide ] || [ "$pattern" = usage ]; } && [ -z "$command" ]; then
        err "$pattern 型需 --command <command>"; return 1
    fi
    case "$docs$command$env" in
        *'#'*) err "字段值不得内嵌 #（会被当注释剥离）"; return 1 ;;
    esac

    # 去重
    if [ -f "$MANIFEST" ]; then
        tmp="$(mktemp)"
        if ! read_manifest > "$tmp"; then rm -f "$tmp"; return 1; fi
        while IFS=$'\t' read -r ename efield eval; do
            if [ "$ename" = "$name" ]; then
                rm -f "$tmp"
                err "已存在同名 MCP：$name"
                return 1
            fi
        done < "$tmp"
        rm -f "$tmp"
    else
        printf 'servers:\n' > "$MANIFEST"
    fi

    # 追加块
    {
        printf '  %s:\n' "$name"
        printf '    docs: %s\n' "$docs"
        printf '    pattern: %s\n' "$pattern"
        [ -n "$command" ] && printf '    command: %s\n' "$command"
        [ -n "$env" ]     && printf '    env: %s\n' "$env"
        printf '\n'
    } >> "$MANIFEST"

    echo "已添加：$name"
    cmd_check
}

cmd_remove() {
    local name="${1:-}" line body indent key in_block=0 removed=0 tmp
    [ -n "$name" ] || { err "remove 需要 <name>"; return 1; }
    [ -f "$MANIFEST" ] || { err "无清单 $MANIFEST"; return 1; }

    tmp="$(mktemp)"
    while IFS= read -r line; do
        case "$line" in
            '    '*) indent=4 ;;
            '  '*)   indent=2 ;;
            *)       indent=0 ;;
        esac
        if [ "$indent" = 2 ]; then
            key="$(printf '%s' "${line#  }" | sed 's/[[:space:]]*$//')"
            key="${key%:}"
            if [ "$key" = "$name" ]; then
                in_block=1; removed=1
                continue
            else
                in_block=0
            fi
        elif [ "$indent" = 4 ]; then
            [ "$in_block" = 1 ] && continue
        fi
        printf '%s\n' "$line"
    done < "$MANIFEST" > "$tmp"

    if [ "$removed" = 0 ]; then
        rm -f "$tmp"
        err "清单中无此 MCP：$name"
        return 1
    fi
    mv "$tmp" "$MANIFEST"
    echo "已移除：$name"
}

cmd_list() {
    local tmp ename efield eval name docs pattern
    [ -f "$MANIFEST" ] || { echo "无清单（$MANIFEST）"; return 0; }
    tmp="$(mktemp)"
    if ! read_manifest > "$tmp"; then rm -f "$tmp"; return 1; fi

    printf 'name\tdocs\tpattern\n'
    name=""; docs=""; pattern=""
    while IFS=$'\t' read -r ename efield eval; do
        if [ -n "$name" ] && [ "$ename" != "$name" ]; then
            printf '%s\t%s\t%s\n' "$name" "$docs" "$pattern"
            docs=""; pattern=""
        fi
        name="$ename"
        case "$efield" in
            docs)    docs="$eval" ;;
            pattern) pattern="$eval" ;;
        esac
    done < "$tmp"
    [ -n "$name" ] && printf '%s\t%s\t%s\n' "$name" "$docs" "$pattern"
    rm -f "$tmp"
}

cmd="${1:-check}"
shift || true
case "$cmd" in
    check)  cmd_check "$@" ;;
    add)    cmd_add "$@" ;;
    remove) cmd_remove "$@" ;;
    list)   cmd_list "$@" ;;
    *)
        echo "用法：mcp-servers.sh <check|add|remove|list> [参数...]" >&2
        echo "  check                                  校验清单（缺省）" >&2
        echo "  add <name> --docs <d> --pattern <p> [--command <c>] [--env <e>]" >&2
        echo "  remove <name>                          移除一个 MCP" >&2
        echo "  list                                   列出清单" >&2
        exit 2
        ;;
esac
