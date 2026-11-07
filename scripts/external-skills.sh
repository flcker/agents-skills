#!/usr/bin/env bash
#
# external-skills.sh
#
# 管理"外部 git 仓库技能"：读 external-skills.yaml 清单（事实源），把声明的外部技能源
# 克隆/更新到用户级缓存，再以 <namespace>.<技能名> 的挂载名链接到各 Agent skill 根目录，
# 与本仓库内建技能（<技能名>）物理隔离，互不覆盖。
#
# 适用于 macOS / Linux / WSL。Windows 原生 PowerShell 请用 external-skills.ps1。
#
# 用法（在 agent-skills 仓库根目录执行）：
#   bash scripts/external-skills.sh apply                     # 同步 + 冲突预检 + 挂载（缺省）
#   bash scripts/external-skills.sh add <source-ref> [--namespace N]
#   bash scripts/external-skills.sh remove <namespace> [--prune]
#   bash scripts/external-skills.sh update [<namespace>|--all]
#   bash scripts/external-skills.sh list
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
#   - namespace 写 "auto" 表示自动推导：优先读源仓库根目录 REPO_ID；无则按 URL 生成 slug。
#   - namespace 是"每源一个"的挂载前缀；同 namespace 下同名技能视为冲突（fail-fast，
#     本轮不挂载任何外部技能，并打印改 namespace 的修复指引）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MANIFEST="$REPO_ROOT/external-skills.yaml"
CACHE_ROOT="${EXTERNAL_SKILLS_HOME:-$HOME/.agents/external-skills}"

# 各 Agent 的「用户级」skill 根目录（与 install-skills.sh 保持一致）。
AGENT_SKILL_ROOTS=(
    "$HOME/.agents/skills"      # dsh（user-agents，兼容 Claude/skills 生态）
    "$HOME/.dsh/skills"         # dsh（user-dsh）
    "$HOME/.claude/skills"      # Claude Code
    "$HOME/.codex/skills"       # OpenAI Codex
)

err()  { echo "错误：$*" >&2; }
warn() { echo "警告：$*" >&2; }

# 把 URL 转成缓存 key / 兜底 namespace：去协议、去 .git、非字母数字压成单个 -
slugify() {
    local s="$1"
    s="${s#https://}"; s="${s#http://}"; s="${s#ssh://}"; s="${s#git@}"
    s="${s%.git}"
    s="$(printf '%s' "$s" | tr -cs '[:alnum:]' '-')"
    s="${s#-}"; s="${s%-}"
    printf '%s\n' "$s"
}

# 读 YAML 清单（受限子集），逐行输出 "ns<TAB>src<TAB>lineno"；错误信息走 stderr，返回非 0。
# 支持的语法：
#   - 整行注释：以 # 开头（允许前导空白）
#   - 行尾注释：值后的 " #..."（空格+# 起）
#   - 头行 sources: 忽略
#   - 条目行：<namespace>: <source-ref>（按第一个 ": " 切分 key/value）
read_manifest() {
    local lineno=0 line key val
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        # 去行首/行尾空白（缩进无关紧要）
        line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        # 剥离 UTF-8 BOM（Windows PowerShell 5.1 的 UTF8 编码写清单会带 BOM）
        line="${line#"$(printf '\357\273\277')"}"
        # 空行 / 整行注释 / sources 头
        case "$line" in
            ''|'#'*) continue ;;
            'sources:'|'sources') continue ;;
        esac
        # 行尾注释：剥掉 " #" 及其后
        line="${line%% #*}"
        line="$(printf '%s' "$line" | sed 's/[[:space:]]*$//')"
        case "$line" in ''|'#'*) continue ;; esac

        # 按第一个 ": " 切分 key/value
        case "$line" in
            *": "*)
                key="${line%%: *}"
                val="${line#*: }"
                ;;
            *)
                err "第 $lineno 行格式错误（需 namespace: source-ref）：$line"
                return 1
                ;;
        esac
        key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$key" ] && [ -n "$val" ] || { err "第 $lineno 行缺 namespace 或 source-ref：$line"; return 1; }
        printf '%s\t%s\t%s\n' "$key" "$val" "$lineno"
    done < "$MANIFEST"
}

# 解析 source-ref → 输出 "url<TAB>ref"；无法识别返回非 0（不打印，由调用方报告行号）。
parse_source_ref() {
    local src="$1" host rest repo refpart url ref
    case "$src" in
        github:*|gitlab:*)
            host="${src%%:*}"
            rest="${src#*:}"
            case "$host" in
                github) host="github.com" ;;
                gitlab) host="gitlab.com" ;;
            esac
            refpart=""
            case "$rest" in
                *@*) repo="${rest%@*}"; refpart="${rest##*@}" ;;
                *)   repo="$rest" ;;
            esac
            url="https://${host}/${repo}.git"
            ref="${refpart:-HEAD}"
            ;;
        https://*|http://*|ssh://*|file://*)
            case "$src" in
                *@*) url="${src%@*}"; ref="${src##*@}" ;;
                *)   url="$src"; ref="HEAD" ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
    printf '%s\t%s\n' "$url" "$ref"
}

