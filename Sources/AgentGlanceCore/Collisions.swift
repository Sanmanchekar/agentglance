import Foundation

/// Detects agents that are likely to step on each other.
public enum Collisions {
    public struct Workspace: Hashable, Sendable {
        /// The checked-out folder (main checkout or a linked worktree).
        public let worktree: String
        /// The shared `.git` dir; equal across all worktrees of one repo.
        public let commonDir: String
    }

    public struct MigrationClash: Hashable, Sendable {
        public let directory: String
        public let number: Int
        /// (worktree, filename) pairs that only exist in one worktree each.
        public let files: [Pair]

        public struct Pair: Hashable, Sendable {
            public let worktree: String
            public let file: String
        }
    }

    /// Finds the git worktree containing `cwd` by walking up to the nearest `.git` dir or file.
    public static func workspace(for cwd: String) -> Workspace? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        while dir.path != "/" {
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
                if isDir.boolValue { return Workspace(worktree: canonical(dir.path), commonDir: canonical(git.path)) }
                // Linked worktrees have a `.git` file: "gitdir: <repo>/.git/worktrees/<name>".
                guard let text = try? String(contentsOf: git, encoding: .utf8),
                      let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
                var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                if !gitdir.hasPrefix("/") { gitdir = dir.appendingPathComponent(gitdir).standardizedFileURL.path }
                let parent = (gitdir as NSString).deletingLastPathComponent
                let common = (parent as NSString).lastPathComponent == "worktrees"
                    ? (parent as NSString).deletingLastPathComponent : gitdir
                return Workspace(worktree: canonical(dir.path), commonDir: canonical(common))
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// Resolves symlinks with realpath. Foundation's standardizing maps /private/tmp to /tmp but keeps /var,
    /// while git and directory enumeration report /private/..., so only realpath gives comparable paths.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Groups sessions that share a worktree; only groups of two or more are returned.
    public static func sharedWorktrees(_ sessions: [SessionMeta], workspaces: [String: Workspace]) -> [String: [SessionMeta]] {
        var groups: [String: [SessionMeta]] = [:]
        for meta in sessions {
            if let ws = workspaces[meta.key] { groups[ws.worktree, default: []].append(meta) }
        }
        return groups.filter { $0.value.count >= 2 }
    }

    static let skippedDirs: Set<String> = [
        ".git", "node_modules", ".venv", "venv", "env", "__pycache__", ".build", "build", "dist",
        "vendor", "Pods", ".tox", ".mypy_cache", ".next", "target",
    ]
    static let migrationDirs: Set<String> = ["migrations", "versions", "migrate"]
    static let migrationExtensions: Set<String> = ["py", "sql", "rb", "ts", "js", "go"]

    /// Numbered migration files in a worktree, keyed by "<relative dir>#<number>".
    public static func migrationFiles(in worktree: String, maxEntries: Int = 50_000) -> [String: Set<String>] {
        let root = URL(fileURLWithPath: canonical(worktree))
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return [:] }
        var out: [String: Set<String>] = [:]
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > maxEntries { break }
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skippedDirs.contains(name) || walker.level > 8 { walker.skipDescendants() }
                continue
            }
            let parent = url.deletingLastPathComponent()
            let digits = name.prefix(while: \.isNumber)
            guard migrationDirs.contains(parent.lastPathComponent), let number = Int(digits),
                  migrationExtensions.contains(url.pathExtension) else { continue }
            let relative = String(parent.path.dropFirst(root.path.count)).trimmingCharacters(in: ["/"])
            out["\(relative)#\(number)", default: []].insert(name)
        }
        return out
    }

    /// Same directory and migration number, but different files that each exist in only one worktree.
    public static func migrationClashes(_ perWorktree: [String: [String: Set<String>]]) -> [MigrationClash] {
        var byKey: [String: [String: Set<String>]] = [:]
        for (worktree, files) in perWorktree {
            for (key, names) in files { byKey[key, default: [:]][worktree] = names }
        }
        var clashes: [MigrationClash] = []
        for (key, trees) in byKey where trees.count >= 2 {
            var counts: [String: Int] = [:]
            for names in trees.values { for name in names { counts[name, default: 0] += 1 } }
            let unique = trees.compactMap { worktree, names in
                names.sorted().first { counts[$0] == 1 }.map { MigrationClash.Pair(worktree: worktree, file: $0) }
            }.sorted { $0.worktree < $1.worktree }
            guard unique.count >= 2, let hash = key.lastIndex(of: "#") else { continue }
            clashes.append(MigrationClash(directory: String(key[..<hash]), number: Int(key[key.index(after: hash)...]) ?? 0,
                                          files: unique))
        }
        return clashes.sorted { ($0.directory, $0.number) < ($1.directory, $1.number) }
    }
}
