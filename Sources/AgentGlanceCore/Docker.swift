import Foundation

public struct ContainerInfo: Sendable, Hashable {
    public var id: String
    public var name: String
    public var image: String
    public var created: Date
    public var labels: [String: String]
    public var mountSources: [String]
    public var ports: [Int]

    public var composeDir: String? { labels["com.docker.compose.project.working_dir"] }

    public init(id: String, name: String, image: String, created: Date, labels: [String: String] = [:],
                mountSources: [String] = [], ports: [Int] = []) {
        self.id = id
        self.name = name
        self.image = image
        self.created = created
        self.labels = labels
        self.mountSources = mountSources
        self.ports = ports
    }
}

public enum DockerClient {
    /// Docker Desktop, Homebrew, Rancher Desktop and OrbStack install locations.
    static let candidates = [
        "/usr/local/bin/docker", "/opt/homebrew/bin/docker", "~/.docker/bin/docker", "~/.rd/bin/docker",
        "~/.orbstack/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker",
    ].map { NSString(string: $0).expandingTildeInPath }

    public static let path: String? = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Running containers, or nil when Docker isn't installed or its daemon isn't answering.
    public static func runningContainers() -> [ContainerInfo]? {
        guard let docker = path,
              let ps = Shell.run(docker, ["ps", "-q", "--no-trunc"], timeout: 3), ps.status == 0 else { return nil }
        let ids = String(decoding: ps.output, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        guard !ids.isEmpty else { return [] }
        guard let inspect = Shell.run(docker, ["inspect"] + ids, timeout: 5), inspect.status == 0 else { return nil }
        return parseInspect(inspect.output)
    }

    /// Stops containers (`docker stop`, not `rm`, so nothing is deleted). Returns the IDs docker reported as stopped.
    public static func stop(_ ids: [String]) -> [String] {
        guard let docker = path, !ids.isEmpty,
              let result = Shell.run(docker, ["stop", "--time", "5"] + ids, timeout: 30) else { return [] }
        let stopped = Set(String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init))
        return ids.filter { stopped.contains($0) || stopped.contains(String($0.prefix(12))) }
    }

    static func parseInspect(_ data: Data) -> [ContainerInfo] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["Id"] as? String,
                  let created = (item["Created"] as? String).flatMap(parseDate) else { return nil }
            let config = item["Config"] as? [String: Any] ?? [:]
            let mounts = (item["Mounts"] as? [[String: Any]] ?? []).compactMap { $0["Source"] as? String }
            let portMap = (item["NetworkSettings"] as? [String: Any])?["Ports"] as? [String: Any] ?? [:]
            let ports = portMap.values.compactMap { $0 as? [[String: Any]] }.flatMap { $0 }
                .compactMap { ($0["HostPort"] as? String).flatMap(Int.init) }
            return ContainerInfo(id: id, name: (item["Name"] as? String ?? id).trimmingCharacters(in: ["/"]),
                                 image: config["Image"] as? String ?? "", created: created,
                                 labels: config["Labels"] as? [String: String] ?? [:],
                                 mountSources: mounts, ports: Array(Set(ports)).sorted())
        }
    }

    /// Docker timestamps carry nanoseconds, which ISO8601DateFormatter can't parse; drop the fraction.
    static func parseDate(_ string: String) -> Date? {
        var trimmed = string
        if let dot = string.firstIndex(of: ".") {
            let zone = string[dot...].firstIndex { $0 == "Z" || $0 == "+" || $0 == "-" }
            trimmed = String(string[..<dot]) + (zone.map { String(string[$0...]) } ?? "Z")
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

public enum ContainerAttributor {
    /// How long before a container's creation an owned `docker` command may have started and still count as its launcher.
    static let launchWindow: UInt64 = 120_000_000
    static let clockSlack: UInt64 = 2_000_000

    /// Assigns running containers to agent sessions.
    ///
    /// Priority: a `docker` command the session ran just before creation (confirmed), then a previous
    /// decision, then a path match on compose dir or mounts for a container created after the session started (likely).
    public static func attribute(_ containers: [ContainerInfo], sessions: [SessionMeta], dockerLaunches: [String: [UInt64]],
                                 known: [String: ContainerOwner], home: String = NSHomeDirectory()) -> [String: ContainerOwner] {
        let byKey = Dictionary(sessions.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [String: ContainerOwner] = [:]

        for container in containers {
            let created = UInt64(max(0, container.created.timeIntervalSince1970) * 1_000_000)

            let launch = dockerLaunches.compactMap { key, starts -> (key: String, start: UInt64)? in
                guard byKey[key] != nil,
                      let start = starts.filter({ $0 <= created + clockSlack && $0 + launchWindow >= created }).max() else { return nil }
                return (key, start)
            }.max { $0.start < $1.start }
            if let launch {
                result[container.id] = ContainerOwner(sessionKey: launch.key, confidence: .confirmed)
                continue
            }

            if let previous = known[container.id], byKey[previous.sessionKey] != nil {
                result[container.id] = previous
                continue
            }

            let paths = [container.composeDir].compactMap { $0 } + container.mountSources
            let candidates = sessions.filter { meta in
                guard meta.rootStart > 0, meta.rootStart <= created,
                      let cwd = meta.cwd, cwd != home, cwd != "/" else { return false }
                return paths.contains { path in
                    isWithin(path, cwd) || (path != home && path != "/" && isWithin(cwd, path))
                }
            }
            if let best = candidates.max(by: { $0.rootStart < $1.rootStart }) {
                result[container.id] = ContainerOwner(sessionKey: best.key, confidence: .likely)
            }
        }
        return result
    }

    static func isWithin(_ path: String, _ dir: String) -> Bool {
        path == dir || path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }
}

enum Shell {
    /// Runs a tool and returns its exit status and stdout, killing it after `timeout` seconds.
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 5) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        // Apps launched from Finder get a minimal PATH; docker needs its own dir for credential helpers.
        var env = ProcessInfo.processInfo.environment
        let toolDir = (tool as NSString).deletingLastPathComponent
        env["PATH"] = ([toolDir, "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
                       + (env["PATH"].map { [$0] } ?? [])).joined(separator: ":")
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return (process.terminationStatus, data)
    }
}
