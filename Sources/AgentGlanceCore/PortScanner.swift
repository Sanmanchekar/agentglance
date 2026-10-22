import Foundation

public enum PortScanner {
    /// Listening TCP ports for the given PIDs, via `lsof` (queried only for owned PIDs to keep it cheap).
    public static func listening(pids: [Int32]) -> [Int32: [Int]] {
        guard !pids.isEmpty else { return [:] }
        let out = run("/usr/sbin/lsof", ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-F", "pn",
                                         "-p", pids.map(String.init).joined(separator: ",")])
        return parse(out)
    }

    /// Parses `lsof -F pn` output: `p<pid>` lines followed by `n<addr>:<port>` lines.
    static func parse(_ output: String) -> [Int32: [Int]] {
        var result: [Int32: Set<Int>] = [:]
        var current: Int32?
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            if tag == "p" {
                current = Int32(value)
            } else if tag == "n", let pid = current, let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) {
                result[pid, default: []].insert(port)
            }
        }
        return result.mapValues { $0.sorted() }
    }

    static func run(_ tool: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
