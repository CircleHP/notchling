import Foundation
import Testing

@testable import Notchling

@Suite("LaunchAgent")
struct LaunchAgentTests {
    /// Trimmed from a real `launchctl print gui/501/homebrew.mxcl.notchling`, including the nested
    /// section that repeats `state` at deeper indentation.
    private let printOutput = """
    homebrew.mxcl.notchling = {
    \tactive count = 1
    \tpath = /Users/someone/Library/LaunchAgents/homebrew.mxcl.notchling.plist
    \ttype = LaunchAgent
    \tstate = running
    \tprogram = /opt/homebrew/opt/notchling/Notchling.app/Contents/MacOS/Notchling
    \texit timeout = 5
    \truns = 1
    \tpid = 19973
    \timmediate reason = speculative
    \tforks = 2
    \tendpoints = {
    \t\t"com.apple.x" = {
    \t\t\tstate = active
    \t\t}
    \t}
    }
    """

    @Test("the job's pid is read out of what launchctl prints")
    func readsThePID() {
        #expect(LaunchAgent.pid(inPrintOutput: printOutput) == 19973)
    }

    @Test("output with no pid at all reports none, rather than guessing")
    func noPID() {
        #expect(LaunchAgent.pid(inPrintOutput: "state = not running\n") == nil)
        #expect(LaunchAgent.pid(inPrintOutput: "") == nil)
    }

    @Test("the service target is the domain launchctl expects")
    func serviceTarget() {
        #expect(LaunchAgent.serviceTarget(uid: 501, label: "local.notchling") == "gui/501/local.notchling")
    }

    /// Both install methods are covered, and each carries the command that starts *it* again —
    /// `brew services start` does nothing for a job `make autostart` wrote, and the reverse needs a
    /// checkout that a Homebrew install does not have.
    @Test("both labels are known, with distinct commands either way")
    func bothLabelsKnown() {
        let labels = LaunchAgent.known.map(\.label)
        #expect(labels.contains("homebrew.mxcl.notchling"))
        #expect(labels.contains("local.notchling"))
        #expect(Set(LaunchAgent.known.map(\.restartCommand)).count == LaunchAgent.known.count)
        #expect(Set(LaunchAgent.known.map(\.stopCommand)).count == LaunchAgent.known.count)
    }

    /// Measured as 0 against a live job. `EINPROGRESS` is accepted beside it because launchd reports
    /// it for a job still winding down, and calling that a failure would tell someone the stop did
    /// not work while it was working. 113 — the label is not registered — stays a failure.
    @Test("an in-progress teardown is not a failed one")
    func exitCodesThatMeanItIsGoing() {
        #expect(LaunchAgent.isSuccess(exitCode: 0))
        #expect(LaunchAgent.isSuccess(exitCode: EINPROGRESS))
        #expect(!LaunchAgent.isSuccess(exitCode: 113))
        #expect(!LaunchAgent.isSuccess(exitCode: 1))
    }

    @Test("the job holding this process is the one that is found")
    func findsTheOwningJob() {
        let job = LaunchAgent.owner(ofPID: 19973, uid: 501) { target in
            target == "gui/501/homebrew.mxcl.notchling" ? printOutput : nil
        }
        #expect(job?.label == "homebrew.mxcl.notchling")
        #expect(job?.restartCommand == "brew services start notchling")
    }

    /// The failure that matters. Someone who has used both install methods can have a leftover job for
    /// the other one; booting that out would stop a widget this process is not, and leave this one
    /// running with the button apparently broken.
    @Test("a registered job running some other process is not ours")
    func ignoresAJobThatIsNotOurs() {
        let job = LaunchAgent.owner(ofPID: 4242, uid: 501) { _ in self.printOutput }
        #expect(job == nil)
    }

    @Test("no job at all is not an error — it means launchd did not start this")
    func noJob() {
        #expect(LaunchAgent.owner(ofPID: 19973, uid: 501) { _ in nil } == nil)
    }

    /// `launchctl print` exits 113 for a label it does not know, and the runner turns any non-zero
    /// exit into nil — so an install method the user does not use must not stop the probe before it
    /// reaches the one they do.
    @Test("an unknown label does not hide a known one behind it")
    func keepsLookingPastAnUnknownLabel() {
        let job = LaunchAgent.owner(ofPID: 19973, uid: 501) { target in
            target.hasSuffix("local.notchling") ? printOutput : nil
        }
        #expect(job?.label == "local.notchling", "the second label is still reached")
    }
}
