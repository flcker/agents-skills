#!/usr/bin/env bash
# mslearn.sh — Query Microsoft Learn official docs via the public MCP HTTP endpoint.
# No auth required. Only depends on curl + standard text tools (Git Bash compatible).
#
# Usage:
#   mslearn.sh search "<query>"            # semantic search over official docs
#   mslearn.sh code "<query>" [language]   # search official code samples (cpp csharp python ...)
#   mslearn.sh fetch "<learn-url>"         # fetch a full doc page as markdown
#
# Output: raw JSON from the MCP tool call (SSE framing already stripped).
# For search/code, the payload lives at result.content[0].text as an escaped JSON string.

set -euo pipefail

ENDPOINT="https://learn.microsoft.com/api/mcp"

die() { echo "ERROR: $*" >&2; exit 1; }

[ $# -ge 2 ] || die "usage: mslearn.sh search|code|fetch <query-or-url> [language]"

CMD="$1"; ARG="$2"; LANG_ARG="${3:-}"

case "$CMD" in
  search) TOOL="microsoft_docs_search" ;;
  code)   TOOL="microsoft_code_sample_search" ;;
  fetch)  TOOL="microsoft_docs_fetch" ;;
  *) die "unknown command: $CMD (expected search|code|fetch)" ;;
esac

# Escape user input for embedding inside a JSON string.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

case "$CMD" in
  search) ARG_JSON="{\"query\":\"$(esc "$ARG")\"}" ;;
  code)   if [ -n "$LANG_ARG" ]; then
            ARG_JSON="{\"query\":\"$(esc "$ARG")\",\"language\":\"$(esc "$LANG_ARG")\"}"
          else
            ARG_JSON="{\"query\":\"$(esc "$ARG")\"}"
          fi ;;
  fetch)  ARG_JSON="{\"url\":\"$(esc "$ARG")\"}" ;;
esac

# Step 1: MCP initialize handshake. The session id comes back in a response header.
# Bodies are piped via stdin (--data-binary @-): passing non-ASCII through curl's
# -d argument corrupts UTF-8 on Windows (mingw curl re-encodes argv).
SID=$(printf '%s' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"claude-mslearn-skill","version":"1.0"}}}' \
  | curl -s -o /dev/null -D - -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  --data-binary @- \
  | grep -i '^mcp-session-id:' | head -1 | sed 's/^[^:]*: *//' | tr -d '\r\n')

[ -n "$SID" ] || die "initialize failed: no mcp-session-id header (endpoint unreachable or API changed?)"

# Step 2: call the tool, strip SSE framing, print the JSON payload.
printf '%s' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$TOOL\",\"arguments\":$ARG_JSON}}" \
  | curl -s -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "mcp-session-id: $SID" \
  --data-binary @- \
  | sed -n 's/^data: //p'
