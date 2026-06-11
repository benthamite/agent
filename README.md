# `agent`: AI coding agent integration for Emacs

`agent` collects the Emacs integration layer for AI coding command-line tools. It provides a shared session switcher, notifications, theme synchronization, terminal fixes, skill execution, and backend modules for Claude Code and Codex.

The package is for Emacs users who run AI coding agents inside terminal buffers and want one coherent interface instead of separate menus and keybindings per CLI. The core package (`agent.el`) owns backend registration, session identity and state, and the unified commands (handoff, restart, exit, skills, audits); `agent-account` handles multi-account selection and config homes for all backends; `agent-capture`, `agent-slack`, and `agent-snippet` add Org prompt capture, Slack-to-project routing, and yasnippet expansion in session buffers; `agent-claude` (with `agent-claude-cli` quarantining undocumented Claude CLI conventions) adds status and usage polling, branch navigation, batch TODO execution, and hook setup; `agent-codex` adds theme sync, `codex exec` execution, and modeline helpers.

Each backend ships a global minor mode (`agent-claude-mode`, `agent-codex-mode`) that owns every hook, advice, and timer the backend installs. Loading the modules installs nothing; you must enable the modes explicitly.

## Installation

With `package-vc`:

```emacs-lisp
(use-package agent
  :vc (:url "https://github.com/benthamite/agent"))
```

With Elpaca:

```emacs-lisp
(use-package agent
  :ensure (:host github :repo "benthamite/agent"))
```

With straight.el:

```emacs-lisp
(use-package agent
  :straight (:host github :repo "benthamite/agent"))
```

Dependencies: Emacs 30 or later, `transient`, and `consult` for the core package. The Claude backend expects `claude-code`; the Codex backend expects `codex`. Optional integrations use `yasnippet`, `doom-modeline`, `gptel`, `agent-log`, and `monet` when available.

## Quick Start

```emacs-lisp
(use-package agent
  :ensure (:host github :repo "benthamite/agent")
  :after (claude-code codex)
  :demand t
  :config
  (require 'agent-claude)
  (require 'agent-codex)
  (agent-claude-mode 1)
  (agent-codex-mode 1))
```

Run `M-x agent-menu` for the unified command menu, or bind it directly:

```emacs-lisp
(keymap-global-set "H-e" #'agent-menu)
```

## Documentation

For a comprehensive description of all user options, commands, and functions, see the [manual](README.org).
