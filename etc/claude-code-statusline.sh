#!/bin/bash
# Claude Code statusline script.
# Reads JSON from stdin and writes it to a temp file for Emacs polling.
# The file is keyed by AGENT_SESSION_UUID, set per CLI process by
# agent-claude, so a restarted session that reuses a buffer name does
# not inherit a dead process's status file.  Falls back to
# CLAUDE_BUFFER_NAME for sessions started without the UUID.
# Requires: shasum or sha256sum

input=$(cat)
KEY=${AGENT_SESSION_UUID:-$CLAUDE_BUFFER_NAME}
if command -v shasum >/dev/null 2>&1; then
    SAFE_NAME=$(printf '%s' "$KEY" | shasum -a 256 | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
    SAFE_NAME=$(printf '%s' "$KEY" | sha256sum | awk '{print $1}')
else
    echo "agent: neither shasum nor sha256sum is available" >&2
    exit 1
fi
STATUS_DIR=${AGENT_CLAUDE_STATUS_DIR:-${TMPDIR:-/tmp}/claude-code-status}
mkdir -p "$STATUS_DIR"
printf '%s' "$input" > "$STATUS_DIR/${SAFE_NAME}.json"
