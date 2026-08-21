# Notices

## Not affiliated with Anthropic

Notchling is an unofficial, third-party tool. It is not made by, endorsed by,
or affiliated with Anthropic. "Claude" and "Claude Code" are trademarks of
Anthropic, PBC, used here only to describe what the tool observes.

It reads Claude Code's own on-disk session registry and receives its hook events.
It sends no telemetry, ever, and reports nothing about you anywhere. It reads two entries from a
session's own transcript — the title Claude derives, and a colour set with `/color` — because they are
recorded nowhere else; that is a local file read and nothing leaves the machine.
Everything it writes lives under `~/.notchling/`.

It makes one kind of network connection, and never without being told to. The panel asks once whether
it should check daily for a new release; unanswered and answered-no both mean it never connects of its
own accord. Answered yes, it runs `git fetch` against this project's public Homebrew tap, once a day
at an hour you pick, and compares the version published there with the one installed.

The settings window also has a **Check Now** button, which makes that same request once, when you
press it, whatever the daily setting says — pressing it is the consent for it.

Either way the request carries nothing but what any `git fetch` of a public repository carries, no
data about you or your sessions is included, and installing an update is a separate, explicit click.
Daily checking can be turned off again in the settings window.

The mascot is this project's own creature, not Anthropic's logo or mark.

## The art is original

Every pixel of the mascot — the walking critter, the alert bar-and-dot, the tick,
their colours and their frame timings — is original to this project and MIT
licensed along with the rest of the code. It lives as ASCII rows in
`Sources/Notchling/UI/Mascot/MascotArt.swift`, where `#` is a lit pixel, and
`make-icon.py` renders the same grid into the app icon so the two cannot drift.

## Third-party code

None. Notchling has no package dependencies — the notch surface, the window and the shape are all in
`Sources/Notchling/UI`. An earlier version drew its notch with DynamicNotchKit (MIT), with thanks; the
current implementation is original.
