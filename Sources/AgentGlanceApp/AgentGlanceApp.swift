import AgentGlanceCore
import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct AgentGlanceApp: App {
    @StateObject private var store = Store()

    init() {
        // Menu bar only: no Dock icon or app switcher entry.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            MenuBarLabel(snapshot: store.snapshot)
        }
        .menuBarExtraStyle(.window)
    }
}

enum Settings {
    static let notifications = "notificationsEnabled"
    /// Minutes after a session ends before its leftovers are stopped automatically; 0 = off.
    static let autoCleanMinutes = "autoCleanMinutes"
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published var lastCleanup: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?

    private let monitor = Monitor()
    private let queue = DispatchQueue(label: "agentglance.monitor")
    private var timer: Timer?
    private let notifier = Notifier()
    private var notifiedWarnings: Set<Warning>?
    private var autoCleaned: Set<String> = []

    init() {
        UserDefaults.standard.register(defaults: [Settings.notifications: true, Settings.autoCleanMinutes: 0])
        notifier.onClean = { [weak self] key in self?.clean(sessionKeys: [key]) }
        notifier.start()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        queue.async { [monitor] in
            let snapshot = monitor.scan()
            DispatchQueue.main.async { self.apply(snapshot) }
        }
    }

    private func apply(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        let defaults = UserDefaults.standard

        if defaults.bool(forKey: Settings.notifications) {
            for session in snapshot.leftBehind where snapshot.justEnded.contains(session.id) {
                notifier.leftovers(session)
            }
            // Warnings present at launch are shown in the panel, not announced.
            let current = Set(snapshot.warnings.filter { $0.kind != .leftoverPort })
            if let seen = notifiedWarnings {
                for warning in current.subtracting(seen) { notifier.warning(warning) }
            }
            notifiedWarnings = current
        }

        let minutes = defaults.integer(forKey: Settings.autoCleanMinutes)
        if minutes > 0 {
            let due = snapshot.leftBehind.filter { session in
                guard let ended = session.endedAt, !autoCleaned.contains(session.id) else { return false }
                return snapshot.takenAt.timeIntervalSince(ended) >= Double(minutes * 60)
            }
            if !due.isEmpty {
                autoCleaned.formUnion(due.map(\.id))
                clean(sessionKeys: Set(due.map(\.id)), label: "Auto-cleaned")
            }
        }
    }

