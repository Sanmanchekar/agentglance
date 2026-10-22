import Darwin
import Foundation

/// Reads the process table for the current user via libproc and `KERN_PROCARGS2`.
public final class ProcessReader {
    /// The only environment keys ever kept. Tokens and other secrets are never read into memory we retain.
    public static let envKeys: Set<String> = [
        "CLAUDE_PID", "CLAUDE_CODE_SESSION_ID", "CLAUDECODE", "AI_AGENT", "PWD",
    ]

    private struct Exec { let name: String; let args: [String]; let env: [String: String]; let path: String? }
    /// args/env only change on exec, which also changes the name; cache by identity + name.
    private var execCache: [ProcID: Exec] = [:]
    private let uid = getuid()
    private let ticksToNanos: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    public init() {}

    public func read() -> [ProcRow] {
        var rows: [ProcRow] = []
        var cache: [ProcID: Exec] = [:]
        for pid in Self.allPids() where pid > 0 {
            guard let bsd = Self.bsdInfo(pid), bsd.pbi_uid == uid else { continue }
            let id = ProcID(pid: pid, start: UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec))
            var name = Self.string(fromTuple: bsd.pbi_name)
            if name.isEmpty { name = Self.string(fromTuple: bsd.pbi_comm) }

            let exec: Exec
            if let cached = execCache[id], cached.name == name {
                exec = cached
            } else {
                let (args, env) = Self.argsAndEnv(pid)
                exec = Exec(name: name, args: args, env: env, path: Self.path(pid))
            }
            cache[id] = exec

            var rss: UInt64 = 0, cpu: UInt64 = 0
            if let task = Self.taskInfo(pid) {
                rss = task.pti_resident_size
                cpu = UInt64(Double(task.pti_total_user + task.pti_total_system) * ticksToNanos)
            }
            rows.append(ProcRow(id: id, ppid: Int32(bsd.pbi_ppid), name: name, path: exec.path, args: exec.args,
                                env: exec.env, cwd: Self.cwd(pid), rssBytes: rss, cpuNanos: cpu))
        }
        execCache = cache
        return rows
    }

    /// Current start time of `pid`, used to re-verify identity right before signalling it.
    public static func identity(of pid: Int32) -> ProcID? {
        guard let bsd = bsdInfo(pid) else { return nil }
        return ProcID(pid: pid, start: UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec))
    }

    // MARK: - libproc / sysctl

    static func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<Int32>.size))
        }
        return Array(pids.prefix(Int(max(n, 0))))
    }

    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func taskInfo(_ pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size ? info : nil
    }

    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = string(fromTuple: info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    static func path(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// Parses `KERN_PROCARGS2`: argc, exec path, padding, argv[argc], then env strings.
    static func argsAndEnv(_ pid: Int32) -> ([String], [String: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return ([], [:]) }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return ([], [:]) }

        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        func nextString() -> String? {
            while i < size, buf[i] == 0 { i += 1 }
            guard i < size else { return nil }
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            return String(decoding: buf[start..<i], as: UTF8.self)
        }
        _ = nextString() // exec path
        var args: [String] = []
        for _ in 0..<max(argc, 0) {
            guard let arg = nextString() else { break }
            args.append(arg)
        }
        var env: [String: String] = [:]
        while i < size {
            // env block ends at an empty string (two consecutive NULs).
            i += 1
            guard i < size, buf[i] != 0 else { break }
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            let entry = String(decoding: buf[start..<i], as: UTF8.self)
            if let eq = entry.firstIndex(of: "=") {
                let key = String(entry[..<eq])
                if envKeys.contains(key) { env[key] = String(entry[entry.index(after: eq)...]) }
            }
        }
        return (args, env)
    }

    static func string<T>(fromTuple tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let len = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<len], as: UTF8.self)
        }
    }
}
