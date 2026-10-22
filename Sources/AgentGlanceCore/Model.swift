import Foundation

public enum AgentTool: String, Codable, Sendable, CaseIterable {
    case claude, codex, gemini
}

/// A process identity that survives PID reuse: the same PID with a different start time is a different process.
public struct ProcID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let pid: Int32
    /// Start time in microseconds since the Unix epoch.
    public let start: UInt64

    public init(pid: Int32, start: UInt64) {
        self.pid = pid
        self.start = start
    }

    public var description: String { "\(pid)" }
}

/// One row of the raw process table, as read from the kernel.
public struct ProcRow: Sendable {
    public var id: ProcID
    public var ppid: Int32
    public var name: String
    public var path: String?
    public var args: [String]
    /// Allow-listed environment keys only (see `ProcessReader.envKeys`).
    public var env: [String: String]
    public var cwd: String?
    public var rssBytes: UInt64
    /// Total user + system CPU time in nanoseconds.
    public var cpuNanos: UInt64

    public var pid: Int32 { id.pid }

    public init(id: ProcID, ppid: Int32, name: String, path: String? = nil, args: [String] = [],
                env: [String: String] = [:], cwd: String? = nil, rssBytes: UInt64 = 0, cpuNanos: UInt64 = 0) {
        self.id = id
        self.ppid = ppid
        self.name = name
        self.path = path
        self.args = args
        self.env = env
        self.cwd = cwd
        self.rssBytes = rssBytes
        self.cpuNanos = cpuNanos
    }

    public var commandLine: String {
        args.isEmpty ? name : args.joined(separator: " ")
    }
}

/// What we know about an agent session; persisted in the ledger so it outlives the agent process.
public struct SessionMeta: Codable, Sendable, Hashable {
    public var key: String
    public var tool: AgentTool
    public var rootPid: Int32
    public var rootStart: UInt64
    public var cwd: String?
    public var sessionId: String?

    public var label: String {
        guard let cwd, !cwd.isEmpty else { return "\(tool.rawValue) pid \(rootPid)" }
        return (cwd as NSString).lastPathComponent
    }

    public var shortSessionId: String? {
        sessionId.map { String($0.prefix(8)) }
    }
}

public struct OwnedProcess: Identifiable, Sendable {
    public var id: ProcID
    public var name: String
    public var command: String
    public var rssBytes: UInt64
    public var cpuPercent: Double
    public var ports: [Int]
}

public struct AgentSession: Identifiable, Sendable {
    public var meta: SessionMeta
    public var isRunning: Bool
    public var processes: [OwnedProcess]

    public var id: String { meta.key }
    public var totalRSS: UInt64 { processes.reduce(0) { $0 + $1.rssBytes } }
    public var totalCPU: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
}

public struct Snapshot: Sendable {
    public var takenAt: Date
    public var sessions: [AgentSession]
    /// Ollama server and runner processes (memory held by local models).
    public var localModels: [OwnedProcess]
    public var warnings: [String]

    public var running: [AgentSession] { sessions.filter(\.isRunning) }
    /// Ended sessions that still have live processes.
    public var leftBehind: [AgentSession] { sessions.filter { !$0.isRunning && !$0.processes.isEmpty } }
    public var leftBehindRSS: UInt64 { leftBehind.reduce(0) { $0 + $1.totalRSS } }
}

public enum Format {
    public static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory)
    }
}
