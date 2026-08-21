//
//  Where the app says what it could not do.
//
//  Every input this app has is an undocumented contract — the session registry, hook payloads, the
//  status line's JSON — and each one can change under it. When one does the widget degrades quietly:
//  a row that never appears, a click that does nothing, numbers that stop moving. These are the
//  places that used to discard the reason.
//
//  Read it with:
//
//      log stream --predicate 'subsystem == "local.notchling"' --level info
//      log show --predicate 'subsystem == "local.notchling"' --last 1h
//
//  On privacy: `Logger` redacts interpolated values by default, so anything left implicit reads as
//  `<private>` in a log someone else collected — useless for the case this exists for. What names a
//  contract is therefore marked public on purpose: file names, event names, error codes, counts.
//  What describes the user's work — paths, prompts, session titles — is left to redact itself.
//

import os

enum Log {
    nonisolated static let subsystem = "local.notchling"

    /// `~/.claude/sessions/<pid>.json`, the one input that reports sessions we never saw start.
    static let registry = Logger(subsystem: subsystem, category: "registry")

    /// The hook spool: events arriving, and events this build could not read.
    static let spool = Logger(subsystem: subsystem, category: "spool")

    /// Clicking a row. The failures here are AppleScript's, and they are the reason "nothing
    /// happens" has never had an explanation.
    static let focus = Logger(subsystem: subsystem, category: "focus")

    /// Plan limits and per-session metrics, written by the status line.
    static let usage = Logger(subsystem: subsystem, category: "usage")

    /// The settings window's own failures — including the one that collects everything above.
    static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
}
