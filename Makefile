SHELL := /bin/bash
export MIX_REBAR3 := $(shell command -v rebar3)
.PHONY: terminal check
terminal:
	./scripts/terminal
check:
	mix format --check-formatted
	mix compile --warnings-as-errors
	mix test
	npm --prefix assets run build

.PHONY: browser-check
browser-check:
	npm --prefix assets run build
	npx --prefix assets playwright install chromium
	node assets/check.mjs

.PHONY: shutdown-check
shutdown-check:
	python3 scripts/check_sigint.py
