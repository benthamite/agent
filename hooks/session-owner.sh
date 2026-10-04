# Sourced by the Claude Code hook scripts.
#
# A `claude -p' run from a session's shell inherits the session's
# environment, so its hooks would report as that session: its Stop would
# mark the session waiting mid-turn.  Emacs writes the session id the
# session's status line reports to <key>.sid in the status directory, and
# a hook whose payload names another session is foreign.  Without that
# file, or without a session id in the payload, nothing is foreign.

# Succeed when hook payload $1 belongs to another Claude session.
agent_hook_foreign_p() {
  local uuid=${AGENT_SESSION_UUID:-}
  [ -n "$uuid" ] || return 1
  local dir=${AGENT_CLAUDE_STATUS_DIR:-${TMPDIR:-/tmp}/claude-code-status}
  local key expected actual
  key=$(printf '%s' "$uuid" | shasum -a 256 | awk '{print $1}')
  expected=$(cat "$dir/$key.sid" 2>/dev/null) || return 1
  [ -n "$expected" ] || return 1
  actual=$(printf '%s' "$1" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
  [ -n "$actual" ] && [ "$actual" != "$expected" ]
}
