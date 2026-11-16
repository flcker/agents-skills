#!/usr/bin/env bash
# qtdocs.sh — Query Qt official docs (doc.qt.io) via structured browsing + page scraping.
# No auth required. Only depends on curl + standard text tools (Git Bash / macOS / Linux compatible).
#
# Usage:
#   qtdocs.sh [--version V|-v V] classes
#   qtdocs.sh [--version V|-v V] qmltypes
#   qtdocs.sh [--version V|-v V] modules
#   qtdocs.sh [--version V|-v V] qmlmodules
#   qtdocs.sh [--version V|-v V] module <name>
#   qtdocs.sh [--version V|-v V] qmlmodule <name>
#   qtdocs.sh [--version V|-v V] class <name> [member]
#   qtdocs.sh [--version V|-v V] type <name> [member]
#   qtdocs.sh [--version V|-v V] fetch <path-or-url>
#
# Output: a single JSON object on stdout. Exit codes: 0 ok / 1 usage / 2 no match or
# ambiguous / 3 network or HTTP error.

set -euo pipefail

VERSION=""
BASE=""

die_usage() { echo "ERROR: $*" >&2; echo "usage: qtdocs.sh [--version V|-v V] classes|qmltypes|modules|qmlmodules|module <name>|qmlmodule <name>|class <name> [member]|type <name> [member]|fetch <path-or-url>" >&2; exit 1; }

# ---- argument parsing -----------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --version|-v)
      [ $# -ge 2 ] || die_usage "missing value for $1"
      VERSION="$2"; shift 2 ;;
    --*|-*)
      die_usage "unknown option: $1" ;;
    *)
      break ;;
  esac
done

CMD="${1:-}"; shift || true
[ -n "$CMD" ] || die_usage "missing command"

# ---- version / base URL ---------------------------------------------------
base_for_version() {
  local v="$1" major
  major="${v%%.*}"
  if (( major >= 6 )); then
    printf 'https://doc.qt.io/qt-%s' "$v"
  else
    printf 'https://doc.qt.io/archives/qt-%s' "$v"
  fi
}

VERSION="${VERSION:-${QTDOCS_VERSION:-6.8}}"
BASE="$(base_for_version "$VERSION")"

# ---- HTTP helpers ---------------------------------------------------------
# fetch_url URL -> body on stdout (exits 3 on non-200)
fetch_url() {
  local url="$1" body code
  body=$(curl -sL -w $'\n%{http_code}' "$url") || { echo "ERROR: network error fetching $url" >&2; exit 3; }
  code="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [ "$code" != "200" ]; then
    echo "ERROR: HTTP $code fetching $url" >&2
    exit 3
  fi
  printf '%s\n' "$body"
}

# fetch_url_soft URL -> body on stdout, returns 0 on 200, 1 otherwise (no exit)
fetch_url_soft() {
  local url="$1" body code
  body=$(curl -sL -w $'\n%{http_code}' "$url") || return 1
  code="${body##*$'\n'}"
  body="${body%$'\n'*}"
  [ "$code" = "200" ] || return 1
  printf '%s\n' "$body"
  return 0
}

get() { fetch_url "$BASE/$1"; }

# ---- text helpers ---------------------------------------------------------
# esc STR -> JSON string literal (single line)
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# jsonstr: read stdin (multi-line), emit a JSON string literal on stdout
jsonstr() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/$/\\n/' | tr -d '\n' | sed 's/\\n$//'
}

# extract_main HTML -> the article body (from <h1 class="title"> or
# <div class="context mainContent"> to </article>)
extract_main() {
  local out
  out=$(printf '%s' "$1" | sed -n '/<h1 class="title"/,/<\/article>/p')
  if [ -z "$out" ]; then
    out=$(printf '%s' "$1" | sed -n '/<div class="context mainContent"/,/<\/article>/p')
  fi
  printf '%s\n' "$out"
}

