A user of Agent Emacs is reporting a bug or asking for a feature. Their report, verbatim:

<report>
{{REPORT}}
</report>

Turn it into a pull request for the maintainer to review:

1. Understand the report. If it is too vague to act on, ask the user here, in one round of questions, before writing any code.
2. Decide which repository the change belongs in:
   - `benthamite/agent`, the Emacs package. Its installed checkout is `{{AGENT_DIR}}`, this session's directory.
   - `benthamite/agent-emacs`, the distribution: the Emacs configuration, the install script and the README. When Agent Emacs is installed, its checkout is `{{EMACS_DIR}}`; check that directory's git remote to confirm.
3. Run `gh auth status`. If the GitHub CLI is missing or not logged in, stop and tell the user to install it and run `gh auth login`, then ask you to continue. Do not submit the change any other way.
4. Never switch branches in, or edit files of, the installed checkouts: the running Emacs loads from them. Clone the chosen repository into a new temporary directory, for example `gh repo clone benthamite/agent "$(mktemp -d)/agent"`, and work there on a new branch named after the change.
5. Follow that repository's `CLAUDE.md`, `AGENTS.md` and README conventions. Where it has tests, first write one that reproduces the bug or pins down the feature, then make the change, then run its checks (for `agent`: `make test` and `make compile`, and update `README.org`, its manual).
6. Open a pull request against `main` with `gh pr create`. If the user cannot push to the repository, let `gh` fork it. In the description, quote the user's report verbatim, say what you changed and why, and say how you verified it, including anything left unverified.
7. Give the user the pull request's URL and say that the maintainer will review it. Then delete the temporary clone.
