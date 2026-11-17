import AppKit
import SwiftUI

/// Choose an exit node, ask Tailscale for a suggestion, and run this device as an exit node.
struct ExitNodesView: View {
    @EnvironmentObject var store: AppStore

    private enum Suggestion: Equatable {
        case idle
        case loading
        /// `node` is the suggested exit node name; `output` the raw CLI text.
        case found(node: String, output: String)
        case unavailable(String)
    }

    @State private var suggestion: Suggestion = .idle
    @State private var filter = ""

    private static let adminConsoleURL = URL(string: "https://login.tailscale.com/admin/machines")

    // MARK: Derived

    private var activeNode: PeerStatus? { store.status?.activeExitNode }
    private var configuredExitNode: String { store.prefs?.exitNode ?? "" }
    private var isAuto: Bool { configuredExitNode.hasPrefix("auto:") }

    private var filteredNodes: [PeerStatus] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.exitNodes }
        return store.exitNodes.filter { node in
            let haystack = [node.displayName, node.dnsNameTrimmed, node.primaryIP ?? "",
                            node.location?.city ?? "", node.location?.country ?? ""].joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }
    }

    /// Value for `--exit-node`: the IP is unambiguous, the DNS name is the fallback.
    private func identifier(for node: PeerStatus) -> String {
        node.primaryIP ?? node.dnsNameTrimmed
    }

    // MARK: Body

    var body: some View {
        PageScroll {
            PageHeader("Exit Nodes", subtitle: "Route this device's internet traffic through another device on your tailnet.",
                       systemImage: "arrow.up.right.circle")
            if !store.cliAvailable {
                SectionCard {
                    EmptyStateView("Tailscale not found", systemImage: "exclamationmark.triangle",
                                   message: "Install Tailscale from tailscale.com/download, or set the path to the command-line tool in Settings.")
                        .frame(minHeight: 160)
                }
            } else if store.status == nil {
                HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
            } else {
                currentCard
                nodesCard
                thisDeviceCard
            }
        }
    }

    // MARK: Current exit node

    private var currentCard: some View {
        SectionCard("Current exit node", systemImage: "network") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let node = activeNode {
                        Text(node.displayName).font(.title3.weight(.semibold))
                        Text(describe(node)).font(.callout).foregroundStyle(.secondary)
                    } else if !configuredExitNode.isEmpty {
                        Text(isAuto ? "Automatic (\(configuredExitNode))" : configuredExitNode).font(.title3.weight(.semibold))
                        Text(isAuto ? "Tailscale chooses the best available exit node." : "Selected, but not currently active. The node may be offline.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("None").font(.title3.weight(.semibold))
                        Text("Internet traffic leaves directly from this device.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if activeNode != nil || !configuredExitNode.isEmpty {
                    Button {
                        Task { await store.runTailscale(PrefsCommands.clearExitNodeArgs(), refresh: [.status, .prefs]) }
                    } label: {
                        Label("Stop using exit node", systemImage: "xmark.circle")
                    }
                    .disabled(store.isBusy)
                }
            }
            Divider()
            Toggle(isOn: allowLANBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow local network access")
                    Text("Keep direct access to printers and other devices on your local network while using an exit node.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(store.isBusy || store.prefs == nil)
            Divider()
            HStack(alignment: .top, spacing: 10) {
                Button {
                    Task { await store.runTailscale(PrefsCommands.exitNodeArgs("auto:any"), refresh: [.status, .prefs]) }
                } label: {
                    Label("Use automatic exit node", systemImage: "wand.and.stars")
                }
                .disabled(store.isBusy || isAuto)
                Text("auto:any lets Tailscale pick the best exit node and switch as conditions change.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            suggestionRow
        }
    }

    private var allowLANBinding: Binding<Bool> {
        Binding(
            get: { store.prefs?.exitNodeAllowLANAccess ?? false },
            set: { value in Task { await store.setPrefs([.exitNodeAllowLANAccess(value)]) } }
        )
    }

    private func describe(_ node: PeerStatus) -> String {
        var parts: [String] = []
        if let place = locationText(node) { parts.append(place) }
        if let ip = node.primaryIP { parts.append(ip) }
        if !node.online { parts.append("offline") }
        return parts.joined(separator: " · ")
    }

    private func locationText(_ node: PeerStatus) -> String? {
        guard let location = node.location else { return nil }
        let text = [location.city, location.country].filter { !$0.isEmpty }.joined(separator: ", ")
        return text.isEmpty ? nil : text
    }

    // MARK: Suggestion

    private var suggestionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await loadSuggestion() }
                } label: {
                    Label("Suggest best", systemImage: "sparkles")
                }
                .disabled(suggestion == .loading || store.isBusy)
                if suggestion == .loading { ProgressView().controlSize(.small) }
                Text("Asks Tailscale which exit node looks best right now. Nothing changes until you choose it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            switch suggestion {
            case .idle, .loading:
                EmptyView()
            case .found(let node, _):
                let peer = peer(matching: node)
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal").foregroundStyle(.green).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Suggested: \(peer?.displayName ?? node)").fontWeight(.medium)
                        if let peer, !describe(peer).isEmpty {
                            Text(describe(peer)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Use") {
                        let target = peer.map(identifier(for:)) ?? node
                        Task { await store.runTailscale(PrefsCommands.exitNodeArgs(target), refresh: [.status, .prefs]) }
                    }
                    .disabled(store.isBusy)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.1)))
            case .unavailable(let text):
                Label(text, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func peer(matching name: String) -> PeerStatus? {
        let wanted = name.hasSuffix(".") ? String(name.dropLast()) : name
        return store.exitNodes.first { $0.dnsNameTrimmed.caseInsensitiveCompare(wanted) == .orderedSame
            || $0.displayName.caseInsensitiveCompare(wanted) == .orderedSame
            || $0.primaryIP == wanted }
    }

    /// Read-only `tailscale exit-node suggest`.
    private func loadSuggestion() async {
        suggestion = .loading
        do {
            let result = try await TailscaleCLI.run(["exit-node", "suggest"], timeout: 20)
            let output = result.combinedOutput
            if let line = output.split(whereSeparator: \.isNewline).first(where: { $0.lowercased().hasPrefix("suggested exit node:") }) {
                let value = line.dropFirst("suggested exit node:".count).trimmingCharacters(in: .whitespaces)
                if result.succeeded, !value.isEmpty {
                    suggestion = .found(node: value, output: output)
                    return
                }
            }
            suggestion = .unavailable(output.isEmpty ? "No exit node suggestion is available." : output)
        } catch {
            suggestion = .unavailable(error.localizedDescription)
        }
    }

    // MARK: Node list

    private var nodesCard: some View {
        SectionCard("Available exit nodes", subtitle: store.exitNodes.isEmpty ? nil : "\(store.exitNodes.count) available", systemImage: "list.bullet") {
            if store.exitNodes.isEmpty {
                emptyHelp
            } else {
                if store.exitNodes.count > 6 {
                    TextField("Filter by name, city or country", text: $filter)
                        .textFieldStyle(.roundedBorder)
                }
                if filteredNodes.isEmpty {
                    Text("No exit nodes match “\(filter)”.").font(.callout).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(filteredNodes.enumerated()), id: \.element.id) { index, node in
                        if index > 0 { Divider() }
                        nodeRow(node)
                    }
                }
            }
        }
    }

    private func nodeRow(_ node: PeerStatus) -> some View {
        HStack(spacing: 10) {
            StatusDot(online: node.online)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(node.displayName).fontWeight(.medium)
                    if node.exitNode {
                        Text("In use").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                HStack(spacing: 6) {
                    if let place = locationText(node) { Text(place) }
                    Text(node.online ? "Online" : "Offline")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let ip = node.primaryIP {
                Text(ip).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button(node.exitNode ? "In use" : "Use") {
                Task { await store.runTailscale(PrefsCommands.exitNodeArgs(identifier(for: node)), refresh: [.status, .prefs]) }
            }
            .disabled(node.exitNode || !node.online || store.isBusy)
            .frame(minWidth: 60)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var emptyHelp: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.up.right.circle").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("No exit nodes available").font(.title3.weight(.semibold))
            Text("An exit node is a device that forwards internet traffic for the rest of your tailnet. To get one, run “tailscale set --advertise-exit-node” on that device (or turn on “Advertise as exit node” below), then approve it in the admin console under Machines, Edit route settings, Use as exit node.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            if let url = Self.adminConsoleURL {
                Button("Open admin console") { NSWorkspace.shared.open(url) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: This device

    private var thisDeviceCard: some View {
        SectionCard("Use this device as an exit node", subtitle: "Let other devices on your tailnet send their internet traffic through this one.", systemImage: "server.rack") {
            Toggle(isOn: advertiseBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advertise as exit node")
                    Text("Equivalent to “tailscale set --advertise-exit-node”.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(store.isBusy || store.prefs == nil)
            if store.prefs?.advertiseExitNode == true {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("This device is advertising itself. Other devices can use it once an admin approves it in the admin console under Machines, Edit route settings.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let url = Self.adminConsoleURL {
                        Button("Open admin console") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }

    private var advertiseBinding: Binding<Bool> {
        Binding(
            get: { store.prefs?.advertiseExitNode ?? false },
            set: { value in Task { await store.setPrefs([.advertiseExitNode(value)]) } }
        )
    }
}
