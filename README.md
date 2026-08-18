# Notchling

<p align="center">
  <a href="https://github.com/CircleHP/notchling/actions/workflows/ci.yml"><img src="https://github.com/CircleHP/notchling/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI: build and test on macOS 15 and 26"></a>
</p>

**A native macOS notch widget that shows what every Claude Code session is doing — and gets you back to
the one that needs you.** Click a row, land in the terminal tab that owns it.

<p align="center">
  <img src="media/notchling.gif" width="700" alt="Notchling in the notch: a compact strip showing session counts drops open into a panel listing three Claude Code sessions — one blocked on a permission prompt with three subagents beneath it, one editing, one finished — then closes again">
</p>

<p align="center"><i>Resting in the notch, opening on a permission prompt, and closing again. The top session
has fanned out to three subagents; one is blocked, and one reports back while the panel is open.<br>
Clicking any row activates the terminal tab that owns that session.</i></p>

## Why

Run more than one Claude Code session and you lose track of them. One finishes and sits idle for ten
minutes before you notice. Another is blocked on a permission prompt in a tab you aren't looking at. The
only way to find out is to cycle through tabs and read each one.

Tools that solve this usually do it for a terminal they control — they know which session is which because
they launched it. Notchling never asks your terminal anything: it reads the session registry **Claude Code
already keeps for itself**, and learns terminal identity from the environment variables Claude inherited
from its shell. That works in any terminal, including sessions that were already running before you
installed it.

## What it does differently

**Click a row and you are there.** Not "session 3 needs attention" — the actual tab, brought forward. Warp
via its deep link, iTerm2 and Terminal.app by matching the controlling tty, other terminals by activating
the app. Rows say in their tooltip how precise the jump will be, before you click.

**It is a native app in the notch, not an overlay on your workspace.** No floating always-on-top window to
misclick, because there is no floating window:

- `LSUIElement`, so it has no Dock icon and never appears in Cmd-Tab.
- `ignoresCycle`, so it is not in the window cycle either.
- It can never take keyboard focus — the panel is explicitly barred from becoming the key window, so it
  cannot steal your menu bar or your typing.
- Its window is **exactly the size of what it draws** — 256×32pt when compact, entirely inside the menu
  bar. A window swallows mouse clicks across its whole rectangle whatever it painted there, so any slack
  would be a dead zone over the browser tabs underneath. There is no slack.
- Swift and SwiftUI with **zero dependencies**. Not Electron, not a Python overlay.

## What you see

- **Every session, most urgent first** — interactive and background, discovered with no configuration.
- **"Working" versus "blocked on you"**, which is the distinction that actually matters.
- **Subagents as a subtree.** A fan-out shows each agent, what it is running, which one is blocked, and
  what the finished ones concluded — plus a `3/5 done` headline so "wait or switch tabs" is answerable at
  a glance.
- **Alerts without banners.** The notch drops open for a few seconds and plays a distinct sound. Nothing
  accumulates in Notification Center and nothing needs dismissing.
- **Stalled turns**, judged against what each tool normally takes *here* — so a twelve-minute test run is
  not flagged and a `Read` that never returns is flagged in 45 seconds.
- **`done 4m ago`** on settled rows, so "just finished, go look" is distinguishable from "cold since
  lunch".
- **Plan usage and per-session context**, optionally.
- **On every screen.** A notched display uses the real notch; every other screen gets a drawn one, same
  shape and behaviour.

It sends nothing anywhere. No network calls, no telemetry, no reading of transcripts. At rest it costs
0.0–0.1% CPU.

## Install

```sh
git clone https://github.com/CircleHP/notchling.git
cd notchling
make install
```

Then restart any Claude sessions that were already running, so they pick up the hooks.

Needs macOS 14+, a Swift 6 toolchain (Xcode 16+ or its Command Line Tools), and `jq`.

The build signs the app itself, so there is no Apple certificate to buy and nothing to notarize — you
compiled it, so macOS does not gate it. Two things follow from that, both one-time: the first jump into
**iTerm2 or Terminal.app** makes macOS ask for permission to control them, and because a self-signed
build's identity changes each rebuild, it asks again after a reinstall. Adding a free Apple Development
certificate makes the grant stick — [SETUP.md](SETUP.md#how-much-signing-you-need) has the three
steps. **Warp needs none of this**: that jump is a URL, not AppleScript.

Two optional extras:

```sh
make statusline    # plan-usage bars + per-session context
make autostart     # start at login
```

`make install` edits exactly one file that isn't ours — `~/.claude/settings.json` — backs it up first, and
**appends** to the existing hook arrays so other tools' hooks survive.

Full setup, preferences, terminal compatibility and troubleshooting: **[SETUP.md](SETUP.md)**.

## Docs

**[SETUP.md](SETUP.md)** — requirements, install, preferences, terminal compatibility, signing, uninstall
and troubleshooting.

## Status

Notchling reads surfaces Claude Code and Warp do not formally document — the session registry, the shape
of subagent hook payloads, and a Warp environment variable. Every one of them is decoded defensively and
degrades to something still usable rather than failing, so the widget keeps working when a field it does
not recognise appears. If something ever does stop working, a Claude Code or Warp update is the first
thing to check.

Every push and pull request is built and tested on **macOS 15 and macOS 26**: a release build with
warnings treated as errors, the full suite, and the signed `.app` that `make install` assembles. The badge
at the top reports the state of `main` — so what a clone gets you is whatever that badge last said.

## Contributing

Pull requests welcome, especially:

- **iTerm2 and Terminal.app focus** — implemented, and confirmation from a real setup would be welcome.
- Terminals not in the compatibility table.
- Anything that breaks against a new Claude Code version.

Run `make test` before opening a PR — 204 tests, no network or fixtures required. `make test` rather than
`swift test`: the tests that drive the hook binary end to end skip themselves if it has not been built.

The code carries its reasoning in comments — the constraints that are easy to break by accident are
written down next to the code that depends on them.

## License

MIT, all of it — see [LICENSE](LICENSE). The mascot is original art, so there are no carve-outs.

Notchling is unofficial and not affiliated with Anthropic. See [NOTICE.md](NOTICE.md).
