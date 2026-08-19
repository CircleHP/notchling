# Contributing

Pull requests welcome. This file is the short version of how the repo works; if something here
disagrees with what the code does, the code is right and this is a bug.

## What is most useful

- **iTerm2 and Terminal.app focus** — implemented, and confirmation from a real setup is welcome.
- Terminals missing from the compatibility table in [SETUP.md](../SETUP.md#terminal-compatibility).
- Anything that breaks against a new Claude Code version. The widget reads surfaces Claude Code does
  not formally document, so this is the failure that matters most and the one we cannot see coming.

## Before you open a pull request

Run **`make test`**, not `swift test`. The tests that drive the `notchling-hook` binary end to end
skip themselves when it has not been built, so a bare `swift test` is quietly a smaller suite. No
network and no fixtures are required.

CI runs on **macOS 15 and macOS 26** and both must be green. There is also a strict-concurrency job
that fails on any diagnostic at all — the tree currently has none, and keeping it that way is what
makes a new one visible.

## The title of your pull request matters more than usual

Merges are squash-only, so **the PR title becomes the commit on `main` — and the line in the release
notes**. `release-notes.sh` reads it. Write it for someone reading a changelog, not for the reviewer.

```
type(scope): summary
```

Imperative, lowercase, no trailing period. Types that reach the notes:

| Type | Section |
|---|---|
| `feat` | Added |
| `fix` | Fixed |
| `perf`, `refactor` | Changed |
| `feat!` (any `!` before the colon) | Breaking, listed first |

`docs`, `test`, `build`, `ci`, `chore` and `style` are internal and do not appear. Anything that does
not parse lands under Other rather than failing the release.

Scope is the subsystem the notes will bold: `sessions`, `state`, `ui`, `hook`, `install`, `ci`,
`plugin`, `spool`, `usage`, `core`.

Run `./release-notes.sh <tag>` to see what a release would say.

## Branches and issues

One branch per issue, named `type/short-slug` — `fix/recycled-pid-identity`, `feat/session-titles`.
The pull request body closes its issue: `Closes #9`. Branches delete themselves on merge.

## Comments

The code carries its reasoning next to the code that depends on it. A comment says what the code does
or what a caller must know — an invariant, a unit, an edge case, why a workaround is required. It does
not narrate the change that introduced it: no "previously", no "changed to", no history. Git remembers
that; a reader six months from now needs the constraint, not the diff.

Match the density of the file you are editing.

## What the tests are for

New behaviour comes with a test that fails without it. Several tests here drive real artefacts rather
than mocks — the hook binary as a subprocess, `statusline-usage.sh` with a scratch `HOME` — because the
contracts they cover are the ones that break in the wild. Those skip themselves when the artefact or
`jq` is missing, so a clean checkout is not a wall of red.

## Reporting a problem

Issues use forms that apply the right labels. If the widget has gone quiet, the two things worth
attaching are `notchling-sessions` output and the log:

```sh
log show --predicate 'subsystem == "local.notchling"' --last 1h
```

Note `log` is a zsh builtin — use `/usr/bin/log` if your shell swallows it.
