import Foundation
import Testing

@testable import Notchling

@Suite("SessionStore — hook events")
@MainActor
struct SessionStoreHookTests {
    @Test("UserPromptSubmit starts a turn and records what was asked")
    func promptStartsTurn() {
        let store = SessionStore()
        let t = Date(timeIntervalSince1970: 1_000_000)
        store.apply(hookEvent("UserPromptSubmit", at: t, [
            "userInput": "split the auth middleware", "promptId": "p1", "cwd": "/w",
        ]))

        let s = try! #require(store.sessions.first)
        #expect(s.state == .working)
        #expect(s.turnStartedAt == t)
        #expect(s.lastPrompt == "split the auth middleware")
        #expect(s.currentPromptID == "p1")
        #expect(!s.isStalled)
    }

    @Test("PreToolUse tallies tools and keeps the turn start")
    func toolsAccumulate() {
        let store = SessionStore()
        let t = Date(timeIntervalSince1970: 1_000_000)
        store.apply(hookEvent("UserPromptSubmit", at: t, ["promptId": "p1"]))
        store.apply(hookEvent("PreToolUse", at: t + 1, ["toolName": "Edit", "toolSummary": "Session.swift"]))
        store.apply(hookEvent("PreToolUse", at: t + 2, ["toolName": "Edit"]))
        store.apply(hookEvent("PreToolUse", at: t + 3, ["toolName": "Bash", "toolSummary": "npm test"]))

        let s = try! #require(store.sessions.first)
        #expect(s.state == .working)
        #expect(s.toolCounts == ["Edit": 2, "Bash": 1])
        #expect(s.currentTool == "Bash")
        #expect(s.currentToolSummary == "npm test")
        #expect(s.turnStartedAt == t, "the turn started at the prompt, not at the latest tool")
    }

    @Test("PreToolUse alone starts the turn clock when there was no prompt event")
    func toolWithoutPromptSeedsTurn() {
        let store = SessionStore()
        let t = Date(timeIntervalSince1970: 1_000_000)
        store.apply(hookEvent("PreToolUse", at: t, ["toolName": "Read"]))
        #expect(store.sessions.first?.turnStartedAt == t)
    }

    @Test("a permission prompt is the state the registry cannot express")
    func permissionPrompt() {
        let store = SessionStore()
        store.apply(hookEvent("Notification", ["notificationType": "permission_prompt",
                                               "message": "Claude needs permission to run npm"]))
        let s = try! #require(store.sessions.first)
        #expect(s.state == .needsYou)
        #expect(s.needsYouMessage == "Claude needs permission to run npm")
    }

    @Test("agent_needs_input and elicitation_dialog also mean needs-you",
          arguments: ["agent_needs_input", "elicitation_dialog"])
    func otherPromptingNotifications(kind: String) {
        let store = SessionStore()
        store.apply(hookEvent("Notification", ["notificationType": kind]))
        #expect(store.sessions.first?.state == .needsYou)
    }

    @Test("idle_prompt is noise after a finished turn, and a signal mid-work")
    func idlePromptOnlyCountsMidWork() {
        // Idle: the input box has merely been sitting there. Ignore it.
        let idleStore = SessionStore()
        idleStore.apply(hookEvent("SessionStart"))
        idleStore.apply(hookEvent("Notification", ["notificationType": "idle_prompt"]))
        #expect(idleStore.sessions.first?.state == .idle)

        // Mid-work: Claude stopped to ask something. That is worth surfacing.
        let workingStore = SessionStore()
        workingStore.apply(hookEvent("UserPromptSubmit"))
        workingStore.apply(hookEvent("Notification", ["notificationType": "idle_prompt", "message": "still there?"]))
        #expect(workingStore.sessions.first?.state == .needsYou)
        #expect(workingStore.sessions.first?.needsYouMessage == "still there?")
    }

    @Test("unknown notification types change nothing")
    func unknownNotificationIgnored() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit"))
        store.apply(hookEvent("Notification", ["notificationType": "auth_success"]))
        #expect(store.sessions.first?.state == .working)
    }

    @Test("Stop finishes the turn and clears in-flight detail")
    func stopFinishes() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit", ["promptId": "p1"]))
        store.apply(hookEvent("PreToolUse", ["toolName": "Bash"]))
        store.apply(hookEvent("Stop", ["lastMessage": "all 42 tests pass"]))

        let s = try! #require(store.sessions.first)
        #expect(s.state == .done)
        #expect(s.lastMessage == "all 42 tests pass")
        #expect(s.currentTool == nil)
        #expect(s.lastProgressAt == nil, "a finished turn cannot be stalled")
    }

    @Test("a failed turn lands in the error state")
    func turnFailure() {
        let store = SessionStore()
        store.apply(hookEvent("StopFailure", ["errorMessage": "boom"]))
        let s = try! #require(store.sessions.first)
        #expect(s.state == .error)
        #expect(s.lastMessage == "boom")
    }

    /// Claude retries a failed tool and usually recovers, so alerting on one trains the user to ignore
    /// the alert that matters. It has to stay visible without becoming notifiable.
    @Test("a failed tool call is visible but never notifiable")
    func toolFailureDoesNotAlert() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit"))
        store.apply(hookEvent("PreToolUse", ["toolName": "Bash"]))
        store.apply(hookEvent("PostToolUseFailure", ["errorMessage": "exit 1"]))

        let s = try! #require(store.sessions.first)
        #expect(s.state == .working, "the turn is still going")
        #expect(s.state.isNotifiable == false)
        #expect(s.activityLine() == "exit 1", "the failure is still on the row")
        #expect(s.lastMessage == nil, "a tool failure is not the session's last word")
    }

    @Test("the next tool clears the failure off the row")
    func nextToolClearsTheFailure() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit"))
        store.apply(hookEvent("PostToolUseFailure", ["errorMessage": "exit 1"]))
        store.apply(hookEvent("PreToolUse", ["toolName": "Read"]))

        let s = try! #require(store.sessions.first)
        #expect(s.lastToolFailure == nil)
        #expect(s.activityLine() == "Read")
    }

    /// The recovery path this whole rule exists for: fail, retry, finish. Nothing along it should have
    /// been notifiable except the finish.
    @Test("a failure that Claude recovers from ends as a normal finish")
    func recoveredFailureEndsClean() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit"))
        store.apply(hookEvent("PreToolUse", ["toolName": "Bash"]))
        store.apply(hookEvent("PostToolUseFailure", ["errorMessage": "exit 1"]))
        store.apply(hookEvent("PreToolUse", ["toolName": "Bash"]))
        store.apply(hookEvent("Stop", ["lastMessage": "done"]))

        let s = try! #require(store.sessions.first)
        #expect(s.state == .done)
        #expect(s.lastToolFailure == nil)
        #expect(s.activityLine() == "done")
    }

    /// macOS reuses pids. A pid left behind in `resolvedPIDs` blocks the identity probe for whatever
    /// session is given that number next, and that session then has no tty and no focus URL — the row
    /// still appears, the click just quietly stops working.
    @Test("a session leaving takes its pid with it, so a reused pid can be probed again")
    func removalPurgesThePID() {
        let store = SessionStore()
        store.apply(registry: [registryEntry(session: "a", pid: 4242)])
        #expect(store.resolvedPIDs.contains(4242), "the first session claimed the pid")

        // Absent from the registry and not alive: gone.
        store.apply(registry: [])
        #expect(store.sessions.isEmpty)
        #expect(store.resolvedPIDs.isEmpty, "the pid must not outlive the session that held it")

        store.apply(registry: [registryEntry(session: "b", pid: 4242)])
        #expect(store.resolvedPIDs.contains(4242), "the next owner of the pid gets its own probe")
    }

    /// The pid is claimed on the registry path — that is where the identity probe lives — but a session
    /// can leave by either route, so `SessionEnd` has to release it too.
    @Test("SessionEnd also releases the pid")
    func sessionEndPurgesThePID() {
        let store = SessionStore()
        store.apply(registry: [registryEntry(session: "a", pid: 4242)])
        #expect(store.resolvedPIDs.contains(4242))
        store.apply(hookEvent("SessionEnd", session: "a"))
        #expect(store.sessions.isEmpty)
        #expect(store.resolvedPIDs.isEmpty)
    }

    @Test("removal is announced, so state held elsewhere can be dropped")
    func removalIsAnnounced() {
        let store = SessionStore()
        var removed: [String] = []
        store.onRemoved = { removed.append($0.sessionID) }
        store.apply(hookEvent("SessionStart", session: "gone"))
        store.apply(hookEvent("SessionEnd", session: "gone"))
        #expect(removed == ["gone"])
    }

    @Test("SessionEnd removes the session outright")
    func sessionEndRemoves() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit"))
        #expect(store.sessions.count == 1)
        store.apply(hookEvent("SessionEnd"))
        #expect(store.sessions.isEmpty)
    }

    @Test("terminal identity is carried across from the hook environment")
    func terminalIdentity() {
        let store = SessionStore()
        store.apply(hookEvent("SessionStart", [
            "focusURL": "warp://session/abc", "warpSessionId": "abc",
            "termProgram": "WarpTerminal", "hostBundleId": "dev.warp.Warp-Stable",
        ]))
        let s = try! #require(store.sessions.first)
        #expect(s.focusURL == "warp://session/abc")
        #expect(s.termProgram == "WarpTerminal")
        #expect(s.hostBundleID == "dev.warp.Warp-Stable")
    }

    /// `agent_type` is also set on the main thread of a session started with `--agent`, without an
    /// `agent_id`. Only the id means "this came from inside a subagent", so only the id may create one.
    @Test("an agent is created by its id, never by a type alone")
    func agentRequiresAnID() {
        let withoutAgent = SessionStore()
        withoutAgent.apply(hookEvent("PreToolUse", ["agentType": "Explore"]))
        #expect(withoutAgent.sessions.first?.agents.isEmpty == true)

        let withAgent = SessionStore()
        withAgent.apply(hookEvent("PreToolUse", ["agentType": "Explore", "agentId": "a1"]))
        #expect(withAgent.sessions.first?.agents["a1"]?.agentType == "Explore")
    }
}

