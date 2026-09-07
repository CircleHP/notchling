//
//  The one ordinary window this app has.
//
//  Preferences cannot live in the notch panel. `WidgetPresenter` refuses to resize while the panel is
//  open — that is what `PanelLayout` freezes its rows for, and why the reason is written out at length
//  there — so anything inside it has to have a height known before it opens. A settings surface is the
//  opposite of that: it grows every time something is added to it.
//
//  It also draws in the system appearance rather than the widget's black chrome. The panel is opaque
//  black because on a notched display it has to match a hole in the screen; a window has no such
//  excuse, and one that ignored the user's appearance would just look broken.
//

import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// Set once at launch, before anything can open the window. The coordinator owns what happens on a
    /// change — turning checks off also drops any release it had already found.
    var onUpdateChecksChanged: ((Bool) -> Void)?
    /// False on an install Homebrew did not make, where there is nothing a yes could do.
    var updatesSupported = false
    /// Runs a check now and returns the line to show. Set at launch, like the two above.
    var checkForUpdatesNow: (() async -> String)?

    func show() {
        let window = window ?? makeWindow()
        self.window = window

        // Rebuilt on every open. The window is reused, so a `@State` initialised from
        // `UpdatePreference` would be read once and then be wrong: answer the panel's consent row
        // after having opened this window and the switch still says off, with the hour disabled —
        // and flipping it to correct itself would turn checking off.
        install(content: window)
        window.center()
        // An accessory app has to ask. Without this the window orders front behind whatever is
        // frontmost, and the click that opened it appears to have done nothing.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Notchling Settings"
        // The controller owns it across opens; without this, closing it deallocates the window out
        // from under the reference and the second open crashes.
        window.isReleasedWhenClosed = false
        window.delegate = self

        install(content: window)
        return window
    }

    /// The window takes its size from what the content asks for, and the content asks for a width and
    /// nothing else — so it has to *not* fill. A `maxHeight: .infinity` in there gives the hosting
    /// view an unbounded fitting size, and the window opens fifteen hundred points tall.
    private func install(content window: NSWindow) {
        let view = NSHostingView(rootView: PreferencesView(
            updatesSupported: updatesSupported,
            setUpdateChecks: { [weak self] in self?.onUpdateChecksChanged?($0) },
            checkNow: { [weak self] in await self?.checkForUpdatesNow?() ?? "Unavailable" }
        ))
        window.contentView = view
        window.setContentSize(view.fittingSize)
    }

    /// Hand focus back to whatever the person was doing. Closing the only window of an app that stays
    /// active leaves keystrokes going nowhere visible.
    ///
    /// `deactivate()` rather than `hide(_:)`: hiding an app hides all of its windows, and one of this
    /// app's windows is the widget.
    func windowWillClose(_ notification: Notification) {
        NSApp.deactivate()
    }
}

/// One thing that can be wired, what it is doing, and the single button that changes it.
private struct WiringRow: View {
    struct Action {
        let title: String
        let run: () -> Void
    }

    let title: String
    let detail: String
    let action: Action?
    let isBusy: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 78, alignment: .leading)

            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let action {
                Button(action.title) { action.run() }
                    .disabled(isBusy)
            }
        }
    }
}

struct PreferencesView: View {
    /// What the diagnostics button is doing, which is the only state on this window so far.
    private enum Collection: Equatable {
        case idle
        case running
        case collected(URL)
        case failed(String)
    }

    /// Wide enough for a sentence at a readable measure. Height is whatever the content comes to —
    /// see `makeWindow()`, which asks the hosting view rather than deciding for it.
    static let width: CGFloat = 400

    let updatesSupported: Bool
    let setUpdateChecks: (Bool) -> Void
    let checkNow: () async -> String

