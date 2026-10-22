import AgentGlanceCore
import AppKit
import SwiftUI

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

@MainActor
final class Store: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published var lastCleanup: String?

    private let monitor = Monitor()
    private let queue = DispatchQueue(label: "agentglance.monitor")
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        queue.async { [monitor] in
            let snapshot = monitor.scan()
            DispatchQueue.main.async { self.snapshot = snapshot }
        }
    }

    func clean(sessionKeys: Set<String>? = nil, pids: Set<Int32>? = nil) {
        guard let snapshot else { return }
        queue.async { [monitor] in
            let result = monitor.clean(sessionKeys: sessionKeys, pids: pids, in: snapshot)
            let summary = "Stopped \(result.stopped.count + result.forceKilled.count) process(es)"
                + (result.skipped.isEmpty ? "" : ", skipped \(result.skipped.count)")
            DispatchQueue.main.async {
                self.lastCleanup = summary
                self.refresh()
            }
        }
    }
}

struct MenuBarLabel: View {
    let snapshot: Snapshot?

    var body: some View {
        if let snapshot, !snapshot.leftBehind.isEmpty {
            Label(Format.bytes(snapshot.leftBehindRSS), systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
        } else {
            let running = snapshot?.running.count ?? 0
            Label(running > 0 ? "\(running)" : "", systemImage: "cpu")
                .labelStyle(.titleAndIcon)
        }
    }
}

struct PanelView: View {
    @ObservedObject var store: Store

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
                content(snapshot)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }

            Divider()
            HStack {
                if let message = store.lastCleanup {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 420)
    }

    @ViewBuilder
    private func content(_ snapshot: Snapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(snapshot.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
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

                Text("Running agents").font(.subheadline.bold())
                if snapshot.running.isEmpty {
                    Text("No agents running").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snapshot.running) { session in
                    SessionView(session: session, store: store)
                }

                if !snapshot.localModels.isEmpty {
                    let total = snapshot.localModels.reduce(0) { $0 + $1.rssBytes }
                    Label("Local models (Ollama) · \(Format.bytes(total))", systemImage: "brain")
                        .font(.caption)
                }
            }
        }
        .frame(maxHeight: 520)
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
                    .foregroundStyle(session.isRunning ? .green : .orange)
                    .font(.caption2)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.meta.label).font(.callout.bold()).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
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
                .disabled(session.processes.isEmpty)
            }

            if expanded {
                ForEach(session.processes) { proc in
                    HStack(spacing: 6) {
                        Text("\(proc.id.pid)").font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
                        Text(proc.name).font(.caption).lineLimit(1)
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
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var subtitle: String {
        let tool = session.meta.tool.rawValue
        let id = session.meta.shortSessionId.map { " · \($0)" } ?? ""
        let state = session.isRunning ? "running" : "ended"
        return "\(tool)\(id) · \(state) · \(session.processes.count) procs · \(Format.bytes(session.totalRSS))"
    }
}
