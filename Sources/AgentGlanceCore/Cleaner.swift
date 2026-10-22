import Darwin
import Foundation

public struct CleanupResult: Sendable {
    public var stopped: [ProcID] = []
    public var forceKilled: [ProcID] = []
    public var skipped: [(ProcID, String)] = []
    public var stoppedContainers: [String] = []
    public var failedContainers: [String] = []

    public var summary: String {
        var parts = ["Stopped \(stopped.count + forceKilled.count) process(es)"]
        if !stoppedContainers.isEmpty { parts.append("\(stoppedContainers.count) container(s)") }
        if !skipped.isEmpty { parts.append("skipped \(skipped.count)") }
        if !failedContainers.isEmpty { parts.append("\(failedContainers.count) container(s) failed") }
        return parts.joined(separator: ", ")
    }
}

public enum Cleaner {
    /// Stops the given processes: SIGTERM, wait up to `grace`, then SIGKILL survivors.
    /// Each PID's start time is re-checked before every signal so a reused PID is never hit.
    public static func stop(_ targets: [ProcID], protecting protected: Set<Int32> = [], grace: TimeInterval = 3) -> CleanupResult {
        var result = CleanupResult()
        var pending: [ProcID] = []
        let me = getpid()

        for id in targets {
            if id.pid <= 1 || id.pid == me || protected.contains(id.pid) {
                result.skipped.append((id, "protected"))
            } else if ProcessReader.identity(of: id.pid) != id {
                result.skipped.append((id, "already gone"))
            } else if kill(id.pid, SIGTERM) == 0 {
                pending.append(id)
            } else {
                result.skipped.append((id, String(cString: strerror(errno))))
            }
        }

        let deadline = Date().addingTimeInterval(grace)
        while !pending.isEmpty, Date() < deadline {
            usleep(100_000)
            pending.removeAll { id in
                guard ProcessReader.identity(of: id.pid) == id else {
                    result.stopped.append(id)
                    return true
                }
                return false
            }
        }

        for id in pending where ProcessReader.identity(of: id.pid) == id {
            if kill(id.pid, SIGKILL) == 0 {
                result.forceKilled.append(id)
            } else {
                result.skipped.append((id, String(cString: strerror(errno))))
            }
        }
        return result
    }
}
