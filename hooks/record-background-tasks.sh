#!/bin/bash
# Record the background tasks Claude Code reports for this session.
# Called by the Stop and SubagentStop hooks, whose payload carries
# Claude Code's own `background_tasks' list.  The payload is written
# whole to a file keyed like the statusline file; Emacs reads the list
# from it.  The write is a rename, so Emacs never reads a partial file.
# A payload from another session, such as a `claude -p' the session ran,
# is dropped; see session-owner.sh.
uuid=${AGENT_SESSION_UUID:-}
if [ -z "$uuid" ]; then
  cat >/dev/null
  exit 0
fi
dir=${AGENT_CLAUDE_STATUS_DIR:-${TMPDIR:-/tmp}/claude-code-status}
key=$(printf '%s' "$uuid" | shasum -a 256 | awk '{print $1}')
mkdir -p "$dir" || exit 0
payload=$(cat) || exit 0
. "$(dirname "$0")/session-owner.sh"
agent_hook_foreign_p "$payload" && exit 0
tmp=$(mktemp "$dir/.$key.tasks.XXXXXX") || exit 0
if printf '%s\n' "$payload" >"$tmp"; then
  mv -f "$tmp" "$dir/$key.tasks.json"
else
  rm -f "$tmp"
fi
