#!/bin/bash
# Forward a Claude Code turn-lifecycle hook to Emacs as a session event.
# Usage: notify-emacs-state.sh TYPE, where TYPE is `activity' or `stop'.
# Called by the UserPromptSubmit, PreToolUse, PostToolUse,
# PostToolUseFailure, SubagentStart, and StopFailure hooks; intended to
# run through fire-and-forget.sh so the CLI doesn't block on emacsclient.
# The send time travels with the event because fire-and-forget delivery
# is unordered: Emacs discards an event sent before the session last
# started waiting.
payload=$(cat)
type=$1
case $type in
  activity|stop) ;;
  *) exit 0 ;;
esac
buf=${CLAUDE_BUFFER_NAME:-}
[ -n "$buf" ] || exit 0
. "$(dirname "$0")/session-owner.sh"
agent_hook_foreign_p "$payload" && exit 0
# Emacs mirrors each session's state to a file keyed like the statusline
# file.  An `activity' event for a session Emacs already marks busy changes
# nothing, so skip the emacsclient call; a missing or unreadable file sends.
if [ "$type" = activity ] && [ -n "${AGENT_SESSION_UUID:-}" ]; then
  state_dir=${AGENT_CLAUDE_STATUS_DIR:-${TMPDIR:-/tmp}/claude-code-status}
  key=$(printf '%s' "$AGENT_SESSION_UUID" | shasum -a 256 | awk '{print $1}')
  [ "$(cat "$state_dir/$key.state" 2>/dev/null)" = busy ] && exit 0
fi
sent=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
# Escape backslashes and double-quotes so the value is safe inside an Elisp string.
buf=${buf//\\/\\\\}
buf=${buf//\"/\\\"}
emacsclient --eval "(claude-code-handle-hook '${type} \"${buf}\" \"${sent}\")" >/dev/null 2>&1 || true
