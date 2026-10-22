import Darwin
import Foundation

/// Takes snapshots of agent sessions and what they own. Not thread-safe: drive it from one queue.
public final class Monitor {
    public static let defaultLedgerURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AgentGlance/ledger.json")

    /// A session counts as active (for same-folder warnings) if its agent used CPU this recently.
    static let activeWindow: TimeInterval = 120
    /// Migration scans walk the file tree, so they run every Nth scan only.
    static let migrationScanEvery = 10
    static let dockerCLINames: Set<String> = ["docker", "com.docker.cli", "docker-compose"]

    private let reader = ProcessReader()
    private let ledgerURL: URL?
    private var ledger: Ledger
    private var lastCPU: [ProcID: (nanos: UInt64, at: Date)] = [:]
    private var previousLive: Set<String>?
    private var endedAt: [String: Date] = [:]
    private var lastActive: [String: Date] = [:]
    private var scanCount = 0
    private var migrationWarnings: [Warning] = []
    public var trackDocker = true
    private(set) public var lastSnapshot: Snapshot?

    public init(ledgerURL: URL? = Monitor.defaultLedgerURL) {
        self.ledgerURL = ledgerURL
        self.ledger = ledgerURL.map(Ledger.load) ?? Ledger()
    }

    public func scan() -> Snapshot {
        let now = Date()
        scanCount += 1
        let rows = reader.read()
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        // Never attribute (or offer to kill) this process or its parent chain, e.g. the shell running the CLI.
        var excluded: Set<Int32> = [getpid()]
        var ppid = getppid()
        while ppid > 1, excluded.insert(ppid).inserted, let parent = byPid[ppid] {
            if AgentDetector.tool(for: parent) != nil { excluded.remove(ppid); break }
            ppid = parent.ppid
        }

        let previousSessions = ledger.sessions
        let attribution = Attributor.attribute(rows, ledger: &ledger, excluding: excluded)
        var metas = attribution.sessions
        let live = attribution.liveRoots

        // Agent activity, for deciding which sessions are actually working right now.
        var cpu: [ProcID: (nanos: UInt64, at: Date)] = [:]
        for key in live {
            guard let meta = metas[key], let root = byPid[meta.rootPid] else { continue }
            if let prev = lastCPU[root.id], root.cpuNanos >= prev.nanos {
                let wall = now.timeIntervalSince(prev.at)
                if wall > 0, Double(root.cpuNanos - prev.nanos) / 1e9 / wall > 0.02 { lastActive[key] = now }
            }
            cpu[root.id] = (root.cpuNanos, now)
        }

        // Containers.
        recordDockerLaunches(attribution.owned, now: now)
        var containers: [ContainerInfo] = []
        var dockerAvailable = false
        if trackDocker, let running = DockerClient.runningContainers() {
            containers = running
            dockerAvailable = true
            let candidates = previousSessions.merging(metas) { _, new in new }
            ledger.containers = ContainerAttributor.attribute(containers, sessions: Array(candidates.values),
                                                              dockerLaunches: ledger.dockerLaunches, known: ledger.containers)
            for owner in ledger.containers.values where metas[owner.sessionKey] == nil {
                metas[owner.sessionKey] = candidates[owner.sessionKey]
            }
        } else {
            // Docker is unavailable: keep earlier decisions (and their sessions) until it answers again.
            for owner in ledger.containers.values where metas[owner.sessionKey] == nil {
                metas[owner.sessionKey] = previousSessions[owner.sessionKey]
            }
        }
        ledger.sessions = metas
        ledger.dockerLaunches = ledger.dockerLaunches.filter { metas[$0.key] != nil }
        if let ledgerURL { ledger.save(to: ledgerURL) }

        var containersByKey: [String: [OwnedContainer]] = [:]
        for container in containers {
            guard let owner = ledger.containers[container.id] else { continue }
            containersByKey[owner.sessionKey, default: []].append(
                OwnedContainer(id: container.id, name: container.name, image: container.image,
                               ports: container.ports, confidence: owner.confidence))
        }

        // Processes.
        let ollama = rows.filter(AgentDetector.isOllama)
        let ownedRows = attribution.owned.values.flatMap { $0 }
        let ports = PortScanner.listening(pids: (ownedRows + ollama).map(\.pid))

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

        // Session lifecycle.
        let justEnded = previousLive.map { $0.subtracting(live) } ?? []
        for key in justEnded { endedAt[key] = now }
        previousLive = live
        endedAt = endedAt.filter { metas[$0.key] != nil && !live.contains($0.key) }
        lastActive = lastActive.filter { live.contains($0.key) }

        var sessions = metas.values.map { meta in
            AgentSession(meta: meta, isRunning: live.contains(meta.key),
                         processes: (attribution.owned[meta.key] ?? []).map(owned).sorted { $0.rssBytes > $1.rssBytes },
                         containers: containersByKey[meta.key] ?? [], endedAt: endedAt[meta.key])
        }
        // Ended sessions with nothing left are history, not something to show.
        sessions.removeAll { !$0.isRunning && !$0.hasLeftovers }
        sessions.sort { ($0.isRunning ? 1 : 0, $0.totalRSS) > ($1.isRunning ? 1 : 0, $1.totalRSS) }
        let models = ollama.map(owned).sorted { $0.rssBytes > $1.rssBytes }
        lastCPU = cpu

        let snapshot = Snapshot(takenAt: now, sessions: sessions, localModels: models,
                                warnings: warnings(sessions: sessions, now: now),
                                justEnded: justEnded, dockerAvailable: dockerAvailable)
        lastSnapshot = snapshot
        return snapshot
    }

