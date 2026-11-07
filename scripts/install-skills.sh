#!/usr/bin/env bash
#
# install-skills.sh
#
# 把本仓库 skills/ 下的所有技能，以"符号链接（symlink）"方式挂载到本机各 Agent 的
# skill 根目录，实现"一处维护（本仓库）、多处即时生效、git pull 即同步"的机制。
#
# 适用于 macOS / Linux / WSL。
# Windows（原生 PowerShell）请使用同目录下的 install-skills.ps1。
#
# 用法（在 agent-skills 仓库根目录执行）：
#   # 默认：挂载新增的技能 + 修正"指向别处"的同名错挂链接 + 清理本仓库悬空链接（幂等）
#   bash scripts/install-skills.sh
#
#   # 只挂载某一分类目录下的技能（分类 = skills/ 下的子目录，如 dev；
#   # 本轮只挂该分类，不卸载已挂载的其他分类——profile 是安装期选择，非运行态隔离）
#   bash scripts/install-skills.sh --profile dev
#
#   # --sync 为兼容别名（清理悬空链接已并入默认行为）
#   bash scripts/install-skills.sh --sync
#
# 身份识别（解决"同名技能来自不同仓库"的歧义）：
#   - 仓库根目录有一个 REPO_ID 文件，保存本仓库的稳定命名空间标识，
#     如 io.github.flcker.agents-skills。
#   - REPO_ID 值不允许包含任何空白字符（空格/制表符/换行），读取时会被剔除。
#   - 每个技能的身份 = REPO_ID + "." + 技能名，例如
#     io.github.flcker.agents-skills.qt6-rhi。
#   - 挂载点下"同名技能链接"是否归属本仓库，依据其链接目标的所属仓库 REPO_ID
#     是否等于本仓库 REPO_ID 来判断，而非仅凭技能名。
#
# WSL 说明（自动覆盖三种布局）：
#   1) 仓库与 Agent 均在 Linux 侧 —— 用普通 symlink 指向 Linux 路径。
#   2) Agent 在 Linux、仓库在 /mnt/c（Windows 侧）—— 同样用 symlink 指向 /mnt/c 路径，
#      但 Windows 侧文件系统不支持真正的符号链接目标跨文件系统读取时，部分 Agent 可能
#      无法跟随；此时脚本会给出"改用复制"的提示。
#   3) Agent 实际在 Windows 侧 —— 本脚本不适用，请改用 Windows 侧 PowerShell 脚本。

set -euo pipefail

# 解析参数：--profile <分类>（只挂载该分类下的技能）；--sync（兼容别名，清理已并入默认行为）
SYNC=0
PROFILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --sync|sync) SYNC=1 ;;
        --profile)
            [ $# -ge 2 ] && [ -n "$2" ] || { echo "错误：--profile 需要一个分类名参数" >&2; exit 1; }
            PROFILE="$2"; shift ;;
        --profile=*)
            PROFILE="${1#--profile=}"
            [ -n "$PROFILE" ] || { echo "错误：--profile 需要一个分类名参数" >&2; exit 1; } ;;
        *) echo "未知参数：$1（支持 --profile <分类>、--sync）" >&2; exit 2 ;;
    esac
    shift
done

# 仓库根目录 = 本脚本所在目录的上一级
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SKILLS_SRC="$REPO_ROOT/skills"
REPO_ID_FILE="$REPO_ROOT/REPO_ID"

echo "== agent-skills 技能挂载（*nix / symlink）=="
echo "技能源：$SKILLS_SRC"
if [ -n "$PROFILE" ]; then
    echo "模式：只挂载分类 $PROFILE 下的技能（挂载新增 + 修正错挂 + 清理悬空链接）"
else
    echo "模式：挂载新增 + 修正错挂 + 清理悬空链接（幂等；--sync 为兼容别名）"
fi

if [ ! -d "$SKILLS_SRC" ]; then
    echo "错误：未找到 skills 目录：$SKILLS_SRC" >&2
    exit 1
fi

# 分类校验：--profile 必须是 skills/ 下真实存在的目录（大小写敏感性取决于文件系统：Linux 区分，macOS APFS 默认不区分）
if [ -n "$PROFILE" ] && [ ! -d "$SKILLS_SRC/$PROFILE" ]; then
    AVAILABLE="$(ls "$SKILLS_SRC" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
    echo "错误：分类不存在：${PROFILE}（可用分类：${AVAILABLE}）" >&2
    exit 1
fi

# 读取本仓库的稳定身份标识；缺失则报错退出
if [ ! -f "$REPO_ID_FILE" ]; then
    echo "错误：未找到仓库标识文件：$REPO_ID_FILE。请先在仓库根目录创建 REPO_ID（内容为命名空间标识，如 io.github.flcker.agents-skills）。" >&2
    exit 1