# 同步一个源到缓存目录（clone / fetch / checkout detach）
sync_source() {
    local url="$1" ref="$2" cache="$3" tmperr="$4"
    if [ ! -d "$cache/.git" ]; then
        # 缓存目录残留但 .git 缺失（半损坏）→ 先清掉再重建
        [ -e "$cache" ] && [ ! -L "$cache" ] && rm -rf "$cache"
        mkdir -p "$(dirname "$cache")"
        if ! git clone --quiet --depth 1 "$url" "$cache" 2>"$tmperr"; then
            err "克隆失败：$url"
            cat "$tmperr" >&2
            return 1
        fi
    fi
    if [ "$ref" = "HEAD" ]; then
        # 缺省：跟随远程默认分支（clone 已落在其上）。更新 = fetch 默认分支 + 重置。
        if ! git -C "$cache" fetch --quiet --depth 1 origin HEAD 2>"$tmperr"; then
            warn "fetch HEAD 失败（$url），尝试完整 fetch..."
            if ! git -C "$cache" fetch --quiet origin 2>"$tmperr"; then
                err "无法更新：$url"
                cat "$tmperr" >&2
                return 1
            fi
        fi
        if ! git -C "$cache" checkout --quiet --detach FETCH_HEAD 2>"$tmperr"; then
            err "checkout 失败：$url @ HEAD"
            cat "$tmperr" >&2
            return 1
        fi
        return 0
    fi
    if ! git -C "$cache" fetch --quiet --depth 1 origin "$ref" 2>"$tmperr"; then
        warn "浅 fetch 失败（$url @ $ref），尝试完整 fetch..."
        if ! git -C "$cache" fetch --quiet origin "$ref" 2>"$tmperr"; then
            err "无法获取 ref：$url @ $ref（commit SHA 需服务端允许，建议改用 tag/branch）"
            cat "$tmperr" >&2
            return 1
        fi
    fi
    if ! git -C "$cache" checkout --quiet --detach FETCH_HEAD 2>"$tmperr"; then
        err "checkout 失败：$url @ $ref"
        cat "$tmperr" >&2
        return 1
    fi
    return 0
}

# 挂载一个外部技能到目标根目录；打印 created/ok/conflict/failed
mount_external() {
    local name="$1" abs="$2" root="$3" link="$root/$name" tgt
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then
        if ln -s "$abs" "$link" 2>/dev/null; then echo created; else echo failed; fi
        return 0
    fi
    if [ ! -L "$link" ]; then
        warn "已存在真实目录（非链接），保护不覆盖：$link"
        echo conflict; return 0
    fi
    tgt="$(readlink -f "$link" 2>/dev/null || true)"
    if [ -n "$tgt" ] && [ "$tgt" = "$abs" ]; then
        echo ok
    else
        warn "已存在指向别处的同名链接，保护不覆盖：$link"
        echo conflict
    fi
    return 0
}

