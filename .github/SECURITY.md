# Security policy

## Reporting a vulnerability

Report privately through **[GitHub Security Advisories](https://github.com/CircleHP/notchling/security/advisories/new)**,
which keeps the report between you and the maintainer until there is a fix. If that is unavailable to
you, email **evmenovdv@gmail.com**.

Please do not open a public issue for a vulnerability.

Expect an acknowledgement within a few days. This is a single-maintainer project, so a fix may take
longer than that — you will be told where it stands rather than left waiting.

## Supported versions

The latest release only. Notchling ships as a single universal bundle and upgrades in place, so there
are no maintenance branches to backport to.

## What the attack surface actually is

Notchling sends no telemetry, and the only network request it makes is one it has to be told it may
make — see [NOTICE.md](../NOTICE.md). That removes a category of risk but not all of it, and a security
policy that only said "we send nothing" would be misleading. What is worth scrutiny:

**`notchling-hook` runs on every tool call.** Both agents execute it as a hook, with your environment,
and both act on what it writes to stdout. Its contract is therefore that it never writes to stdout and
never exits non-zero — a break in either can alter or interrupt a session rather than merely break the
widget. Anything that can make it violate that is a genuine finding.

Under Codex that contract carries more than it does under Claude Code. Codex lets a hook *decide* a
permission request by what it prints, so a hook registered on `PermissionRequest` — which this one is —
could approve a command on your behalf simply by printing the wrong thing. Printing nothing means "no
opinion", which is what leaves the question in the terminal where you can see it. Anything that can put
a single byte on that stdout is a finding of a different order from a broken widget.

**`install-hooks.sh` edits `~/.claude/settings.json` and `~/.codex/hooks.json`.** It backs each file up
first, appends to the existing hook arrays so other tools' hooks survive, and removes only its own
entries. A path that makes it clobber unrelated configuration, or write a command it did not resolve,
is a finding.

Appending rather than inserting is load-bearing for Codex specifically: Codex keys a hook's trust
decision by its position in the file, so an entry written anywhere but the end renumbers the groups
after it and invalidates the decisions the user already made about other tools' hooks — silently, and
in the direction of re-asking rather than of granting. Anything that inserts, reorders or renumbers is
a finding. So is anything that writes Codex's trust state at all: that record is the user's answer to a
question about executing code, and this project never writes it.

The
settings window runs this same script as a subprocess, from the copy in its own bundle rather than one
found on `PATH`; a change that lets it run something else, or change a configuration without being
clicked, belongs here too.

**The status line chain executes a command this project did not write.** Claude Code has one status
line slot, so where another tool holds it `notchling-hooks statusline` can generate
`~/.notchling/statusline.sh`, which runs Notchling's script and then the command that was configured
before — kept verbatim in `statusline-wrapped.sh` and run with `bash`, exactly as Claude Code would
have run it. It is the user's own command, taken from their own settings file and nowhere else.
Anything that lets what runs there come from somewhere other than that file, or that makes the pair
resolve to a path outside `~/.notchling` — both are passed to `rm -f` when the chain is undone — is a
finding.

**The spool is a directory of files other processes can write.** `~/.notchling/events/` is created
`0700` and every file in it is parsed by the widget. Payload handling that can be made to crash or
hang the app belongs here.

**Recorded paths must survive an upgrade.** Anything written into `~/.claude/settings.json` uses the
Homebrew `opt` prefix rather than a versioned Cellar path. A change that records a path which later
points somewhere else is a finding, because the recorded command is executed on every session.

**The update path runs Homebrew.** Checking for a release runs `git fetch` in the tap's clone; the
install button runs `brew upgrade notchling`. Both are subprocesses launched with the absolute paths
of the Homebrew install that placed this bundle, with `HOMEBREW_NO_AUTO_UPDATE=1` so one click means
one formula. Neither runs at all until the question in the panel has been answered yes, and the check
parses the formula's own text rather than asking `brew` for a version. Anything that makes this reach a
tap, a repository or a formula other than this project's is a finding, as is anything that makes it run
with an environment or a `brew` path it did not resolve itself.

**A Claude Code session's transcript is read, locally.** `TranscriptReader` scans backwards from the end
of the session's own `.jsonl` under `~/.claude/projects/` for two entries recorded nowhere else: the
title Claude derives, and a colour set with `/color`. Nothing else is taken from the file and nothing
leaves the machine. A path that makes it read a file outside that directory, or forward any of it
anywhere, is a finding.

**A Codex rollout is read, narrowly, and the narrowness is enforced by construction.** Every Codex
hook event names the session's own record under `~/.codex/sessions/`, and three numbers a row shows
exist nowhere else: the context fill and the two rate-limit windows. That file also contains the
conversation, so `CodexRolloutReader` applies three filters in an order that matters. A line longer than
`maxLineLength` is discarded before anything examines it — the records sought run to 3.7KB and the ones
carrying content run to 230KB, so conversation lines are refused on their size alone. Only a line
naming one of the two records is then handed to a JSON parser. Only five fields are taken out of them.

Anything that weakens that order is a finding: raising the cap so a content record can pass it, parsing
before the name test, or forwarding a field that is not on the list. So is anything that points the
reader at a file other than the one the hook named, or points a Claude session at it.

**A Codex session's derived name is read from a shared index.** `~/.codex/session_index.jsonl` carries
one line per naming — the name Codex derives, and any rename after it — and one field is taken from the
last entry for a session. The file's location is derived from the rollout path the hook reported rather
than from `CODEX_HOME`, so a widget launched at login does not depend on a terminal's environment. The
local database that holds the same name is deliberately not opened. A path that makes this read
somewhere else, or take anything but the name, is a finding.

**What is out of scope:** the widget displaying content from a session you are already running —
prompts, titles, tool names and error text are the user's own data, shown on the user's own screen.

## Signing

The app is signed ad-hoc, which is free and requires no Apple account. It is not notarized, and it is
not distributed through a browser, so it never carries the quarantine attribute that would demand
notarization. If you obtained a "Notchling" from anywhere other than this repository or the
`CircleHP/notchling` Homebrew tap, it is not this project's build.