@Suite("SessionStore — transitions and callbacks")
@MainActor
struct SessionStoreTransitionTests {
    @Test("onTransition fires once per edge with the states either side")
    func transitionsFireOncePerEdge() {
        let store = SessionStore()
        var edges: [(SessionState, SessionState)] = []
        store.onTransition = { _, from, to in edges.append((from, to)) }

        store.apply(hookEvent("UserPromptSubmit"))                                        // idle → working
        store.apply(hookEvent("PreToolUse", ["toolName": "Read"]))                        // no edge
        store.apply(hookEvent("Notification", ["notificationType": "permission_prompt"]))  // working → needsYou
        store.apply(hookEvent("PreToolUse", ["toolName": "Read"]))                        // needsYou → working
        store.apply(hookEvent("Stop"))                                                     // working → done

        #expect(edges.map(\.0) == [.idle, .working, .needsYou, .working])
        #expect(edges.map(\.1) == [.working, .needsYou, .working, .done])
    }

    @Test("a repeated permission prompt in the same turn is not a new edge")
    func repeatedPromptIsNotAnEdge() {
        let store = SessionStore()
        var count = 0
        store.onTransition = { _, _, to in if to == .needsYou { count += 1 } }
        store.apply(hookEvent("UserPromptSubmit"))
        store.apply(hookEvent("Notification", ["notificationType": "permission_prompt"]))
        store.apply(hookEvent("Notification", ["notificationType": "permission_prompt"]))
        #expect(count == 1)
    }

    @Test("onChange is not fired when a registry rescan changes nothing")
    func noChangeNoPublish() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)
        var changes = 0
        store.onChange = { changes += 1 }

        let entry = registryEntry(status: "busy", name: "proj", statusUpdatedAt: clock.current)
        store.apply(registry: [entry])
        let afterFirst = changes
        #expect(afterFirst > 0)

        // Same snapshot again. An unconditional publish here would re-render the notch every 2s
        // forever, which is what the equality guard in rebuild() exists to prevent.
        store.apply(registry: [entry])
        store.apply(registry: [entry])
        #expect(changes == afterFirst)
    }

    @Test("a working session with no progress is flagged stalled exactly once")
    func stallFiresOnce() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)
        var stalls = 0
        store.onStalled = { _ in stalls += 1 }

        store.apply(hookEvent("UserPromptSubmit", at: clock.current, ["promptId": "p1"]))
        clock.advance(SessionStore.stallThreshold + 1)
        store.tick()
        #expect(stalls == 1)
        #expect(store.sessions.first?.isStalled == true)

        store.tick()
        store.tick()
        #expect(stalls == 1, "still the same stalled turn")

        // Progress clears the flag; the next turn stalling is new information.
        store.apply(hookEvent("PreToolUse", at: clock.current, ["toolName": "Bash"]))
        #expect(store.sessions.first?.isStalled == false)
        clock.advance(SessionStore.stallThreshold + 1)
        store.tick()
        #expect(stalls == 2)
    }

    @Test("aggregateState picks the most urgent state on screen")
    func aggregate() {
        let store = SessionStore()
        #expect(store.aggregateState == .idle)

        store.apply(hookEvent("UserPromptSubmit", session: "a"))
        #expect(store.aggregateState == .working)

        store.apply(hookEvent("Stop", session: "b"))
        #expect(store.aggregateState == .working, "working outranks done")

        store.apply(hookEvent("StopFailure", session: "c"))
        #expect(store.aggregateState == .error, "error outranks working")

        store.apply(hookEvent("Notification", session: "d", ["notificationType": "permission_prompt"]))
        #expect(store.aggregateState == .needsYou, "needs-you outranks everything")
    }

    @Test("rows sort by urgency, then stalled first, then most recently changed")
    func sortOrder() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)

        store.apply(hookEvent("UserPromptSubmit", session: "working-old", at: clock.current))
        clock.advance(1)
        store.apply(hookEvent("UserPromptSubmit", session: "working-new", at: clock.current))
        clock.advance(1)
        store.apply(hookEvent("Stop", session: "finished", at: clock.current))
        clock.advance(1)
        store.apply(hookEvent("Notification", session: "blocked", at: clock.current,
                              ["notificationType": "permission_prompt"]))

        #expect(store.sessions.map(\.sessionID) == ["blocked", "working-new", "working-old", "finished"])

        // A stalled working session sorts above healthy ones so it cannot hide behind them.
        clock.advance(SessionStore.stallThreshold + 1)
        store.apply(hookEvent("PreToolUse", session: "working-new", at: clock.current, ["toolName": "Read"]))
        store.tick()
        let working = store.sessions.filter { $0.state == .working }.map(\.sessionID)
        #expect(working == ["working-old", "working-new"], "the stalled one leads")
        #expect(store.sessions.first(where: { $0.sessionID == "working-old" })?.isStalled == true)
    }
}

