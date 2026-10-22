import Darwin
import Foundation

/// Takes snapshots of agent sessions and what they own. Not thread-safe: drive it from one queue.
public final class Monitor {
    public static let defaultLedgerURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AgentGlance/ledger.json")

    private let reader = ProcessReader()
    private let ledgerURL: URL?
    private var ledger: Ledger
    private var lastCPU: [ProcID: (nanos: UInt64, at: Date)] = [:]
    private(set) public var lastSnapshot: Snapshot?

    public init(ledgerURL: URL? = Monitor.defaultLedgerURL) {
        self.ledgerURL = ledgerURL
        self.ledger = ledgerURL.map(Ledger.load) ?? Ledger()
    }

    public func scan() -> Snapshot {
        let now = Date()
        let rows = reader.read()
        // Never attribute (or offer to kill) this process or its parent chain, e.g. the shell running the CLI.
        var excluded: Set<Int32> = [getpid()]
        var ppid = getppid()
        while ppid > 1, excluded.insert(ppid).inserted, let parent = rows.first(where: { $0.pid == ppid }) {
            if AgentDetector.tool(for: parent) != nil { excluded.remove(ppid); break }
            ppid = parent.ppid
        }

        let attribution = Attributor.attribute(rows, ledger: &ledger, excluding: excluded)
        if let ledgerURL { ledger.save(to: ledgerURL) }

        let ollama = rows.filter(AgentDetector.isOllama)
        let ownedRows = attribution.owned.values.flatMap { $0 }
        let ports = PortScanner.listening(pids: (ownedRows + ollama).map(\.pid))

        var cpu: [ProcID: (nanos: UInt64, at: Date)] = [:]
        func owned(_ row: ProcRow) -> OwnedProcess {
            var percent = 0.0
            if let prev = lastCPU[row.id], row.cpuNanos >= prev.nanos {
                let wall = now.timeIntervalSince(prev.at)
                if wall > 0 { percent = Double(row.cpuNanos - prev.nanos) / 1e9 / wall * 100 }
            }
            cpu[row.id] = (row.cpuNanos, now)
            return OwnedProcess(id: row.id, name: row.name, command: row.commandLine,
                                rssBytes: row.rssBytes, cpuPercent: percent, ports: ports[row.pid] ?? [])
        }

        var sessions = attribution.sessions.values.map { meta in
            AgentSession(meta: meta, isRunning: attribution.liveRoots.contains(meta.key),
                         processes: (attribution.owned[meta.key] ?? []).map(owned).sorted { $0.rssBytes > $1.rssBytes })
        }
        sessions.sort { ($0.isRunning ? 1 : 0, $0.totalRSS) > ($1.isRunning ? 1 : 0, $1.totalRSS) }
        let models = ollama.map(owned).sorted { $0.rssBytes > $1.rssBytes }
        lastCPU = cpu

        var warnings: [String] = []
        for session in sessions where !session.isRunning {
            let ports = Set(session.processes.flatMap(\.ports)).sorted()
            guard !ports.isEmpty else { continue }
            let list = ports.map { ":\($0)" }.joined(separator: " ")
            warnings.append("Ended session \(session.meta.label) still holds \(ports.count == 1 ? "port" : "ports") \(list)")
        }

        let snapshot = Snapshot(takenAt: now, sessions: sessions, localModels: models, warnings: warnings)
        lastSnapshot = snapshot
        return snapshot
    }

    /// Stops processes from the given sessions (all ended sessions by default). Running agent roots are always protected.
    public func clean(sessionKeys: Set<String>? = nil, pids: Set<Int32>? = nil, in snapshot: Snapshot) -> CleanupResult {
        let targets = targets(sessionKeys: sessionKeys, pids: pids, in: snapshot)
        let roots = Set(snapshot.running.map(\.meta.rootPid))
        return Cleaner.stop(targets.map(\.id), protecting: roots)
    }

    public func targets(sessionKeys: Set<String>? = nil, pids: Set<Int32>? = nil, in snapshot: Snapshot) -> [OwnedProcess] {
        let sessions: [AgentSession]
        if let sessionKeys {
            sessions = snapshot.sessions.filter { sessionKeys.contains($0.meta.key) || sessionKeys.contains($0.meta.sessionId ?? "") }
        } else if pids != nil {
            sessions = snapshot.sessions
        } else {
            sessions = snapshot.leftBehind
        }
        return sessions.flatMap(\.processes).filter { pids?.contains($0.id.pid) ?? true }
    }
}
