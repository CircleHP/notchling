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

    /// Fired for every state transition, once per edge.
    var onTransition: ((Session, SessionState, SessionState) -> Void)?

    /// Fired the moment a working session crosses `stallThreshold`, once per turn.
    var onStalled: ((Session) -> Void)?

    var onChange: (() -> Void)?

    /// Fired when a session leaves the store, so state held elsewhere and keyed by it can go too.
    var onRemoved: ((Session) -> Void)?

    private var index: [String: Session] = [:]

    private let processEnvironment = ProcessEnvironmentReader()

    private let transcripts = TranscriptReader()

    /// pids already looked up, so a session with genuinely no terminal identity is not re-probed on
    /// every sweep. Purged by `remove(id:)`: a pid that outlives its session blocks identity
    /// resolution for whatever process macOS gives that number to next.
    private(set) var resolvedPIDs: Set<Int32> = []

    /// Injectable so the time-based arbitration below can be tested without sleeping. Every rule in this
    /// file that compares timestamps has edge cases an hour or a second either side of the obvious case, so
    /// they are worth pinning down deterministically.
    private let now: () -> Date
    private let readPendingVersion: () -> String?
    private var lastVersionCheck: Date?

    init(
        now: @escaping () -> Date = { Date.now },
        pendingVersion: @escaping () -> String? = { InstalledBuild.pendingVersion() }
    ) {
        self.now = now
        self.readPendingVersion = pendingVersion
    }

    /// The only way a session leaves the store.
    ///
    /// Removing it from `index` alone leaves its pid in `resolvedPIDs` and its environment in the
    /// reader's cache forever. macOS reuses pids, so the next session to be handed that number is
    /// silently refused a terminal-identity probe: no tty, no focus URL, and a click that falls back
    /// to activating the app instead of jumping to the tab.
    @discardableResult
    private func remove(id: String) -> Session? {
        guard let session = index.removeValue(forKey: id) else { return nil }
        if let pid = session.pid {
            resolvedPIDs.remove(pid)
            processEnvironment.forget(pid: pid)
        }
        transcripts.forget(sessionID: id)
        onRemoved?(session)
        return session
    }

    /// Current state of one session by id. The panel freezes which rows it draws when it opens but keeps
    /// their *contents* live, and this is how a frozen row finds itself again.
    func session(id: String) -> Session? { index[id] }

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
        var session = index[event.sessionId] ?? Session(sessionID: event.sessionId)
        let previous = session.state

        if let pid = event.pid { session.pid = pid }
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
                remove(id: event.sessionId)
                rebuild()
                return

            default:
                break
            }
        }

        if let newState {
            setState(newState, on: &session, evidenceAt: event.date)
        }

        index[event.sessionId] = session
        rebuild()
        notifyTransition(from: previous, session: session)
        readTranscriptMarks(for: event.sessionId)
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

        case "agent_completed":
            return .done

        default:
            // auth_success, elicitation_complete, … — nothing to show.
            return nil
        }
    }

    // MARK: - Registry

    func apply(registry entries: [RegistryEntry]) {
        let seen = Set(entries.map(\.sessionId))

        for entry in entries {
            var session = index[entry.sessionId] ?? Session(sessionID: entry.sessionId)
            let previous = session.state

            session.pid = entry.pid
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

            index[entry.sessionId] = session

            // Not just for registry-discovered sessions: a hook event from a terminal that publishes
            // no focus URL leaves us with no tty either, and the tty is what the iTerm/Terminal
            // fallbacks match on.
            if session.processCommand == nil, let pid = session.pid,
               !resolvedPIDs.contains(pid)
            {
                resolvedPIDs.insert(pid)
                resolveTerminalIdentity(for: entry.sessionId, pid: pid)
            }

            readTranscriptMarks(for: entry.sessionId)

            notifyTransition(from: previous, session: session)
        }

        // Absence from the registry is the primary signal that a session is gone, but not an instant
        // one: at session start, hook events can arrive before the registry file is written, and
        // dropping the session then makes it flicker. After the grace period it is gone even if its
        // pid looks alive, because a pid can be recycled.
        let stamp = now()
        for (id, var session) in index where !seen.contains(id) {
            // A pid we have and cannot find is proof the session is gone. No pid at all is not: the
            // hook resolves it from `CLAUDE_PID` or a walk up the parent chain, and both come up
            // empty often enough. Reading that as death removed the grace period from the one case
            // it was written for — hook events arriving before the registry file exists.
            if let pid = session.pid, !ProcessLiveness.isAlive(pid) {
                remove(id: id)
                continue
            }
            if let since = session.missingFromRegistrySince {
                if stamp.timeIntervalSince(since) > Self.registryGrace {
                    remove(id: id)
                }
            } else {
                session.missingFromRegistrySince = stamp
                index[id] = session
            }
        }

        rebuild()
    }

    /// The title Claude derives and the colour a user sets live only in the session's transcript, so
    /// they have to be read rather than received. Cheap in practice: the reader does nothing unless
    /// the file changed since it last looked, and it reads backwards from the end.
    private func readTranscriptMarks(for sessionID: String) {
        guard let session = index[sessionID] else { return }
        let path = session.transcriptPath
            ?? session.cwd.flatMap { TranscriptReader.path(forSession: sessionID, cwd: $0) }
        guard let path else { return }

        transcripts.read(sessionID: sessionID, path: path) { [weak self] marks in
            guard let self, var session = self.index[sessionID] else { return }
            if let custom = marks.customTitle { session.customTitle = custom }
            if let title = marks.title { session.aiTitle = title }
            if let colour = marks.colorName { session.colorName = colour }
            self.index[sessionID] = session
            self.rebuild()
        }
    }

    private func resolveTerminalIdentity(for sessionID: String, pid: Int32) {
        processEnvironment.read(pid: pid) { [weak self] identity in
            guard let self, var session = self.index[sessionID] else { return }
            if session.focusURL == nil { session.focusURL = identity.focusURL }
            if session.warpSessionID == nil { session.warpSessionID = identity.warpSessionID }
            if session.termProgram == nil { session.termProgram = identity.termProgram }
            if session.hostBundleID == nil { session.hostBundleID = identity.hostBundleID }
            if session.tty == nil { session.tty = identity.tty }
            if session.processCommand == nil { session.processCommand = identity.command }
            self.index[sessionID] = session
            self.rebuild()
        }
    }

    // MARK: - Periodic upkeep

    /// Called on a slow timer. Deliberately does no I/O beyond `kill(pid, 0)` and a few small reads.
    func tick() {
        let freshUsage = UsageReader.read()
        if freshUsage != usage { usage = freshUsage }

        refreshPendingVersion()

        let metrics = SessionMetricsReader.readAll()

        var changed = false
        let stamp = now()

        for (id, var session) in index {
            if session.metrics != metrics[id] {
                session.metrics = metrics[id]
                index[id] = session
                changed = true
            }

            let threshold = session.stallThreshold(absolute: Self.stallThreshold)
            let stalled = (session.stalledFor(now: stamp) ?? 0) > threshold
            if stalled != session.isStalled {
                session.isStalled = stalled
                index[id] = session
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
                index[id] = session
                changed = true
            }

            if session.state == .done, stamp.timeIntervalSince(session.stateChangedAt) > Self.doneDecay {
                setState(.idle, on: &session, evidenceAt: stamp)
                index[id] = session
                changed = true
            }
            if let pid = session.pid, !ProcessLiveness.isAlive(pid) {
                remove(id: id)
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
}