@Suite("SessionStore — registry arbitration")
@MainActor
struct SessionStoreRegistryTests {
    @Test("registry status maps to working and idle, and seeds the turn clock")
    func statusMapping() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)
        let busySince = clock.current.addingTimeInterval(-30)

        store.apply(registry: [registryEntry(pid: livePID, status: "busy", name: "proj",
                                             statusUpdatedAt: busySince)])
        var s = try! #require(store.sessions.first)
        #expect(s.state == .working)
        #expect(s.name == "proj")
        // A session already mid-turn at launch has no hook history, so the registry's timestamp is
        // the only thing that can say when the turn began.
        #expect(s.turnStartedAt == busySince)

        clock.advance(10)
        store.apply(registry: [registryEntry(pid: livePID, status: "idle", name: "proj",
                                             statusUpdatedAt: clock.current)])
        s = try! #require(store.sessions.first)
        #expect(s.state == .idle)
        #expect(s.turnStartedAt == nil)
    }

    @Test("a missing registry field means 'not reported', never 'cleared'")
    func missingFieldsDoNotClobber() {
        let store = SessionStore()
        store.apply(registry: [registryEntry(pid: livePID, status: "idle", name: "proj", cwd: "/work")])
        // A later snapshot that omits name and cwd must not wipe them.
        store.apply(registry: [registryEntry(pid: livePID, status: "idle")])

        let s = try! #require(store.sessions.first)
        #expect(s.name == "proj")
        #expect(s.cwd == "/work")
    }

    @Test("the registry cannot clear needs-you on its own")
    func registryDoesNotClearNeedsYou() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)

        store.apply(hookEvent("Notification", at: clock.current, ["notificationType": "permission_prompt"]))
        #expect(store.sessions.first?.state == .needsYou)

        // A blocked session reads as idle here, but the registry has no way to know why.
        clock.advance(5)
        store.apply(registry: [registryEntry(pid: livePID, status: "idle", statusUpdatedAt: clock.current)])
        #expect(store.sessions.first?.state == .needsYou)
    }

    @Test("a hook event does clear needs-you")
    func hookClearsNeedsYou() {
        let store = SessionStore()
        store.apply(hookEvent("Notification", ["notificationType": "permission_prompt"]))
        store.apply(hookEvent("PreToolUse", ["toolName": "Bash"]))
        #expect(store.sessions.first?.state == .working, "the approved tool ran")
    }

    @Test("sustained registry-idle eventually releases a stuck needs-you")
    func sustainedIdleReleasesNeedsYou() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)

        store.apply(hookEvent("Notification", at: clock.current, ["notificationType": "permission_prompt"]))
        store.apply(registry: [registryEntry(pid: livePID, status: "idle", statusUpdatedAt: clock.current)])
        #expect(store.sessions.first?.state == .needsYou)

        clock.advance(SessionStore.needsYouReleaseAfterIdle + 1)
        store.apply(registry: [registryEntry(pid: livePID, status: "idle", statusUpdatedAt: clock.current)])
        #expect(store.sessions.first?.state == .idle,
                "otherwise a session that stops emitting hooks while blocked is pinned forever")
    }

    @Test("the release clock starts when needs-you began, not when the registry went idle")
    func releaseClockUsesTheLaterOfTheTwo() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)

        // A session that has already been idle for an hour.
        store.apply(registry: [registryEntry(pid: livePID, status: "idle", statusUpdatedAt: clock.current)])
        clock.advance(3600)
        store.apply(registry: [registryEntry(pid: livePID, status: "idle", statusUpdatedAt: clock.current)])

        // Now a permission prompt arrives.
        store.apply(hookEvent("Notification", at: clock.current, ["notificationType": "permission_prompt"]))
        #expect(store.sessions.first?.state == .needsYou)

        // Seconds later the registry is rescanned. Measured from the registry's idle timestamp alone, this
        // would cancel instantly, which is the case this test pins down.
        clock.advance(5)
        store.apply(registry: [registryEntry(pid: livePID, status: "idle", statusUpdatedAt: clock.current)])
        #expect(store.sessions.first?.state == .needsYou)

        clock.advance(SessionStore.needsYouReleaseAfterIdle)
        store.apply(registry: [registryEntry(pid: livePID, status: "idle", statusUpdatedAt: clock.current)])
        #expect(store.sessions.first?.state == .idle)
    }

    @Test("a fresh done is not flattened to idle by the registry")
    func doneSurvivesRegistryIdle() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)

        store.apply(hookEvent("Stop", at: clock.current, ["lastMessage": "done"]))
        clock.advance(1)
        store.apply(registry: [registryEntry(pid: livePID, status: "idle", statusUpdatedAt: clock.current)])
        #expect(store.sessions.first?.state == .done, "let the decay finish")
    }

    @Test("done decays to idle after doneDecay")
    func doneDecays() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)

        store.apply(hookEvent("Stop", at: clock.current))
        clock.advance(SessionStore.doneDecay - 1)
        store.tick()
        #expect(store.sessions.first?.state == .done)

        clock.advance(2)
        store.tick()
        #expect(store.sessions.first?.state == .idle)
    }

    @Test("older evidence never overrides newer")
    func staleEvidenceLoses() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)

        store.apply(hookEvent("UserPromptSubmit", at: clock.current))
        #expect(store.sessions.first?.state == .working)

        // A registry snapshot whose status predates the hook event must not win.
        store.apply(registry: [registryEntry(pid: livePID, status: "idle",
                                             statusUpdatedAt: clock.current.addingTimeInterval(-60))])
        #expect(store.sessions.first?.state == .working)
    }

    @Test("a session missing from the registry is kept for a grace period, then dropped")
    func missingSessionGrace() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)

        // Discovered by hooks, with a live pid, before the registry file exists.
        store.apply(hookEvent("UserPromptSubmit", at: clock.current, ["pid": Int(livePID)]))
        store.apply(registry: [])
        #expect(store.sessions.count == 1, "dropping it here would make the row flicker at session start")

        clock.advance(SessionStore.registryGrace + 1)
        store.apply(registry: [])
        #expect(store.sessions.isEmpty, "a pid can be recycled, so absence eventually wins")
    }

    @Test("the build on disk is checked on a slow interval, not on every sweep")
    func pendingVersionIsThrottled() {
        let clock = TestClock()
        var reads = 0
        var answer: String? = nil
        let store = SessionStore(now: clock.now, pendingVersion: {
            reads += 1
            return answer
        })

        store.tick()
        #expect(reads == 1)
        #expect(store.pendingVersion == nil)

        // Releases are rare and the newest is the stable one, so the interval is hours rather than
        // seconds — a whole day of sweeps inside it must not produce a second read.
        clock.advance(SessionStore.versionCheckInterval - 1)
        store.tick()
        #expect(reads == 1, "still inside the interval")

        answer = "1.0.4"
        clock.advance(SessionStore.versionCheckInterval + 1)
        store.tick()
        #expect(reads == 2)
        #expect(store.pendingVersion == "1.0.4")

        // And it clears again, so a widget restarted into the new build stops nagging.
        answer = nil
        clock.advance(SessionStore.versionCheckInterval + 1)
        store.tick()
        #expect(store.pendingVersion == nil)
    }

    @Test("a session with no pid gets the grace period, not an immediate drop")
    func missingPIDGrace() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)

        // The hook reports no pid when `CLAUDE_PID` is unset and the parent walk finds no claude
        // process — which is the same moment the registry file may not exist yet, so treating it as
        // death made the row appear and vanish.
        store.apply(hookEvent("UserPromptSubmit", at: clock.current))
        store.apply(registry: [])
        #expect(store.sessions.count == 1, "no pid is unknown, not dead")

        clock.advance(SessionStore.registryGrace + 1)
        store.apply(registry: [])
        #expect(store.sessions.isEmpty, "it still cannot outlive the grace period")
    }

    @Test("a session whose process is gone is dropped immediately")
    func deadProcessDropped() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit", ["pid": Int(deadPID)]))
        store.apply(registry: [])
        #expect(store.sessions.isEmpty)
    }

    @Test("tick drops sessions whose process died")
    func tickDropsDead() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit", ["pid": Int(deadPID)]))
        #expect(store.sessions.count == 1)
        store.tick()
        #expect(store.sessions.isEmpty)
    }

    @Test("pooled background plumbing is hidden from the panel")
    func infrastructureHidden() {
        let store = SessionStore()
        store.apply(registry: [
            registryEntry(session: "real", pid: livePID, status: "busy", name: "My task", kind: "bg", jobId: "j1"),
            registryEntry(session: "spare", pid: livePID, status: "idle", name: "j2", kind: "bg", jobId: "j2"),
        ])
        #expect(store.sessions.map(\.sessionID) == ["real"], "the unclaimed spare is plumbing")
    }

    @Test("counts reflect only visible sessions")
    func counts() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit", session: "a"))
        store.apply(hookEvent("UserPromptSubmit", session: "b"))
        store.apply(hookEvent("Notification", session: "c", ["notificationType": "permission_prompt"]))
        store.apply(hookEvent("Stop", session: "d"))
        store.apply(hookEvent("StopFailure", session: "e"))

        #expect(store.workingCount == 2)
        #expect(store.needsYouCount == 1)
        #expect(store.doneCount == 1)
        #expect(store.errorCount == 1)
        #expect(store.idleCount == 0)
    }
}

