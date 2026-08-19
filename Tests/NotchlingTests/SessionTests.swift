import Foundation
import Testing

@testable import Notchling

// MARK: - SessionState

@Suite("SessionState")
struct SessionStateTests {
    @Test("urgency orders attention-wanting states first")
    func urgencyOrder() {
        let ordered: [SessionState] = [.needsYou, .error, .working, .done, .idle]
        #expect(ordered.map(\.urgency) == [0, 1, 2, 3, 4])
        // Sorting by urgency must reproduce that order from any starting arrangement.
        #expect(ordered.shuffled().sorted { $0.urgency < $1.urgency } == ordered)
    }

    @Test("only the states worth interrupting for are notifiable")
    func notifiable() {
        #expect(SessionState.needsYou.isNotifiable)
        #expect(SessionState.done.isNotifiable)
        #expect(SessionState.error.isNotifiable)
        #expect(!SessionState.working.isNotifiable)
        #expect(!SessionState.idle.isNotifiable)
    }

    @Test("raw values round-trip, since NOTCHLING_PREVIEW parses them")
    func rawValues() {
        for state in [SessionState.working, .needsYou, .done, .error, .idle] {
            #expect(SessionState(rawValue: state.rawValue) == state)
        }
        #expect(SessionState(rawValue: "nonsense") == nil)
    }
}

// MARK: - Session

@Suite("Session")
struct SessionTests {
    private func session(_ id: String = "abc123def456") -> Session {
        Session(sessionID: id)
    }

    @Test("displayName prefers the registry name, then cwd, then a short id")
    func displayNameFallbacks() {
        var s = session()
        #expect(s.displayName == "abc123de", "with nothing else, the first 8 id characters")

        s.cwd = "/Users/someone/code/my-project"
        #expect(s.displayName == "my-project")

        s.name = "api-refactor-7c"
        #expect(s.displayName == "api-refactor-7c")

        // An empty string is not a name.
        s.name = ""
        #expect(s.displayName == "my-project")
    }

    @Test("projectName is the cwd basename, or nil")
    func projectName() {
        var s = session()
        #expect(s.projectName == nil)
        s.cwd = "/a/b/widget"
        #expect(s.projectName == "widget")
        s.cwd = ""
        #expect(s.projectName == nil)
    }

    @Test("toolTally sorts by count, breaks ties by name, and keeps three")
    func toolTally() {
        var s = session()
        #expect(s.toolTally == nil)

        s.toolCounts = ["Edit": 3, "Bash": 2, "Read": 1]
        #expect(s.toolTally == "Edit ×3, Bash ×2, Read")

        // Equal counts fall back to alphabetical, so the label is stable between renders.
        s.toolCounts = ["Write": 2, "Bash": 2]
        #expect(s.toolTally == "Bash ×2, Write ×2")

        s.toolCounts = ["A": 5, "B": 4, "C": 3, "D": 2]
        #expect(s.toolTally == "A ×5, B ×4, C ×3", "only the three busiest")
    }

    @Test("activityLine says something useful in every state")
    func activityLine() {
        var s = session()
        #expect(s.activityLine() == nil, "idle with no finish behind it has nothing to say")

        s.state = .working
        #expect(s.activityLine() == nil, "working with no tool yet")
        s.currentTool = "Bash"
        #expect(s.activityLine() == "Bash")
        s.currentToolSummary = "npm test"
        #expect(s.activityLine() == "Bash · npm test")
        s.currentToolSummary = "Bash"
        #expect(s.activityLine() == "Bash", "a summary equal to the tool name is not repeated")

        s.state = .needsYou
        s.needsYouMessage = "Claude needs permission"
        #expect(s.activityLine() == "Claude needs permission")
        s.needsYouMessage = nil
        s.currentToolSummary = "npm test"
        #expect(s.activityLine() == "npm test", "falls back to the tool summary")

        s.state = .done
        s.lastMessage = "All tests pass"
        #expect(s.activityLine() == "All tests pass")

        s.state = .error
        s.lastMessage = nil
        #expect(s.activityLine() == "failed")
    }

    @Test("stalledFor only measures working sessions with recorded progress")
    func stalledFor() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var s = session()

        s.lastProgressAt = base
        s.state = .idle
        #expect(s.stalledFor(now: base + 900) == nil, "not working, so not stalled")

        s.state = .working
        s.lastProgressAt = nil
        #expect(s.stalledFor(now: base + 900) == nil, "no progress recorded yet")

