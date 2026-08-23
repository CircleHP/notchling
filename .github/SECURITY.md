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

**`notchling-hook` runs on every tool call.** Claude Code executes it as a hook, with your environment,
and acts on what it writes to stdout. Its contract is therefore that it never writes to stdout and
never exits non-zero — a break in either can alter or interrupt a session rather than merely break the
widget. Anything that can make it violate that is a genuine finding.

**`install-hooks.sh` edits `~/.claude/settings.json`.** It backs the file up first, appends to the
existing hook arrays so other tools' hooks survive, and removes only its own entries. A path that
makes it clobber unrelated configuration, or write a command it did not resolve, is a finding.

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

**A session's transcript is read, locally.** `TranscriptReader` scans backwards from the end of the
session's own `.jsonl` under `~/.claude/projects/` for two entries recorded nowhere else: the title
Claude derives, and a colour set with `/color`. Nothing else is taken from the file and nothing leaves
the machine. A path that makes it read a file outside that directory, or forward any of it anywhere, is
a finding.

**What is out of scope:** the widget displaying content from a session you are already running —
prompts, titles, tool names and error text are the user's own data, shown on the user's own screen.

## Signing

The app is signed ad-hoc, which is free and requires no Apple account. It is not notarized, and it is
not distributed through a browser, so it never carries the quarantine attribute that would demand
notarization. If you obtained a "Notchling" from anywhere other than this repository or the
`CircleHP/notchling` Homebrew tap, it is not this project's build.
