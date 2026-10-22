import AgentGlanceCore
import Foundation

let usage = """
usage: agentglance [ps] [--json]
       agentglance clean [--dry-run] [--yes] [--session KEY]... [--pid PID]...

  ps      Show agent sessions and the processes each one started (default).
  clean   Stop processes left behind by ended sessions. --session/--pid narrow
          the targets; --pid may also target a running session's process.
"""

var args = Array(CommandLine.arguments.dropFirst())
var command = "ps"
if let first = args.first, !first.hasPrefix("-") || first == "-h" || first == "--help" {
    command = args.removeFirst()
}

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func values(_ name: String) -> [String] {
    var out: [String] = []
    while let i = args.firstIndex(of: name), i + 1 < args.count {
        out.append(args[i + 1])
        args.removeSubrange(i...(i + 1))
    }
    return out
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("agentglance: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

func pad(_ s: String, _ width: Int, left: Bool = false) -> String {
    let fill = String(repeating: " ", count: max(0, width - s.count))
    return left ? fill + s : s + fill
}

func render(_ snapshot: Snapshot) {
    if snapshot.sessions.isEmpty {
        print("No agent sessions found.")
    }
    for session in snapshot.sessions {
        let meta = session.meta
        let id = meta.shortSessionId.map { " (\($0))" } ?? ""
        let state = session.isRunning
            ? "running · \(session.processes.count) procs · \(Format.bytes(session.totalRSS))"
            : "ENDED · left \(session.processes.count) procs · \(Format.bytes(session.totalRSS))"
        print("\(session.isRunning ? "●" : "○") \(meta.tool.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(meta.label)\(id)  \(state)")
        for proc in session.processes {
            let ports = proc.ports.map { ":\($0)" }.joined(separator: ",")
            print("    \(pad(String(proc.id.pid), 7, left: true))  \(pad(String(proc.name.prefix(16)), 16)) "
                + "\(pad(String(ports.prefix(14)), 14)) \(pad(Format.bytes(proc.rssBytes), 9, left: true)) "
                + "\(pad(String(format: "%.1f%%", proc.cpuPercent), 6, left: true))  \(proc.command.prefix(70))")
        }
    }
    if !snapshot.localModels.isEmpty {
        let total = snapshot.localModels.reduce(0) { $0 + $1.rssBytes }
        print("\n◆ local models (ollama)  \(snapshot.localModels.count) procs · \(Format.bytes(total))")
    }
    for warning in snapshot.warnings { print("⚠ \(warning)") }
    if !snapshot.leftBehind.isEmpty {
        print("\n\(Format.bytes(snapshot.leftBehindRSS)) left behind by ended sessions. Run `agentglance clean` to stop it.")
    }
}

func json(_ snapshot: Snapshot) {
    let sessions: [[String: Any]] = snapshot.sessions.map { s in
        [
            "key": s.meta.key, "tool": s.meta.tool.rawValue, "label": s.meta.label,
            "session_id": s.meta.sessionId ?? NSNull(), "cwd": s.meta.cwd ?? NSNull(),
            "running": s.isRunning, "rss_bytes": s.totalRSS,
            "processes": s.processes.map { p in
                ["pid": p.id.pid, "name": p.name, "command": p.command, "rss_bytes": p.rssBytes,
                 "cpu_percent": p.cpuPercent, "ports": p.ports] as [String: Any]
            },
        ]
    }
    let object: [String: Any] = ["sessions": sessions, "warnings": snapshot.warnings,
                                 "left_behind_bytes": snapshot.leftBehindRSS]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

let monitor = Monitor()

switch command {
case "ps":
    let asJSON = flag("--json")
    guard args.isEmpty else { fail("unexpected arguments: \(args.joined(separator: " "))") }
    // Two scans so CPU% has a baseline.
    _ = monitor.scan()
    usleep(500_000)
    let snapshot = monitor.scan()
    asJSON ? json(snapshot) : render(snapshot)

case "clean":
    let dryRun = flag("--dry-run"), yes = flag("--yes")
    let keys = values("--session")
    let pidArgs = values("--pid")
    let pids = pidArgs.compactMap(Int32.init)
    guard args.isEmpty, pids.count == pidArgs.count else { fail("bad arguments: \(args.joined(separator: " "))") }

    let snapshot = monitor.scan()
    let targets = monitor.targets(sessionKeys: keys.isEmpty ? nil : Set(keys),
                                  pids: pids.isEmpty ? nil : Set(pids), in: snapshot)
    guard !targets.isEmpty else {
        print("Nothing to clean.")
        exit(0)
    }
    print("Will stop \(targets.count) process(es), \(Format.bytes(targets.reduce(0) { $0 + $1.rssBytes })):")
    for t in targets { print("    \(t.id.pid)  \(t.name)  \(String(t.command.prefix(80)))") }
    if dryRun { exit(0) }
    if !yes {
        print("Proceed? [y/N] ", terminator: "")
        guard readLine()?.lowercased() == "y" else { print("Aborted."); exit(1) }
    }
    let result = monitor.clean(sessionKeys: keys.isEmpty ? nil : Set(keys),
                               pids: pids.isEmpty ? nil : Set(pids), in: snapshot)
    print("Stopped \(result.stopped.count), force-killed \(result.forceKilled.count), skipped \(result.skipped.count).")
    for (id, reason) in result.skipped { print("    skipped \(id.pid): \(reason)") }

case "-h", "--help", "help":
    print(usage)

default:
    fail("unknown command \(command)")
}