        s.lastProgressAt = base
        #expect(s.stalledFor(now: base + 900) == 900)
    }

    @Test("pooled background spares are identified by argv, not by name")
    func infrastructureDetection() {
        // A never-claimed spare: its name is still the job id.
        var unclaimed = session()
        unclaimed.kind = .bg
        unclaimed.jobID = "job-1"
        unclaimed.name = "job-1"
        #expect(unclaimed.isUnclaimedSpare)
        #expect(unclaimed.isInfrastructure)

        // A spare that ran a job keeps the job's *name* after finishing, so the name test misses it.
        // Only argv gives it away, and without it the row never leaves the panel.
        var claimed = session()
        claimed.kind = .bg
        claimed.jobID = "job-2"
        claimed.name = "Add Hebrew locale and RTL support"
        #expect(!claimed.isUnclaimedSpare, "the name no longer matches the job id")
        #expect(!claimed.isInfrastructure, "and without argv we cannot tell")

        claimed.processCommand = "/usr/local/bin/claude bg-spare --bg-spare"
        #expect(claimed.isPooledSpare)
        #expect(claimed.isInfrastructure)

        var ptyHost = session()
        ptyHost.kind = .bg
        ptyHost.processCommand = "claude bg-pty-host"
        #expect(ptyHost.isPooledSpare)
    }

    @Test("a real background agent is not infrastructure")
    func realBackgroundAgent() {
        var s = session()
        s.kind = .bg
        s.jobID = "job-3"
        s.name = "Migrate the auth middleware"
        s.processCommand = "claude --session-id 1234 --print"
        #expect(!s.isInfrastructure)
    }

    @Test("an interactive session is never infrastructure, whatever its argv")
    func interactiveNeverInfrastructure() {
        var s = session()
        s.kind = .interactive
        s.processCommand = "claude bg-spare"
        #expect(!s.isInfrastructure, "the kind check guards this")
    }
}

@Suite("finished-recently memory")
struct FinishedAgoTests {
    private let finishedAt = Date(timeIntervalSince1970: 1_000_000)

    private func settled() -> Session {
        var session = Session(sessionID: "s")
        session.state = .idle
        session.lastFinishedAt = finishedAt
        return session
    }

    /// The whole point: `done` decays to idle after twenty seconds so the notch stops shouting, and until
    /// this existed that also discarded the fact. A session that had just finished looked exactly like one
    /// that had been cold for an hour.
    @Test("a settled row still says when it finished")
    func recentFinishIsRemembered() {
        let session = settled()
        #expect(session.activityLine(now: finishedAt.addingTimeInterval(5)) == "done just now")
        #expect(session.activityLine(now: finishedAt.addingTimeInterval(59)) == "done just now")
        #expect(session.activityLine(now: finishedAt.addingTimeInterval(4 * 60)) == "done 4m ago")
        #expect(session.activityLine(now: finishedAt.addingTimeInterval(25 * 60)) == "done 25m ago")
    }

    /// Past the memory window it is history rather than news, and a permanently annotated row would just
    /// be noise on every idle session you have ever run.
    @Test("an old finish stops being mentioned")
    func oldFinishIsForgotten() {
        let session = settled()
        let past = Session.finishedMemory + 1
        #expect(session.activityLine(now: finishedAt.addingTimeInterval(past)) == nil)
    }

    @Test("a session that never finished says nothing")
    func neverFinished() {
        var session = Session(sessionID: "s")
        session.state = .idle
        #expect(session.activityLine() == nil)
    }

    /// Clocks can go backwards — an NTP correction, or a hook event stamped slightly in the future.
    @Test("a finish in the future is ignored rather than printed as nonsense")
    func futureFinish() {
        let session = settled()
        #expect(session.activityLine(now: finishedAt.addingTimeInterval(-30)) == nil)
    }

    /// Only settled rows use the slot. A working session's activity line is what it is doing now, which
    /// matters more than what it did last time.
    @Test("a busy session shows its work, not its history")
    func busyRowsAreUnaffected() {
        var session = settled()
        session.state = .working
        session.currentTool = "Bash"
        #expect(session.activityLine(now: finishedAt.addingTimeInterval(60)) == "Bash")
    }
}

@Suite("SessionStore — finish memory")
@MainActor
struct StoreFinishMemoryTests {
    @Test("Stop records the finish, and a new turn supersedes it")
    func recordedAndCleared() {
        let clock = TestClock()
        let store = SessionStore(now: clock.now)

        store.apply(hookEvent("UserPromptSubmit", session: "s", at: clock.current))
        clock.advance(10)
        store.apply(hookEvent("Stop", session: "s", at: clock.current))
        #expect(store.sessions.first?.lastFinishedAt == clock.current)

        // A new turn that never finishes must not resurface the old one.
        clock.advance(60)
        store.apply(hookEvent("UserPromptSubmit", session: "s", at: clock.current))
        #expect(store.sessions.first?.lastFinishedAt == nil)
    }

    /// `notchling-1a` identifies nothing when three sessions are open, and Claude already derives a
    /// real title from the conversation. A name a person chose still beats both.
    @Test("a chosen name wins, then Claude's title, then the slug")
    func namePrecedence() {
        var session = Session(sessionID: "abcdef1234")
        session.cwd = "/Users/me/work/api"
        #expect(session.displayName == "api", "nothing but cwd yet")

        session.name = "notchling-1a"
        session.nameSource = "derived"
        #expect(session.displayName == "notchling-1a", "the slug, until there is a title")

        session.aiTitle = "Ship app via Homebrew"
        #expect(session.displayName == "Ship app via Homebrew")

        session.name = "release work"
        session.nameSource = nil
        #expect(session.displayName == "release work", "a name someone set beats a derived title")
    }

    /// A background job's registry name is the task's own title, which is already the best name it
    /// has — replacing it with a conversation-derived one would be a downgrade.
    @Test("a background job keeps its registry name")
    func backgroundKeepsItsName() {
        var session = Session(sessionID: "s")
        session.kind = .bg
        session.name = "fix the flaky test"
        session.nameSource = "derived"
        session.aiTitle = "Investigating CI failures"
        #expect(session.displayName == "fix the flaky test")
    }
}
