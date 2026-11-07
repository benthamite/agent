#!/bin/bash
# Record what a Claude Code session is doing, for agent's derived status.
#
# Runs on PreToolUse.  It reads the payload and takes the time at once,
# then answers Claude Code and writes in the background, so a tool call
# never waits on it.  Each event becomes one file in the session's
# activity directory, named TIME.KIND, where KIND is `todo' (the to-do
# item in progress, empty when none is) or `action' (the tool call).
# Writes from background processes can land out of order; Emacs reads
# the file with the latest TIME of each kind, so a late older write
# never replaces a newer one.  Subagents' tool calls and tool lookups
# (ToolSearch) are left out.
uuid=${AGENT_SESSION_UUID:-}
payload=$(cat)
[ -n "$uuid" ] || exit 0
sent=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
dir=${AGENT_CLAUDE_STATUS_DIR:-${TMPDIR:-/tmp}/claude-code-status}
here=$(dirname "$0")
(
  . "$here/session-owner.sh"
  agent_hook_foreign_p "$payload" && exit 0
  key=$(printf '%s' "$uuid" | shasum -a 256 | awk '{print $1}')
  line=$(printf '%s' "$payload" | perl -MJSON::PP -MFile::Basename -0777 -ne '
    my $d = eval { decode_json($_) };
    exit unless ref $d eq "HASH";
    exit if defined $d->{agent_id} && $d->{agent_id} ne "";
    my $tool = $d->{tool_name} // "";
    # Loading a tool says nothing about the work.
    exit if $tool eq "ToolSearch";
    my $in = ref $d->{tool_input} eq "HASH" ? $d->{tool_input} : {};
    sub base { my $f = shift // ""; $f eq "" ? "a file" : basename($f) }
    my ($kind, $text) = ("action", "");
    if ($tool eq "TodoWrite") {
      $kind = "todo";
      for my $t (@{ ref $in->{todos} eq "ARRAY" ? $in->{todos} : [] }) {
        next unless ref $t eq "HASH" && ($t->{status} // "") eq "in_progress";
        $text = $t->{activeForm} // $t->{content} // "";
        last;
      }
    } elsif ($tool eq "Bash") {
      $text = $in->{description} // "";
      if ($text eq "") {
        my ($word) = ($in->{command} // "") =~ /(\S+)/;
        $text = "Running " . ($word // "a command");
      }
    } elsif ($tool eq "Read") { $text = "Reading " . base($in->{file_path}) }
    elsif ($tool =~ /\A(?:Edit|MultiEdit)\z/) { $text = "Editing " . base($in->{file_path}) }
    elsif ($tool eq "NotebookEdit") { $text = "Editing " . base($in->{notebook_path}) }
    elsif ($tool eq "Write") { $text = "Writing " . base($in->{file_path}) }
    elsif ($tool eq "Grep") { $text = "Searching for " . ($in->{pattern} // "text") }
    elsif ($tool eq "Glob") { $text = "Finding " . ($in->{pattern} // "files") }
    elsif ($tool eq "WebFetch") {
      my ($host) = ($in->{url} // "") =~ m{\A\w+://([^/]+)};
      $text = "Fetching " . ($host // "a web page");
    }
    elsif ($tool eq "WebSearch") { $text = "Searching the web for " . ($in->{query} // "") }
    elsif ($tool =~ /\A(?:Task|Agent)\z/) { $text = "Running a subagent: " . ($in->{description} // "") }
    elsif ($tool eq "Skill") { $text = "Using the " . ($in->{skill} // $in->{command} // "") . " skill" }
    elsif ($tool =~ /\Amcp__([^_]+(?:_[^_]+)*)__(.+)\z/) { $text = "Using $2 ($1)" }
    elsif ($tool ne "") { $text = "Using $tool" }
    else { exit }
    $text =~ s/\s+/ /g;
    $text =~ s/\A | \z//g;
    $text = substr($text, 0, 117) . "..." if length $text > 120;
    binmode STDOUT, ":encoding(UTF-8)";
    print "$kind\t$text";
  ') || exit 0
  [ -n "$line" ] || exit 0
  kind=${line%%$'\t'*}
  text=${line#*$'\t'}
  activity="$dir/$key.activity"
  mkdir -p "$activity" || exit 0
  tmp=$(mktemp "$activity/.write.XXXXXX") || exit 0
  if printf '%s' "$text" >"$tmp"; then
    mv -f "$tmp" "$activity/$sent.$kind"
  else
    rm -f "$tmp"
  fi
) </dev/null >/dev/null 2>&1 &
exit 0