    @State private var collection: Collection = .idle
    @State private var showsClaudeUsage = PanelPreference.showsPlanUsage(for: .claude)
    @State private var showsCodexUsage = PanelPreference.showsPlanUsage(for: .codex)
    @State private var wiring: AgentWiring?
    @State private var wiringError: String?
    @State private var isWiring = false
    /// Raised only when something else holds the status line slot, because that is the one action
    /// here that would change a configuration this app did not write.
    @State private var askingAboutStatusLine = false
    /// An unanswered question reads as off here. The panel is where it gets asked; this is where it
    /// gets changed, and a switch cannot show three states.
    @State private var checksEnabled = UpdatePreference.current == .on
    @State private var checkHour = UpdatePreference.hour
    @State private var manualCheck: String?
    @State private var isCheckingNow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            identity
            if AgentSetup.isSupported {
                Divider()
                claudeCode
                // Only for a machine that has Codex. An agent nobody here runs is not a row worth
                // drawing, and a row offering to wire one is worse — it reads as something missing.
                if showsCodex {
                    Divider()
                    codex
                }
            } else {
                // No installer beside this build — a `swift run` rather than a bundle — so there are no
                // agent blocks for these to sit under, and they would otherwise be unreachable.
                Divider()
                panel
            }
            if updatesSupported {
                Divider()
                updateChecks
            }
            Divider()
            diagnostics
        }
        .padding(20)
        .frame(width: PreferencesView.width, alignment: .leading)
    }

    private var identity: some View {
        HStack(spacing: 10) {
            BrandMarkView(height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Notchling")
                    .font(.system(size: 13, weight: .semibold))
                Text(InstalledBuild.running.map { "Version \($0)" } ?? "Version unknown")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Claude Code

    /// What `notchling-hooks` would tell you, with the command run for you.
    ///
    /// Every row reads its real state first, so the button says the true next action rather than a
    /// hopeful "Install" — and every button runs the same script the command line does. The state
    /// itself is never decided here: see `AgentSetup`.
    private var claudeCode: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Code")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if let wiring {
                WiringRow(
                    title: "Hooks",
                    detail: hooksDetail(wiring),
                    action: hooksAction(wiring),
                    isBusy: isWiring
                )
                WiringRow(
                    title: "Plan usage",
                    detail: statusLineDetail(wiring),
                    action: statusLineAction(wiring),
                    isBusy: isWiring
                )
                Text("Sessions started from now on pick this up. Ones already running never will — Claude Code reads both at session start.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                planUsageToggle(for: .claude, isOn: $showsClaudeUsage)
            } else if wiringError == nil {
                ProgressView().controlSize(.small)
            }

            if let wiringError {
                Text(wiringError)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await reloadWiring() }
        .confirmationDialog(
            "A status line is already configured",
            isPresented: $askingAboutStatusLine,
            titleVisibility: .visible
        ) {
            Button("Run Notchling in Front of It") { perform { try AgentSetup.addStatusLine(occupied: .chain) } }
            Button("Replace It", role: .destructive) { perform { try AgentSetup.addStatusLine(occupied: .replace) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(wiring?.statusLineCommand ?? "It") has the one status line slot, and the plan limits reach it and nothing else. Notchling can read the same payload and print nothing, leaving yours to print exactly what it prints now.")
        }
    }

    // MARK: - Codex

    /// Shown only where there is something to say. `available` is the machine looking like it has
    /// Codex; the second half covers hooks left wired by an install that has since gone.
    private var showsCodex: Bool {
        guard let codex = wiring?.codex else { return false }
        return codex.available || codex.hooks != .none
    }

    /// One row, because hooks are the whole of Codex's surface: there is no registry to discover
    /// sessions from and no status line slot to put plan usage in.
    @ViewBuilder
    private var codex: some View {
        if let wiring, let codex = wiring.codex {
            VStack(alignment: .leading, spacing: 8) {
                Text("Codex")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                WiringRow(
                    title: "Hooks",
                    detail: codexHooksDetail(codex),
                    action: codexHooksAction(codex, resolved: wiring.hookResolved),
                    isBusy: isWiring
                )

                Text(codexFootnote(codex))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                planUsageToggle(for: .codex, isOn: $showsCodexUsage)
            }
        }
    }

    private func codexHooksDetail(_ codex: CodexWiring) -> String {
        switch codex.hooks {
        case .wired: "Wired"
        case .none: "Not wired — Codex sessions do not appear at all"
        case .elsewhere: "Wired to another copy of Notchling"
        // Not something this writes, and not something it should claim to have found either.
        case .plugin: "Provided by a Codex plugin"
        }
    }

    /// `resolved` is the hook binary this build would write down. Nothing is offered that cannot run:
    /// without one the script dies, and a button whose only outcome is an error is worse than none.
    private func codexHooksAction(_ codex: CodexWiring, resolved: String) -> WiringRow.Action? {
        switch codex.hooks {
        case .wired:
            .init(title: "Unwire") { perform { try AgentSetup.unwireHooks(provider: .codex) } }
        case .none:
            resolved.isEmpty
                ? nil
                : .init(title: "Wire") { perform { try AgentSetup.wireHooks(provider: .codex) } }
        case .elsewhere:
            resolved.isEmpty
                ? nil
                : .init(title: "Re-point") { [stale = codex.hookCommand] in
                    perform { try AgentSetup.repointHooks(from: stale, provider: .codex) }
                }
        case .plugin:
            nil
        }
    }

    /// Wiring the file is not the last step here, which is the one thing about Codex a person has to
    /// be told: it will not run a hook it has not been asked about.
    private func codexFootnote(_ codex: CodexWiring) -> String {
        switch codex.hooks {
        case .wired, .elsewhere, .plugin:
            "Run /hooks inside Codex to review and trust these. Sessions started from then on pick "
                + "them up; ones already running never will."
        case .none:
            "Wiring appends to \(codex.home), backs it up first and leaves other tools alone. "
                + "Codex then asks you to review the hooks before it runs any of them."
        }
    }

    private func hooksDetail(_ wiring: AgentWiring) -> String {
        switch wiring.hooks {
        case .wired: "Wired"
        case .none: "Not wired — the widget sees sessions but not what they are doing"
        case .elsewhere: "Wired to another copy of Notchling"
        case .plugin:
            wiring.hookCommand.isEmpty
                ? "Provided by the Notchling plugin"
                : "Provided by the plugin, and wired here too — every event is reported twice"
        }
    }

    /// Nothing is offered that cannot run. Wiring and re-pointing both need a hook binary to have
    /// been found; without one the script dies, and a button whose only outcome is an error message
    /// is worse than no button.
    private func hooksAction(_ wiring: AgentWiring) -> WiringRow.Action? {
        switch wiring.hooks {
        case .wired:
            .init(title: "Unwire") { perform { try AgentSetup.unwireHooks() } }
        case .none:
            wiring.hookResolved.isEmpty
                ? nil
                : .init(title: "Wire") { perform { try AgentSetup.wireHooks() } }
        case .elsewhere:
            wiring.hookResolved.isEmpty
                ? nil
                : .init(title: "Re-point") { [stale = wiring.hookCommand] in
                    perform { try AgentSetup.repointHooks(from: stale) }
                }
        // The plugin's own hooks are not ours to remove — but a settings.json copy alongside them is
        // exactly the double-reporting `setup` offers to undo, and hiding it makes a machine that is
        // reporting everything twice look healthy.
        case .plugin:
            wiring.hookCommand.isEmpty
                ? nil
                : .init(title: "Unwire") { [stale = wiring.hookCommand] in
                    perform { try AgentSetup.unwireHooks(at: stale) }
                }
        }
    }

    private func statusLineDetail(_ wiring: AgentWiring) -> String {
        switch wiring.statusLine {
        case .ours: "Wired"
        case .chain: "Wired, in front of \(wiring.wrapped)"
        case .foreign: "\(wiring.statusLineCommand) has the slot, so nothing feeds the bars"
        case .none: "Not wired — no plan usage, and no per-session context"
        }
    }

    private func statusLineAction(_ wiring: AgentWiring) -> WiringRow.Action? {
        switch wiring.statusLine {
        case .ours, .chain: .init(title: "Remove") { perform { try AgentSetup.removeStatusLine() } }
        case .foreign:
            wiring.statusLineResolved.isEmpty
                ? nil
                : .init(title: "Add…") { askingAboutStatusLine = true }
        case .none:
            wiring.statusLineResolved.isEmpty
                ? nil
                : .init(title: "Wire") { perform { try AgentSetup.addStatusLine() } }
        }
    }

    /// Off the main actor: `status` shells out to `claude plugin list`, which is not instant, and the
    /// window is drawing a spinner for that whole time.
    private func reloadWiring() async {
        let read = await Task.detached { Result { try AgentSetup.read() } }.value
        switch read {
        case let .success(current):
            wiring = current
            wiringError = nil
        case let .failure(error):
            wiringError = Self.message(for: error)
        }
    }

    /// The reload comes first and the message second, which is not fussiness: `reloadWiring` clears
    /// `wiringError` on success, and it almost always succeeds — so setting the message before it
    /// erased every failure this block can produce before a frame was ever drawn. The row snapped
    /// back to the state it was already in and said nothing.
    private func perform(_ work: @escaping @Sendable () throws -> Void) {
        isWiring = true
        wiringError = nil
        Task {
            let done = await Task.detached { Result { try work() } }.value
            await reloadWiring()
            if case let .failure(error) = done { wiringError = Self.message(for: error) }
            isWiring = false
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case AgentSetup.Failure.unavailable: "This copy of Notchling has no installer beside it."
        case let AgentSetup.Failure.failed(reason): reason
        default: "Could not read what is wired."
        }
    }

    /// The plan-usage switches live with the agent whose plan they describe, one each, because they are
    /// separate accounts: someone paying for one and not the other has no reason to give up a line of
    /// the panel to the one they do not. Independent, so either or both can be on.
    ///
    /// Written straight to the preference, like the hour picker below and unlike the update switch:
    /// nothing has to react to this. The panel reads the flag on its next sweep, two seconds away.
    @ViewBuilder
    private func planUsageToggle(for provider: Provider, isOn: Binding<Bool>) -> some View {
        Toggle("Show plan usage", isOn: isOn)
            .onChange(of: isOn.wrappedValue) { _, shown in
                PanelPreference.setShowsPlanUsage(shown, for: provider)
            }

        Text(planUsageFootnote(for: provider))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Only where the agent blocks are not drawn. See the body.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Panel")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            planUsageToggle(for: .claude, isOn: $showsClaudeUsage)
            planUsageToggle(for: .codex, isOn: $showsCodexUsage)
        }
    }

    private func planUsageFootnote(for provider: Provider) -> String {
        switch provider {
        case .claude:
            "The 5-hour and 7-day numbers along the bottom of the panel. Off, they are neither drawn nor "
                + "read. Per-session context stays."
        case .codex:
            "The 5-hour and 7-day numbers along the bottom of the panel, read out of the session's own "
                + "record. Off, that record is not opened for them at all. Per-session context stays."
        }
    }

    private var updateChecks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Check for new versions daily", isOn: $checksEnabled)
                .onChange(of: checksEnabled) { _, enabled in setUpdateChecks(enabled) }

            Picker("At", selection: $checkHour) {
                ForEach(0 ..< 24, id: \.self) { hour in
                    Text(UpdatePreference.label(forHour: hour)).tag(hour)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(!checksEnabled)
            .onChange(of: checkHour) { _, hour in UpdatePreference.hour = hour }

            Text("Fetches this app's Homebrew tap to see whether a newer release exists. Nothing is sent, and nothing is installed until you ask for it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                // Works whatever the switch says: asking is its own consent, for this one request.
                Button("Check Now") { check() }
                    .disabled(isCheckingNow)

                if isCheckingNow {
                    ProgressView().controlSize(.small)
                } else if let manualCheck {
                    Text(manualCheck)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func check() {
        isCheckingNow = true
        manualCheck = nil
        Task {
            let result = await checkNow()
            manualCheck = result
            isCheckingNow = false
        }
    }

    /// The button says what it does, so it is on its own. What it cannot say is that the file is
    /// usually empty — the widget only logs what it could not do — and that an empty one is still
    /// worth sending. That belongs in a tooltip rather than in two lines of prose above one control.
    private var diagnostics: some View {
        HStack(spacing: 10) {
            Button("Collect Logs…") { collect() }
                .disabled(collection == .running)
                .help("Writes what the widget has logged in the last \(LogCollection.window) to a file and reveals it. Usually empty — that is worth reporting too.")

            switch collection {
            case .idle:
                EmptyView()
            case .running:
                ProgressView().controlSize(.small)
            case .collected:
                Text("Revealed in Finder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case let .failed(reason):
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    /// Off the main actor: `log show` walks the whole store and takes seconds on a machine that has
    /// been up a while, and the window is drawing a spinner that whole time.
    private func collect() {
        collection = .running
        Task {
            let result = await Task.detached { Result { try LogCollection.collect() } }.value
            switch result {
            case let .success(url):
                collection = .collected(url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case let .failure(error):
                collection = .failed("Could not collect logs")
                Log.diagnostics.error(
                    "log show failed: \((error as NSError).code, privacy: .public)"
                )
            }
        }
    }
}
