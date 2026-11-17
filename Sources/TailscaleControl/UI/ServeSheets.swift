import SwiftUI

// MARK: - Quick route

/// Preset for the quick-route sheet.
struct ServeQuickPreset: Hashable {
    var exposePort: Int = 443
    var funnel = false
}

/// Small sheet: expose a local port over HTTPS in one step.
struct ServeQuickRouteSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var exposePort: Int
    @State private var funnel: Bool
    @State private var localPortText = ""
    @State private var saving = false

    init(preset: ServeQuickPreset) {
        _exposePort = State(initialValue: preset.exposePort)
        _funnel = State(initialValue: preset.funnel)
    }

    private var composed: (rule: ServeRule?, message: String?) {
        guard let local = Int(localPortText.trimmingCharacters(in: .whitespaces)), (1...65535).contains(local) else {
            return (nil, localPortText.isEmpty ? "Enter the local port to share, for example 3000." : "The local port must be a number from 1 to 65535.")
        }
        var rule = ServeRule.localProxy(exposePort: exposePort, localPort: local)
        rule.funnel = funnel
        do { try rule.validate() } catch { return (nil, error.localizedDescription) }
        return (rule, nil)
    }

    private var conflict: ServeRule? {
        guard let rule = composed.rule else { return nil }
        return store.serveRules.first { !$0.isForeground && $0.identity == rule.identity }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quick Route")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)

            Form {
                Section {
                    TextField("Local port", text: $localPortText, prompt: Text("3000"))
                    Picker("Tailscale port", selection: $exposePort) {
                        ForEach(ServeRule.funnelPorts, id: \.self) { Text(String($0)).tag($0) }
                    }
                    Toggle(isOn: $funnel) { Label("Share publicly with Funnel", systemImage: "globe") }
                } footer: {
                    Text("Serves http://127.0.0.1:<local port> over HTTPS at the root of this node.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(store.isBusy)

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let message = composed.message, !localPortText.isEmpty {
                    Label(message, systemImage: "exclamationmark.circle.fill").font(.callout).foregroundStyle(.red)
                } else if let conflict {
                    Label("This replaces the existing route \(conflict.summary).", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let rule = composed.rule { CommandPreview(args: rule.applyArgs()) }
                if let error = store.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    if store.isBusy || saving { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Create Route") { create() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(composed.rule == nil || store.isBusy || saving)
                }
            }
            .padding(16)
        }
        .frame(width: 460)
        .onAppear { store.dismissError() }
    }

    private func create() {
        guard let rule = composed.rule, !saving else { return }
        saving = true
        Task {
            let ok = await store.apply(rule: rule)
            saving = false
            if ok { dismiss() }
        }
    }
}

// MARK: - Docker picker

/// Lists running containers that publish a TCP port and hands the chosen one back.
struct ServeDockerSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var onPick: (DockerTarget) -> Void

    @State private var loading = true
    @State private var selection: String?

    private var selected: DockerTarget? { store.dockerTargets.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("From Docker").font(.title3.weight(.semibold))
                Text("Running containers that publish a port on this Mac.").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)

            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()

            HStack {
                Button { Task { await reload() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(loading)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue") { if let selected { onPick(selected) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
            .padding(16)
        }
        .frame(width: 540, height: 400)
        .task { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            VStack(spacing: 8) { ProgressView(); Text("Looking for containers…").foregroundStyle(.secondary) }
        } else if let error = store.dockerError {
            EmptyStateView("Docker is not available", systemImage: "shippingbox", message: error)
        } else if store.dockerTargets.isEmpty {
            EmptyStateView("No published ports", systemImage: "shippingbox",
                           message: "No running container publishes a TCP port. Start one with -p, then rescan.")
        } else {
            List(store.dockerTargets, selection: $selection) { target in
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.containerName).font(.body.weight(.medium))
                    Text(verbatim: "localhost:\(target.hostPort) → \(target.containerPort)  ·  \(target.image)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(target.id)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded { onPick(target) })
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func reload() async {
        loading = true
        await store.refreshDocker()
        loading = false
        if selection == nil || selected == nil { selection = store.dockerTargets.first?.id }
    }
}