@Suite("SessionStore.state(forNotification:current:)")
struct NotificationRuleTests {
    private func event(_ type: String) -> HookEvent {
        hookEvent("Notification", ["notificationType": type])
    }

    @Test("the prompts that mean a session is blocked on you")
    func blockingPrompts() {
        for type in ["permission_prompt", "agent_needs_input", "elicitation_dialog"] {
            #expect(SessionStore.state(forNotification: event(type), current: .working) == .needsYou, "\(type)")
            #expect(SessionStore.state(forNotification: event(type), current: .idle) == .needsYou, "\(type)")
        }
    }


    /// Raised once per background agent leaving the running band, carrying the parent's `session_id` and
    /// no `agent_id`. Reading it as a finish is how a spawned agent returning came to sound and drop the
    /// notch as if the user's own turn had ended.
    @Test("agent_completed is an agent finishing, which is not a session finishing")
    func agentCompletedSaysNothing() {
        for state in [SessionState.working, .idle, .done, .needsYou, .error] {
            #expect(SessionStore.state(forNotification: event("agent_completed"), current: state) == nil, "\(state)")
        }
    }

}

@Suite("ToolDurations")
struct ToolDurationsTests {
    @Test("no history means no opinion, so the caller keeps its own threshold")
    func noHistory() {
        let durations = ToolDurations()
        #expect(durations.unusualAfter(tool: "Bash") == nil)
        #expect(durations.longestSeen(for: "Bash") == nil)
    }

    /// Multiplying the slowest run, not the median: the cost of crying wolf is that the flag stops being
    /// read at all, so a tool that has ever been slow is given room to be slow again.
    @Test("the threshold is the slowest run so far, times a factor")
    func thresholdFollowsTheSlowestRun() {
        var durations = ToolDurations()
        durations.record(40, for: "Bash")
        durations.record(120, for: "Bash")
        durations.record(30, for: "Bash")
        #expect(durations.longestSeen(for: "Bash") == 120)
        #expect(durations.unusualAfter(tool: "Bash") == 120 * ToolDurations.factor)
    }

    /// A `Read` normally returns instantly, but flagging one at 600ms would be noise.
    @Test("fast tools are floored, so a quick tool is not flagged for being briefly slow")
    func fastToolsAreFloored() {
        var durations = ToolDurations()
        durations.record(0.2, for: "Read")
        #expect(durations.unusualAfter(tool: "Read") == ToolDurations.floor)
    }

    @Test("history is per tool and does not bleed between them")
    func perTool() {
        var durations = ToolDurations()
        durations.record(600, for: "Bash")
        durations.record(0.3, for: "Read")
        #expect(durations.unusualAfter(tool: "Bash")! > durations.unusualAfter(tool: "Read")!)
    }

    /// Bounded, so the estimate tracks the repository as it changes rather than remembering one bad run
    /// from an hour ago forever.
    @Test("history is bounded and keeps the most recent runs")
    func historyIsBounded() {
        var durations = ToolDurations()
        durations.record(9_000, for: "Bash")
        for _ in 0 ..< ToolDurations.historyLength { durations.record(10, for: "Bash") }
        #expect(durations.longestSeen(for: "Bash") == 10, "the outlier should have aged out")
    }

    @Test("nonsense durations are ignored rather than poisoning the baseline")
    func rejectsNonsense() {
        var durations = ToolDurations()
        durations.record(-5, for: "Bash")
        durations.record(.infinity, for: "Bash")
        durations.record(0, for: "Bash")
        #expect(durations.longestSeen(for: "Bash") == nil)
    }
}

@Suite("adaptive stall detection")
@MainActor
struct AdaptiveStallTests {
    /// The point of the whole exercise: a tool that always takes ten minutes must not be reported as
    /// stalled at ten minutes, and a tool that always returns instantly must not need ten minutes of
    /// silence before anyone says so.
    @Test("the threshold follows the running tool, not one number for everything")
    func thresholdIsPerTool() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)

        // Two Bash runs that each took four minutes, closed out by the next tool starting.
        store.apply(hookEvent("UserPromptSubmit", session: "s", at: clock.current))
        store.apply(hookEvent("PreToolUse", session: "s", at: clock.current, ["toolName": "Bash"]))
        clock.advance(240)
        store.apply(hookEvent("PreToolUse", session: "s", at: clock.current, ["toolName": "Bash"]))
        clock.advance(240)
        store.apply(hookEvent("PreToolUse", session: "s", at: clock.current, ["toolName": "Read"]))

        let session = try! #require(store.sessions.first)
        // Bash has earned 240 * 3; Read has never finished one, so it falls back to the absolute default.
        #expect(session.toolDurations.unusualAfter(tool: "Bash") == 720)
        #expect(session.toolDurations.unusualAfter(tool: "Read") == nil)
        #expect(session.stallThreshold(absolute: 600) == 600, "Read has no history yet")
    }

    /// A tool sitting behind a permission prompt spends its time waiting for a person. Recording that as
    /// the tool's duration would let one slow approval raise the bar for every later run.
    @Test("time spent waiting for a permission answer is not the tool's time")
    func blockedToolsAreNotRecorded() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)

        store.apply(hookEvent("UserPromptSubmit", session: "s", at: clock.current))
        store.apply(hookEvent("PreToolUse", session: "s", at: clock.current, ["toolName": "Bash"]))
        store.apply(hookEvent("Notification", session: "s", at: clock.current, [
            "notificationType": "permission_prompt",
        ]))
        clock.advance(900)  // a person went to lunch
        store.apply(hookEvent("PreToolUse", session: "s", at: clock.current, ["toolName": "Bash"]))

        let session = try! #require(store.sessions.first)
        #expect(session.toolDurations.longestSeen(for: "Bash") == nil,
                "15 minutes of human latency must not become Bash's baseline")
    }

    @Test("Stop closes out the last tool of a turn")
    func stopRecordsTheFinalTool() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)

        store.apply(hookEvent("UserPromptSubmit", session: "s", at: clock.current))
        store.apply(hookEvent("PreToolUse", session: "s", at: clock.current, ["toolName": "Grep"]))
        clock.advance(12)
        store.apply(hookEvent("Stop", session: "s", at: clock.current))

        let session = try! #require(store.sessions.first)
        #expect(session.toolDurations.longestSeen(for: "Grep") == 12)
    }
}

