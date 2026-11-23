#!/bin/bash
# Record the background work Claude Code reports for this session.
#
# Stop and SubagentStop payloads carry Claude Code's own
# `background_tasks' list.  The payload is written whole to a file keyed
# like the statusline file; Emacs reads the list from it.  The write is
# a rename, so Emacs never reads a partial file.
#
# That list reports an agent-team teammate as running for as long as it
# exists, idle or not.  So the subagents and teammates working right now
# are kept apart, as one empty file per agent_id in <key>.agents/:
# SubagentStart, which also fires each time a teammate takes a new
# message, creates the agent's file; SubagentStop and TeammateIdle
# remove it.  Emacs counts teammate tasks only while that directory has
# an entry.
#
# The session is the one the payload names when Emacs recorded it, and
# otherwise the inherited one, whose payloads from another session, such
# as a `claude -p' the session ran, are dropped; see session-owner.sh.
payload=$(cat) || exit 0
. "$(dirname "$0")/session-owner.sh"
agent_hook_foreign_p "$payload" && exit 0
uuid=${AGENT_SESSION_UUID:-}
[ -n "$uuid" ] || exit 0
dir=${AGENT_CLAUDE_STATUS_DIR:-${TMPDIR:-/tmp}/claude-code-status}
key=$(agent_hook_key "$uuid")
mkdir -p "$dir" || exit 0
fields=$(printf '%s' "$payload" | perl -MJSON::PP -0777 -ne \
  'my $d = eval { decode_json($_) }; exit unless ref $d eq "HASH";
   my ($e, $a) = @$d{qw(hook_event_name agent_id)};
   $a = "" unless defined $a && !ref $a && $a =~ /\A[\w-]+\z/;
   print "$e $a" if defined $e && !ref $e')
event=${fields%% *}
agent=${fields#* }
agents="$dir/$key.agents"
case $event in
  SubagentStart)
    [ -n "$agent" ] && mkdir -p "$agents" && : >"$agents/$agent"
    exit 0 ;;
  TeammateIdle)
    [ -n "$agent" ] && rm -f "$agents/$agent"
    exit 0 ;;
  SubagentStop)
    [ -n "$agent" ] && rm -f "$agents/$agent" ;;
esac
tmp=$(mktemp "$dir/.$key.tasks.XXXXXX") || exit 0
if printf '%s\n' "$payload" >"$tmp"; then
  mv -f "$tmp" "$dir/$key.tasks.json"
else
  rm -f "$tmp"
fi
