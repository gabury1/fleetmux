# fleetmux — bin/fmux is the artifact produced by concatenating src/*.sh in numeric order.
#
# Order is meaning. bash has no entry-point function — the file executes top to bottom, so
# ① a function definition must run before its name is registered, and
# ② subcommands form an `if [ "${1:-}" = "--x" ]; then …; exit 0; fi` chain, so whichever
#   branch appears first wins.
# So the numeric prefix pins the execution order, and the SRC list's listing order is the
# final file's order. Changing the order changes behavior.
#
# What each file holds:
#   00-header.sh   shebang · set -euo pipefail · LC_ALL · STATE · resolving its own absolute path (tt_self/SELF/SELFQ)
#   05-config.sh   config — whitelist parser · env > file > default precedence · tt_conf_get/on/source
#   10-util.sh     portability helpers (tt_comm) · bash 3.2 branch (TT_TINY_READ) · hook.log rotation
#   20-manifest.sh manifest path/format · uuid detection · integrity check (awk) · atomic write · 3-generation backup
#   30-state.sh    state-determination layer — screen "working" detection (tt_working) · finished lock/normalize ·
#                  hook file validity (tt_hook_valid) · tt_is_agent · tt_broadcast · hook sweep · tt_jv
#   35-lastprompt.sh last prompt (last-<sid>) — awk scanner that extracts from the payload · save function ·
#                  awk that renders the preview header. Both 50 (hook) and 90 (preview) use it, hence it comes before both.
#   40-mfops.sh    manifest mutation — lock · line lookup · upsert · rename · forget
#   50-hook.sh     fleet aggregation (tt_fleet_agg) · --hook receiver (working/idle/waiting/clear/boot) · --status
#   60-rc.sh       rc detection helpers (rc_*) · --cron (=--rc-check) · --rc
#   70-fleet.sh    tt_conv_of · --snapshot · --forget · --restore
#   80-view.sh     --list
#   85-config-cli.sh config CLI — validation · atomic write · tt config subcommands
#   86-config-view.sh in-popup config screen — --config-list/--config-toggle/--config-view
#   87-tmux-conf.sh  generates the tmux snippet — summon-key binding · on-detach snapshot hook (--tmux-conf [--write])
#                    Comes after 85: `tt config set` exits inside 85, so it can't see this file's functions.
#                    So 85 doesn't call the function directly — it re-invokes via `$SELF --tmux-conf --write`.
#   90-main.sh     tt_prompt · --do-* · --preview · --hooks-json · --codex-hooks · --help · entry point (fzf popup)
#
# The shebang must live only in 00-header.sh — putting it in another file would bury a shebang
# in the middle of the concatenated result.
# When adding a file, also add it to the SRC list below in numeric order (this list is the
# source of truth, not a glob).

SRC = src/00-header.sh \
      src/05-config.sh \
      src/10-util.sh \
      src/20-manifest.sh \
      src/30-state.sh \
      src/35-lastprompt.sh \
      src/40-mfops.sh \
      src/50-hook.sh \
      src/60-rc.sh \
      src/70-fleet.sh \
      src/80-view.sh \
      src/85-config-cli.sh \
      src/86-config-view.sh \
      src/87-tmux-conf.sh \
      src/90-main.sh

OUT    = bin/fmux
PREFIX = $(HOME)/.local
BINDIR = $(PREFIX)/bin

all: $(OUT)

$(OUT): $(SRC)
	cat $(SRC) > $(OUT)
	chmod +x $(OUT)
	bash -n $(OUT)
	@echo "built $(OUT)"

# Syntax check. Runs shellcheck if present, and says so out loud if it skipped it.
check: $(OUT)
	bash -n $(OUT)
	bash -n install.sh
	@if command -v shellcheck > /dev/null 2>&1; then \
		shellcheck -x $(OUT) && echo "shellcheck: clean"; \
		shellcheck install.sh || echo "shellcheck: install.sh has findings — not a gate yet (no one has confirmed it clean). Fold it into the line above once fixed"; \
	else \
		echo "shellcheck not installed — skipped"; \
	fi
	@./test/run.sh