@Suite("subagent lifecycle")
@MainActor
struct SubagentLifecycleTests {
    /// What `SubagentStop` is registered *for*: without it, a subagent finishing is invisible and a row goes
    /// on claiming an agent is working indefinitely. A finished agent stops counting as running but stays
    /// readable for a moment, because its result is the interesting part.
    @Test("a finished agent stops running but is still readable")
    func finishLeavesTheAgentReadable() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit"))
        store.apply(hookEvent("SubagentStart", ["agentId": "a1", "agentType": "Explore"]))
        #expect(store.sessions.first?.runningAgents.count == 1)

        store.apply(hookEvent("SubagentStop", ["agentId": "a1", "agentType": "Explore"]))
        let session = try! #require(store.sessions.first)
        #expect(session.runningAgents.isEmpty)
        #expect(session.agents["a1"]?.agentType == "Explore", "the finished agent keeps its identity")
        #expect(session.agentSummary == "1/1 done")
    }

    /// Treating any stop as "the fan-out is over" would misreport a session mid-fan-out as finished while
    /// its other agents were still working.
    @Test("one agent finishing does not finish the rest")
    func partialCompletionIsReportedAsSuch() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit"))
        store.apply(hookEvent("SubagentStart", ["agentId": "a1", "agentType": "Explore"]))
        store.apply(hookEvent("SubagentStart", ["agentId": "a2", "agentType": "fork"]))
        store.apply(hookEvent("SubagentStop", ["agentId": "a1"]))

        let session = try! #require(store.sessions.first)
        #expect(session.runningAgents.map(\.agentID) == ["a2"])
        #expect(session.agentSummary == "1/2 done")
    }

    /// A `SubagentStop` can be missed — the hook may not be registered yet, or the agent may die hard.
    /// The turn ending is proof enough that nothing it spawned is still running.
    @Test("Stop clears the agents even when no SubagentStop arrived")
    func stopIsTheBackstop() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit"))
        store.apply(hookEvent("SubagentStart", ["agentId": "a1", "agentType": "Explore"]))
        store.apply(hookEvent("Stop"))

        let session = try! #require(store.sessions.first)
        #expect(session.agents.isEmpty, "Stop drops them outright rather than lingering")
        #expect(session.agentSummary == nil)
    }

    /// An agent whose start we never saw still has to be registered, or its `SubagentStop` would be the
    /// first we hear of it and there would be nothing to finish.
    @Test("an agent seen only through its tool calls is still registered")
    func toolCallRegistersTheAgent() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit"))
        store.apply(hookEvent("PreToolUse", ["agentId": "a1", "agentType": "Explore", "toolName": "Grep"]))
        #expect(store.sessions.first?.runningAgents.map(\.agentID) == ["a1"])

        store.apply(hookEvent("SubagentStop", ["agentId": "a1"]))
        #expect(store.sessions.first?.runningAgents.isEmpty == true)
    }

    /// One fan-out must not sound five times. `SubagentStop` deliberately changes no state, which is
    /// what keeps it out of `onTransition` and therefore out of `SoundCues`.
    @Test("a finishing agent is not a session finishing")
    func subagentStopIsNotAnEdge() {
        let store = SessionStore()
        var edges: [(SessionState, SessionState)] = []
        store.onTransition = { _, from, to in edges.append((from, to)) }

        store.apply(hookEvent("UserPromptSubmit"))
        store.apply(hookEvent("SubagentStart", ["agentId": "a1"]))
        store.apply(hookEvent("SubagentStop", ["agentId": "a1"]))
        store.apply(hookEvent("SubagentStop", ["agentId": "a2"]))

        #expect(edges.count == 1, "only the prompt's idle → working")
        #expect(edges.first?.1 == .working)
        #expect(store.sessions.first?.state == .working, "the session is still mid-turn")
    }

    /// The other half of the same rule, and the one that was wrong. A background agent finishing arrives
    /// as a `Notification` on the parent session rather than as `SubagentStop`, so it took the session's
    /// own switch and marked the turn done — a sound and a peek per agent, while the turn was still going.
    @Test("a background agent finishing is not a session finishing either")
    func agentCompletedIsNotAnEdge() {
        let store = SessionStore()
        var edges: [(SessionState, SessionState)] = []
        store.onTransition = { _, from, to in edges.append((from, to)) }

        store.apply(hookEvent("UserPromptSubmit"))
        store.apply(hookEvent("Notification", ["notificationType": "agent_completed", "message": "Explore finished"]))
        store.apply(hookEvent("Notification", ["notificationType": "agent_completed", "message": "fork failed"]))

        #expect(edges.count == 1, "only the prompt's idle → working")
        #expect(store.sessions.first?.state == .working, "the session is still mid-turn")
    }

    /// Between turns there is no `Stop` coming to correct it, so the row sat on `done` — and decayed to
    /// `idle` — off the back of an agent the session had merely been waiting for.
    @Test("a background agent finishing between turns leaves an idle session idle")
    func agentCompletedLeavesIdleAlone() {
        let store = SessionStore()
        store.apply(hookEvent("SessionStart"))
        store.apply(hookEvent("Notification", ["notificationType": "agent_completed", "message": "Explore finished"]))
        #expect(store.sessions.first?.state == .idle)
    }

    /// The most misleading failure available here. During a fan-out the main thread emits nothing between
    /// the `Task` call and the agents returning, so if subagent events did not advance the session's
    /// progress, every fan-out longer than the threshold would report a false stall.
    @Test("subagent activity keeps the parent from looking stalled")
    func subagentActivityIsProgress() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)
        var stalled: [String] = []
        store.onStalled = { stalled.append($0.sessionID) }

        store.apply(hookEvent("UserPromptSubmit", session: "s", at: clock.current))
        store.apply(hookEvent("PreToolUse", session: "s", at: clock.current, ["toolName": "Task"]))

        // Well past the 600s fallback in total, but never 600s without an agent reporting in.
        clock.advance(400)
        store.apply(hookEvent("SubagentStart", session: "s", at: clock.current, ["agentId": "a1"]))
        clock.advance(400)
        store.tick()
        #expect(stalled.isEmpty, "an agent started 400s ago is progress")

        store.apply(hookEvent("PreToolUse", session: "s", at: clock.current, [
            "agentId": "a1", "toolName": "Grep",
        ]))
        clock.advance(400)
        store.tick()
        #expect(stalled.isEmpty, "so is a tool call from inside that agent")
        #expect(store.sessions.first?.isStalled == false)

        // And the detector still works: silence from everyone, agents included.
        clock.advance(700)
        store.tick()
        #expect(stalled == ["s"], "1100s with no sign of life from any agent is a stall")
    }

    /// `SubagentStart` is the only progress signal a fan-out gets before its agents call any tools, so
    /// it has to start the turn clock when the session was idle.
    @Test("SubagentStart marks the session working")
    func startImpliesWorking() {
        let store = SessionStore()
        let t = Date(timeIntervalSince1970: 1_000_000)
        store.apply(hookEvent("SubagentStart", at: t, ["agentId": "a1", "agentType": "fork"]))

        let session = try! #require(store.sessions.first)
        #expect(session.state == .working)
        #expect(session.turnStartedAt == t)
        #expect(session.lastProgressAt == t)
    }
}