# apply：同步 + 冲突预检 + 挂载（幂等）
cmd_apply() {
    local tmperr tmpnames parsed lineno ns src extra pr url ref key cache
    local explicit ns_resolved repoid skill_md skill_dir skill_name name desc skill_abs
    local dupes d root st mounted skipped failed total

    [ -f "$MANIFEST" ] || { echo "无清单 $MANIFEST，没有外部技能，跳过。"; return 0; }

    tmperr="$(mktemp)"
    tmpnames="$(mktemp)"
    parsed="$(mktemp)"
    rawmanifest="$(mktemp)"
    trap 'rm -f "$tmperr" "$tmpnames" "$parsed" "$rawmanifest"' RETURN

    # 读 YAML 清单（受限子集）→ 临时文件（逐行 ns/src/lineno）
    if ! read_manifest > "$rawmanifest"; then
        return 1
    fi

    # 解析清单 → parsed 文件（ns / explicit / url / ref / cache / lineno）
    lineno=0
    while IFS=$'\t' read -r ns src mlineno; do
        lineno=$mlineno
        if ! pr="$(parse_source_ref "$src")" || [ -z "$pr" ]; then
            err "第 $lineno 行解析失败：$src"
            return 1
        fi
        url="${pr%%$'\t'*}"
        ref="${pr#*$'\t'}"
        key="$(slugify "$url")"
        cache="$CACHE_ROOT/$key"
        if [ "$ns" = "auto" ]; then explicit=0; else explicit=1; fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ns" "$explicit" "$url" "$ref" "$cache" "$lineno" >> "$parsed"
    done < "$rawmanifest"

    # 阶段1：同步所有源
    total=0
    while IFS=$'\t' read -r ns explicit url ref cache lineno; do
        echo "同步外部源：$url @ $ref"
        if ! sync_source "$url" "$ref" "$cache" "$tmperr"; then return 1; fi
        total=$((total + 1))
    done < "$parsed"

    # 阶段2：确定 namespace + 扫描技能（宽松发现：任意含 SKILL.md 的目录）
    while IFS=$'\t' read -r ns explicit url ref cache lineno; do
        if [ "$explicit" = "1" ]; then
            ns_resolved="$ns"
        else
            repoid="$(tr -d '[:space:]' < "$cache/REPO_ID" 2>/dev/null || true)"
            if [ -n "$repoid" ]; then ns_resolved="$repoid"; else ns_resolved="$(slugify "$url")"; fi
        fi
        [ -z "$ns_resolved" ] && { err "第 $lineno 行 namespace 为空"; return 1; }
        while IFS= read -r skill_md; do
            skill_dir="$(dirname "$skill_md")"
            skill_name="$(basename "$skill_dir")"
            printf '%s\t%s @ %s\t%s\n' "$ns_resolved.$skill_name" "$url" "$ref" "$skill_dir" >> "$tmpnames"
        done < <(find "$cache" -name SKILL.md -not -path '*/.git/*' 2>/dev/null)
    done < "$parsed"

    if [ ! -s "$tmpnames" ]; then
        echo "未发现任何外部技能（各源下均无 SKILL.md）。"
        return 0
    fi

    # 阶段3：冲突预检（同挂载名重复 → fail-fast，整轮不挂载）
    dupes="$(cut -f1 "$tmpnames" | sort | uniq -d)"
    if [ -n "$dupes" ]; then
        echo ""
        echo "== 外部技能冲突（同 namespace 下同名技能），本轮不挂载任何外部技能 =="
        while IFS= read -r d; do
            echo "[冲突] $d："
            awk -F'\t' -v d="$d" '$1==d {print "  - "$2}' "$tmpnames"
            echo "  处理：给其中一源指定不同 namespace。编辑 $MANIFEST 改首列，或"
            echo "        bash scripts/external-skills.sh remove <旧namespace> 后 add <source-ref> --namespace <新>"
        done <<< "$dupes"
        return 1
    fi

    # 阶段4：挂载
    mounted=0; skipped=0; failed=0
    while IFS=$'\t' read -r name desc skill_abs; do
        for root in "${AGENT_SKILL_ROOTS[@]}"; do
            [ -d "$root" ] || continue
            st="$(mount_external "$name" "$skill_abs" "$root")"
            case "$st" in
                created) echo "已挂载：$root/$name -> $skill_abs"; mounted=$((mounted + 1)) ;;
                ok|conflict) skipped=$((skipped + 1)) ;;
                failed) failed=$((failed + 1)) ;;
            esac
        done
    done < "$tmpnames"

    echo ""
    echo "完成。外部技能：同步 $total 个源，挂载 $mounted 个，跳过 $skipped 个，失败 $failed 个。"
    echo "缓存目录：$CACHE_ROOT"
}

cmd_add() {
    local src="" ns="auto" new_pr exist_pr mns msrc mlineno
    while [ $# -gt 0 ]; do
        case "$1" in
            --namespace) [ $# -ge 2 ] || { err "--namespace 需要一个值"; return 1; }; ns="$2"; shift ;;
            --namespace=*) ns="${1#--namespace=}" ;;
            -*) err "未知参数：$1"; return 1 ;;
            *) src="$1" ;;
        esac
        shift
    done
    [ -n "$src" ] || { err "缺少 source-ref"; return 1; }
    new_pr="$(parse_source_ref "$src")" || { err "无法识别的 source-ref：$src"; return 1; }

    if [ -f "$MANIFEST" ]; then
        # 去重：按归一化后的 url+ref 比较，而非原始字符串
        while IFS=$'\t' read -r mns msrc mlineno; do
            [ -n "$msrc" ] || continue
            if exist_pr="$(parse_source_ref "$msrc" 2>/dev/null || true)" && [ -n "$exist_pr" ] && [ "$exist_pr" = "$new_pr" ]; then
                warn "已存在同一源：$msrc"
                return 0
            fi
        done < <(read_manifest)
    else
        # 新建清单：写 sources: 头
        printf 'sources:\n' > "$MANIFEST"
    fi
    printf '%s: %s\n' "$ns" "$src" >> "$MANIFEST"
    echo "已添加：$ns  <-  $src"
    cmd_apply
}

