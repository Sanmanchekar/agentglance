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

    public init(key: String, tool: AgentTool, rootPid: Int32, rootStart: UInt64, cwd: String?, sessionId: String?) {
        self.key = key
        self.tool = tool
        self.rootPid = rootPid
        self.rootStart = rootStart
        self.cwd = cwd
        self.sessionId = sessionId
    }

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
    /// A macOS app (inside a .app bundle), e.g. Docker Desktop opened by an agent. Never bulk-cleaned.
    public var isApp = false
}

public enum ContainerConfidence: String, Codable, Sendable {
    /// The session's own `docker` command was seen starting just before the container was created.
    case confirmed
    /// The container's compose dir or mounts are inside the session's folder and it was created after the session started.
    case likely
}

public struct ContainerOwner: Codable, Sendable, Hashable {
    public var sessionKey: String
    public var confidence: ContainerConfidence

    public init(sessionKey: String, confidence: ContainerConfidence) {
        self.sessionKey = sessionKey
        self.confidence = confidence
    }
}

public struct OwnedContainer: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var image: String
    public var ports: [Int]
    public var confidence: ContainerConfidence

    public var shortId: String { String(id.prefix(12)) }
}

public struct AgentSession: Identifiable, Sendable {
    public var meta: SessionMeta
    public var isRunning: Bool
    public var processes: [OwnedProcess]
    public var containers: [OwnedContainer] = []
    /// When this monitor saw the agent exit; nil if running or if it ended before monitoring started.
    public var endedAt: Date?
    /// Latest state from Claude Code hooks; nil when hooks aren't installed or haven't fired yet.
    public var activity: AgentActivity?
    public var activityMessage: String?
    public var activitySince: Date?

    public var id: String { meta.key }
    public var totalRSS: UInt64 { processes.reduce(0) { $0 + $1.rssBytes } }
    public var totalCPU: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
    public var hasLeftovers: Bool { !processes.isEmpty || !containers.isEmpty }
}

public struct Warning: Hashable, Sendable {
    public enum Kind: String, Sendable { case leftoverPort, sameFolder, migrationClash }
    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

public struct Snapshot: Sendable {
    public var takenAt: Date
    public var sessions: [AgentSession]
    /// Ollama server and runner processes (memory held by local models).
    public var localModels: [OwnedProcess]
    public var warnings: [Warning]
    /// Keys of sessions whose agent exited since the previous scan.
    public var justEnded: Set<String> = []
    /// Whether a Docker daemon answered; containers are only tracked when it did.
    public var dockerAvailable = false
    /// Claude plan limits from the status line bridge (expired windows already dropped).
    public var limits: PlanLimits?

    /// Running sessions that are blocked on you: a permission prompt or a finished turn.
    public var needingYou: [AgentSession] { running.filter { $0.activity?.needsYou == true } }

    public var running: [AgentSession] { sessions.filter(\.isRunning) }
    /// Ended sessions that still have live processes or containers.
    public var leftBehind: [AgentSession] { sessions.filter { !$0.isRunning && $0.hasLeftovers } }
    public var leftBehindRSS: UInt64 { leftBehind.reduce(0) { $0 + $1.totalRSS } }
    public var leftBehindContainers: Int { leftBehind.reduce(0) { $0 + $1.containers.count } }
}

public enum Format {
    public static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory)
    }

    /// e.g. "3 procs · 1.2 GB · 2 containers"
    public static func leftovers(processes: Int, bytes: UInt64, containers: Int) -> String {
        var parts = ["\(processes) \(processes == 1 ? "proc" : "procs")", Format.bytes(bytes)]
        if containers > 0 { parts.append("\(containers) \(containers == 1 ? "container" : "containers")") }
        return parts.joined(separator: " · ")
    }
}