@Suite("subagent activity")
@MainActor
struct SubagentActivityTests {
    /// Attributed to the session, a fan-out's row shows whichever agent called a tool last, labelled as if
    /// the main thread were running it — next to an elapsed timer that belongs to the session's turn.
    @Test("a subagent's tool belongs to the subagent, not to the session")
    func toolStaysWithTheAgent() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)

        store.apply(hookEvent("UserPromptSubmit", at: clock.current))
        store.apply(hookEvent("PreToolUse", at: clock.current, ["toolName": "Agent"]))
        store.apply(hookEvent("SubagentStart", at: clock.current, ["agentId": "a1", "agentType": "Explore"]))
        store.apply(hookEvent("PreToolUse", at: clock.current, [
            "agentId": "a1", "toolName": "Grep", "toolSummary": "session store",
        ]))

        let session = try! #require(store.sessions.first)
        #expect(session.currentTool == "Agent", "the main thread is still running the Task call")
        #expect(session.toolCounts["Grep"] == nil, "the agent's tool is not the session's tally")

        let agent = try! #require(session.agents["a1"])
        #expect(agent.currentTool == "Grep")
        #expect(agent.activityLine == "Grep · session store")
        #expect(agent.toolCounts["Grep"] == 1)
    }

    /// A session's stall threshold is derived from what its tools normally take here, so pooling in every
    /// subagent's timings would make it an average over unrelated execution contexts.
    @Test("tool history is kept per agent, not pooled onto the session")
    func durationHistoriesAreSeparate() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)

        store.apply(hookEvent("UserPromptSubmit", session: "s", at: clock.current))
        store.apply(hookEvent("SubagentStart", session: "s", at: clock.current, ["agentId": "a1"]))
        store.apply(hookEvent("PreToolUse", session: "s", at: clock.current, [
            "agentId": "a1", "toolName": "Bash",
        ]))
        clock.advance(300)
        // The next tool starting is what proves the last one finished — for the agent, here.
        store.apply(hookEvent("PreToolUse", session: "s", at: clock.current, [
            "agentId": "a1", "toolName": "Bash",
        ]))

        let session = try! #require(store.sessions.first)
        #expect(session.toolDurations.longestSeen(for: "Bash") == nil,
                "five minutes inside an agent must not become the session's baseline for Bash")
        #expect(session.agents["a1"]?.toolDurations.longestSeen(for: "Bash") == 300)
    }

    /// The session is what you navigate to, so a blocked agent has to surface on it — otherwise the one
    /// notification the widget exists to deliver is the one it swallows.
    @Test("an agent waiting on a permission prompt blocks its session")
    func blockedAgentBlocksTheSession() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit"))
        store.apply(hookEvent("SubagentStart", ["agentId": "a1", "agentType": "code-reviewer"]))
        store.apply(hookEvent("Notification", [
            "agentId": "a1", "notificationType": "permission_prompt", "message": "Bash npm test",
        ]))

        let session = try! #require(store.sessions.first)
        #expect(session.state == .needsYou)
        #expect(session.needsYouMessage == "Bash npm test")
        #expect(session.agents["a1"]?.state == .needsYou)
    }

    /// One agent getting on with its own work must not overwrite the fact that a sibling is asking.
    @Test("a sibling's tool call does not mask a blocked agent")
    func siblingActivityDoesNotMaskAPrompt() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit"))
        store.apply(hookEvent("SubagentStart", ["agentId": "a1"]))
        store.apply(hookEvent("SubagentStart", ["agentId": "a2"]))
        store.apply(hookEvent("Notification", ["agentId": "a1", "notificationType": "permission_prompt"]))
        store.apply(hookEvent("PreToolUse", ["agentId": "a2", "toolName": "Read"]))

        let session = try! #require(store.sessions.first)
        #expect(session.state == .needsYou, "a1 is still waiting on a person")
        #expect(session.agents["a2"]?.state == .working)
    }

    /// `SubagentStop` carries `last_assistant_message`, which is the whole reason keeping a finished agent
    /// on screen for a moment is worth anything.
    @Test("a finished agent records what it concluded")
    func finishRecordsTheResult() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)
        store.apply(hookEvent("UserPromptSubmit", at: clock.current))
        store.apply(hookEvent("SubagentStart", at: clock.current, ["agentId": "a1", "agentType": "Explore"]))
        clock.advance(30)
        store.apply(hookEvent("SubagentStop", at: clock.current, [
            "agentId": "a1", "lastMessage": "found 2 races",
        ]))

        let agent = try! #require(store.sessions.first?.agents["a1"])
        #expect(agent.state == .done)
        #expect(agent.isFinished)
        #expect(agent.activityLine == "found 2 races")
        #expect(agent.elapsed(now: clock.current) == 30, "an elapsed time stops at the finish")
    }

    @Test("finished agents linger to be read, then decay")
    func finishedAgentsDecay() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)
        store.apply(hookEvent("UserPromptSubmit", at: clock.current))
        store.apply(hookEvent("SubagentStart", at: clock.current, ["agentId": "a1"]))
        store.apply(hookEvent("SubagentStop", at: clock.current, ["agentId": "a1"]))

        clock.advance(SessionStore.doneDecay - 1)
        store.tick()
        #expect(store.sessions.first?.agents["a1"] != nil, "still readable just before the decay")

        clock.advance(2)
        store.tick()
        #expect(store.sessions.first?.agents.isEmpty == true)
    }

    /// Oldest first, so a row does not jump position when a sibling finishes ahead of it.
    @Test("agents are ordered by when they started")
    func agentsAreStablyOrdered() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)
        store.apply(hookEvent("SubagentStart", at: clock.current, ["agentId": "first"]))
        clock.advance(1)
        store.apply(hookEvent("SubagentStart", at: clock.current, ["agentId": "second"]))
        clock.advance(1)
        store.apply(hookEvent("SubagentStart", at: clock.current, ["agentId": "third"]))
        store.apply(hookEvent("SubagentStop", at: clock.current, ["agentId": "second"]))

        let session = try! #require(store.sessions.first)
        #expect(session.sortedAgents.map(\.agentID) == ["first", "second", "third"])
        #expect(session.runningAgents.map(\.agentID) == ["first", "third"],
                "second finished but has not moved anyone")
    }

    /// An agent failing is handed back to the main thread, which often recovers. Reporting it as the
    /// session failing would cry wolf on a fan-out that ends up succeeding.
    @Test("a failed agent is not a failed session")
    func agentFailureStaysWithTheAgent() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit"))
        store.apply(hookEvent("SubagentStart", ["agentId": "a1"]))
        store.apply(hookEvent("StopFailure", ["agentId": "a1", "errorMessage": "agent crashed"]))

        let session = try! #require(store.sessions.first)
        #expect(session.state == .working, "the main thread is still going")
        #expect(session.agents["a1"]?.state == .error)
        #expect(session.agents["a1"]?.activityLine == "agent crashed")
    }

    /// Same rule one level down: a tool failing inside an agent is not the agent failing, so the row
    /// must not turn red and nothing must sound.
    @Test("a failed tool inside an agent leaves the agent working")
    func agentToolFailureIsNotAgentFailure() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit"))
        store.apply(hookEvent("SubagentStart", ["agentId": "a1"]))
        store.apply(hookEvent("PreToolUse", ["agentId": "a1", "toolName": "Grep"]))
        store.apply(hookEvent("PostToolUseFailure", ["agentId": "a1", "errorMessage": "no matches"]))

        let session = try! #require(store.sessions.first)
        #expect(session.agents["a1"]?.state == .working)
        #expect(session.agents["a1"]?.lastMessage == "no matches")
        #expect(session.state == .working)
    }

    /// The fallback that keeps the routing honest: an event carrying an `agent_id` that we have no
    /// agent-scoped rule for must still be handled at session level rather than silently dropped.
    @Test("an event with no agent-scoped rule still reaches the session")
    func unknownAgentEventFallsThrough() {
        let store = SessionStore()
        store.apply(hookEvent("UserPromptSubmit", ["agentId": "a1"]))
        #expect(store.sessions.first?.state == .working)
        #expect(store.sessions.first?.agents.isEmpty == true, "no agent was invented for it")
    }

    /// A new turn supersedes the last one's fan-out, so a missed `Stop` cannot leave agents on screen
    /// through the next prompt.
    @Test("a new prompt clears the previous turn's agents")
    func newTurnClearsAgents() {
        let store = SessionStore()
        store.apply(hookEvent("SubagentStart", ["agentId": "a1"]))
        #expect(store.sessions.first?.agents.count == 1)

        store.apply(hookEvent("UserPromptSubmit"))
        #expect(store.sessions.first?.agents.isEmpty == true)
    }
}

