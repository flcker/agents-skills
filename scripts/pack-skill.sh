#!/usr/bin/env bash
# 打包 skill 为 zip（IM 分发用，如发给 openclaw）：文件名带 SKILL.md 的 updated 日期，接收方据此判断版本
# 用法: bash scripts/pack-skill.sh <skill名> [更多...] | all | --profile <分类>
# 产出: 单技能 dist/<skill名>-<updated日期>.zip；--profile <分类> 批量打包该分类全部技能到 dist/<分类>/（逐技能独立 zip，各带版本号）
#       zip 顶层为 <分类>/<skill名>/…，解压到 skills/ 下即恢复目录结构完成安装
# 排除敏感/垃圾文件: .env（含凭证，绝不打包）、__pycache__、*.pyc、.DS_Store；.env.example 保留
# 压缩工具优先 zip 命令，回退 bsdtar（tar --version 含 bsdtar，如 macOS 自带 tar）；都没有时用 scripts/pack-skill.ps1
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SKILLS_DIR="$REPO_ROOT/skills"
DIST_DIR="$REPO_ROOT/dist"

FAIL=0

# 在 skills/<分类>/<name>/ 两级结构中按名定位技能；找到输出分类名，找不到返回非 0
locate_skill() {
  local name="$1" d
  for d in "$SKILLS_DIR"/*/"$name"/; do
    if [[ -f "${d}SKILL.md" ]]; then
      basename "$(dirname "$d")"
      return 0
    fi
  done
  return 1
}

pack_one() {
  local name="$1" cat updated zip skill_dir
  if ! cat="$(locate_skill "$name")"; then
    echo "跳过 ${name}：skills/<分类>/${name}/SKILL.md 不存在" >&2
    FAIL=1
    return 0
  fi
  skill_dir="$SKILLS_DIR/$cat/$name"
  # 读 frontmatter 的 updated（仓库约定必填；缺失视为不合规，打包文件名也依赖它）
  updated=$(grep -m1 '^updated:' "$skill_dir/SKILL.md" | sed 's/^updated:[[:space:]]*//; s/[[:space:]]*$//' || true)
  if [[ -z "$updated" ]]; then
    echo "跳过 ${name}：SKILL.md 缺少 updated 字段（仓库约定必填）" >&2
    FAIL=1
    return 0
  fi
  mkdir -p "$DIST_DIR"
  zip="$DIST_DIR/$name-$updated.zip"
  if command -v zip > /dev/null 2>&1; then
    (cd "$SKILLS_DIR" && rm -f "$zip" && zip -r -q "$zip" "$cat/$name" \
      -x '*/.env' '*__pycache__*' '*.pyc' '*/.DS_Store')
  elif tar --version 2> /dev/null | grep -qi bsdtar; then
    # bsdtar：-a 按扩展名（.zip）选格式；--exclude 按归档内路径模式匹配
    (cd "$SKILLS_DIR" && rm -f "$zip" && tar -a -cf "$zip" \
      --exclude '*/.env' --exclude '*__pycache__*' --exclude '*.pyc' --exclude '*/.DS_Store' \
      "$cat/$name")
  else
    echo "跳过 ${name}：未找到 zip 命令或 bsdtar，请用 scripts/pack-skill.ps1" >&2
    FAIL=1
    return 0
  fi
  echo "已打包 ${name} → ${DIST_DIR#$REPO_ROOT/}/$name-$updated.zip（$(du -h "$zip" | cut -f1)）"
}

# 分类批量打包：该分类下全部含 SKILL.md 的技能 → dist/<分类>/ 下逐技能 zip（文件名带各自 updated 版本号）
pack_profile() {
  local cat="$1" count=0 d name
  if [[ ! -d "$SKILLS_DIR/$cat" ]]; then
    echo "错误：分类不存在：${cat}（可用分类：$(ls "$SKILLS_DIR" | tr '\n' ' ')）" >&2
    FAIL=1
    return 0
  fi
  local names=()
  for d in "$SKILLS_DIR/$cat"/*/; do
    if [[ -f "${d}SKILL.md" ]]; then
      names+=("$(basename "$d")")
      count=$((count+1))
    fi
  done
  if [[ "$count" -eq 0 ]]; then
    echo "跳过分类 ${cat}：其下没有技能目录" >&2
    FAIL=1
    return 0
  fi
  DIST_DIR="$DIST_DIR/$cat"
  for name in "${names[@]}"; do
    pack_one "$name"
  done
  echo "分类 ${cat} 批量打包完成：$count 个 → ${DIST_DIR#$REPO_ROOT/}/"
}

if [[ $# -eq 0 ]]; then
  echo "用法: bash scripts/pack-skill.sh <skill名> [更多...] | all | --profile <分类>" >&2
  exit 1
fi
if [[ "$1" == "--profile" ]]; then
  if [[ $# -ne 2 || -z "$2" ]]; then
    echo "用法: bash scripts/pack-skill.sh --profile <分类>" >&2
    exit 1
  fi
  pack_profile "$2"
  exit "$FAIL"
fi
if [[ "$1" == "all" && $# -eq 1 ]]; then
  for d in "$SKILLS_DIR"/*/*/; do
    if [[ -f "${d}SKILL.md" ]]; then
      pack_one "$(basename "$d")"
    fi
  done
else
  for name in "$@"; do
    pack_one "$name"
  done
fi
exit "$FAIL"