# html_to_md: read stdin (HTML), emit markdown on stdout.
html_to_md() {
  awk '
    function dec(s,  t){ t=s; gsub(/&lt;/,"<",t); gsub(/&gt;/,">",t); gsub(/&quot;/,"\"",t); gsub(/&#39;/,"\047",t); gsub(/&nbsp;/," ",t); gsub(/&amp;/,"&",t); return t }
    function strip(s){ gsub(/<[^>]*>/,"",s); return s }
    function collapse(s){ gsub(/[ \t]+/," ",s); sub(/^ /,"",s); sub(/ $/,"",s); return s }
    function codeclean(s){ gsub(/<\/?span[^>]*>/,"",s); gsub(/<\/?a[^>]*>/,"",s); gsub(/<[^>]*>/,"",s); return dec(s) }
    {
      line=$0
      # --- pre block handling (fenced code) ---
      if (!inpre && line ~ /<pre[ >]/) {
        sub(/<pre[^>]*>/,"",line)
        inpre=1; buf=""
        if (line ~ /<\/pre>/) {
          sub(/<\/pre>.*/,"",line)
          print "```"; print codeclean(line); print "```"
          inpre=0; next
        }
        if (line != "") buf=buf codeclean(line) "\n"
        next
      }
      if (inpre) {
        if (line ~ /<\/pre>/) {
          sub(/<\/pre>.*/,"",line)
          buf=buf codeclean(line)
          sub(/\n$/,"",buf)
          print "```"; print buf; print "```"
          inpre=0
        } else {
          buf=buf codeclean(line) "\n"
        }
        next
      }
      # --- headings ---
      if (line ~ /<h1/) { print "# " collapse(dec(strip(line))); next }
      if (line ~ /<h2/) { print "## " collapse(dec(strip(line))); next }
      if (line ~ /<h3/) { print "### " collapse(dec(strip(line))); next }
      if (line ~ /<h4/) { print "#### " collapse(dec(strip(line))); next }
      # --- list item ---
      if (line ~ /<li/) { print "- " collapse(dec(strip(line))); next }
      # --- paragraph / generic text ---
      gsub(/<br[^>]*>/, "\n", line)
      gsub(/<p[^>]*>/, "", line)
      gsub(/<\/p>/, "\n\n", line)
      gsub(/<[^>]*>/, "", line)
      line=dec(line)
      # collapse runs of blank lines, drop fully-blank-only noise lines
      if (line ~ /[^[:space:]]/) print collapse(line)
    }
  '
}

# ---- list page pair helpers ----------------------------------------------
# list_dd_pairs HTML -> "href<TAB>name" lines for <dd><a href>name</a></dd>
list_dd_pairs() {
  printf '%s\n' "$1" | grep -o '<dd><a href="[^"]*">[^<]*</a></dd>' \
    | sed 's/<dd><a href="\([^"]*\)">\([^<]*\)<\/a><\/dd>/\1\t\2/'
}

# list_module_pairs HTML -> "href<TAB>name" lines for tblName cells
list_module_pairs() {
  printf '%s\n' "$1" | sed -n 's/.*<td class="tblName"[^>]*><p><a href="\([^"]*\)">\([^<]*\)<\/a><\/p><\/td>.*/\1\t\2/p'
}

# list_module_desc HTML LINE -> description text (may be empty)
module_desc_of() {
  local d
  d=$(printf '%s' "$1" | sed -n 's/.*<td class="tblDescr"><p>\(.*\)<\/p><\/td>.*/\1/p')
  [ -n "$d" ] || { printf ''; return; }
  printf '%s' "$d" | sed -e 's/&lt;/</g;s/&gt;/>/g;s/&quot;/"/g;s/&#39;/'"'"'/g;s/&nbsp;/ /g;s/&amp;/\&/g;s/<[^>]*>//g' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

# ---- module name resolution ----------------------------------------------
# resolve_module NAME SUFFIX PAGE KIND -> prints href (matched) on stdout; exit 2 on miss/ambiguous
resolve_module() {
  local name="$1" suffix="$2" page="$3" kind="$4"
  local html norm cands candidate hrefs

  html=$(get "$page")
  hrefs=$(list_module_pairs "$html" | cut -f1)

  norm=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -d ' _-')

  cands="qt${norm}${suffix}"
  case "$norm" in
    qt*) cands="$cands"$'\n'"${norm}${suffix}" ;;
  esac
  case "$norm" in
    *module) cands="$cands"$'\n'"${norm}.html" ;;
  esac

  # candidate exact-href match (hrefs are unique in the list)
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if printf '%s\n' "$hrefs" | grep -Fxq "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done <<< "$cands"

  # fallback: anchor-text exact match (case-insensitive, whitespace collapsed)
  local foldname folded matched=""
  foldname=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
  while IFS=$'\t' read -r h n; do
    folded=$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
    if [ "$folded" = "$foldname" ]; then
      matched="$matched
$n	$h"
    fi
  done <<< "$(list_module_pairs "$html")"
  matched=$(printf '%s\n' "$matched" | sed '/^$/d')

  local count
  count=$(printf '%s\n' "$matched" | grep -c . || true)
  if [ "$count" = "1" ]; then
    printf '%s' "$(printf '%s\n' "$matched" | cut -f2)"
    return 0
  elif [ "$count" = "0" ]; then
    echo "ERROR: ${kind} '${name}' not found" >&2
    exit 2
  else
    echo "ERROR: ambiguous ${kind} '${name}':" >&2
    printf '%s\n' "$matched" | sed 's/^/  /' >&2
    exit 2
  fi
}

