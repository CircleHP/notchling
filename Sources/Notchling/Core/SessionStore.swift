//
//  The single source of truth, merging two independent inputs: the registry Claude Code maintains
//  itself (authoritative for existence, pid, name and cwd, and it sees sessions that started before
//  this app did) and our hook events (the only source for states the registry cannot express).
//
//  Arbitration rule: whichever input observed the session more recently wins, with one exception —
//  the registry may not clear `needsYou`. See `apply(registry:)`.
//

import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    /// How long a finished session stays visibly `done` before settling to `idle`.
    static let doneDecay: TimeInterval = 20

    /// How often the copy on disk is compared with the one running.
    ///
    /// Deliberately long. Releases are rare, the newest one is the stable one until somebody reports
    /// otherwise, and the widget is meant to run for weeks at a time — so a user who has already
    /// waited for a release can wait a few more hours to be told about it. Checking often would buy
    /// nothing and cost a plist read on a timer that exists for something else.
    ///
    /// Wall-clock, so a machine that slept through the interval notices on the next sweep after it
    /// wakes rather than counting only the time it was awake.
    static let versionCheckInterval: TimeInterval = 6 * 60 * 60

    /// How long a session may be absent from the registry snapshot before it is dropped. Covers the
    /// start-up window where hooks fire before the registry file is written.
    static let registryGrace: TimeInterval = 30

    /// The fallback, used only until a tool has completed here at least once. After that the threshold
    /// comes from the tool's own history — see `Session.stallThreshold(absolute:)`. It stays generous
    /// because with no history at all, crying wolf would train the flag to be ignored.
    static let stallThreshold: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["NOTCHLING_STALL_SECS"],
           let value = TimeInterval(raw), value > 0
        {
            return value
        }
        return 600
    }()

    /// How long the registry must continuously report `idle` before that overrides a stuck
    /// `needsYou`. Generous, because being wrong here silently drops the one notification the widget
    /// exists to deliver.
    static let needsYouReleaseAfterIdle: TimeInterval = 60

    /// Display-ordered: attention-wanting first, then most recently active.
    private(set) var sessions: [Session] = []

    var usage: UsageSnapshot?

    /// A build sitting on disk that this process is not the one running. See `InstalledBuild`.
    var pendingVersion: String?

    /// Everything the panel shows about updating, written by `UpdateCoordinator`.
    ///
    /// Here rather than on the coordinator for the same reason `usage` is here: this class is what the
    /// panel reads, and it is already carried through every layer of the view tree. One value rather
    /// than three properties, so adding to it does not widen anything.
    var updates = UpdateStatus()

    /// Fired for every state transition, once per edge.
    var onTransition: ((Session, SessionState, SessionState) -> Void)?

    /// Fired the moment a working session crosses `stallThreshold`, once per turn.
    var onStalled: ((Session) -> Void)?

    var onChange: (() -> Void)?

    /// Fired when a session leaves the store, so state held elsewhere and keyed by it can go too.
    var onRemoved: ((Session) -> Void)?

    private var index: [SessionKey: Session] = [:]

    private let processEnvironment = ProcessEnvironmentReader()

    private let transcripts = TranscriptReader()

    /// pids already looked up, so a session with genuinely no terminal identity is not re-probed on
    /// every sweep. Purged by `remove(key:)`: a pid that outlives its session blocks identity
    /// resolution for whatever process macOS gives that number to next.
    private(set) var resolvedPIDs: Set<Int32> = []

    /// Injectable so the time-based arbitration below can be tested without sleeping. Every rule in this
    /// file that compares timestamps has edge cases an hour or a second either side of the obvious case, so
    /// they are worth pinning down deterministically.
    private let now: () -> Date
    private let readPendingVersion: () -> String?
    private let readMetrics: @MainActor () -> [String: SessionMetrics]
    private var lastVersionCheck: Date?

    init(
        now: @escaping () -> Date = { Date.now },
        pendingVersion: @escaping () -> String? = { InstalledBuild.pendingVersion() },
        metrics: @escaping @MainActor () -> [String: SessionMetrics] = { SessionMetricsReader.readAll() }
    ) {
        self.now = now
        self.readPendingVersion = pendingVersion
        self.readMetrics = metrics
    }

    /// The only way a session leaves the store.
    ///
    /// Removing it from `index` alone leaves its pid in `resolvedPIDs` and its environment in the
    /// reader's cache forever. macOS reuses pids, so the next session to be handed that number is
    /// silently refused a terminal-identity probe: no tty, no focus URL, and a click that falls back
    /// to activating the app instead of jumping to the tab.
    @discardableResult
    private func remove(key: SessionKey) -> Session? {
        guard let session = index.removeValue(forKey: key) else { return nil }
        if let pid = session.pid { release(pid: pid) }
        transcripts.forget(key: key)
        onRemoved?(session)
        return session
    }

    /// Record which process a session belongs to, letting go of whatever pid it held before.
    ///
    /// A pid left behind in `resolvedPIDs` and the reader's cache after the session stopped using it
    /// refuses a probe to whatever process macOS hands that number to next — the row appears and the
    /// click quietly does nothing. `remove(key:)` only ever released the pid a session still held, so a
    /// session whose pid *changed* stranded the old one.
    private func adopt(pid: Int32, startedAt: Double?, on session: inout Session) {
        if let held = session.pid, held != pid {
            release(pid: held)
            session.pidStartedAt = nil
        }
        session.pid = pid

        // The reporter's answer wins where there is one: the hook read it as a child of the agent, so
        // the pid was certainly that process then. Reading it here is the fallback for a pid that
        // arrived without one — the registry reports no start time — and is only as good as how
        // promptly the app got to the event.
        if let startedAt {
            session.pidStartedAt = startedAt
        } else if session.pidStartedAt == nil {
            session.pidStartedAt = ProcessLiveness.startTime(of: pid)
        }
    }

    private func release(pid: Int32) {
        resolvedPIDs.remove(pid)
        processEnvironment.forget(pid: pid)
    }

    /// Current state of one session. The panel freezes which rows it draws when it opens but keeps
    /// their *contents* live, and this is how a frozen row finds itself again.
    func session(key: SessionKey) -> Session? { index[key] }

    // MARK: - Aggregates

    var needsYouCount: Int { count(of: .needsYou) }
    var workingCount: Int { count(of: .working) }
    var doneCount: Int { count(of: .done) }
    var errorCount: Int { count(of: .error) }
    var idleCount: Int { count(of: .idle) }

    private func count(of state: SessionState) -> Int {
        sessions.reduce(0) { $0 + ($1.state == state ? 1 : 0) }
    }

    /// `NOTCHLING_PREVIEW=done` forces one state for visual inspection. Otherwise unreachable on
    /// demand — the session you are driving from is always `working`.
    private static let previewState: SessionState? = ProcessInfo.processInfo
        .environment["NOTCHLING_PREVIEW"]
        .flatMap(SessionState.init(rawValue:))

    /// The single state the mascot represents, when several sessions disagree.
    var aggregateState: SessionState {
        if let preview = Self.previewState { return preview }
        if needsYouCount > 0 { return .needsYou }
        if errorCount > 0 { return .error }
        if workingCount > 0 { return .working }
        if doneCount > 0 { return .done }
        return .idle
    }

    // MARK: - Hook events

    func apply(_ event: HookEvent) {
        // The watcher sets aside every event whose agent this build cannot name, so reaching here with
        // an unknown one should be impossible. Belt and braces: the cost of being wrong is a session
        // filed under the wrong agent, and every source keyed by it then answering for the wrong one.
        guard let key = event.sessionKey else { return }
        var session = index[key] ?? Session(sessionID: event.sessionId, provider: key.provider)
        let previous = session.state

        if let pid = event.pid { adopt(pid: pid, startedAt: event.pidStartedAt, on: &session) }
        if let cwd = event.cwd { session.cwd = cwd }
        // Terminal identity only ever arrives from the top-level session's own environment.
        if let url = event.focusURL { session.focusURL = url }
        if let warp = event.warpSessionId { session.warpSessionID = warp }
        if let term = event.termProgram { session.termProgram = term }
        if let host = event.hostBundleId { session.hostBundleID = host }

        var newState: SessionState?

        // An event from inside a subagent describes that agent, not the session that spawned it. Progress
        // and attention still belong to the session, but the tool identity
        // and its timing history do not — attributed to the session, they make a row claim its main thread
        // is running a subagent's `Grep`.
        var wasAgentScoped = false
        if let agentID = event.agentId {
            wasAgentScoped = applyAgentEvent(
                event, agentID: agentID, to: &session, sessionState: &newState
            )
        }

        if let path = event.transcriptPath, session.transcriptPath == nil {
            session.transcriptPath = path
        }

        if !wasAgentScoped {
            switch event.event {
            case "SessionStart":
                newState = .idle
                session.turnStartedAt = nil
                session.lastToolFailure = nil
                session.agents.removeAll()
                session.toolCounts = [:]
                session.currentTool = nil
                session.needsYouMessage = nil

            case "UserPromptSubmit":
                newState = .working
                session.turnStartedAt = event.date
                session.lastToolFailure = nil
                session.agents.removeAll()
                session.toolCounts = [:]
                session.currentTool = nil
                session.currentToolSummary = nil
                session.needsYouMessage = nil
                session.lastMessage = nil
                session.lastPrompt = event.userInput
                session.lastProgressAt = event.date
                session.currentPromptID = event.promptId
                session.isStalled = false
                // A new turn supersedes the last finish, so an unfinished turn cannot resurface it.
                session.lastFinishedAt = nil

            case "PreToolUse":
                newState = .working
                session.needsYouMessage = nil
                session.lastToolFailure = nil
                // A new tool starting is proof the previous one finished, which is the only completion signal
                // there is — `PostToolUse` stays unregistered because its payload can be megabytes.
                session.recordCurrentToolDuration(endingAt: event.date)
                session.lastProgressAt = event.date
                session.isStalled = false
                if let promptID = event.promptId { session.currentPromptID = promptID }
                if let tool = event.toolName {
                    session.currentTool = tool
                    session.currentToolSummary = event.toolSummary
                    session.toolCounts[tool, default: 0] += 1
                }
                if session.turnStartedAt == nil { session.turnStartedAt = event.date }

            case "Notification":
                newState = Self.state(forNotification: event, current: session.state)
                if newState == .needsYou {
                    session.needsYouMessage = event.message
                    // Whatever this tool's elapsed time ends up being, it now includes a human deciding.
                    session.currentToolWasBlocked = true
                }

            case "Stop":
                newState = .done
                session.isStalled = false
                // The turn ending means every agent it spawned is finished, whatever we did or did not
                // observe. This is the backstop for a `SubagentStop` that never arrived.
                session.agents.removeAll()
                session.lastFinishedAt = event.date
                session.recordCurrentToolDuration(endingAt: event.date)
                session.lastProgressAt = nil
                session.lastMessage = event.lastMessage
                session.currentTool = nil
                session.currentToolSummary = nil
                session.needsYouMessage = nil

            case "StopFailure":
                newState = .error
                session.lastMessage = event.errorMessage ?? session.lastMessage
                session.currentTool = nil
                session.lastToolFailure = nil

            // Deliberately not `.error`: a tool call failing is routine, Claude retries and usually
            // recovers, and alerting every time trains the user to ignore the alert that matters. The
            // failure stays on the row until the next tool starts; if Claude cannot recover, the turn
            // ends and `StopFailure` raises it then.
            case "PostToolUseFailure":
                session.lastToolFailure = event.errorMessage ?? "tool failed"
                session.currentTool = nil
                session.currentToolSummary = nil
                session.lastProgressAt = event.date
                session.isStalled = false

            case "SessionEnd":
                remove(key: key)
                rebuild()
                return

            default:
                break
            }
        }

        if let newState {
            setState(newState, on: &session, evidenceAt: event.date)
        }

        index[key] = session
        rebuild()
        notifyTransition(from: previous, session: session)
        probeTerminalIdentity(for: key)
        readTranscriptMarks(for: key)
    }

    /// Apply an event that came from inside a subagent, and report whether it was one of those at all.
    ///
    /// `false` means the event is not agent-scoped and the session's own switch should handle it. That
    /// fallback is deliberate: an event we have not thought about must not vanish just because it happened
    /// to carry an `agent_id`.
    ///
    /// `sessionState` is what the *session* should become as a result, which is not always what the agent
    /// became — an agent finishing is not the session finishing, and an agent blocked on a permission
    /// prompt does block the session.
    private func applyAgentEvent(
        _ event: HookEvent,
        agentID: String,
        to session: inout Session,
        sessionState: inout SessionState?
    ) -> Bool {
        var agent = session.agents[agentID]
            ?? SubagentActivity(agentID: agentID, agentType: event.agentType, startedAt: event.date)
        if let type = event.agentType { agent.agentType = type }

        /// Progress belongs to both. During a fan-out the main thread emits nothing between the `Task`
        /// call and the agents returning, so without bubbling this up every fan-out longer than the stall
        /// threshold would report a false stall. There is a regression test for exactly that.
        func recordProgress() {
            agent.lastProgressAt = event.date
            session.lastProgressAt = event.date
            session.isStalled = false
        }

        switch event.event {
        case "SubagentStart":
            agent.state = .working
            agent.finishedAt = nil
            recordProgress()
            sessionState = .working
            if session.turnStartedAt == nil { session.turnStartedAt = event.date }

        case "PreToolUse":
            agent.state = .working
            // Same completion signal the session uses: the next tool starting proves the last one
            // finished. Recorded against this agent's history, never its session's.
            agent.recordCurrentToolDuration(endingAt: event.date)
            recordProgress()
            if let tool = event.toolName {
                agent.currentTool = tool
                agent.currentToolSummary = event.toolSummary
                agent.toolCounts[tool, default: 0] += 1
            }
            sessionState = .working

        case "Notification":
            if Self.state(forNotification: event, current: agent.state) == .needsYou {
                agent.state = .needsYou
                agent.currentToolWasBlocked = true
                // Also on the session: until child rows exist, the session's row is the only place this
                // message can be read.
                session.needsYouMessage = event.message
                session.currentToolWasBlocked = true
            }

        case "SubagentStop":
            agent.recordCurrentToolDuration(endingAt: event.date)
            agent.state = .done
            agent.finishedAt = event.date
            agent.currentTool = nil
            agent.currentToolSummary = nil
            agent.lastMessage = event.lastMessage
            // No `sessionState`. An agent returning is progress, not a finish — only the session's own
            // `Stop` is that, and a state change here would fire one notification and one sound cue per
            // agent, five of each for a single fan-out.
            session.lastProgressAt = event.date
            session.isStalled = false

        case "StopFailure":
            agent.state = .error
            agent.finishedAt = event.date
            agent.lastMessage = event.errorMessage ?? agent.lastMessage
            agent.currentTool = nil
            // Left off the session on purpose: an agent failing is something the main thread is handed
            // back and often recovers from, so it is not the session failing.

        // As above: a failed tool call is not a failed agent. The message is kept so the row can show
        // what went wrong, but the agent stays working and nothing turns red.
        case "PostToolUseFailure":
            agent.lastMessage = event.errorMessage ?? agent.lastMessage
            agent.currentTool = nil
            agent.currentToolSummary = nil
            session.lastProgressAt = event.date
            session.isStalled = false

        default:
            return false
        }

        session.agents[agentID] = agent

        // A blocked agent blocks the session: the session is what you navigate to, and its terminal
        // really is waiting on a person. Checked across every running agent, so one agent carrying on
        // with its own work cannot mask a sibling's prompt.
        if session.runningAgents.contains(where: { $0.state == .needsYou }) {
            sessionState = .needsYou
        }

        return true
    }

    /// `Notification` is the only hook event whose meaning depends on a second field. Keeping that decision
    /// here leaves the event switch a flat list of one case per event, and makes the rule testable on its
    /// own.
    ///
    /// Returns nil when the notification says nothing worth showing.
    nonisolated static func state(
        forNotification event: HookEvent,
        current: SessionState
    ) -> SessionState? {
        switch event.notificationType {
        case "permission_prompt", "agent_needs_input", "elicitation_dialog":
            return .needsYou

        case "idle_prompt":
            // Means the input box has simply been idle. After a finished turn that is noise — `Stop`
            // already notified. It only matters when the session stopped mid-work to ask.
            return current == .working ? .needsYou : nil

        // `agent_completed` is not this session finishing. Claude Code raises it from the background-agent
        // list, once per agent that leaves the running band, with the parent's `session_id` and no
        // `agent_id` — so it arrives here rather than in `applyAgentEvent`, and answering `.done` made a
        // spawned agent returning sound and drop the notch exactly as if the user's own turn had ended.
        // A fan-out did it once per agent. Only the session's own `Stop` is a finish.
        //
        // It also covers the failing case: the payload says "finished" or "failed" in `message` alone, so
        // `.done` played the success cue for an agent that had failed.
        default:
            // auth_success, elicitation_complete, … — nothing to show.
            return nil
        }
    }

    // MARK: - Registry

    /// Claude Code's own registry, so everything it describes is a Claude session — and, the part that
    /// matters more than it reads, absence from a snapshot is evidence about *those* alone. A session
    /// whose agent keeps no registry is missing from every snapshot by construction, and reaping on
    /// that would delete it a grace period after it first appeared.
    func apply(registry entries: [RegistryEntry]) {
        let provider = Provider.claude
        let keys = entries.map { SessionKey(provider: provider, id: $0.sessionId) }
        let seen = Set(keys)

        for (entry, key) in zip(entries, keys) {
            var session = index[key] ?? Session(sessionID: entry.sessionId, provider: provider)
            let previous = session.state

            adopt(pid: entry.pid, startedAt: nil, on: &session)
            // A missing field means the registry did not report it, not that it was cleared.
            if let name = entry.name { session.name = name }
            if let cwd = entry.cwd { session.cwd = cwd }
            if let kind = entry.kind.flatMap(SessionKind.init(rawValue:)) { session.kind = kind }
            if let jobID = entry.jobId { session.jobID = jobID }
            session.missingFromRegistrySince = nil

            // A session blocked on a permission prompt reads as `busy` here, because a tool call is
            // still in flight — so a *sustained* idle is evidence that our `needsYou` is stale.
            if entry.status == "idle" {
                if session.registryIdleSince == nil { session.registryIdleSince = now() }
            } else {
                session.registryIdleSince = nil
            }

            // `needsYou` cannot be sticky forever, or a session that stops emitting hook events
            // while blocked is pinned to it for the rest of its life.
            //
            // The clock starts at whichever is *later*: when the registry went idle, or when we
            // entered `needsYou`. Using the registry's timestamp alone cancelled the state on the
            // very next scan for any session that had already been idle a while.
            if session.state == .needsYou,
               let idleSince = session.registryIdleSince,
               now().timeIntervalSince(max(idleSince, session.stateChangedAt)) > Self.needsYouReleaseAfterIdle
            {
                setState(.idle, on: &session, evidenceAt: now())
                session.needsYouMessage = nil
            }

            if session.state != .needsYou, let status = entry.status {
                let evidenceAt = entry.statusDate ?? now()
                if evidenceAt > session.stateSourceAt {
                    let mapped: SessionState = (status == "busy") ? .working : .idle
                    // Let a fresh `done` finish its decay rather than being flattened to idle.
                    let flattensDone = (mapped == .idle && session.state == .done)
                    if !flattensDone {
                        setState(mapped, on: &session, evidenceAt: evidenceAt)
                        // A session already mid-turn when the widget launched has no hook history,
                        // so nothing has told us when its turn began. `statusUpdatedAt` is when it
                        // went busy; without this the row shows no elapsed time until the next tool.
                        if mapped == .working, session.turnStartedAt == nil {
                            session.turnStartedAt = entry.statusDate
                        }
                        if mapped == .idle {
                            session.turnStartedAt = nil
                        }
                    }
                }
            }

            index[key] = session

            probeTerminalIdentity(for: key)
            readTranscriptMarks(for: key)

            notifyTransition(from: previous, session: session)
        }

        // Absence from the registry is the primary signal that a session is gone, but not an instant
        // one: at session start, hook events can arrive before the registry file is written, and
        // dropping the session then makes it flicker. After the grace period it is gone even if its
        // pid looks alive, because a pid can be recycled.
        let stamp = now()
        for (key, var session) in index where key.provider == provider && !seen.contains(key) {
            // A pid we have and cannot find is proof the session is gone. No pid at all is not: the
            // hook resolves it from `CLAUDE_PID` or a walk up the parent chain, and both come up
            // empty often enough. Reading that as death removed the grace period from the one case
            // it was written for — hook events arriving before the registry file exists.
            if let pid = session.pid,
               !ProcessLiveness.isSameProcess(pid: pid, startedAt: session.pidStartedAt)
            {
                remove(key: key)
                continue
            }
            if let since = session.missingFromRegistrySince {
                if stamp.timeIntervalSince(since) > Self.registryGrace {
                    remove(key: key)
                }
            } else {
                session.missingFromRegistrySince = stamp
                index[key] = session
            }
        }

        rebuild()
    }

    /// The title Claude derives and the colour a user sets live only in the session's transcript, so
    /// they have to be read rather than received. Cheap in practice: the reader does nothing unless
    /// the file changed since it last looked, and it reads backwards from the end.
    private func readTranscriptMarks(for key: SessionKey) {
        // The marks are records in Claude Code's own transcript format. Another agent's transcript is a
        // different file saying different things: scanning it would read megabytes of somebody's
        // conversation off disk on every change, looking for records that cannot be in it.
        guard key.provider.capabilities.hasTranscriptMarks else { return }
        guard let session = index[key] else { return }
        let path = session.transcriptPath
            ?? session.cwd.flatMap { TranscriptReader.path(forSession: key.id, cwd: $0) }
        guard let path else { return }

        transcripts.read(key: key, path: path) { [weak self] marks in
            guard let self, var session = self.index[key] else { return }
            if let custom = marks.customTitle { session.customTitle = custom }
            if let title = marks.title { session.aiTitle = title }
            if let colour = marks.colorName { session.colorName = colour }
            self.index[key] = session
            self.rebuild()
        }
    }

    /// Ask the process behind a session which terminal it belongs to, at most once per pid.
    ///
    /// Driven by the session having a pid rather than by the registry reporting one. A hook event from
    /// a terminal that publishes no focus URL leaves us with no tty either, and the tty is what the
    /// iTerm2 and Terminal.app focus paths match on — so a provider with no registry at all still has
    /// to reach this, or a click on its row can never do better than activating an app.
    ///
    /// Call it only after the session has been written to `index`: a pid already in the reader's cache
    /// completes synchronously, and the answer has nowhere to land until the session is there.
    private func probeTerminalIdentity(for key: SessionKey) {
        guard let session = index[key], session.processCommand == nil,
              let pid = session.pid, !resolvedPIDs.contains(pid)
        else { return }

        resolvedPIDs.insert(pid)
        resolveTerminalIdentity(for: key, pid: pid)
    }

    private func resolveTerminalIdentity(for key: SessionKey, pid: Int32) {
        processEnvironment.read(pid: pid) { [weak self] identity in
            guard let self, var session = self.index[key] else { return }
            // The probe answers about a number, and between asking and answering that number can come
            // to mean another process. Storing the answer then would put a stranger's terminal on this
            // session's row, and a click would go there.
            guard session.pid == pid,
                  ProcessLiveness.isSameProcess(pid: pid, startedAt: session.pidStartedAt)
            else { return }
            if session.focusURL == nil { session.focusURL = identity.focusURL }
            if session.warpSessionID == nil { session.warpSessionID = identity.warpSessionID }
            if session.termProgram == nil { session.termProgram = identity.termProgram }
            if session.hostBundleID == nil { session.hostBundleID = identity.hostBundleID }
            if session.tty == nil { session.tty = identity.tty }
            if session.processCommand == nil { session.processCommand = identity.command }
            self.index[key] = session
            self.rebuild()
        }
    }

    // MARK: - Periodic upkeep

    /// Called on a slow timer. Deliberately does no I/O beyond one `sysctl` per session and a few
    /// small reads — both in-kernel, and neither growing with how busy a session is.
    func tick() {
        // Turned off means not read at all rather than read and hidden. Nobody is looking at the
        // result, and the scan still reports a usage file it cannot decode — a finding in the log
        // about a part of the widget the person has switched off.
        let freshUsage = PanelPreference.showsPlanUsage ? UsageReader.read() : nil
        if freshUsage != usage { usage = freshUsage }

        refreshPendingVersion()

        let metrics = readMetrics()

        var changed = false
        let stamp = now()

        for (key, var session) in index {
            // The status line writes one file per session id and it is Claude Code's, so an agent that
            // has none must not be handed a reading that merely shares an id with one of its sessions.
            let reading = session.provider.capabilities.hasStatusLineMetrics
                ? metrics[session.sessionID]
                : nil
            if session.metrics != reading {
                session.metrics = reading
                index[key] = session
                changed = true
            }

            let threshold = session.stallThreshold(absolute: Self.stallThreshold)
            let stalled = (session.stalledFor(now: stamp) ?? 0) > threshold
            if stalled != session.isStalled {
                session.isStalled = stalled
                index[key] = session
                changed = true
                if stalled { onStalled?(session) }
            }

            // Finished agents linger so a fan-out still reads as "4 of 5 done" for a moment, then go.
            // Same decay as a finished session, for the same reason: past it, it is history not news.
            let expired = session.agents.filter { _, agent in
                guard let finishedAt = agent.finishedAt else { return false }
                return stamp.timeIntervalSince(finishedAt) > Self.doneDecay
            }
            if !expired.isEmpty {
                for agentID in expired.keys { session.agents.removeValue(forKey: agentID) }
                index[key] = session
                changed = true
            }

            if session.state == .done, stamp.timeIntervalSince(session.stateChangedAt) > Self.doneDecay {
                setState(.idle, on: &session, evidenceAt: stamp)
                index[key] = session
                changed = true
            }
            // Not merely alive: the same process. A recycled pid answers `kill(pid, 0)` and would keep
            // a dead session on the panel for as long as something unrelated held the number.
            if let pid = session.pid,
               !ProcessLiveness.isSameProcess(pid: pid, startedAt: session.pidStartedAt)
            {
                remove(key: key)
                changed = true
            }
        }

        if changed { rebuild() }
    }

    /// Throttled: `tick()` runs every two seconds, and nothing about an upgrade changes that fast.
    private func refreshPendingVersion() {
        let stamp = now()
        if let last = lastVersionCheck, stamp.timeIntervalSince(last) < Self.versionCheckInterval {
            return
        }
        lastVersionCheck = stamp

        let found = readPendingVersion()
        if found != pendingVersion { pendingVersion = found }
    }

    // MARK: - Internals

    private func setState(_ newState: SessionState, on session: inout Session, evidenceAt: Date) {
        session.stateSourceAt = max(session.stateSourceAt, evidenceAt)
        guard session.state != newState else { return }
        session.state = newState
        session.stateChangedAt = now()
    }

    private func notifyTransition(from previous: SessionState, session: Session) {
        guard session.state != previous else { return }
        onTransition?(session, previous, session.state)
    }

    private func rebuild() {
        let next = index.values
            .filter { !$0.isInfrastructure }
            .sorted {
                if $0.state.urgency != $1.state.urgency { return $0.state.urgency < $1.state.urgency }
                if $0.isStalled != $1.isStalled { return $0.isStalled }
                if $0.stateChangedAt != $1.stateChangedAt { return $0.stateChangedAt > $1.stateChangedAt }
                return $0.displayName < $1.displayName
            }

        // Only publish a real change. The registry is re-scanned every two seconds, and an
        // unconditional write counts as a mutation to @Observable — which would re-evaluate the
        // notch views every two seconds forever, whether or not anything moved.
        guard next != sessions else { return }
        sessions = next
        onChange?()
    }
}

enum ProcessLiveness {
    /// `EPERM` means the process exists but belongs to someone else, which still counts as alive.
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// When the process behind a pid started, as epoch seconds, or nil when there is no such process.
    static func startTime(of pid: Int32) -> Double? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        guard started.tv_sec > 0 else { return nil }
        return Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
    }

    /// Whether `pid` still means the process that was seen starting at `startedAt`.
    ///
    /// Compared to the second rather than exactly: the value travels through JSON, and two processes
    /// cannot plausibly share a pid inside one second — the kernel has to work through the whole pid
    /// space before handing that number out again.
    ///
    /// A nil `startedAt` is not a mismatch. It means nothing was recorded to compare against, so this
    /// can only answer liveness, which is all the app could do before start times were carried at all.
    static func isSameProcess(pid: Int32, startedAt: Double?) -> Bool {
        guard let current = startTime(of: pid) else { return false }
        guard let startedAt else { return true }
        return abs(current - startedAt) < 1
    }
}
