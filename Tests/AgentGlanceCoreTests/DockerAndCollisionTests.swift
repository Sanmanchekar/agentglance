@testable import AgentGlanceCore
import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func micros(_ date: Date) -> UInt64 { UInt64(date.timeIntervalSince1970 * 1_000_000) }

private func session(_ key: String, cwd: String, startedAt: Date) -> SessionMeta {
    SessionMeta(key: key, tool: .claude, rootPid: 1, rootStart: micros(startedAt), cwd: cwd, sessionId: nil)
}

private func container(_ id: String, created: Date, compose: String? = nil, mounts: [String] = []) -> ContainerInfo {
    ContainerInfo(id: id, name: id, image: "postgres:16", created: created,
                  labels: compose.map { ["com.docker.compose.project.working_dir": $0] } ?? [:], mountSources: mounts)
}

@Suite struct ContainerAttributorTests {
    let a = session("a", cwd: "/work/api", startedAt: t0)
    let b = session("b", cwd: "/work/web", startedAt: t0.addingTimeInterval(60))

    @Test func dockerCommandSeenJustBeforeCreationConfirms() {
        let c = container("c1", created: t0.addingTimeInterval(300))
        let owners = ContainerAttributor.attribute([c], sessions: [a, b],
                                                   dockerLaunches: ["b": [micros(t0.addingTimeInterval(290))]], known: [:], home: "/home")
        #expect(owners["c1"] == ContainerOwner(sessionKey: "b", confidence: .confirmed))
    }

    @Test func staleDockerCommandDoesNotConfirm() {
        let c = container("c1", created: t0.addingTimeInterval(600))
        let owners = ContainerAttributor.attribute([c], sessions: [a, b],
                                                   dockerLaunches: ["b": [micros(t0.addingTimeInterval(100))]], known: [:], home: "/home")
        #expect(owners["c1"] == nil)
    }

    @Test func composeDirInsideSessionFolderIsLikely() {
        let c = container("c1", created: t0.addingTimeInterval(120), compose: "/work/api/docker")
        let owners = ContainerAttributor.attribute([c], sessions: [a, b], dockerLaunches: [:], known: [:], home: "/home")
        #expect(owners["c1"] == ContainerOwner(sessionKey: "a", confidence: .likely))
    }

    @Test func containerCreatedBeforeSessionIsNotClaimed() {
        let c = container("c1", created: t0.addingTimeInterval(-60), compose: "/work/api")
        let owners = ContainerAttributor.attribute([c], sessions: [a], dockerLaunches: [:], known: [:], home: "/home")
        #expect(owners.isEmpty)
    }

    @Test func homeFolderSessionsNeverClaimByPath() {
        let home = session("h", cwd: "/home", startedAt: t0)
        let c = container("c1", created: t0.addingTimeInterval(60), mounts: ["/home/projects/x"])
        let owners = ContainerAttributor.attribute([c], sessions: [home], dockerLaunches: [:], known: [:], home: "/home")
        #expect(owners.isEmpty)
    }

    @Test func earlierDecisionIsKeptOnceLaunchExpires() {
        let c = container("c1", created: t0.addingTimeInterval(300))
        let known = ["c1": ContainerOwner(sessionKey: "b", confidence: .confirmed)]
        let owners = ContainerAttributor.attribute([c], sessions: [a, b], dockerLaunches: [:], known: known, home: "/home")
        #expect(owners["c1"]?.confidence == .confirmed)
    }

    @Test func parsesDockerInspect() throws {
        let json = """
        [{"Id":"abc123","Name":"/api-db-1","Created":"2026-10-22T10:00:00.123456789Z",
          "Config":{"Image":"postgres:16","Labels":{"com.docker.compose.project.working_dir":"/work/api"}},
          "Mounts":[{"Source":"/work/api/data"}],
          "NetworkSettings":{"Ports":{"5432/tcp":[{"HostIp":"0.0.0.0","HostPort":"55432"},{"HostIp":"::","HostPort":"55432"}],"6379/tcp":null}}}]
        """
        let parsed = DockerClient.parseInspect(Data(json.utf8))
        let c = try #require(parsed.first)
        #expect(c.name == "api-db-1")
        #expect(c.composeDir == "/work/api")
        #expect(c.mountSources == ["/work/api/data"])
        #expect(c.ports == [55432])
        #expect(c.created == ISO8601DateFormatter().date(from: "2026-10-22T10:00:00Z"))
    }
}