# ---- subcommands ----------------------------------------------------------
cmd_classes() {
  local html pairs count href name items first
  html=$(get "classes.html")
  pairs=$(list_dd_pairs "$html")
  count=$(printf '%s\n' "$pairs" | grep -c . || true)
  items=""; first=1
  while IFS=$'\t' read -r href name; do
    [ $first -eq 1 ] || items="$items,"
    items="$items{\"name\":\"$(esc "$name")\",\"href\":\"$(esc "$href")\"}"
    first=0
  done <<< "$pairs"
  printf '{"version":"%s","count":%s,"items":[%s]}\n' "$VERSION" "$count" "$items"
}

cmd_qmltypes() {
  local html pairs count href name items first
  html=$(get "qmltypes.html")
  pairs=$(list_dd_pairs "$html")
  count=$(printf '%s\n' "$pairs" | grep -c . || true)
  items=""; first=1
  while IFS=$'\t' read -r href name; do
    [ $first -eq 1 ] || items="$items,"
    items="$items{\"name\":\"$(esc "$name")\",\"href\":\"$(esc "$href")\"}"
    first=0
  done <<< "$pairs"
  printf '{"version":"%s","count":%s,"items":[%s]}\n' "$VERSION" "$count" "$items"
}

cmd_modules_impl() {
  # $1 = page (modules-cpp.html / modules-qml.html), $2 = list name
  local page="$1" html count line href name desc items first
  html=$(get "$page")
  count=0; items=""; first=1
  while IFS= read -r line; do
    case "$line" in
      *tblName*) ;;
      *) continue ;;
    esac
    href=$(printf '%s' "$line" | sed -n 's/.*<td class="tblName"[^>]*><p><a href="\([^"]*\)">[^<]*<\/a><\/p><\/td>.*/\1/p')
    name=$(printf '%s' "$line" | sed -n 's/.*<td class="tblName"[^>]*><p><a href="[^"]*">\([^<]*\)<\/a><\/p><\/td>.*/\1/p')
    [ -n "$href" ] || continue
    desc=$(module_desc_of "$line")
    [ $first -eq 1 ] || items="$items,"
    items="$items{\"name\":\"$(esc "$name")\",\"href\":\"$(esc "$href")\",\"description\":\"$(esc "$desc")\"}"
    count=$((count+1)); first=0
  done <<< "$html"
  printf '{"version":"%s","count":%s,"items":[%s]}\n' "$VERSION" "$count" "$items"
}

cmd_modules() { cmd_modules_impl "modules-cpp.html"; }
cmd_qmlmodules() { cmd_modules_impl "modules-qml.html"; }

