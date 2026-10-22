import Foundation

/// Persisted memory of ownership decisions, so attribution survives the agent exiting
/// and its children being re-parented to launchd.
public struct Ledger: Codable, Sendable {
    public var owners: [ProcID: String] = [:]
    public var sessions: [String: SessionMeta] = [:]
    /// Container ID -> owning session.
    public var containers: [String: ContainerOwner] = [:]
    /// Session key -> start times (µs) of `docker` commands it ran recently.
    public var dockerLaunches: [String: [UInt64]] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owners = try c.decodeIfPresent([ProcID: String].self, forKey: .owners) ?? [:]
        sessions = try c.decodeIfPresent([String: SessionMeta].self, forKey: .sessions) ?? [:]
        containers = try c.decodeIfPresent([String: ContainerOwner].self, forKey: .containers) ?? [:]
        dockerLaunches = try c.decodeIfPresent([String: [UInt64]].self, forKey: .dockerLaunches) ?? [:]
    }

    public static func load(from url: URL) -> Ledger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else { return Ledger() }
        return ledger
    }

    public func save(to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

public enum AgentDetector {
    /// Identifies an agent CLI from its executable or script path.
    public static func tool(for row: ProcRow) -> AgentTool? {
        var candidates = [row.name]
        if let path = row.path { candidates.append((path as NSString).lastPathComponent) }
        // npm installs run as `node /path/to/bin/claude`.
        for arg in row.args.prefix(2) { candidates.append((arg as NSString).lastPathComponent) }
        let joined = row.args.prefix(3).joined(separator: " ")

        if candidates.contains("claude") || joined.contains("@anthropic-ai/claude-code") { return .claude }
        if candidates.contains("codex") || joined.contains("@openai/codex") { return .codex }
        if candidates.contains("gemini") || joined.contains("@google/gemini-cli") { return .gemini }
        return nil
    }

    public static func isOllama(_ row: ProcRow) -> Bool {
        row.name == "ollama" || row.path.map { ($0 as NSString).lastPathComponent == "ollama" } ?? false
    }
}

public struct Attribution: Sendable {
    /// Session key -> metadata, for every session that is live or still owns a live process.
    public var sessions: [String: SessionMeta]
    /// Keys of sessions whose agent root process is alive.
    public var liveRoots: Set<String>
    /// Session key -> processes it owns (agent roots excluded).
    public var owned: [String: [ProcRow]]
}

public enum Attributor {
    public static func rootKey(_ tool: AgentTool, _ id: ProcID) -> String {
        "\(tool.rawValue):\(id.pid):\(id.start)"
    }

    /// Assigns every process to the agent session that started it, updating `ledger` in place.
    ///
    /// Priority: live ancestry, then the inherited `CLAUDE_PID` env tag, then ledger memory.
    public static func attribute(_ rows: [ProcRow], ledger: inout Ledger, excluding excluded: Set<Int32> = []) -> Attribution {
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        func ancestors(of row: ProcRow) -> [ProcRow] {
            var chain: [ProcRow] = []
            var ppid = row.ppid
            var seen: Set<Int32> = [row.pid]
            while ppid > 1, !seen.contains(ppid), let parent = byPid[ppid], parent.id.start <= row.id.start {
                chain.append(parent)
                seen.insert(ppid)
                ppid = parent.ppid
            }
            return chain
        }

        // Roots: detected agents with no detected ancestor (a nested agent belongs to the outer one).
        var roots: [Int32: SessionMeta] = [:]
        for row in rows where !excluded.contains(row.pid) {
            guard let tool = AgentDetector.tool(for: row),
                  !ancestors(of: row).contains(where: { AgentDetector.tool(for: $0) != nil }) else { continue }
            let key = rootKey(tool, row.id)
            var meta = ledger.sessions[key] ?? SessionMeta(key: key, tool: tool, rootPid: row.pid,
                                                           rootStart: row.id.start, cwd: row.cwd, sessionId: nil)
            if meta.cwd == nil { meta.cwd = row.cwd }
            roots[row.pid] = meta
        }

        var sessions: [String: SessionMeta] = [:]
        for meta in roots.values { sessions[meta.key] = meta }
        var owned: [String: [ProcRow]] = [:]
        var newOwners: [ProcID: String] = [:]

        func liveRoot(pid: Int32, startedBy row: ProcRow) -> SessionMeta? {
            guard let meta = roots[pid], meta.rootStart <= row.id.start else { return nil }
            return meta
        }

        for row in rows where roots[row.pid] == nil && !excluded.contains(row.pid) {
            var key: String?

            if let root = ancestors(of: row).lazy.compactMap({ liveRoot(pid: $0.pid, startedBy: row) }).first {
                key = root.key
            } else if let tagged = row.env["CLAUDE_PID"].flatMap(Int32.init) {
                if let root = liveRoot(pid: tagged, startedBy: row) {
                    key = root.key
                } else {
                    key = endedClaudeSession(pid: tagged, row: row, ledger: ledger, into: &sessions)
                }
            } else if let remembered = ledger.owners[row.id] {
                key = remembered
            }

            guard let key else { continue }
            owned[key, default: []].append(row)
            newOwners[row.id] = key
            if sessions[key] == nil { sessions[key] = ledger.sessions[key] }
            if var meta = sessions[key], meta.sessionId == nil, let sid = row.env["CLAUDE_CODE_SESSION_ID"] {
                meta.sessionId = sid
                sessions[key] = meta
            }
        }

        // Drop owned processes whose session metadata was lost; keep the ledger to what is still alive.
        owned = owned.filter { sessions[$0.key] != nil }
        ledger.owners = newOwners.filter { sessions[$0.value] != nil }
        ledger.sessions = sessions

        return Attribution(sessions: sessions, liveRoots: Set(roots.values.map(\.key)), owned: owned)
    }

    /// Finds the session for an orphan whose `CLAUDE_PID` agent has exited, preferring the ledger's
    /// record of that agent; otherwise synthesises one from the orphan's own env.
    private static func endedClaudeSession(pid: Int32, row: ProcRow, ledger: Ledger,
                                           into sessions: inout [String: SessionMeta]) -> String {
        let known = ledger.sessions.values
            .filter { $0.tool == .claude && $0.rootPid == pid && $0.rootStart <= row.id.start }
            .max { $0.rootStart < $1.rootStart }
        if let known {
            sessions[known.key] = sessions[known.key] ?? known
            return known.key
        }
        let sid = row.env["CLAUDE_CODE_SESSION_ID"]
        let key = "claude:\(pid):env:\(sid ?? "unknown")"
        if sessions[key] == nil {
            sessions[key] = SessionMeta(key: key, tool: .claude, rootPid: pid, rootStart: 0,
                                        cwd: row.env["PWD"] ?? row.cwd, sessionId: sid)
        }
        return key
    }
}
