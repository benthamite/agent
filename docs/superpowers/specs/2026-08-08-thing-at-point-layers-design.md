# Acting on the thing at point, deliberately

## Problem

`agent-act-on-thing-at-point` dispatches to four commands that each grew on
their own.  Two decisions inside them were never made on purpose, only
inherited:

| Thing | Which session | Which directory |
|---|---|---|
| Forge topic | always new | the repo's worktree |
| Backtrace | always new | the package source, gptel-ranked |
| Slack message | always new | Epoch registry, gptel-ranked |
| org TODO | always existing | the current file's project |

The org TODO targets an existing session for no reason beyond how it was
written first.  The project list is worse: the Epoch registry is one source,
`agent-audit-project-directories` is a second that grows by accretion, and
nothing connects either to the account the session will run under, though the
account is exactly what determines which projects are plausible.

Adding email — the maildir path of the message at point in mu4e — would add a
fifth handler and a third project list unless these are settled first.

## Design

Three layers.  Each decides one thing, and only the third is allowed to differ
per kind of thing.

### Layer 1: recognize

An ordered table of predicates, each answering from the buffer alone, without
loading the module that owns its handler.  Email joins as a fifth entry:
`mu4e-headers-mode` or `mu4e-view-mode` with `(mu4e-message-at-point t)`
non-nil.  Its path comes from `(mu4e-message-field-at-point :path)`.

### Layer 2: choose the session

Uniform across all five.  No prefix argument starts a new session; `C-u`
prompts among running sessions instead.  This matches how the commands are
actually used: the common case is routing something into a fresh session.

A new session needs a directory, and the kinds divide honestly here:

- **Anchored** things carry one.  A Forge topic has its repository's worktree;
  a backtrace has its package's source directory.  Nothing to choose.
- **Unanchored** things carry only text: a Slack message, an email, an org
  TODO.  Their directory comes from the account's project sources, ranked by
  that text.

#### `agent-project-sources`

An alist mapping an account-name regexp to a list of sources, first match
wins, `""` as the catch-all for an account with no entry and for no account at
all:

```elisp
'(("epoch"      . ("~/My Drive/Epoch/projects/shared/project-registry.json"))
  ("trajectory" . ("~/Trajectory/reasoning-tasks/*"))
  (""           . ("~/repos/*" "~/My Drive/dotfiles" "~/work/side-thing")))
```

An account's sources are a list because projects are rarely all in one place.
Registries, globs, and plain directories mix freely in it, so a set of
projects scattered across unrelated folders is spelled by naming each one.

The account is the current account of the backend that will run the session,
from `agent-account-current`.  A backend with no account selected matches the
catch-all.

A source is either a registry or a path pattern:

- A source ending in `.json` is a **registry**: project entries with an id, a
  title, a summary, and a directory.  Directories resolve exactly as they do
  today — the doc folder under `~/My Drive/Epoch/projects/<id>/`, preferred
  over any recorded repo path.
- Anything else is a **path pattern**, expanded with `file-expand-wildcards`,
  one level, never recursively.  A pattern containing a wildcard keeps only
  matches that are git repositories or worktrees, which is what removes
  `~/repos/epoch/` from `~/repos/*` and `tasks/` from the Trajectory
  worktrees.  A pattern without a wildcard names exactly that directory and is
  kept whether or not it is a repository, so a non-repo project can always be
  listed explicitly.

Candidates from all of an account's sources are concatenated and deduplicated
by true path.

#### Ranking

The prompt is always a `completing-read`, so the order is a suggestion and
never a constraint.  gptel ranks the candidates only when at least one carries
a description — that is, when a registry contributed it.  Under a glob-only
account there is nothing to rank on, so the request is skipped entirely rather
than sent with bare directory names.

### Layer 3: deliver

Per kind, because the payloads genuinely differ:

| Thing | Payload | Submitted? |
|---|---|---|
| Forge topic | the issue or PR URL | no |
| Backtrace | the saved backtrace path with fix instructions | yes, as today |
| Slack message | the message permalink | no |
| Email | the maildir path | no |
| org TODO | the heading and body | yes, and flips to the in-progress keyword |

A URL and a maildir path are *references*: they go in unsubmitted so the
request can be typed next to them.  An org TODO already is the request.

### The handler contract

Handlers become context extractors.  Each is called with a continuation and
calls it with a plist: `:directory` when anchored, `:text` when not,
`:payload`, `:submit`, and an optional `:after` thunk for the TODO's keyword
change.  The core then does layer 2 and layer 3.

The continuation is not decoration.  The Slack extractor is already
asynchronous — it fetches a permalink over the network, then asks gptel — so a
synchronous contract would force the one path that cannot be synchronous to
stay special.  Extractors with nothing to wait for call the continuation
immediately.

## What changes

- `agent.el`: `agent-act-on-thing-at-point` gains the prefix argument and
  layers 2 and 3.  New `agent-project-sources`, candidate enumeration, and
  ranking.  The table maps predicates to extractors instead of commands.
- `agent-slack.el`: keeps the permalink fetch, loses session starting and
  project selection.  The registry parser goes with them: a registry is now
  one kind of project source, and core enumeration cannot reach into a
  module it is forbidden to require.
- `agent-forge.el`, `agent-todo.el`: shrink to extractors.
- `agent-mu4e.el`: new, small — a predicate and an extractor.
- The four commands remain interactive wrappers that call the dispatcher with
  their own extractor forced, so existing bindings keep working.

Renamed with obsolete aliases: `agent-act-on-slack-message-model` and
`-backend` become `agent-project-ranking-model` and `-backend`, since ranking
is no longer Slack's.  `agent-epoch-project-registry-file` becomes obsolete —
the registry is named by an entry in `agent-project-sources`.
`agent-epoch-projects-root` becomes `agent-project-registry-root`, keeping its
job of resolving the registry's relative paths under a name that no longer
claims the mechanism is Epoch's.

## Testing

Enumeration is the part with real logic and gets the most tests: a wildcard
pattern keeps repositories and drops plain directories, a wildcard-free
pattern is kept as-is, expansion never recurses, candidates from several
sources are deduplicated by true path, and account lookup falls through to the
catch-all for an unmatched account and for no account.

Ranking is tested for the skip: a glob-only candidate set makes no gptel
request.  Layer 2 is tested for the prefix argument choosing an existing
session over starting one.  Layer 3 is tested per kind for payload and
submission, with the TODO asserting the keyword change.  The existing
predicate tests carry over and gain the mu4e pair.

## Decided, not asked

- The org TODO becomes unanchored: with no prefix it starts a new session in a
  project chosen from the TODO's text, rather than in the notes repository
  where the heading happens to live.  This is the one behavior change an
  existing habit will notice.
- Email inserts the bare maildir path unsubmitted, matching Slack and Forge
  rather than the TODO.
