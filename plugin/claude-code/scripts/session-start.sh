#!/bin/bash
# Engram — SessionStart hook for Claude Code
#
# 1. Ensures the engram server is running
# 2. Creates a session in engram
# 3. Auto-imports git-synced chunks if .engram/manifest.json exists
# 4. Injects a minimal tool-availability pointer + compacted memory context
#
# Memory protocol (when/what to save, search, close) lives in the
# `engram:memory` skill shipped with this plugin and is loaded on demand.
# Re-injecting the full protocol on every SessionStart wastes ~1.8 KB of
# context window per session, so this script only emits a short pointer.

ENGRAM_PORT="${ENGRAM_PORT:-7437}"
ENGRAM_URL="http://127.0.0.1:${ENGRAM_PORT}"

# Tunables (override via env)
#   ENGRAM_CONTEXT_LIMIT   — max observations to inject (default 8)
#   ENGRAM_CONTEXT_MAXLEN  — max chars per observation line (default 140)
CTX_LIMIT="${ENGRAM_CONTEXT_LIMIT:-8}"
CTX_MAXLEN="${ENGRAM_CONTEXT_MAXLEN:-140}"

# Load shared helpers
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/_helpers.sh"

# Read hook input from stdin
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
OLD_PROJECT=$(basename "$CWD")
PROJECT=$(detect_project "$CWD")

# Ensure engram server is running
if ! curl -sf "${ENGRAM_URL}/health" --max-time 1 > /dev/null 2>&1; then
  engram serve &>/dev/null &
  sleep 0.5
fi

# Migrate project name if it changed (one-time, idempotent)
if [ "$OLD_PROJECT" != "$PROJECT" ] && [ -n "$OLD_PROJECT" ] && [ -n "$PROJECT" ]; then
  curl -sf "${ENGRAM_URL}/projects/migrate" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg old "$OLD_PROJECT" --arg new "$PROJECT" \
      '{old_project: $old, new_project: $new}')" \
    > /dev/null 2>&1
fi

# Create session
if [ -n "$SESSION_ID" ] && [ -n "$PROJECT" ]; then
  curl -sf "${ENGRAM_URL}/sessions" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg id "$SESSION_ID" --arg project "$PROJECT" --arg dir "$CWD" \
      '{id: $id, project: $project, directory: $dir}')" \
    > /dev/null 2>&1
fi

# Auto-import git-synced chunks
if [ -f "${CWD}/.engram/manifest.json" ]; then
  engram sync --import 2>/dev/null
fi

# Fetch memory context with server-side limit + compact rendering.
#
# The /context endpoint honors `limit` (max observations) and `compact=1`
# (drop inline content preview) as of the feat/context-limit-compact change.
# Older engram binaries silently ignore the query params and return the
# full context, which this script then post-processes with awk as a
# belt-and-suspenders fallback — so the hook works against both old and
# new servers.
ENCODED_PROJECT=$(printf '%s' "$PROJECT" | jq -sRr @uri)
CONTEXT=$(curl -sf "${ENGRAM_URL}/context?project=${ENCODED_PROJECT}&limit=${CTX_LIMIT}&compact=1" --max-time 3 2>/dev/null | jq -r '.context // empty')

# Fallback post-processing for older servers that don't honor compact=1.
# On a new server the observation section is already single-line-per-bullet
# with no content preview, so this awk pass is a near no-op; on an old
# server it concatenates each bullet's continuation lines, collapses
# whitespace, caps per-bullet length at $CTX_MAXLEN, and enforces the same
# $CTX_LIMIT as a safety net.
if [ -n "$CONTEXT" ]; then
  CONTEXT=$(printf '%s\n' "$CONTEXT" | awk -v lim="$CTX_LIMIT" -v max="$CTX_MAXLEN" '
    function flush() {
      if (buf == "") return
      if (kept < lim) {
        gsub(/[[:space:]]+/, " ", buf)
        if (length(buf) > max) buf = substr(buf, 1, max - 1) "…"
        print buf
        kept++
      }
      buf = ""
    }
    /^### Recent Observations/ { flush(); in_obs = 1; print; next }
    /^### / { flush(); in_obs = 0; print; next }
    in_obs && /^- \[/ { flush(); buf = $0; next }
    in_obs { if (buf != "") buf = buf " " $0; next }
    { print }
    END { flush() }
  ')
fi

# Inject minimal protocol pointer + compacted context as additionalContext.
cat <<'PROTOCOL'
## Engram Memory — active

Core tools (always available): mem_save, mem_search, mem_context,
mem_session_summary, mem_get_observation, mem_suggest_topic_key, mem_update,
mem_session_start, mem_session_end, mem_save_prompt.
Admin tools via ToolSearch: mem_stats, mem_delete, mem_timeline, mem_capture_passive.

Full protocol (when/what to save, search rules, session close) lives in the
`engram:memory` skill — load it on demand when you need the rules.
PROTOCOL

if [ -n "$CONTEXT" ]; then
  printf '\n%s\n' "$CONTEXT"
fi

exit 0