cmd_remove() {
    local target="$1" prune=0 cache_to_prune="" tmp pr pu base
    [ -n "$target" ] || { err "remove 需要 namespace"; return 1; }
    shift
    [ $# -gt 0 ] && [ "$1" = "--prune" ] && prune=1
    [ -f "$MANIFEST" ] || { err "无清单 $MANIFEST"; return 1; }

    # --prune 时先记下该 namespace 对应源的缓存路径（缓存 key = url slug）
    if [ "$prune" = 1 ]; then
        while IFS=$'\t' read -r ns src mlineno; do
            [ "$ns" = "$target" ] || continue
            pr="$(parse_source_ref "$src" 2>/dev/null || true)"
            [ -n "$pr" ] || continue
            pu="${pr%%$'\t'*}"
            cache_to_prune="$CACHE_ROOT/$(slugify "$pu")"
        done < <(read_manifest)
    fi

    # 卸载该 namespace 的所有链接（只删 symlink，保护真实目录）
    # 精确匹配：链接名 = "<namespace>.<技能名>"，技能名不含 "."（kebab-case 约定）。
    # 因此 namespace 部分 = 去掉最后一个 "." 及其后。用 ${base%.*} 严格比较，避免
    # target=foo 时误删 namespace="foo.bar" 的链接 "foo.bar.xxx"。
    for root in "${AGENT_SKILL_ROOTS[@]}"; do
        [ -d "$root" ] || continue
        for entry in "$root"/"$target".*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            base="$(basename "$entry")"
            [ "${base%.*}" = "$target" ] || continue
            if [ -L "$entry" ]; then
                rm -f "$entry"
                echo "已卸载：$entry"
            fi
        done
    done

    # 从清单删除该 namespace 的条目行（保留注释与 sources: 头）
    tmp="$(mktemp)"
    while IFS= read -r line; do
        key="$(printf '%s' "${line%%: *}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        if [ "$key" = "$target" ]; then
            continue
        fi
        printf '%s\n' "$line"
    done < "$MANIFEST" > "$tmp"
    mv "$tmp" "$MANIFEST"
    echo "已移除 namespace：$target"

    if [ "$prune" = 1 ] && [ -n "$cache_to_prune" ] && [ -d "$cache_to_prune" ]; then
        rm -rf "$cache_to_prune"
        echo "已删除缓存：$cache_to_prune"
    fi
}

cmd_update() {
    # update 等价全量 apply（幂等同步所有源）。<namespace> 参数仅做存在性提示，
    # 不改变同步范围（单个源更新可直接 remove+add，或编辑清单后 apply）。
    local ns="${1:-}"
    if [ -n "$ns" ] && [ "$ns" != "--all" ]; then
        if [ -f "$MANIFEST" ] && ! grep -qE "^[[:space:]]*${ns}[[:space:]]*:" "$MANIFEST"; then
            warn "清单中无显式 namespace '$ns'；仍执行全量同步。"
        fi
    fi
    cmd_apply
}

cmd_list() {
    local ns src mlineno pr url ref
    [ -f "$MANIFEST" ] || { echo "无清单（$MANIFEST）"; return 0; }
    printf 'namespace\tsource-ref\tURL\tref\n'
    while IFS=$'\t' read -r ns src mlineno; do
        pr="$(parse_source_ref "$src" 2>/dev/null || true)"
        if [ -n "$pr" ]; then
            url="${pr%%$'\t'*}"; ref="${pr#*$'\t'}"
        else
            url="<解析失败>"; ref=""
        fi
        printf '%s\t%s\t%s\t%s\n' "$ns" "$src" "$url" "$ref"
    done < <(read_manifest)
}

cmd="${1:-apply}"
shift || true
case "$cmd" in
    apply)   cmd_apply "$@" ;;
    add)     cmd_add "$@" ;;
    remove)  cmd_remove "$@" ;;
    update)  cmd_update "$@" ;;
    list)    cmd_list "$@" ;;
    *)
        echo "用法：external-skills.sh <apply|add|remove|update|list> [参数...]" >&2
        echo "  apply                    同步 + 冲突预检 + 挂载（缺省）" >&2
        echo "  add <source-ref> [--namespace N]   新增外部源" >&2
        echo "  remove <namespace> [--prune]       移除外部源（--prune 连缓存一起删）" >&2
        echo "  update [<namespace>|--all]         重新同步（全量）" >&2
        echo "  list                    列出清单与解析结果" >&2
        exit 2
        ;;
esac
