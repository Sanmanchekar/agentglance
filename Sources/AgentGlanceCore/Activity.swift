import Darwin
import Foundation

/// What an agent is doing right now, as reported by Claude Code hooks.
public enum AgentActivity: String, Codable, Sendable {
    case working
    /// The turn finished; the agent is waiting for your next prompt.
    case waiting
    /// Blocked on a permission prompt.
    case needsPermission = "needs_permission"
    case error
    case idle

    public var needsYou: Bool { self == .waiting || self == .needsPermission }

    public var label: String {
        switch self {
        case .working: "working"
        case .waiting: "your turn"
        case .needsPermission: "needs permission"
        case .error: "error"
        case .idle: "idle"
        }
    }
}

public struct ActivityRecord: Codable, Sendable {
    public var sessionId: String
    public var claudePid: Int32?
    public var event: String
    public var activity: AgentActivity
    public var message: String?
    public var at: Date
}

public struct LimitWindow: Codable, Sendable, Hashable {
    public var usedPercent: Double
    public var resetsAt: Date

    /// The window rolled over and nothing has been used since: the next message starts a new one.
    public func hasReset(at now: Date) -> Bool { resetsAt <= now }
}

/// Claude plan usage limits, as Claude Code reports them to the status line (Pro/Max only).
public struct PlanLimits: Codable, Sendable {
    public var fiveHour: LimitWindow?
    public var sevenDay: LimitWindow?
    public var updatedAt: Date

    /// A window whose reset time has passed is at 0%, not unknown: keep showing it, emptied.
    public func current(at now: Date) -> PlanLimits {
        func roll(_ w: LimitWindow?) -> LimitWindow? {
            w.map { $0.hasReset(at: now) ? LimitWindow(usedPercent: 0, resetsAt: $0.resetsAt) : $0 }
        }
        return PlanLimits(fiveHour: roll(fiveHour), sevenDay: roll(sevenDay), updatedAt: updatedAt)
    }
}

/// Files shared between the CLI (written from Claude Code hooks and the status line) and the monitor.
public enum StateStore {
    public static let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AgentGlance")
    static var activityDir: URL { directory.appendingPathComponent("activity") }
    static var limitsURL: URL { directory.appendingPathComponent("limits.json") }

    /// Maps a Claude Code hook event to the activity it implies; nil means "no change".
    public static func activity(forHook event: String, payload: [String: Any]) -> AgentActivity? {
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStop":
            return .working
        case "PermissionRequest":
            return .needsPermission
        case "Notification":
            let type = payload["notification_type"] as? String ?? ""
            let message = (payload["message"] as? String ?? "").lowercased()
            if type == "permission_prompt" || message.contains("permission") { return .needsPermission }
            return .waiting
        case "Stop":
            return .waiting
        case "StopFailure":
            return .error
        case "SessionStart":
            return .idle
        default:
            return nil
        }
    }

    /// Handles one hook invocation. Silent and best-effort: a hook must never disturb the agent.
    public static func recordHook(_ data: Data, claudePid: Int32?, now: Date = Date()) {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = payload["session_id"] as? String, !sessionId.isEmpty,
              let event = payload["hook_event_name"] as? String else { return }
        let file = activityDir.appendingPathComponent("\(sanitize(sessionId)).json")
        if event == "SessionEnd" {
            try? FileManager.default.removeItem(at: file)
            return
        }
        guard let activity = activity(forHook: event, payload: payload) else { return }
        let record = ActivityRecord(sessionId: sessionId, claudePid: claudePid, event: event, activity: activity,
                                    message: payload["message"] as? String, at: now)
        write(record, to: file)
    }

    public static func loadActivities() -> [ActivityRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: activityDir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { read(ActivityRecord.self, from: $0) }
    }

    public static func removeActivity(sessionId: String) {
        try? FileManager.default.removeItem(at: activityDir.appendingPathComponent("\(sanitize(sessionId)).json"))
    }

    /// Extracts `rate_limits` from the status line input. Absent windows keep their last known value.
    public static func recordStatusLine(_ data: Data, now: Date = Date()) {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = parseLimits(payload, now: now) else { return }
        write(limits, to: limitsURL)
    }

    static func parseLimits(_ payload: [String: Any], now: Date) -> PlanLimits? {
        guard let raw = payload["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> LimitWindow? {
            guard let w = raw[key] as? [String: Any], let used = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let resets = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
            return LimitWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets))
        }
        let previous = loadLimits()
        let fiveHour = window("five_hour") ?? previous?.fiveHour
        let sevenDay = window("seven_day") ?? previous?.sevenDay
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return PlanLimits(fiveHour: fiveHour, sevenDay: sevenDay, updatedAt: now)
    }

    public static func loadLimits() -> PlanLimits? {
        read(PlanLimits.self, from: limitsURL)
    }

    /// The nearest ancestor process that is an agent CLI (hooks run as `claude -> sh -> agentglance`).
    public static func agentAncestor(of pid: Int32) -> Int32? {
        var current = pid
        for _ in 0..<8 {
            guard let info = ProcessReader.bsdInfo(current) else { return nil }
            let parent = Int32(info.pbi_ppid)
            guard parent > 1, let parentInfo = ProcessReader.bsdInfo(parent) else { return nil }
            var name = ProcessReader.string(fromTuple: parentInfo.pbi_name)
            if name.isEmpty { name = ProcessReader.string(fromTuple: parentInfo.pbi_comm) }
            let (args, _) = ProcessReader.argsAndEnv(parent)
            let row = ProcRow(id: ProcID(pid: parent, start: 0), ppid: 0, name: name,
                              path: ProcessReader.path(parent), args: args)
            if AgentDetector.tool(for: row) != nil { return parent }
            current = parent
        }
        return nil
    }

    private static func sanitize(_ id: String) -> String {
        String(id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" })
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }
}