fi
REPO_ID="$(tr -d '[:space:]' < "$REPO_ID_FILE")"
if [ -z "$REPO_ID" ]; then
    echo "错误：REPO_ID 内容为空：$REPO_ID_FILE" >&2
    exit 1
fi
echo "仓库身份：$REPO_ID"

# 各 Agent 的「用户级」skill 根目录（只挂载到存在的目录）。
# dsh 另会扫描项目级 <project>/.dsh/skills 与 <project>/.agents/skills，无需本脚本处理。
# 如需新增 Agent，在下面追加一行即可。
AGENT_SKILL_ROOTS=(
    "$HOME/.agents/skills"      # dsh（user-agents，兼容 Claude/skills 生态）
    "$HOME/.dsh/skills"         # dsh（user-dsh）
    "$HOME/.claude/skills"      # Claude Code
    "$HOME/.codex/skills"       # OpenAI Codex
)

# 判断当前路径是否位于 Windows 挂载点（/mnt/c 等），用于提示跨文件系统链接风险
is_windows_mount() {
    case "$1" in
        /mnt/*) return 0 ;;
        *)      return 1 ;;
    esac
}

# 从给定的技能绝对路径向上查找其所属仓库的 REPO_ID 内容；找不到返回空。
get_repo_id_of() {
    local dir
    dir="$(cd "$1" 2>/dev/null && pwd || echo "$1")"
    while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        if [ -f "$dir/REPO_ID" ]; then
            tr -d '[:space:]' < "$dir/REPO_ID" 2>/dev/null
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# 挂载一个技能到目标根目录；通过标准输出打印状态：created / ok / remounted / conflict / failed
mount_into_root() {
    local skill_name="$1" skill_abs="$2" root="$3"
    local link_path="$root/$skill_name"

    if [ ! -e "$link_path" ] && [ ! -L "$link_path" ]; then
        if ln -s "$skill_abs" "$link_path" 2>/dev/null; then
            echo "created"
        else
            echo "挂载失败：$link_path" >&2
            echo "failed"
        fi
        return 0
    fi

    # 真实目录（非链接）→ 尊重用户数据，跳过不覆盖
    if [ ! -L "$link_path" ]; then
        echo "已存在真实目录（非链接），跳过且不覆盖：$link_path" >&2
        echo "conflict"
        return 0
    fi

    local target_full
    # 解析链接目标；失败则保守跳过
    if ! target_full="$(readlink -f "$link_path" 2>/dev/null)" || [ -z "$target_full" ]; then
        echo "跳过（无法解析现有链接目标，避免误动）：$link_path" >&2
        echo "conflict"
        return 0
    fi

    # 目标归属本仓库（REPO_ID 一致）→ 正确，跳过
    local target_repo_id
    target_repo_id="$(get_repo_id_of "$target_full" 2>/dev/null || true)"
    if [ "$target_repo_id" = "$REPO_ID" ]; then
        echo "ok"
        return 0
    fi

    # 目标无法归到任何带 REPO_ID 的仓库（外部散装技能）→ 保护，绝不重挂/覆盖
    if [ -z "$target_repo_id" ]; then
        echo "已存在指向外部（无 REPO_ID）的同名链接，保护并跳过：$link_path" >&2
        echo "conflict"
        return 0
    fi

    # 目标归属"别的仓库"（REPO_ID 非空且 ≠ 本仓库）→ 错挂，删掉重挂到本仓库
    if rm -f "$link_path" && ln -s "$skill_abs" "$link_path" 2>/dev/null; then
        echo "remounted"
    else
        echo "修正错挂失败：$link_path" >&2
        echo "failed"
    fi
    return 0
}

mounted=0
skipped=0
remounted=0
failed=0
cleaned=0

# 清理各 Agent 根目录下「目标归属本仓库（REPO_ID 一致）且目标已不存在」的悬空链接（已并入默认行为，--sync 为兼容别名）。
# 只删除归本仓库且悬空的链接；外部仓库、仍有效、真实目录/文件一律保留。
# 置于挂载之前：目录结构变更（如分类迁移）后，一次运行即可完成「清旧 + 挂新」。
for root in "${AGENT_SKILL_ROOTS[@]}"; do
    [ -d "$root" ] || continue

    # 用不带尾部斜杠的 * 枚举所有条目（含悬空链接，悬空链接不会被 */ 匹配到）
    for entry in "$root"/*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue

        # 只处理 symlink；真实目录/普通文件一律保留
        if [ -L "$entry" ]; then
            target_full=""
            target_repo_id=""
            # readlink -f 要求目标存在，悬空链接会解析失败（退出码非 0）；
            # 此时改取 raw target（readlink 不带 -f），相对路径按链接所在目录拼成
            # 绝对路径（词法处理，不要求目标存在）。归属判断沿用 get_repo_id_of
            # 沿该路径向上找 REPO_ID——其对不存在的路径有词法回退，目标叶子缺失
            # 不影响祖先目录的 REPO_ID 查找。
            if ! target_full="$(readlink -f "$entry" 2>/dev/null)" || [ -z "$target_full" ]; then
                target_full="$(readlink "$entry" 2>/dev/null || true)"
                if [ -z "$target_full" ]; then
                    echo "跳过（无法读取链接目标）：$entry" >&2
                    continue
                fi
                case "$target_full" in
                    /*) ;;
                    *)  target_full="$(dirname "$entry")/$target_full" ;;
                esac
            fi

            target_repo_id="$(get_repo_id_of "$target_full" 2>/dev/null || true)"
            # 目标仓库标识 != 本仓库 → 外部技能链接，保护，绝不删
            if [ "$target_repo_id" != "$REPO_ID" ]; then
                continue
            fi

            # 归属本仓库但目标已不存在 → 悬空残留，清理
            if [ ! -e "$target_full" ]; then
                rm -rf "$entry"
                echo "已清理悬空链接：$entry"
                cleaned=$((cleaned + 1))
            fi
        fi
    done
done

# 提示一级散放（skills/<name>/ 直接含 SKILL.md）——技能须位于分类目录下，不会被挂载
for cat_dir in "$SKILLS_SRC"/*/; do
    [ -d "$cat_dir" ] || continue
    if [ -f "$cat_dir/SKILL.md" ]; then
        echo "跳过（skill 须位于分类目录下：skills/<分类>/<skill-name>/，当前在 skills/$(basename "$cat_dir")/）：$(basename "$cat_dir")" >&2
    fi
done

# 挂载单个技能目录到所有 Agent 根（供两级扫描复用）
mount_skill() {
    local skill_dir="$1" skill_name root status
    skill_name="$(basename "$skill_dir")"

    # 跳过没有 SKILL.md 的目录（非技能目录）
    if [ ! -f "$skill_dir/SKILL.md" ]; then
        echo "跳过（不是技能目录，无 SKILL.md）：$skill_name" >&2
        return 0
    fi

    for root in "${AGENT_SKILL_ROOTS[@]}"; do
        [ -d "$root" ] || continue   # Agent 未安装则跳过

        status="$(mount_into_root "$skill_name" "$skill_dir" "$root")"
        case "$status" in
            created)     echo "已挂载：$root/$skill_name -> $skill_dir"; mounted=$((mounted + 1)) ;;
            ok)          skipped=$((skipped + 1)) ;;
            remounted)   echo "已修正错挂并重挂：$root/$skill_name -> $skill_dir"; remounted=$((remounted + 1)) ;;
            conflict)    skipped=$((skipped + 1)) ;;
            failed)      failed=$((failed + 1)) ;;
        esac
    done

    # 跨文件系统（仓库在 /mnt/c 等 Windows 挂载点）时的额外提示
    if is_windows_mount "$REPO_ROOT"; then
        echo "  注意：仓库位于 Windows 挂载点（${REPO_ROOT}），若目标 Agent 无法跟随跨文件系统"
        echo "  的符号链接，请改用复制方式：cp -R \"$skill_dir\" \"<目标root>/\""
    fi
}

