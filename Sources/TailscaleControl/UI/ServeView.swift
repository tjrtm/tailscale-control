import AppKit
import SwiftUI

/// Serve & Funnel: a native editor for every `tailscale serve` / `tailscale funnel` route of this node.
struct ServeView: View {
    @EnvironmentObject var store: AppStore

    @State private var filter = ""
    @State private var selection: String?
    @State private var sheet: ServeSheet?
    @State private var pending: ServePendingAction?

    private enum ServeSheet: Identifiable {
        case editor(ServeEditorRequest)
        case docker
        case quick(ServeQuickPreset)

        var id: String {
            switch self {
            case .editor(let r): return "editor-" + r.id.uuidString
            case .docker: return "docker"
            case .quick(let p): return "quick-\(p.exposePort)-\(p.funnel)"
            }
        }
    }

    // MARK: Data

    private var nodeRules: [ServeRule] { store.serveRules.filter { $0.service == nil } }

    private var visibleRules: [ServeRule] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return nodeRules }
        return nodeRules.filter { rule in
            let haystack = [rule.summary, rule.url(dnsName: store.selfDNSName) ?? "", rule.mode.title,
                            rule.funnel ? "public funnel" : "tailnet"].joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
    }

    private struct PortGroup: Identifiable {
        let port: Int
        let rules: [ServeRule]
        var id: Int { port }
    }

    private var groups: [PortGroup] {
        Dictionary(grouping: visibleRules, by: \.port)
            .map { PortGroup(port: $0.key, rules: $0.value) }
            .sorted { $0.port < $1.port }
    }

    private var baseURL: String? { store.selfDNSName.map { "https://\($0)" } }

    /// First public HTTPS port whose root path is not used yet (443 when all are taken).
    private func freeWebPort() -> Int {
        let used = Set(nodeRules.filter { $0.mode.isWeb && $0.normalizedMount == "/" }.map(\.port))
        return ServeRule.funnelPorts.first { !used.contains($0) } ?? 443
    }

    private func newDraft(target: String = "http://127.0.0.1:8080") -> ServeRule {
        ServeRule(mode: .https, port: freeWebPort(), target: .proxy(target))
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if !nodeRules.isEmpty {
                Divider()
                footerBar
            }
        }
        .serveConfirmations($pending)
        .task {
            // `--show=add-route` (documentation screenshots): open the route editor once the routes are loaded.
            guard LaunchOptions.consumeShow("add-route") else { return }
            for _ in 0..<50 where store.serveConfig == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            sheet = .editor(.add(newDraft()))
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .editor(let request):
                ServeRuleEditor(request: request).environmentObject(store)
            case .docker:
                ServeDockerSheet { target in
                    sheet = .editor(.add(newDraft(target: target.proxyTarget)))
                }
                .environmentObject(store)
            case .quick(let preset):
                ServeQuickRouteSheet(preset: preset).environmentObject(store)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader("Serve & Funnel",
                       subtitle: "Share local apps, folders and ports with your tailnet, or publicly with Funnel.",
                       systemImage: "arrow.triangle.branch")

            if !store.cliAvailable {
                hint("The Tailscale command-line tool was not found. Install Tailscale or set its path in Settings to manage routes.",
                     systemImage: "exclamationmark.triangle.fill", color: .red)
            } else if store.status != nil, !store.isRunning {
                hint("Tailscale is not connected. Connect it before changing routes; routes only serve traffic while it is running.",
                     systemImage: "bolt.slash.fill", color: .orange)
            }

            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(.secondary).accessibilityHidden(true)
                Text("Base URL").foregroundStyle(.secondary)
                if let baseURL {
                    Text(baseURL).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    CopyButton(text: baseURL).help("Copy base URL")
                    if let link = URL(string: baseURL) {
                        Button { NSWorkspace.shared.open(link) } label: { Image(systemName: "safari") }
                            .buttonStyle(.borderless)
                            .help("Open in browser")
                            .accessibilityLabel("Open base URL in browser")
                    }
                } else {
                    Text("not available yet").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)

            actionBar
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func hint(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { sheet = .editor(.add(newDraft())) } label: { Label("Add Route", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .help("Add a new serve or Funnel route")

            Menu {
                Button("HTTPS :443 to a local port…") { sheet = .quick(ServeQuickPreset(exposePort: 443)) }
                Button("HTTPS :8443 to a local port…") { sheet = .quick(ServeQuickPreset(exposePort: 8443)) }
                Divider()
                Button("Public (Funnel) :443 to a local port…") { sheet = .quick(ServeQuickPreset(exposePort: 443, funnel: true)) }
            } label: { Label("Quick Route", systemImage: "bolt") }
                .fixedSize()
                .help("Share a local port over HTTPS in one step")

            Button { sheet = .docker } label: { Label("From Docker…", systemImage: "shippingbox") }
                .help("Pick a running container's published port")

            Menu {
                Button("Reset Funnel…", role: .destructive) { pending = .resetFunnel }
                Button("Reset All Routes…", role: .destructive) { pending = .resetAll }
            } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                .fixedSize()
                .help("Remove routes in bulk")

            Spacer(minLength: 8)

            TextField("Filter routes", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .accessibilityLabel("Filter routes")
        }
        .disabled(store.isBusy || !store.cliAvailable)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if nodeRules.isEmpty {
            if store.serveConfig == nil && store.isRefreshing {
                VStack { ProgressView("Loading routes…") }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(
                    "No routes yet",
                    systemImage: "arrow.triangle.branch",
                    message: "Add a route to share a local app, folder or port with your tailnet, or with the whole internet using Funnel.",
                    actionTitle: store.cliAvailable ? "Add Route" : nil,
                    action: { sheet = .editor(.add(newDraft())) })
            }
        } else if visibleRules.isEmpty {
            EmptyStateView("No matching routes", systemImage: "magnifyingglass",
                           message: "No route matches “\(filter)”.", actionTitle: "Clear Filter", action: { filter = "" })
        } else {
            List(selection: $selection) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.rules) { rule in
                            ServeRuleRow(
                                rule: rule,
                                onEdit: { sheet = .editor(.edit($0)) },
                                onDuplicate: { sheet = .editor(.duplicate($0, existing: store.serveRules)) },
                                pending: $pending)
                                .tag(rule.id)
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onDeleteCommand {
                if let rule = nodeRules.first(where: { $0.id == selection }), !rule.isForeground, !store.isBusy {
                    pending = .remove(rule)
                }
            }
        }
    }

    private func groupHeader(_ group: PortGroup) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "Port \(group.port)").font(.headline)
            if let name = store.selfDNSName, let first = group.rules.first(where: { $0.mode.isWeb }) {
                let secure = first.mode == .https
                let isDefault = group.port == (secure ? 443 : 80)
                Text(verbatim: "\(secure ? "https" : "http")://\(name)\(isDefault ? "" : ":\(group.port)")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var footerBar: some View {
        let total = nodeRules.count
        let publicCount = nodeRules.filter(\.funnel).count
        return HStack(spacing: 12) {
            Text("\(total) route\(total == 1 ? "" : "s")")
            Label("\(publicCount) public", systemImage: "globe")
                .foregroundStyle(publicCount > 0 ? Color.orange : Color.secondary)
            Spacer()
            if store.isBusy, let desc = store.busyDescription {
                ProgressView().controlSize(.small)
                Text(desc).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            } else {
                Text("Double-click a route to edit it.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }
}