    func clean(sessionKeys: Set<String>? = nil, pids: Set<Int32>? = nil, containerIds: Set<String>? = nil, label: String? = nil) {
        guard let snapshot else { return }
        queue.async { [monitor] in
            let result = monitor.clean(sessionKeys: sessionKeys, pids: pids, containerIds: containerIds, in: snapshot)
            DispatchQueue.main.async {
                self.lastCleanup = label.map { "\($0): \(result.summary)" } ?? result.summary
                self.refresh()
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Launch at login failed: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Posts notifications with a "Clean up" action. Only works when running from the .app bundle.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let category = "LEFTOVERS"
    static let cleanAction = "CLEAN"
    var onClean: ((String) -> Void)?
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        guard let center else { return }
        center.delegate = self
        let clean = UNNotificationAction(identifier: Self.cleanAction, title: "Clean up")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [clean],
                                                                 intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func leftovers(_ session: AgentSession) {
        let content = UNMutableNotificationContent()
        content.title = "\(session.meta.label) ended but left things running"
        content.body = Format.leftovers(processes: session.processes.count, bytes: session.totalRSS,
                                        containers: session.containers.count)
            + (session.processes.flatMap(\.ports).isEmpty ? "" : " · ports " + session.processes.flatMap(\.ports).map { ":\($0)" }.joined(separator: " "))
        content.categoryIdentifier = Self.category
        content.userInfo = ["session": session.id]
        post(content, id: "leftovers-\(session.id)")
    }

    func warning(_ warning: Warning) {
        let content = UNMutableNotificationContent()
        content.title = warning.kind == .migrationClash ? "Migration clash between agents" : "Agents may collide"
        content.body = warning.message
        post(content, id: "warning-\(warning.message.hashValue)")
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        center?.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Self.cleanAction,
           let key = response.notification.request.content.userInfo["session"] as? String {
            DispatchQueue.main.async { self.onClean?(key) }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

struct MenuBarLabel: View {
    let snapshot: Snapshot?

    /// Most urgent first: leftovers, then agents waiting on you, then the running count. 5h limit appended.
    var body: some View {
        let limit = snapshot?.limits?.fiveHour.map { " · \(Int($0.usedPercent.rounded()))%" } ?? ""
        if let snapshot, !snapshot.leftBehind.isEmpty {
            Label(Format.bytes(snapshot.leftBehindRSS) + limit, systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
        } else if let snapshot, !snapshot.needingYou.isEmpty {
            Label("\(snapshot.needingYou.count)" + limit, systemImage: "bell.badge.fill")
                .labelStyle(.titleAndIcon)
        } else {
            let running = snapshot?.running.count ?? 0
            Label((running > 0 ? "\(running)" : "") + limit, systemImage: "cpu")
                .labelStyle(.titleAndIcon)
        }
    }
}

struct LimitGauge: View {
    let title: String
    let window: LimitWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption.bold())
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%").font(.caption.monospacedDigit())
            }
            ProgressView(value: min(window.usedPercent, 100), total: 100)
                .tint(window.usedPercent >= 90 ? .red : window.usedPercent >= 75 ? .orange : .accentColor)
            Group {
                if window.hasReset(at: now) {
                    Text("reset · starts with your next message")
                } else {
                    HStack(spacing: 3) {
                        Text("resets in")
                        Text(window.resetsAt, style: .relative)
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelView: View {
    @ObservedObject var store: Store
    @AppStorage(Settings.notifications) private var notifications = true
    @AppStorage(Settings.autoCleanMinutes) private var autoCleanMinutes = 0
    @State private var contentHeight: CGFloat = 0
    @State private var showAllRunning = false
    private let collapsedRunningCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AgentGlance").font(.headline)
                Spacer()
                if let snapshot = store.snapshot {
                    Text(snapshot.takenAt, style: .time).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let snapshot = store.snapshot {
                // A ScrollView has no height of its own in a menu bar window, so size it to its content.
                ScrollView {
                    content(snapshot)
                        .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
                }
                .frame(height: min(max(contentHeight, 20), 560))
                .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 440)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let message = store.lastCleanup {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Menu {
                    Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                    Toggle("Notify when a session leaves things running", isOn: $notifications)
                    Picker("Auto-clean leftovers", selection: $autoCleanMinutes) {
                        Text("Off").tag(0)
                        Text("10 minutes after a session ends").tag(10)
                        Text("1 hour after a session ends").tag(60)
                    }
                    Divider()
                    Button("Quit AgentGlance") { NSApplication.shared.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let error = store.loginError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func content(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let limits = snapshot.limits, limits.fiveHour != nil || limits.sevenDay != nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 16) {
                        if let w = limits.fiveHour { LimitGauge(title: "5-hour limit", window: w, now: snapshot.takenAt) }
                        if let w = limits.sevenDay { LimitGauge(title: "Weekly limit", window: w, now: snapshot.takenAt) }
                    }
                    // Limits only refresh while a Claude Code session's status line runs; say how old they are.
                    if snapshot.takenAt.timeIntervalSince(limits.updatedAt) > 600 {
                        HStack(spacing: 3) {
                            Text("Updated")
                            Text(limits.updatedAt, style: .relative)
                            Text("ago · refreshes while a Claude Code session is open")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(snapshot.warnings, id: \.self) { warning in
                Label(warning.message, systemImage: warning.kind == .leftoverPort ? "network" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !snapshot.leftBehind.isEmpty {
                HStack {
                    Text("Left behind · \(Format.bytes(snapshot.leftBehindRSS))").font(.subheadline.bold())
                    Spacer()
                    Button("Clean up all") { store.clean() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                }
                ForEach(snapshot.leftBehind) { session in
                    SessionView(session: session, store: store)
                }
            }

            let running = snapshot.running
            HStack {
                Text("Running agents (\(running.count))").font(.subheadline.bold())
                if !snapshot.needingYou.isEmpty {
                    Text("\(snapshot.needingYou.count) need you").font(.caption.bold()).foregroundStyle(.orange)
                }
                Spacer()
                if running.count > collapsedRunningCount {
                    Button(showAllRunning ? "Show fewer" : "Show all") { showAllRunning.toggle() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            if running.isEmpty {
                Text("No agents running").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(showAllRunning ? running : Array(running.prefix(collapsedRunningCount))) { session in
                SessionView(session: session, store: store)
            }

            if !snapshot.localModels.isEmpty {
                let total = snapshot.localModels.reduce(0) { $0 + $1.rssBytes }
                Label("Local models (Ollama) · \(Format.bytes(total))", systemImage: "brain")
                    .font(.caption)
            }
            if DockerClient.path != nil && !snapshot.dockerAvailable {
                Label("Docker isn't running, so containers aren't tracked", systemImage: "shippingbox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SessionView: View {
    let session: AgentSession
    @ObservedObject var store: Store
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: session.isRunning ? "circle.fill" : "circle")
                    .foregroundStyle(dotColor)
                    .font(.caption2)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.meta.label).font(.callout.bold()).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if session.activity == .needsPermission, let message = session.activityMessage {
                        Text(message).font(.caption2).foregroundStyle(.red).lineLimit(2)
                    }
                }
                Spacer()
                if !session.isRunning {
                    Button("Clean up") { store.clean(sessionKeys: [session.meta.key]) }
                        .controlSize(.small)
                }
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(!session.hasLeftovers)
            }

            if expanded {
                ForEach(session.processes) { proc in
                    HStack(spacing: 6) {
                        Text("\(proc.id.pid)").font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
                        Text(proc.name).font(.caption).lineLimit(1)
                        if proc.isApp {
                            Text("app").font(.caption2).foregroundStyle(.secondary)
                                .help("A Mac app the agent opened. Not included in Clean up; use ✕ to quit it.")
                        }
                        if !proc.ports.isEmpty {
                            Text(proc.ports.map { ":\($0)" }.joined(separator: " "))
                                .font(.caption.monospaced()).foregroundStyle(.blue)
                        }
                        Spacer()
                        Text(Format.bytes(proc.rssBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button {
                            store.clean(pids: [proc.id.pid])
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop \(proc.command)")
                    }
                }
                ForEach(session.containers) { container in
                    HStack(spacing: 6) {
                        Image(systemName: "shippingbox").font(.caption).frame(width: 52, alignment: .trailing)
                        Text(container.name).font(.caption).lineLimit(1)
                        if !container.ports.isEmpty {
                            Text(container.ports.map { ":\($0)" }.joined(separator: " "))
                                .font(.caption.monospaced()).foregroundStyle(.blue)
                        }
                        if container.confidence == .likely {
                            Text("likely").font(.caption2).foregroundStyle(.secondary)
                                .help("Created inside this session's folder after it started, but its docker command wasn't seen. Not included in Clean up all.")
                        }
                        Spacer()
                        Text(container.image).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Button {
                            store.clean(containerIds: [container.id])
                        } label: {
                            Image(systemName: "stop.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("docker stop \(container.name)")
                    }
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var dotColor: Color {
        guard session.isRunning else { return .orange }
        switch session.activity {
        case .needsPermission: return .red
        case .waiting: return .yellow
        case .error: return .pink
        case .working, .idle, nil: return .green
        }
    }

    private var subtitle: String {
        let tool = session.meta.tool.rawValue
        let id = session.meta.shortSessionId.map { " · \($0)" } ?? ""
        let state = session.isRunning ? (session.activity?.label ?? "running") : "ended"
        let summary = Format.leftovers(processes: session.processes.count, bytes: session.totalRSS,
                                       containers: session.containers.count)
        return "\(tool)\(id) · \(state) · \(summary)"
    }
}
