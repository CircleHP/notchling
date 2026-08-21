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
    @State private var showsPlanUsage = PanelPreference.showsPlanUsage
    /// An unanswered question reads as off here. The panel is where it gets asked; this is where it
    /// gets changed, and a switch cannot show three states.
    @State private var checksEnabled = UpdatePreference.current == .on
    @State private var checkHour = UpdatePreference.hour
    @State private var manualCheck: String?
    @State private var isCheckingNow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            identity
            Divider()
            panel
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

    /// Written straight to the preference, like the hour picker below and unlike the update switch:
    /// nothing has to react to this. The panel reads the flag on its next sweep, two seconds away.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show plan usage", isOn: $showsPlanUsage)
                .onChange(of: showsPlanUsage) { _, shown in PanelPreference.showsPlanUsage = shown }

            Text("The 5-hour and 7-day bars along the bottom of the panel. Off, they are neither drawn nor read. Per-session context stays.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