# 扫描技能：skills/<分类>/<技能>/（两级）；--profile 时只扫该分类
if [ -n "$PROFILE" ]; then
    for skill_dir in "$SKILLS_SRC/$PROFILE"/*/; do
        [ -d "$skill_dir" ] || continue
        mount_skill "$skill_dir"
    done
else
    for skill_dir in "$SKILLS_SRC"/*/*/; do
        [ -d "$skill_dir" ] || continue
        mount_skill "$skill_dir"
    done
fi

echo ""
echo "完成。本次挂载 $mounted 个，跳过 $skipped 个，修正错挂 $remounted 个，失败 $failed 个，清理悬空链接 $cleaned 个。"
echo "提示：本仓库 git pull 后，所有已挂载的技能自动更新，无需重装。"
echo "新增技能后重跑本脚本即可挂载；悬空链接自动清理（--sync 为兼容别名）。"

# 外部技能（清单 external-skills.yaml 非空时委托 external-skills.sh apply）
EXT_SCRIPT="$REPO_ROOT/scripts/external-skills.sh"
EXT_MANIFEST="$REPO_ROOT/external-skills.yaml"
if [ -f "$EXT_MANIFEST" ] && [ -x "$EXT_SCRIPT" ] && \
   grep -qE '^[[:space:]]*[^#[:space:]][^:]*:[[:space:]]+[^[:space:]]' "$EXT_MANIFEST"; then
    echo ""
    echo "== 外部技能同步（external-skills）=="
    if ! bash "$EXT_SCRIPT" apply; then
        echo "警告：外部技能同步失败（内建技能挂载已完成）。" >&2
    fi
fi
