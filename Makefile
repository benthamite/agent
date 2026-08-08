EMACS ?= emacs
PROFILE := $(shell emacsclient -e 'init-current-profile' 2>/dev/null | tr -d '"')
ELPACA := $(HOME)/.config/emacs-profiles/$(PROFILE)/elpaca
LOAD_PATH := --eval '(dolist (dir (file-expand-wildcards "$(ELPACA)/builds/*/")) (add-to-list (quote load-path) dir))' --eval '(push default-directory load-path)'
SRC := agent.el agent-account.el agent-capture.el agent-slack.el agent-snippet.el agent-forge.el agent-todo.el agent-claude-cli.el agent-claude.el agent-codex.el agent-chief.el agent-project.el
TEST_FILES := test/agent-test.el test/agent-account-test.el test/agent-capture-test.el test/agent-slack-test.el test/agent-snippet-test.el test/agent-forge-test.el test/agent-todo-test.el test/agent-claude-cli-test.el test/agent-claude-test.el test/agent-codex-test.el test/agent-chief-test.el test/agent-project-test.el

.PHONY: compile test clean

compile:
	$(EMACS) --batch $(LOAD_PATH) -f batch-byte-compile $(SRC)
	rm -f *.elc

test:
	$(EMACS) --batch $(LOAD_PATH) --eval '(require (quote ert))' $(foreach f,$(TEST_FILES),-l $(f)) -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
