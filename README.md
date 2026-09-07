# Notchling

**Keep an eye on every Claude Code and Codex session, right from your Mac’s notch.**

See what’s working, what’s finished, and what needs you — then click a session to jump back to it.

<p align="center">
  <img src="media/notchling.gif" width="700" alt="Notchling opens from the notch to show Claude Code sessions, a permission prompt, subagent progress, and plan usage">
</p>

<p align="center"><i>The panel opens when a session needs attention, then tucks itself away.</i></p>

## Stay on top of your sessions

- **Know when you’re needed.** See permission prompts, failed turns, and finished work, with brief
  alerts and distinct sounds.
- **Jump back with a click.** Go straight to the session’s tab or pane in Warp, iTerm2, and Terminal.app.
  Other supported terminals bring the app forward.
- **Follow parallel work.** See every session in one place whichever CLI it belongs to, most urgent
  first, with subagent progress beneath each one and session names and colours you recognise.
- **Keep usage in view.** Optional per-agent plan usage and a per-session context meter show how much
  room you have left, for each CLI separately — two plans do not add up to one number.
- **Stay focused.** The widget never takes keyboard focus, and works across displays — including
  Macs and monitors without a notch.

## Get started

You’ll need **macOS 14 Sonoma or later**, **Homebrew**, and **Claude Code**, **Codex**, or both.

```sh
brew install CircleHP/notchling/notchling
notchling-hooks setup
```

Setup asks before configuring each CLI it finds, offers optional usage meters, and can start the widget
now and at login. Restart any sessions that were already running so they pick up the hooks — and for
Codex, run `/hooks` in a session to review them, because Codex will not run a hook it has not been
asked about. No Xcode or compilation needed.

Codex rows show less than Claude Code rows do, and the [setup guide](SETUP.md#codex) says exactly what
and why.

Hover over the notch to see your sessions, click a row to return to work, and open the gear for settings.

See the [setup guide](SETUP.md) for other installation options, configuration, and troubleshooting.

## Your sessions stay on your Mac

Notchling reads session information locally, including session titles, colours, context and plan
limits. It reads a handful of named records and nothing else — a Codex session's own file holds the
conversation too, and the lines carrying it are discarded on their size before anything parses them. No
telemetry, and no session data is sent anywhere. Update checks run only if you enable them or click **Check Now**;
installing an update is a separate choice. [Privacy details](NOTICE.md).

## Help and more

- [Terminal compatibility](SETUP.md#terminal-compatibility) — supported terminals and limits on jumping to a session.
- [Upgrading](SETUP.md#upgrading) · [Troubleshooting](SETUP.md#troubleshooting) · [Uninstalling](SETUP.md#uninstall)
- [Report a bug or request a feature](https://github.com/CircleHP/notchling/issues)
- [Build from source](SETUP.md#from-source) · [Contribute](.github/CONTRIBUTING.md)

MIT licensed, including the mascot — see [LICENSE](LICENSE).
Notchling is unofficial and not affiliated with Anthropic or OpenAI.