cmd_module() {
  local name href html region pairs count h n items first
  name="${1:-}"; [ -n "$name" ] || die_usage "module requires <name>"
  href=$(resolve_module "$name" "-module.html" "modules-cpp.html" "module")
  html=$(get "$href")
  # capture from <h2 id="classes"> up to (but excluding) <h2 id="details">
  region=$(printf '%s\n' "$html" | awk '
    /<h2 id="classes"/ { f=1 }
    f && /<h2 id="details"/ { next }
    f { print }
  ')
  pairs=$(list_module_pairs "$region")
  count=0; items=""; first=1
  while IFS=$'\t' read -r h n; do
    [ -n "$h" ] || continue
    [ $first -eq 1 ] || items="$items,"
    items="$items{\"name\":\"$(esc "$n")\",\"href\":\"$(esc "$h")\"}"
    count=$((count+1)); first=0
  done <<< "$pairs"
  printf '{"module":"%s","href":"%s","count":%s,"classes":[%s]}\n' "$(esc "$name")" "$(esc "$href")" "$count" "$items"
}

cmd_qmlmodule() {
  local name href html region pairs count h n items first
  name="${1:-}"; [ -n "$name" ] || die_usage "qmlmodule requires <name>"
  href=$(resolve_module "$name" "-qmlmodule.html" "modules-qml.html" "qmlmodule")
  html=$(get "$href")
  # capture value-types and object-types sections (each to its next <h2)
  region=$(printf '%s\n' "$html" | awk '
    /<h2 id="value-types"/ { f=1 }
    /<h2 id="object-types"/ { f=1 }
    f && /<h2 / && !/<h2 id="value-types"/ && !/<h2 id="object-types"/ { f=0; next }
    f { print }
  ')
  pairs=$(list_module_pairs "$region")
  count=0; items=""; first=1
  while IFS=$'\t' read -r h n; do
    [ -n "$h" ] || continue
    [ $first -eq 1 ] || items="$items,"
    items="$items{\"name\":\"$(esc "$n")\",\"href\":\"$(esc "$h")\"}"
    count=$((count+1)); first=0
  done <<< "$pairs"
  printf '{"module":"%s","href":"%s","count":%s,"types":[%s]}\n' "$(esc "$name")" "$(esc "$href")" "$count" "$items"
}

# resolve_class NAME LISTPAGE KIND -> href (stdout); class falls back to lowercase.html, type does not
resolve_class() {
  local name="$1" page="$2" kind="$3"
  local html pairs matched count href
  html=$(get "$page")
  pairs=$(list_dd_pairs "$html")
  matched=$(printf '%s\n' "$pairs" | awk -F'\t' -v n="$name" '$2==n {print}')
  count=$(printf '%s\n' "$matched" | grep -c . || true)
  if [ "$count" = "1" ]; then
    printf '%s' "$(printf '%s\n' "$matched" | cut -f1)"
    return 0
  elif [ "$count" -gt 1 ]; then
    echo "ERROR: ambiguous ${kind} '${name}':" >&2
    printf '%s\n' "$matched" | sed 's/^/  /' >&2
    exit 2
  fi
  if [ "$kind" = "class" ]; then
    local lo
    lo=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    if fetch_url_soft "$BASE/$lo.html" >/dev/null; then
      printf '%s' "$lo.html"
      return 0
    fi
  fi
  echo "ERROR: ${kind} '${name}' not found" >&2
  exit 2
}

# class member: h3 anchor id
class_member_region() {
  local html="$1" member="$2" cname="$3" url="$4"
  local h3lines exact prefix mid region sig
  h3lines=$(printf '%s\n' "$html" | grep '<h3 class="fn"')
  exact=$(printf '%s\n' "$h3lines" | grep -F "id=\"$member\"")
  local n
  n=$(printf '%s\n' "$exact" | grep -c . || true)
  if [ "$n" = "1" ]; then
    mid="$member"
  elif [ "$n" -gt 1 ]; then
    echo "ERROR: ambiguous member '$member' on $cname:" >&2
    printf '%s\n' "$exact" | sed 's/<[^>]*>//g; s/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' | sed 's/^/  /' >&2
    exit 2
  else
    prefix=$(printf '%s\n' "$h3lines" | grep -F "id=\"$member" | grep -vF "id=\"$member\"")
    n=$(printf '%s\n' "$prefix" | grep -c . || true)
    if [ "$n" = "1" ]; then
      mid=$(printf '%s' "$prefix" | sed -n 's/.*id="\([^"]*\)".*/\1/p')
      exact="$prefix"
    elif [ "$n" -gt 1 ]; then
      echo "ERROR: ambiguous member '$member' on $cname:" >&2
      printf '%s\n' "$prefix" | sed 's/<[^>]*>//g; s/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//' | sed 's/^/  /' >&2
      exit 2
    else
      echo "ERROR: member '$member' not found on $cname (run 'class $cname' for the full member list)" >&2
      exit 2
    fi
  fi

  region=$(printf '%s\n' "$html" | awk -v id="$mid" '
    BEGIN { incap=0; done=0 }
    done { next }
    /<h3 class="fn"/ {
      if (incap) { done=1; next }
      if (index($0, "id=\"" id "\"")) incap=1
    }
    /<h2/ { if (incap) { done=1; next } }
    incap { print }
  ')
  sig=$(printf '%s' "$exact" | sed 's/<[^>]*>//g' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
  printf '{"class":"%s","member":"%s","signature":"%s","markdown":"%s","url":"%s"}\n' \
    "$(esc "$cname")" "$(esc "$member")" "$(esc "$sig")" \
    "$(printf '%s\n' "$region" | html_to_md | jsonstr)" "$(esc "$url")"
}

cmd_class() {
  local name member href html
  name="${1:-}"; [ -n "$name" ] || die_usage "class requires <name>"
  member="${2:-}"
  href=$(resolve_class "$name" "classes.html" "class")
  html=$(get "$href")
  local url="$BASE/$href"
  if [ -n "$member" ]; then
    class_member_region "$html" "$member" "$name" "$url"
    return
  fi
  local main title
  main=$(extract_main "$html")
  title=$(printf '%s\n' "$main" | grep '<h1 class="title"' | head -n 1 | sed 's/<[^>]*>//g' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
  printf '{"class":"%s","title":"%s","url":"%s","markdown":"%s"}\n' \
    "$(esc "$name")" "$(esc "$title")" "$(esc "$url")" \
    "$(printf '%s\n' "$main" | html_to_md | jsonstr)"
}

# QML type member: <tr class="odd" id="MEMBER-KIND"> to <!-- @@@MEMBER -->
type_member_region() {
  local html="$1" member="$2" tname="$3" url="$4"
  local kind anchor found region sig

  found=""
  for kind in prop method signal; do
    anchor="<tr class=\"odd\" id=\"$member-$kind\" valign=\"top\">"
    if printf '%s\n' "$html" | grep -Fq "$anchor"; then
      found="$member-$kind"
      break
    fi
  done
  if [ -z "$found" ]; then
    echo "ERROR: member '$member' not found on $tname" >&2
    exit 2
  fi

  region=$(printf '%s\n' "$html" | awk -v anchor="$found" '
    BEGIN { incap=0; done=0 }
    done { next }
    index($0, "id=\"" anchor "\"") && !incap { incap=1 }
    incap && index($0, "<!-- @@@") { print; done=1; next }
    incap { print }
  ')
  # signature from the tblQmlPropNode / tblQmlFuncNode cell
  sig=$(printf '%s\n' "$region" | awk '/<td class="tblQml(Prop|Func)Node">/{f=1} f{print} f&&/<\/td>/{f=0}' \
    | sed 's/<[^>]*>//g' | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
  printf '{"type":"%s","member":"%s","signature":"%s","markdown":"%s","url":"%s"}\n' \
    "$(esc "$tname")" "$(esc "$member")" "$(esc "$sig")" \
    "$(printf '%s\n' "$region" | html_to_md | jsonstr)" "$(esc "$url")"
}

cmd_type() {
  local name member href html
  name="${1:-}"; [ -n "$name" ] || die_usage "type requires <name>"
  member="${2:-}"
  href=$(resolve_class "$name" "qmltypes.html" "type")
  html=$(get "$href")
  local url="$BASE/$href"
  if [ -n "$member" ]; then
    type_member_region "$html" "$member" "$name" "$url"
    return
  fi
  local main title
  main=$(extract_main "$html")
  title=$(printf '%s\n' "$main" | grep '<h1 class="title"' | head -n 1 | sed 's/<[^>]*>//g' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
  printf '{"type":"%s","title":"%s","url":"%s","markdown":"%s"}\n' \
    "$(esc "$name")" "$(esc "$title")" "$(esc "$url")" \
    "$(printf '%s\n' "$main" | html_to_md | jsonstr)"
}

cmd_fetch() {
  local arg url html main title
  arg="${1:-}"; [ -n "$arg" ] || die_usage "fetch requires <path-or-url>"
  case "$arg" in
    http://*|https://*) url="$arg" ;;
    *) url="$BASE/$arg" ;;
  esac
  html=$(fetch_url "$url")
  main=$(extract_main "$html")
  title=$(printf '%s\n' "$main" | grep '<h1 class="title"' | head -n 1 | sed 's/<[^>]*>//g' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
  printf '{"url":"%s","title":"%s","markdown":"%s"}\n' \
    "$(esc "$url")" "$(esc "$title")" \
    "$(printf '%s\n' "$main" | html_to_md | jsonstr)"
}

# ---- dispatch -------------------------------------------------------------
case "$CMD" in
  classes)    cmd_classes ;;
  qmltypes)   cmd_qmltypes ;;
  modules)    cmd_modules ;;
  qmlmodules) cmd_qmlmodules ;;
  module)     cmd_module "$@" ;;
  qmlmodule)  cmd_qmlmodule "$@" ;;
  class)      cmd_class "$@" ;;
  type)       cmd_type "$@" ;;
  fetch)      cmd_fetch "$@" ;;
  *) die_usage "unknown command: $CMD" ;;
esac