@Suite("PanelLayout")
struct PanelLayoutTests {
    private func sessions(_ states: [SessionState]) -> [Session] {
        states.enumerated().map { index, state in
            var session = Session(sessionID: "s\(index)")
            session.state = state
            return session
        }
    }

    private func withAgents(_ count: Int, state: SessionState = .working, finished: Int = 0) -> Session {
        var session = Session(sessionID: "fan")
        session.state = state
        for index in 0 ..< count {
            var agent = SubagentActivity(
                agentID: "a\(index)",
                agentType: "Explore",
                startedAt: Date(timeIntervalSince1970: 1_000_000 + Double(index))
            )
            if index < finished {
                agent.state = .done
                agent.finishedAt = agent.startedAt.addingTimeInterval(1)
            }
            session.agents[agent.agentID] = agent
        }
        return session
    }

    @Test("a list that fits is shown whole, with nothing to say about the rest")
    func fitsWhole() {
        let layout = PanelLayout(sessions: sessions([.working, .idle, .done]))
        #expect(layout.rows.count == 3)
        #expect(layout.rows.allSatisfy { $0.isSession })
        #expect(layout.hiddenSessions.isEmpty)
        #expect(layout.summary == nil)
    }

    /// Rows arrive sorted by urgency, so the cap must drop from the tail — anything actionable has to
    /// survive it. This is the property that makes truncation acceptable at all.
    @Test("the cap drops the tail, so actionable rows survive")
    func dropsTheTail() {
        let states: [SessionState] = [.needsYou, .error, .working] + Array(repeating: .idle, count: 9)
        let layout = PanelLayout(sessions: sessions(states), limit: 4)
        #expect(layout.rows.count == 4)
        #expect(layout.hiddenSessions.count == 8)
    }

    /// "8 more idle" and "8 more" are different promises: one says nothing is being hidden that you would
    /// act on, the other admits that something might be.
    @Test("the summary distinguishes hidden idle rows from hidden actionable ones")
    func summaryIsHonest() {
        let allIdle = PanelLayout(sessions: sessions(Array(repeating: .idle, count: 6)), limit: 4)
        #expect(allIdle.summary == "2 more idle")

        let mixed = PanelLayout(
            sessions: sessions([.idle, .idle, .idle, .idle, .working, .idle]),
            limit: 4
        )
        #expect(mixed.summary == "2 more", "a working session is hidden, so do not claim they are idle")
    }

    @Test("an empty list produces nothing")
    func empty() {
        let layout = PanelLayout(sessions: [])
        #expect(layout.rows.isEmpty)
        #expect(layout.summary == nil)
    }

    /// The default has to be small enough that ten rows still fit a laptop display.
    @Test("the shipped cap is a glanceable number")
    func shippedCap() {
        #expect(PanelLayout.maximumRows <= 12)
        #expect(PanelLayout.maximumRows >= 5)
        #expect(PanelLayout.maximumAgentRows < PanelLayout.maximumRows)
    }

    // MARK: - Agents

    @Test("a working session's agents follow it, indented")
    func agentsFollowTheirSession() {
        let layout = PanelLayout(sessions: [withAgents(3)])
        #expect(layout.rows.map(\.id) == ["s:fan", "a:fan:a0", "a:fan:a1", "a:fan:a2"])
        #expect(layout.rows.allSatisfy { $0.sessionID == "fan" })
    }

    /// The tree glyph closes the block, so the last agent has to be identifiable as last.
    @Test("only the final agent of a block closes it")
    func blockEnds() {
        let layout = PanelLayout(sessions: [withAgents(2)] + sessions([.working]))
        #expect(layout.isLastInBlock(0) == false, "a session followed by its own agents")
        #expect(layout.isLastInBlock(1) == false)
        #expect(layout.isLastInBlock(2) == true, "last agent before the next session")
        #expect(layout.isLastInBlock(3) == true, "a session with no agents is its own block")
    }

    /// The load-bearing rule: a fan-out is detail about one session, and must not be able to hide another
    /// session entirely. Sessions claim their rows before any agent does.
    @Test("a fan-out cannot push another session off the list")
    func sessionsClaimRowsFirst() {
        let fan = withAgents(8)
        var other = Session(sessionID: "other")
        other.state = .needsYou
        let layout = PanelLayout(sessions: [fan, other], limit: 4)

        #expect(layout.rows.filter(\.isSession).map(\.sessionID) == ["fan", "other"])
        #expect(layout.rows.count <= 4)
    }