@Suite struct CollisionTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ag-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func linkedWorktreeSharesCommonDirWithMainCheckout() throws {
        let root = try tempDir()
        let main = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".git/worktrees/feature"),
                                                withIntermediateDirectories: true)
        let linked = root.appendingPathComponent("repo-feature")
        try write("gitdir: \(main.path)/.git/worktrees/feature\n", to: linked.appendingPathComponent(".git"))
        try FileManager.default.createDirectory(at: linked.appendingPathComponent("src"), withIntermediateDirectories: true)

        let a = try #require(Collisions.workspace(for: main.path))
        let b = try #require(Collisions.workspace(for: linked.appendingPathComponent("src").path))
        #expect(a.commonDir == b.commonDir)
        #expect(a.worktree != b.worktree)
        #expect(b.worktree == Collisions.canonical(linked.path))

        // A /tmp-style symlinked path must resolve to the same repo as its /private target.
        let viaSymlink = try #require(Collisions.workspace(for: "/tmp/../" + linked.path))
        #expect(viaSymlink.commonDir == a.commonDir)
    }

    @Test func detectsSameMigrationNumberAcrossWorktrees() throws {
        let root = try tempDir()
        let one = root.appendingPathComponent("one"), two = root.appendingPathComponent("two")
        for tree in [one, two] {
            try write("", to: tree.appendingPathComponent("app/migrations/0041_initial.py"))
        }
        try write("", to: one.appendingPathComponent("app/migrations/0042_add_email.py"))
        try write("", to: two.appendingPathComponent("app/migrations/0042_add_phone.py"))
        try write("", to: two.appendingPathComponent("node_modules/x/migrations/0042_vendor.js"))

        let clashes = Collisions.migrationClashes([
            one.path: Collisions.migrationFiles(in: one.path),
            two.path: Collisions.migrationFiles(in: two.path),
        ])
        #expect(clashes.count == 1)
        #expect(clashes.first?.directory == "app/migrations")
        #expect(clashes.first?.number == 42)
        #expect(Set(clashes.first?.files.map(\.file) ?? []) == ["0042_add_email.py", "0042_add_phone.py"])
    }

    @Test func sharedMigrationHistoryIsNotAClash() {
        let files = ["app/migrations#41": Set(["0041_initial.py"])]
        #expect(Collisions.migrationClashes(["/a": files, "/b": files]).isEmpty)
    }

    @Test func groupsOnlySessionsSharingAWorktree() {
        let ws = Collisions.Workspace(worktree: "/repo", commonDir: "/repo/.git")
        let other = Collisions.Workspace(worktree: "/repo-2", commonDir: "/repo/.git")
        let metas = ["a", "b", "c"].map { SessionMeta(key: $0, tool: .claude, rootPid: 1, rootStart: 1, cwd: nil, sessionId: nil) }
        let groups = Collisions.sharedWorktrees(metas, workspaces: ["a": ws, "b": ws, "c": other])
        #expect(groups.keys.sorted() == ["/repo"])
        #expect(groups["/repo"]?.map(\.key).sorted() == ["a", "b"])
    }
}

@Suite struct ActivityAndInstallerTests {
    @Test func mapsHookEventsToActivity() {
        #expect(StateStore.activity(forHook: "PreToolUse", payload: [:]) == .working)
        #expect(StateStore.activity(forHook: "Stop", payload: [:]) == .waiting)
        #expect(StateStore.activity(forHook: "PermissionRequest", payload: [:]) == .needsPermission)
        #expect(StateStore.activity(forHook: "Notification", payload: ["notification_type": "permission_prompt"]) == .needsPermission)
        #expect(StateStore.activity(forHook: "Notification", payload: ["message": "Claude is waiting for your input"]) == .waiting)
        #expect(StateStore.activity(forHook: "StopFailure", payload: [:]) == .error)
        #expect(StateStore.activity(forHook: "SomethingNew", payload: [:]) == nil)
    }

