# Notices

## Not affiliated with Anthropic or OpenAI

Notchling is an unofficial, third-party tool. It is not made by, endorsed by,
or affiliated with either. "Claude" and "Claude Code" are trademarks of
Anthropic, PBC, and "Codex" is OpenAI's, used here only to describe what the
tool observes.

It reads Claude Code's own on-disk session registry and receives hook events from both agents.
It sends no telemetry, ever, and reports nothing about you anywhere. It reads two entries from a Claude
Code session's own transcript — the title Claude derives, and a colour set with `/color` — because they
are recorded nowhere else; that is a local file read and nothing leaves the machine.

For Codex it reads two local files, and a named few things out of them. Every Codex hook event points
at that session's own record of itself, and three of the numbers a row shows exist nowhere else: how
full the context is, and where the account's two rate-limit windows stand. It reads those, the effort
setting, and nothing else — and it reads the name Codex derives for a session from the small shared
index beside them, which is the same kind of thing as the title above.

That record also contains the conversation, which is not read. What keeps that from being a promise you
have to take on faith is the order the file is examined in: a line longer than eight kilobytes is
discarded before anything looks at it, and the records being sought run to under four, while the ones
carrying what anybody said run to hundreds. Only a line naming one of those two records is given to a
JSON parser at all. Nothing is sent anywhere, from either file.

Everything it writes lives under `~/.notchling/`, apart from two files it is told to edit:
`~/.claude/settings.json` — the hook entries and the optional status line — and `~/.codex/hooks.json`,
the hook entries alone. Both are written only by `notchling-hooks` or by a button in the settings
window, backed up on every change, and removable by the same commands. It never writes Codex's record
of which hooks you have trusted; that answer is yours to give, inside Codex.

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
licensed along with the rest of the code — as are the two marks that head a
session row, one per agent, which evoke rather than copy and are nobody's logo.
All of it lives as ASCII rows under `Sources/Notchling/UI/Mascot/`, where `#` is
a lit pixel, and `make-icon.py` renders the mascot's own grid into the app icon
so the two cannot drift.

## Third-party code

None. Notchling has no package dependencies — the notch surface, the window and the shape are all in
`Sources/Notchling/UI`. An earlier version drew its notch with DynamicNotchKit (MIT), with thanks; the
current implementation is original.