    /// The overflow line pays for itself out of the session's own allowance rather than borrowing a row
    /// from whatever comes next.
    @Test("agents past the cap collapse to a counted line")
    func agentOverflow() {
        let layout = PanelLayout(sessions: [withAgents(9)], limit: 10, agentLimit: 4)
        #expect(layout.rows.count == 5, "one session plus its four-row allowance")
        #expect(layout.rows.last == .agentOverflow(sessionID: "fan", count: 6),
                "three agents shown, six accounted for")
    }

    @Test("an exactly-fitting fan-out needs no overflow line")
    func exactFit() {
        let layout = PanelLayout(sessions: [withAgents(4)], agentLimit: 4)
        #expect(layout.rows.count == 5)
        #expect(layout.rows.dropFirst().allSatisfy { $0.isAgent })
    }

    /// A finished or resting session's internal structure does not inform what to do next, which is the
    /// only question the panel is for.
    @Test("agents are drawn only while their session is still doing something about them",
          arguments: [SessionState.done, .idle])
    func settledSessionsHideTheirAgents(state: SessionState) {
        let layout = PanelLayout(sessions: [withAgents(3, state: state)])
        #expect(layout.rows.count == 1, "just the session")
    }

    /// The header has to agree with the rows. It counts every session the layout accounts for — drawn or
    /// truncated — and never the live store, which can move on while the panel is held open.
    @Test("the session count covers drawn and hidden sessions, and never the agents")
    func sessionCountIgnoresAgents() {
        let layout = PanelLayout(sessions: [withAgents(3)] + sessions([.working, .idle]), limit: 4)
        #expect(layout.rows.count == 4, "three sessions plus one agent row")
        #expect(layout.sessionCount == 3)

        let truncated = PanelLayout(sessions: sessions(Array(repeating: .idle, count: 9)), limit: 4)
        #expect(truncated.sessionCount == 9, "the hidden ones still exist")
    }

    @Test("a blocked session still shows its agents, since one of them is the reason")
    func blockedSessionsShowAgents() {
        let layout = PanelLayout(sessions: [withAgents(2, state: .needsYou)])
        #expect(layout.rows.count == 3)
    }

    /// The headline has to survive the row cap: this is what makes "wait or switch tabs" answerable even
    /// when only three of nine agents get a row.
    @Test("the session's own line carries the fan-out aggregate")
    func aggregateOnTheSessionLine() {
        var fresh = withAgents(5)
        fresh.currentTool = "Agent"
        #expect(fresh.agentSummary == "5 agents")
        // Without the tool prefix: "Agent · 5 agents" says the same thing twice, and the tool a fan-out's
        // main thread is running is always the one that spawned it.
        #expect(fresh.activityLine() == "5 agents")

        var partly = withAgents(5, finished: 3)
        partly.currentTool = "Agent"
        #expect(partly.agentSummary == "3/5 done")
        #expect(partly.activityLine() == "3/5 done")

        let single = withAgents(1)
        #expect(single.agentSummary == "1 agent")
        #expect(single.activityLine() == "1 agent")

        var plain = Session(sessionID: "p")
        plain.state = .working
        plain.currentTool = "Edit"
        plain.currentToolSummary = "Session.swift"
        #expect(plain.agentSummary == nil)
        #expect(plain.activityLine() == "Edit · Session.swift", "no agents, no change")
    }
}

/// The reader answers on the main actor after a hop through its own queue, and skips a read while
/// one is already running — so a test has to give that hop somewhere to land and keep asking, the
/// way the app does by rescanning the registry every couple of seconds. The timeout is only here so
/// a failure fails instead of hanging.
@MainActor
private func settle(
    _ store: SessionStore,
    registry entry: RegistryEntry,
    timeout: TimeInterval = 3,
    until condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        store.apply(registry: [entry])
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

/// End to end over real files, because the defect these cover was never in one function: every rule
/// held on its own, and the name still degraded once Claude Code renamed the session underneath us.
@Suite("SessionStore — where a session's name comes from")
@MainActor
struct SessionNameSourceTests {
    private func transcript(_ lines: [String]) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchling-naming-\(UUID().uuidString).jsonl")
        try! lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func append(_ line: String, to path: String) {
        let handle = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try! handle.seekToEnd()
        handle.write(Data(line.appending("\n").utf8))
        try! handle.close()
    }

    private func started(_ path: String) -> SessionStore {
        let store = SessionStore()
        store.apply(hookEvent("SessionStart", session: "s1", ["transcriptPath": path]))
        return store
    }

    @Test("the registry's slug shows until the transcript has a title")
    func slugUntilTitled() async {
        let path = transcript([#"{"type":"user","message":{"role":"user"}}"#])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let entry = registryEntry(session: "s1", name: "proj-1a")

        let store = started(path)
        store.apply(registry: [entry])
        #expect(store.sessions.first?.displayName == "proj-1a")

        append(#"{"type":"ai-title","aiTitle":"Ship app via Homebrew","sessionId":"s1"}"#, to: path)
        #expect(await settle(store, registry: entry) {
            store.sessions.first?.displayName == "Ship app via Homebrew"
        })
    }

    /// The one a user reported: two sessions wanting the same name are renamed by Claude Code, which
    /// records that in the registry and nowhere else. Reading the registry as a person's choice took
    /// the title back off every session in a project at once, and never gave it back.
    @Test("a collision rename cannot take the title back")
    func collisionRename() async {
        let path = transcript([#"{"type":"ai-title","aiTitle":"Ship app via Homebrew","sessionId":"s1"}"#])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let entry = registryEntry(session: "s1", name: "proj-1a")

        let store = started(path)
        #expect(await settle(store, registry: entry) {
            store.sessions.first?.displayName == "Ship app via Homebrew"
        })

        store.apply(registry: [registryEntry(session: "s1", name: "proj-2b")])
        #expect(store.sessions.first?.name == "proj-2b", "the rename is recorded")
        #expect(store.sessions.first?.displayName == "Ship app via Homebrew", "but it is not the name")
    }

    @Test("a name a person set outranks the title Claude derives")
    func chosenNameWins() async {
        let path = transcript([
            #"{"type":"ai-title","aiTitle":"Ship app via Homebrew","sessionId":"s1"}"#,
            #"{"type":"custom-title","customTitle":"release work","sessionId":"s1"}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let entry = registryEntry(session: "s1", name: "proj-1a")

        let store = started(path)
        #expect(await settle(store, registry: entry) {
            store.sessions.first?.displayName == "release work"
        })
    }

    /// Claude keeps retitling the conversation after a person has named it, so the newer record is
    /// the one that must lose here — the only place in the reader where newest does not win.
    @Test("a title written after the name does not replace it")
    func titleAfterNameLoses() async {
        let path = transcript([#"{"type":"custom-title","customTitle":"release work","sessionId":"s1"}"#])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let entry = registryEntry(session: "s1", name: "proj-1a")

        let store = started(path)
        #expect(await settle(store, registry: entry) {
            store.sessions.first?.displayName == "release work"
        })

        append(#"{"type":"ai-title","aiTitle":"Something else entirely","sessionId":"s1"}"#, to: path)
        #expect(await settle(store, registry: entry) {
            store.sessions.first?.aiTitle == "Something else entirely"
        })
        #expect(store.sessions.first?.displayName == "release work")
    }

    @Test("a background job keeps its registry name whatever the transcript says")
    func backgroundKeepsItsName() async {
        let path = transcript([
            #"{"type":"custom-title","customTitle":"release work","sessionId":"s1"}"#,
            #"{"type":"ai-title","aiTitle":"Investigating CI failures","sessionId":"s1"}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let entry = registryEntry(session: "s1", name: "fix the flaky test", kind: "bg")

        let store = started(path)
        #expect(await settle(store, registry: entry) {
            store.sessions.first?.customTitle == "release work"
        })
        #expect(store.sessions.first?.displayName == "fix the flaky test")
    }

    /// The sibling behaviour, kept here because it broke once already: reading three marks instead of
    /// two must not stop a later `/color` from landing.
    @Test("a colour set later still reaches the row")
    func colourFollows() async {
        let path = transcript([#"{"type":"ai-title","aiTitle":"Ship it","sessionId":"s1"}"#])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let entry = registryEntry(session: "s1", name: "proj-1a")

        let store = started(path)
        #expect(await settle(store, registry: entry) { store.sessions.first?.aiTitle == "Ship it" })
        #expect(store.sessions.first?.colorName == nil)

        append(#"{"type":"agent-color","agentColor":"green","sessionId":"s1"}"#, to: path)
        #expect(await settle(store, registry: entry) { store.sessions.first?.colorName == "green" })

        append(#"{"type":"agent-color","agentColor":"pink","sessionId":"s1"}"#, to: path)
        #expect(await settle(store, registry: entry) { store.sessions.first?.colorName == "pink" })
    }
}
