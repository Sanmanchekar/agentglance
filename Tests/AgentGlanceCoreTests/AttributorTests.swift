@testable import AgentGlanceCore
import Foundation
import Testing

private func row(_ pid: Int32, _ ppid: Int32, _ name: String, start: UInt64? = nil,
                 args: [String] = [], env: [String: String] = [:], cwd: String? = nil) -> ProcRow {
    ProcRow(id: ProcID(pid: pid, start: start ?? UInt64(pid)), ppid: ppid, name: name,
            args: args, env: env, cwd: cwd)
}

@Suite struct AttributorTests {
    @Test func descendantsOfLiveAgentAreOwned() {
        var ledger = Ledger()
        let rows = [
            row(10, 1, "zsh"),
            row(20, 10, "claude", cwd: "/work/login-page"),
            row(30, 20, "zsh"),
            row(40, 30, "node", args: ["node", "vite"]),
            row(50, 10, "vim"),
        ]
        let result = Attributor.attribute(rows, ledger: &ledger)
        let key = Attributor.rootKey(.claude, ProcID(pid: 20, start: 20))

        #expect(result.liveRoots == [key])
        #expect(Set(result.owned[key]?.map(\.pid) ?? []) == [30, 40])
        #expect(result.sessions[key]?.label == "login-page")
    }

    @Test func orphanIsTracedByEnvTagAfterAgentExits() {
        var ledger = Ledger()
        let liveKey = Attributor.rootKey(.claude, ProcID(pid: 20, start: 20))
        _ = Attributor.attribute([
            row(20, 1, "claude", cwd: "/work/fix-tests"),
            row(40, 20, "node", env: ["CLAUDE_PID": "20", "CLAUDE_CODE_SESSION_ID": "abc12345-x"]),
        ], ledger: &ledger)

        // Agent exits; node is re-parented to launchd.
        let result = Attributor.attribute([
            row(40, 1, "node", env: ["CLAUDE_PID": "20", "CLAUDE_CODE_SESSION_ID": "abc12345-x"]),
        ], ledger: &ledger)

        #expect(result.liveRoots.isEmpty)
        #expect(result.owned[liveKey]?.map(\.pid) == [40])
        #expect(result.sessions[liveKey]?.label == "fix-tests")
        #expect(result.sessions[liveKey]?.sessionId == "abc12345-x")
    }

    @Test func untaggedOrphanIsTracedByLedgerMemory() {
        var ledger = Ledger()
        let key = Attributor.rootKey(.codex, ProcID(pid: 20, start: 20))
        _ = Attributor.attribute([row(20, 1, "codex"), row(40, 20, "python3")], ledger: &ledger)

        let result = Attributor.attribute([row(40, 1, "python3")], ledger: &ledger)
        #expect(result.owned[key]?.map(\.pid) == [40])
        #expect(result.liveRoots.isEmpty)
    }

    @Test func reusedPidIsNotMistakenForOldProcess() {
        var ledger = Ledger()
        _ = Attributor.attribute([row(20, 1, "codex"), row(40, 20, "python3")], ledger: &ledger)

        // pid 40 now belongs to an unrelated process with a later start time.
        let result = Attributor.attribute([row(40, 1, "python3", start: 999)], ledger: &ledger)
        #expect(result.owned.isEmpty)
    }

    @Test func orphanWithUnknownAgentGetsSessionFromEnv() {
        var ledger = Ledger()
        let result = Attributor.attribute([
            row(40, 1, "node", env: ["CLAUDE_PID": "77", "CLAUDE_CODE_SESSION_ID": "s1", "PWD": "/work/api"]),
        ], ledger: &ledger)
        let session = result.sessions.values.first
        #expect(session?.label == "api")
        #expect(session?.sessionId == "s1")
        #expect(result.liveRoots.isEmpty)
    }

    @Test func nestedAgentBelongsToOuterAgent() {
        var ledger = Ledger()
        let rows = [row(20, 1, "claude"), row(30, 20, "codex"), row(40, 30, "node")]
        let result = Attributor.attribute(rows, ledger: &ledger)
        let outer = Attributor.rootKey(.claude, ProcID(pid: 20, start: 20))
        #expect(result.liveRoots == [outer])
        #expect(Set(result.owned[outer]?.map(\.pid) ?? []) == [30, 40])
    }

    @Test func npmInstalledAgentIsDetectedFromScriptPath() {
        let npm = row(20, 1, "node", args: ["node", "/usr/local/bin/claude"])
        #expect(AgentDetector.tool(for: npm) == .claude)
        #expect(AgentDetector.tool(for: row(21, 1, "node", args: ["node", "server.js"])) == nil)
    }

    @Test func excludedProcessesAreIgnored() {
        var ledger = Ledger()
        let rows = [row(20, 1, "claude"), row(30, 20, "zsh"), row(40, 30, "agentglance")]
        let result = Attributor.attribute(rows, ledger: &ledger, excluding: [30, 40])
        #expect(result.owned.isEmpty)
    }
}

@Suite struct PortScannerTests {
    @Test func parsesLsofFieldOutput() {
        let out = "p123\nn*:3000\nn[::1]:3000\np456\nn127.0.0.1:5173\n"
        #expect(PortScanner.parse(out) == [123: [3000], 456: [5173]])
    }
}

@Suite struct MonitorRulesTests {
    @Test func recognisesAgentGlanceOwnProcesses() {
        let app = ProcRow(id: ProcID(pid: 1, start: 1), ppid: 1, name: "AgentGlance",
                          path: "/x/build/AgentGlance.app/Contents/MacOS/AgentGlance")
        let cli = ProcRow(id: ProcID(pid: 2, start: 1), ppid: 1, name: "agentglance", path: "/Users/me/.local/bin/agentglance")
        let other = ProcRow(id: ProcID(pid: 3, start: 1), ppid: 1, name: "node", path: "/usr/local/bin/node")
        #expect(Monitor.isAgentGlance(app))
        #expect(Monitor.isAgentGlance(cli))
        #expect(!Monitor.isAgentGlance(other))
    }

    @Test func bulkCleanSkipsAppsButExplicitPidDoesNot() {
        let meta = SessionMeta(key: "k", tool: .claude, rootPid: 9, rootStart: 1, cwd: "/w", sessionId: nil)
        let server = OwnedProcess(id: ProcID(pid: 10, start: 1), name: "node", command: "node", rssBytes: 1, cpuPercent: 0, ports: [])
        let app = OwnedProcess(id: ProcID(pid: 11, start: 1), name: "Docker", command: "Docker", rssBytes: 1, cpuPercent: 0,
                               ports: [], isApp: true)
        let snapshot = Snapshot(takenAt: Date(), sessions: [AgentSession(meta: meta, isRunning: false, processes: [server, app])],
                                localModels: [], warnings: [])
        let monitor = Monitor(ledgerURL: nil)
        #expect(monitor.targets(in: snapshot).processes.map(\.id.pid) == [10])
        #expect(monitor.targets(pids: [11], in: snapshot).processes.map(\.id.pid) == [11])
    }
}
