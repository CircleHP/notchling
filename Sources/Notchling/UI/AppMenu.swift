//
//  A main menu that is never drawn.
//
//  An accessory app does not get the menu bar. Verified rather than assumed: with the settings window
//  key and `lsappinfo` reporting this app frontmost, the strip at the top of the screen still belonged
//  to the app behind it. So there is no empty menu bar to avoid here — that fear is why
//  `WidgetPanel.canBecomeKey` is false, and it does not apply to an ordinary window.
//
//  What a main menu still does is supply key equivalents to the key window. Without one, Command-Q
//  does not quit, Command-W does not close, and — the one that matters as soon as a setting needs
//  typing into — Command-V does nothing in a text field. Also verified: Command-Q terminated the app
//  only once this existed.
//
//  Nothing here has a target. Standard selectors travel the responder chain, which is what lets the
//  Edit items reach a text field this file knows nothing about.
//

import AppKit

@MainActor
enum AppMenu {
    static func install() {
        let bar = NSMenu()
        bar.addItem(applicationItem())
        bar.addItem(editItem())
        bar.addItem(windowItem())
        NSApp.mainMenu = bar
    }

    /// Only items with a key equivalent. An About item would be unreachable — there is no bar to pull
    /// it down from — so it would be a line of code that can never run.
    private static func applicationItem() -> NSMenuItem {
        let menu = NSMenu(title: "Notchling")
        menu.addItem(
            withTitle: "Settings…",
            action: #selector(AppDelegate.showPreferences(_:)),
            keyEquivalent: ","
        )
        menu.addItem(.separator())
        // Not `NSApplication.terminate`. Under launchd's `KeepAlive` that ends the process and gets a
        // new one a second later, which is the fake quit the power button used to be — leaving it here
        // would just move the bug to the keyboard.
        menu.addItem(
            withTitle: "Quit Notchling",
            action: #selector(AppDelegate.stopWidget(_:)),
            keyEquivalent: "q"
        )

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    /// Present so text fields behave. Nothing on the settings window is editable yet, which is exactly
    /// why this is easy to leave out until the first one is added and paste silently does nothing.
    private static func editItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    /// Command-W. The settings window has a close button, but a window that cannot be dismissed from
    /// the keyboard is the kind of thing only its author never notices.
    private static func windowItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
