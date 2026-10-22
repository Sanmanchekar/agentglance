import AgentGlanceCore
import Foundation

let usage = """
usage: agentglance [ps] [--json] [--no-docker]
       agentglance clean [--dry-run] [--yes] [--session KEY]... [--pid PID]... [--container ID]...

  ps      Show agent sessions and the processes and containers each one started (default).
  clean   Stop what ended sessions left behind: their processes and their *confirmed*
          containers (`docker stop`, nothing is deleted). --session narrows to sessions;
          --pid / --container target exact items, including a running session's or a
          container that is only *likely* the agent's.
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

func ports(_ list: [Int]) -> String {
    String(list.map { ":\($0)" }.joined(separator: ",").prefix(14))
}

func render(_ snapshot: Snapshot) {
    if snapshot.sessions.isEmpty {
        print("No agent sessions found.")
    }
    for session in snapshot.sessions {
        let meta = session.meta
        let id = meta.shortSessionId.map { " (\($0))" } ?? ""
        let summary = Format.leftovers(processes: session.processes.count, bytes: session.totalRSS,
                                       containers: session.containers.count)
        let state = session.isRunning ? "running · \(summary)" : "ENDED · left \(summary)"
        print("\(session.isRunning ? "●" : "○") \(pad(meta.tool.rawValue, 7)) \(meta.label)\(id)  \(state)")
        for proc in session.processes {
            print("    \(pad(String(proc.id.pid), 7, left: true))  \(pad(String(proc.name.prefix(16)), 16)) "
                + "\(pad(ports(proc.ports), 14)) \(pad(Format.bytes(proc.rssBytes), 9, left: true)) "
                + "\(pad(String(format: "%.1f%%", proc.cpuPercent), 6, left: true))  \(proc.command.prefix(70))")
        }
        for container in session.containers {
            print("    \(container.shortId)  \(pad(String(container.name.prefix(16)), 16)) \(pad(ports(container.ports), 14)) "
                + "container · \(container.image)\(container.confidence == .likely ? " · likely" : "")")
        }
    }
    if !snapshot.localModels.isEmpty {
        let total = snapshot.localModels.reduce(0) { $0 + $1.rssBytes }
        print("\n◆ local models (ollama)  \(snapshot.localModels.count) procs · \(Format.bytes(total))")
    }
    if DockerClient.path != nil && !snapshot.dockerAvailable {
        print("\n(Docker isn't running, so containers aren't tracked.)")
    }
    if !snapshot.warnings.isEmpty { print("") }
    for warning in snapshot.warnings { print("⚠ \(warning.message)") }
    if !snapshot.leftBehind.isEmpty {
        let containers = snapshot.leftBehindContainers
        print("\n\(Format.bytes(snapshot.leftBehindRSS))\(containers > 0 ? " and \(containers) container(s)" : "") left behind by ended sessions. Run `agentglance clean` to stop it.")
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
            "containers": s.containers.map { c in
                ["id": c.id, "name": c.name, "image": c.image, "ports": c.ports,
                 "confidence": c.confidence.rawValue] as [String: Any]
            },
        ]
    }
    let object: [String: Any] = [
        "sessions": sessions, "left_behind_bytes": snapshot.leftBehindRSS, "docker_available": snapshot.dockerAvailable,
        "warnings": snapshot.warnings.map { ["kind": $0.kind.rawValue, "message": $0.message] },
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

let monitor = Monitor()
monitor.trackDocker = !flag("--no-docker")

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
    let containerIds = values("--container")
    guard args.isEmpty, pids.count == pidArgs.count else { fail("bad arguments: \(args.joined(separator: " "))") }

    let snapshot = monitor.scan()
    let sessionKeys = keys.isEmpty ? nil : Set(keys)
    let pidSet = pids.isEmpty ? nil : Set(pids)
    let containerSet = containerIds.isEmpty ? nil : Set(containerIds)
    let targets = monitor.targets(sessionKeys: sessionKeys, pids: pidSet, containerIds: containerSet, in: snapshot)
    guard !targets.isEmpty else {
        print("Nothing to clean.")
        exit(0)
    }
    print("Will stop \(targets.processes.count) process(es) (\(Format.bytes(targets.processes.reduce(0) { $0 + $1.rssBytes })))"
        + (targets.containers.isEmpty ? ":" : " and \(targets.containers.count) container(s):"))
    for t in targets.processes { print("    \(t.id.pid)  \(t.name)  \(String(t.command.prefix(80)))") }
    for c in targets.containers { print("    \(c.shortId)  \(c.name)  \(c.image)") }
    let skippedLikely = snapshot.leftBehind.flatMap(\.containers).filter { $0.confidence == .likely }
    if pidSet == nil, containerSet == nil, !skippedLikely.isEmpty {
        print("Not touching \(skippedLikely.count) container(s) that are only likely the agent's; use --container ID to stop one.")
    }
    if dryRun { exit(0) }
    if !yes {
        print("Proceed? [y/N] ", terminator: "")
        guard readLine()?.lowercased() == "y" else { print("Aborted."); exit(1) }
    }
    let result = monitor.clean(sessionKeys: sessionKeys, pids: pidSet, containerIds: containerSet, in: snapshot)
    print(result.summary + ".")
    for (id, reason) in result.skipped { print("    skipped \(id.pid): \(reason)") }

case "-h", "--help", "help":
    print(usage)

default:
    fail("unknown command \(command)")
}
