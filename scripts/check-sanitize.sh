#!/usr/bin/env bash
# Scan skills/ and scripts/ for secrets and internal identifiers before publishing.
# Exit 1 on any hit. macOS / Linux / WSL / git-bash.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hits=0

# Internal domain suffixes are NOT stored here (this file is public).
# Put one suffix per line in internal-domains.txt (gitignored).
DOMAIN_FILE="$REPO/internal-domains.txt"

# 扫描范围：skills/ 与 scripts/ 下的文本文件（.md/.sh/.ps1/.mjs/.py）
shopt -s nullglob globstar
files=()
for f in "$REPO"/skills/**/*.md "$REPO"/skills/**/*.sh "$REPO"/skills/**/*.ps1 \
         "$REPO"/skills/**/*.mjs "$REPO"/skills/**/*.py \
         "$REPO"/scripts/*.sh "$REPO"/scripts/*.ps1 "$REPO"/scripts/*.mjs "$REPO"/scripts/*.py; do
    [ -f "$f" ] && files+=("$f")
done
shopt -u globstar nullglob

if [ ${#files[@]} -eq 0 ]; then echo "no scannable files in $REPO" >&2; exit 1; fi

# 明显占位符（公开文档里常见的 token 示例）不视为密钥
is_placeholder() {
    printf '%s' "$1" | grep -qiE 'YOUR_|PLACEHOLDER|placeholder|example\.com|xxx|XXX|<\w+>' && return 0 || return 1
}

check() {
    local file="$1" label="$2" pattern="$3"
    local found
    found=$(grep -nEi "$pattern" "$file" 2>/dev/null || true)
    if [ -n "$found" ]; then
        while IFS= read -r line; do
            is_placeholder "$line" && continue
            printf 'SECRET   %s  %s  ->  %s\n' "$(realpath --relative-to="$REPO" "$file" 2>/dev/null || echo "$file")" "$label" "$line"
            hits=$((hits + 1))
        done <<< "$found"
    fi
}

for f in "${files[@]}"; do
    check "$f" "OpenAI/Anthropic key" 'sk-[A-Za-z0-9_-]{16,}'
    check "$f" "GitHub token"         'gh[pousr]_[A-Za-z0-9]{20,}'
    check "$f" "GitLab token"         'glpat-[A-Za-z0-9_-]{16,}'
    check "$f" "AWS access key"       'AKIA[0-9A-Z]{16}'
    check "$f" "Private key"          'BEGIN [A-Z ]*PRIVATE KEY'
    check "$f" "Slack token"          'xox[baprs]-[A-Za-z0-9-]{10,}'
    check "$f" "Inline password"      '(password|passwd|pwd)[[:space:]]*[:=][[:space:]]*[^[:space:]]+'
    check "$f" "Inline api key"       '(api[_-]?key|secret|token)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9+/_-]{12,}'
    check "$f" "Bearer token"         'bearer[[:space:]]+[A-Za-z0-9._-]{20,}'
    check "$f" "Private IPv4"         '\b(10\.[0-9]{1,3}|192\.168\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3})\.[0-9]{1,3}\b'
    check "$f" "IP with port"         '\b[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]{2,5}\b'
    check "$f" "Chinese mobile"       '(^|[^0-9])1[3-9][0-9]{9}([^0-9]|$)'
    check "$f" "Email"                '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
done

if [ -f "$DOMAIN_FILE" ]; then
    while IFS= read -r suffix; do
        suffix="${suffix%%#*}"
        suffix="$(echo "$suffix" | tr -d '[:space:]')"
        [ -z "$suffix" ] && continue
        esc=$(printf '%s' "$suffix" | sed 's/\./\\./g')
        for f in "${files[@]}"; do
            found=$(grep -nEi "[A-Za-z0-9.-]+\.$esc" "$f" 2>/dev/null || true)
            if [ -n "$found" ]; then
                while IFS= read -r line; do
                    printf 'INTERNAL %s  Internal domain %s  ->  %s\n' "$(basename "$f")" "$suffix" "$line"
                    hits=$((hits + 1))
                done <<< "$found"
            fi
        done
    done < "$DOMAIN_FILE"
fi

echo
if [ "$hits" -eq 0 ]; then
    echo "clean: ${#files[@]} file(s), no secrets or internal identifiers"
    exit 0
fi
echo "$hits finding(s) - fix before publishing"
exit 1
