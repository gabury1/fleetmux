# Distribution channel — go with one `curl | sh`

Decided 2026-08-06 · Decided by: the maintainer

## Decision

Public distribution goes through **one line: `curl -fsSL … | bash`.** Homebrew tap,
`.deb`/`.rpm`, and AUR are not built right now.

## Why

**macOS ships with `curl` built in.** The original plan was two branches — brew for
Mac, curl for Linux — but that just covers the same people twice through two paths. A
channel whose coverage overlaps is not a gain, it is maintenance cost.

Why each alternative was rejected:

| Channel | Why rejected |
|---|---|
| Homebrew tap | Its coverage overlaps with curl. The only remaining benefit is `brew upgrade`, but if the installer is idempotent, that's replaced by just running the same one-liner again (starship and rustup do exactly this) |
| `.deb` / `.rpm` | Without standing up a repository, the user just downloads it from the release and runs `dpkg -i` — no better than curl. Standing one up means permanently owning GPG keys, hosting, and renewal — that infrastructure is overkill for **a single bash file with no compile step** |
| AUR | Only reaches Arch users. Community PRs can cover it; there's no reason for us to take on that maintenance burden first |
| nix / mise | Revisit if requested |

Brew gets pulled back out when people start saying "I want to install this through a
package manager." By then a public tarball and SHA already exist, so the formula is
30 lines — **not building it now doesn't make it more expensive later.**

## The four things that must get built as a result

1. **`install.sh` remote mode** — coming in via `curl | sh` means there's no clone.
   Right now it calls `make install` from inside a clone, so a path that fetches and
   installs a release tarball is needed.
2. **Default to the latest tag** — if we let people pull `main`, then the moment
   `main` breaks, **every new install breaks along with it.** Default to a tag; `main`
   only when explicitly requested.
3. **Verify against `SHA256SUMS`** — publish it with the release and have the
   installer check it. It's the only line of defense for a piped install.
4. **Split out `tt setup`** — move configuration (hook shim, tmux snippet, summon
   key, skill) into the installed binary itself. That makes it possible to
   reconfigure without a clone, and gives a standard shape for whatever package
   manager eventually shows up: the package just drops the binary, and `tt setup`
   handles configuration (the `gh auth setup-git` / `starship init` pattern).

## What goes in the docs

The README lays out **two paths side by side** — the piped one-liner, and download it,
read it, then run it yourself. Developers being wary of `curl | sh` these days is
reasonable, and that wariness isn't dismissed.

## Timing

We'll build this after the three of us have used it from a `git clone` first.
Hardening it before real usage just means having to fix it again once feedback comes
in.
