# Sourced by the Claude Code hook scripts and the status line script.
#
# AGENT_SESSION_UUID and CLAUDE_BUFFER_NAME name the session that started
# this process, which need not be the session it runs.  Two cases differ:
#
# A session Claude Code runs in its background service gets the
# environment of whichever session started that service.  So Emacs
# writes, for each session id a buffer runs, <sha256 of the id>.owner in
# the status directory: the buffer's UUID on the first line and the name
# its CLI was started under on the second.  A payload naming such a
# session takes its identity from that file.
#
# A `claude -p' run from a session's shell inherits the session's
# environment, so its hooks would report as that session: its Stop would
# mark the session waiting mid-turn.  Emacs writes the session id the
# session's status line reports to <key>.sid in the status directory, and
# a hook whose payload names another session is foreign.  Without that
# file, or without a session id in the payload, nothing is foreign.

# Print the session id that hook payload $1 names, if any.
agent_hook_session_id() {
  printf '%s' "$1" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4
}

# Print the status-directory key of $1.
agent_hook_key() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

# Set AGENT_SESSION_UUID and CLAUDE_BUFFER_NAME to those of the session
# that hook payload $1 names, when Emacs recorded which buffer runs it.
# Otherwise leave them as inherited and fail.
agent_hook_adopt_owner() {
  local dir=${AGENT_CLAUDE_STATUS_DIR:-${TMPDIR:-/tmp}/claude-code-status}
  local id uuid buf
  id=$(agent_hook_session_id "$1")
  [ -n "$id" ] || return 1
  { IFS= read -r uuid && IFS= read -r buf; } \
    2>/dev/null <"$dir/$(agent_hook_key "$id").owner" || return 1
  [ -n "$uuid" ] && [ -n "$buf" ] || return 1
  AGENT_SESSION_UUID=$uuid
  CLAUDE_BUFFER_NAME=$buf
}

# Succeed when hook payload $1 belongs to a session other than the one
# to report as.  That one is the session Emacs recorded for the payload,
# whose identity is then taken, or else the inherited one.
agent_hook_foreign_p() {
  agent_hook_adopt_owner "$1" && return 1
  local uuid=${AGENT_SESSION_UUID:-}
  [ -n "$uuid" ] || return 1
  local dir=${AGENT_CLAUDE_STATUS_DIR:-${TMPDIR:-/tmp}/claude-code-status}
  local expected actual
  expected=$(cat "$dir/$(agent_hook_key "$uuid").sid" 2>/dev/null) || return 1
  [ -n "$expected" ] || return 1
  actual=$(agent_hook_session_id "$1")
  [ -n "$actual" ] && [ "$actual" != "$expected" ]
}