    private func recordDockerLaunches(_ owned: [String: [ProcRow]], now: Date) {
        for (key, rows) in owned {
            for row in rows where Self.dockerCLINames.contains(row.name) {
                if !(ledger.dockerLaunches[key] ?? []).contains(row.id.start) {
                    ledger.dockerLaunches[key, default: []].append(row.id.start)
                }
            }
        }
        let cutoff = UInt64(max(0, now.timeIntervalSince1970 - 900) * 1_000_000)
        ledger.dockerLaunches = ledger.dockerLaunches.compactMapValues { starts in
            let recent = starts.filter { $0 >= cutoff }
            return recent.isEmpty ? nil : recent
        }
    }

    private func warnings(sessions: [AgentSession], now: Date) -> [Warning] {
        var warnings: [Warning] = []
        for session in sessions where !session.isRunning {
            let ports = Set(session.processes.flatMap(\.ports) + session.containers.flatMap(\.ports)).sorted()
            guard !ports.isEmpty else { continue }
            let list = ports.map { ":\($0)" }.joined(separator: " ")
            warnings.append(Warning(.leftoverPort, "Ended session \(session.meta.label) still holds \(ports.count == 1 ? "port" : "ports") \(list)"))
        }

        let running = sessions.filter(\.isRunning).map(\.meta)
        var workspaces: [String: Collisions.Workspace] = [:]
        for meta in running {
            if let cwd = meta.cwd, let ws = Collisions.workspace(for: cwd) { workspaces[meta.key] = ws }
        }

        let active = running.filter { lastActive[$0.key].map { now.timeIntervalSince($0) < Self.activeWindow } ?? false }
        for (worktree, group) in Collisions.sharedWorktrees(active, workspaces: workspaces).sorted(by: { $0.key < $1.key }) {
            let ids = group.map { $0.shortSessionId ?? "pid \($0.rootPid)" }.joined(separator: ", ")
            warnings.append(Warning(.sameFolder, "\(group.count) agents are working in the same folder \((worktree as NSString).lastPathComponent) (\(ids)); they can overwrite each other's edits"))
        }

        if scanCount % Self.migrationScanEvery == 1 {
            var treesByRepo: [String: Set<String>] = [:]
            for ws in workspaces.values { treesByRepo[ws.commonDir, default: []].insert(ws.worktree) }
            migrationWarnings = treesByRepo.values.filter { $0.count >= 2 }.flatMap { trees in
                let files = Dictionary(uniqueKeysWithValues: trees.map { ($0, Collisions.migrationFiles(in: $0)) })
                return Collisions.migrationClashes(files).map { clash in
                    let detail = clash.files.map { "\($0.file) in \(($0.worktree as NSString).lastPathComponent)" }
                        .joined(separator: " vs ")
                    return Warning(.migrationClash, "Migration \(clash.number) clash in \(clash.directory): \(detail)")
                }
            }
        }
        return warnings + migrationWarnings
    }

    // MARK: - Cleanup

    public struct Targets: Sendable {
        public var processes: [OwnedProcess]
        public var containers: [OwnedContainer]
        public var isEmpty: Bool { processes.isEmpty && containers.isEmpty }
    }

    /// What `clean` would stop. With no explicit PIDs or container IDs, that's every process plus every
    /// *confirmed* container of the chosen sessions (all ended sessions by default). Likely containers
    /// are only stopped when named explicitly.
    public func targets(sessionKeys: Set<String>? = nil, pids: Set<Int32>? = nil, containerIds: Set<String>? = nil,
                        in snapshot: Snapshot) -> Targets {
        let explicit = pids != nil || containerIds != nil
        let sessions: [AgentSession]
        if let sessionKeys {
            sessions = snapshot.sessions.filter { sessionKeys.contains($0.meta.key) || sessionKeys.contains($0.meta.sessionId ?? "")
                || sessionKeys.contains($0.meta.shortSessionId ?? "") }
        } else {
            sessions = explicit ? snapshot.sessions : snapshot.leftBehind
        }
        let processes = sessions.flatMap(\.processes).filter { explicit ? pids?.contains($0.id.pid) ?? false : true }
        let containers = sessions.flatMap(\.containers).filter { container in
            guard explicit else { return container.confidence == .confirmed }
            return containerIds?.contains { container.id.hasPrefix($0) || container.name == $0 } ?? false
        }
        return Targets(processes: processes, containers: containers)
    }

    public func clean(sessionKeys: Set<String>? = nil, pids: Set<Int32>? = nil, containerIds: Set<String>? = nil,
                      in snapshot: Snapshot) -> CleanupResult {
        let targets = targets(sessionKeys: sessionKeys, pids: pids, containerIds: containerIds, in: snapshot)
        let roots = Set(snapshot.running.map(\.meta.rootPid))
        var result = Cleaner.stop(targets.processes.map(\.id), protecting: roots)
        let ids = targets.containers.map(\.id)
        result.stoppedContainers = DockerClient.stop(ids)
        result.failedContainers = ids.filter { !result.stoppedContainers.contains($0) }
        return result
    }
}
