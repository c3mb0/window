SHELL := /bin/bash
export MIX_REBAR3 := $(shell command -v rebar3)
.PHONY: terminal check
terminal:
	./scripts/terminal
check: archive-build
	mix format --check-formatted
	mix compile --warnings-as-errors
	cargo fmt --manifest-path native/archive/Cargo.toml -- --check
	DUCKDB_DOWNLOAD_LIB=1 cargo clippy --locked --manifest-path native/archive/Cargo.toml -- -D warnings
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

.PHONY: archive-build storage-crash-check storage-browser-check
archive-build:
	./scripts/build-archive
storage-crash-check: archive-build
	python3 scripts/check_storage_crashes.py
storage-browser-check: archive-build
	npm --prefix assets run build
	WINDOW_OPEN_BROWSER=0 WINDOW_SHELF_ONLY=1 node assets/check.mjs
	WINDOW_OPEN_BROWSER=0 WINDOW_SHELF_ONLY=1 WINDOW_BROWSER=firefox node assets/check.mjs
	WINDOW_OPEN_BROWSER=0 WINDOW_STORAGE_PROBE=archive_outage node assets/check.mjs
	WINDOW_OPEN_BROWSER=0 WINDOW_STORAGE_PROBE=sqlite_outage node assets/check.mjs