    @Test func parsesStatusLineRateLimits() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload: [String: Any] = ["rate_limits": [
            "five_hour": ["used_percentage": 23.5, "resets_at": 1_800_003_600],
            "seven_day": ["used_percentage": 41, "resets_at": 1_800_400_000],
        ]]
        let limits = StateStore.parseLimits(payload, now: now)
        #expect(limits?.fiveHour?.usedPercent == 23.5)
        #expect(limits?.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1_800_400_000))
        // After the 5h window resets it reads 0% (still shown), while the weekly window keeps its value.
        let later = limits?.current(at: Date(timeIntervalSince1970: 1_800_010_000))
        #expect(later?.fiveHour?.usedPercent == 0)
        #expect(later?.fiveHour?.hasReset(at: Date(timeIntervalSince1970: 1_800_010_000)) == true)
        #expect(later?.sevenDay?.usedPercent == 41)
        #expect(StateStore.parseLimits(["model": "x"], now: now) == nil)
    }

    let existing: [String: Any] = [
        "hooks": ["Stop": [["hooks": [["type": "command", "command": "/x/cc-status"]]]]],
        "statusLine": ["type": "command", "command": "~/.claude/statusline-command.sh", "refreshInterval": 5],
        "enabledPlugins": ["a": true],
    ]

    @Test func installKeepsExistingHooksAndWrapsStatusLine() {
        let after = Installer.install(into: existing, binary: "/bin/ag")
        let stop = (after["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        let commands = stop?.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        #expect(commands == ["/x/cc-status", "/bin/ag hook"])
        let status = after["statusLine"] as? [String: Any]
        #expect(status?["command"] as? String == "/bin/ag statusline -- ~/.claude/statusline-command.sh")
        #expect(status?["refreshInterval"] as? Int == 5)
        #expect(after["enabledPlugins"] != nil)
        // Idempotent.
        #expect(Installer.describeChanges(from: after, to: Installer.install(into: after, binary: "/bin/ag"), binary: "/bin/ag").isEmpty)
    }

    @Test func uninstallRestoresOriginal() throws {
        let roundTrip = Installer.uninstall(from: Installer.install(into: existing, binary: "/bin/ag"), binary: "/bin/ag")
        let a = try JSONSerialization.data(withJSONObject: roundTrip, options: .sortedKeys)
        let b = try JSONSerialization.data(withJSONObject: existing, options: .sortedKeys)
        #expect(a == b)
    }
}

@Suite struct InstallerMigrationTests {
    @Test func homebrewInstallPointsAtStablePrefixPath() {
        let brew = Installer.hookBinary(forExecutable: "/opt/homebrew/Cellar/agentglance/0.1.1/bin/agentglance")
        #expect(brew.binary == "/opt/homebrew/bin/agentglance")
        #expect(!brew.needsCopy)
        let source = Installer.hookBinary(forExecutable: "/work/.build/release/agentglance")
        #expect(source.binary == Installer.defaultBinary)
        #expect(source.needsCopy)
    }

    @Test func reinstallMovesHooksAndStatusLineToNewBinary() {
        let old = Installer.install(into: [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "/x/cc-status"]]]]],
            "statusLine": ["type": "command", "command": "~/.claude/statusline-command.sh"],
        ], binary: "/Users/me/.local/bin/agentglance")
        let moved = Installer.install(into: old, binary: "/opt/homebrew/bin/agentglance")
        let stop = ((moved["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?
            .flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        #expect(stop == ["/x/cc-status", "/opt/homebrew/bin/agentglance hook"])
        #expect((moved["statusLine"] as? [String: Any])?["command"] as? String
                == "/opt/homebrew/bin/agentglance statusline -- ~/.claude/statusline-command.sh")
    }
}