# Split verification: checks that concatenating src/*.sh is byte-identical to the committed bin/fmux.
# Any difference means the split is not move-only.
verify:
	@t=$${TMPDIR:-/tmp}/fmux-verify.$$$$; \
	cat $(SRC) > $$t.joined; \
	git show HEAD:$(OUT) > $$t.head; \
	if diff -u $$t.head $$t.joined; then \
		rm -f $$t.joined $$t.head; \
		echo "verify: src/*.sh joins byte-identically to the committed $(OUT)"; \
	else \
		rm -f $$t.joined $$t.head; \
		echo "verify: MISMATCH — the split is not move-only"; \
		exit 1; \
	fi

# ── release archive ─────────────────────────────────────────────────────────
# `make dist` builds the two things that go on a release:
#   dist/fleetmux-<VERSION>.tar.gz   what the installer downloads and unpacks
#   dist/SHA256SUMS                  what the installer checks against — the only defense a pipe install has
#
# **Do not build these by hand.** If a human types sha256sum at release time, they'll eventually
# forget it, and the day they do, `curl | bash` installs unverified. Hence this target.
#
# Why not use the source tarball GitHub auto-generates: its bytes aren't guaranteed stable
# (a git version bump can change the compression output). We have to hash the file we built
# ourselves and ship it alongside for the check to mean anything. The installer also looks for
# this exact asset name (fleetmux-<tag>.tar.gz) first.
#
# The hashing tool differs between Linux and Mac — sha256sum (GNU) if present, else shasum -a 256 (Mac).
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
DISTDIR ?= dist
DISTNAME = fleetmux-$(VERSION)
SHA256   = $(shell if command -v sha256sum > /dev/null 2>&1; then echo sha256sum; else echo "shasum -a 256"; fi)

dist: $(OUT)
	rm -rf "$(DISTDIR)/$(DISTNAME)" "$(DISTDIR)/$(DISTNAME).tar.gz" "$(DISTDIR)/SHA256SUMS"
	mkdir -p "$(DISTDIR)/$(DISTNAME)"
	cp -R bin libexec src skills Makefile install.sh README.md LICENSE "$(DISTDIR)/$(DISTNAME)/"
	tar -czf "$(DISTDIR)/$(DISTNAME).tar.gz" -C "$(DISTDIR)" "$(DISTNAME)"
	rm -rf "$(DISTDIR)/$(DISTNAME)"
	cd "$(DISTDIR)" && $(SHA256) "$(DISTNAME).tar.gz" > SHA256SUMS
	@echo "dist: $(DISTDIR)/$(DISTNAME).tar.gz"
	@cat "$(DISTDIR)/SHA256SUMS"
	@echo "Upload both of these as release assets — the installer looks for that exact name."

install: $(OUT)
	mkdir -p $(BINDIR)
	cp $(OUT) $(BINDIR)/fmux
	chmod +x $(BINDIR)/fmux
	@echo "installed $(BINDIR)/fmux"
# The tt symlink. It must be usable right after a bare `make install` — the PATH shim
# (libexec/claude) confirms we exist via `command -v tt`, so without this name the hook
# injection doesn't attach at all.
# Never overwrite someone else's tt — an installer must not delete another tool.
#   ⚠️ The old guard was `[ -e ] && [ ! -L ]`: it protected regular files but **clobbered
#   other people's symlinks**. Symlinking a personal tool into ~/.local/bin is the most common
#   pattern, so this comment was misrepresenting the code (team deploy gate I2). install.sh
#   inherits this same rule when make is present, so its tt_link_ours and this one must make
#   **the same call**: only touch it when it's absent or already a symlink pointing at fmux.
	@if [ ! -e "$(BINDIR)/tt" ] && [ ! -L "$(BINDIR)/tt" ]; then \
		ln -sf fmux "$(BINDIR)/tt"; \
		echo "linked $(BINDIR)/tt -> fmux"; \
	elif [ -L "$(BINDIR)/tt" ] && { [ "$$(readlink "$(BINDIR)/tt")" = fmux ] || [ "$$(readlink "$(BINDIR)/tt")" = "$(BINDIR)/fmux" ]; }; then \
		ln -sf fmux "$(BINDIR)/tt"; \
		echo "relinked $(BINDIR)/tt -> fmux"; \
	else \
		echo "skip: $(BINDIR)/tt is not ours — leaving it alone"; \
		echo "      current: $$(ls -ld "$(BINDIR)/tt")"; \
	fi

.PHONY: all check verify install dist
