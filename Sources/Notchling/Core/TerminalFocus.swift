//
//  Brings the terminal that owns a session to the front.
//
//  Warp exports `WARP_FOCUS_URL=warp://session/<uuid>` into every shell's environment and handles
//  that URL itself. It is undocumented (warpdotdev/warp#8611 is still open) but it ships in every
//  Warp shell, which is what gives this widget a handle on a terminal that exposes no scripting
//  interface. Unverified: whether it selects the specific pane or merely activates Warp.
//

import AppKit

enum TerminalFocus {
    @MainActor
    static func focus(_ session: Session) {
        if let focusURL = session.focusURL, let url = URL(string: focusURL) {
            NSWorkspace.shared.open(url)
            return
        }

        // iTerm2 and Terminal.app are scriptable, and can be matched on the controlling tty.
        if let tty = session.tty {
            switch session.termProgram {
            case "iTerm.app":
                runAppleScript(iTermScript(tty: tty))
                return
            case "Apple_Terminal":
                runAppleScript(terminalScript(tty: tty))
                return
            default:
                break
            }
        }

        // Anything else: activate the owning application and let the user find the tab.
        if let hostBundleID = session.hostBundleID, activate(bundleID: hostBundleID) { return }
        if let fallback = bundleID(forTermProgram: session.termProgram) {
            _ = activate(bundleID: fallback)
        }
    }

    /// Whether `focus` can do something precise, as opposed to merely activating an app.
    static func canFocusPrecisely(_ session: Session) -> Bool {
        if session.focusURL != nil { return true }
        if session.tty != nil, session.termProgram == "iTerm.app" || session.termProgram == "Apple_Terminal" {
            return true
        }
        return false
    }

    // MARK: - Helpers

    @MainActor
    private static func activate(bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    }

    private static func bundleID(forTermProgram termProgram: String?) -> String? {
        switch termProgram {
        case "WarpTerminal": "dev.warp.Warp-Stable"
        case "iTerm.app": "com.googlecode.iterm2"
        case "Apple_Terminal": "com.apple.Terminal"
        case "vscode": "com.microsoft.VSCode"
        default: nil
        }
    }

    private static func runAppleScript(_ source: String) {
        // NSAppleScript rather than `osascript`: no subprocess, and no shell quoting to get wrong.
        guard let script = NSAppleScript(source: source) else {
            Log.focus.error("AppleScript would not compile")
            return
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)

        // The usual one is -1743: the user has not granted this app permission to send events to
        // the terminal, which looks exactly like a click that did nothing.
        guard let error else { return }
        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        let message = (error[NSAppleScript.errorMessage] as? String) ?? "no message"
        Log.focus.error("focus failed: \(code, privacy: .public) \(message, privacy: .public)")
    }

    private static func iTermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                    repeat with theSession in sessions of theTab
                        if tty of theSession is "\(tty)" then
                            select theWindow
                            select theTab
                            select theSession
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                    if tty of theTab is "\(tty)" then
                        set selected tab of theWindow to theTab
                        set index of theWindow to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }
}
