import AppKit
import SwiftUI

// MARK: - Mode presentation

extension ServeRule.Mode {
    /// Short label for the badge.
    var serveBadgeTitle: String {
        switch self {
        case .https: return "HTTPS"
        case .http: return "HTTP"
        case .tcp: return "TCP"
        case .tlsTerminatedTCP: return "TLS-TCP"
        }
    }

    var serveBadgeColor: Color {
        switch self {
        case .https: return .blue
        case .http: return .orange
        case .tcp: return .purple
        case .tlsTerminatedTCP: return .teal
        }
    }
}

extension ServeRule {
    /// Whether the quick Funnel toggle makes sense for this rule.
    var serveFunnelEligible: Bool {
        !isForeground && service == nil && mode != .http && Self.funnelPorts.contains(port) && acceptAppCaps.isEmpty
    }

    /// `tailscale serve ...` as one copyable shell line.
    var serveCommandLine: String { CommandRunner.displayCommandLine(["tailscale"] + applyArgs()) }
}

// MARK: - Pending confirmations

/// Destructive or public-facing actions that wait for the user's confirmation.
enum ServePendingAction: Identifiable {
    case remove(ServeRule)
    case enableFunnel(ServeRule)
    case resetAll
    case resetFunnel

    var id: String {
        switch self {
        case .remove(let r): return "remove|" + r.id
        case .enableFunnel(let r): return "funnel|" + r.id
        case .resetAll: return "resetAll"
        case .resetFunnel: return "resetFunnel"
        }
    }

    var title: String {
        switch self {
        case .remove(let r): return "Remove \(r.summary)?"
        case .enableFunnel: return "Make this route public?"
        case .resetAll: return "Remove all routes?"
        case .resetFunnel: return "Turn off all Funnel routes?"
        }
    }

    var message: String {
        switch self {
        case .remove: return "The route stops working immediately."
        case .enableFunnel(let r): return "Anyone on the internet will be able to reach \(r.summary)."
        case .resetAll: return "Removes every serve and Funnel route on this node (tailscale serve reset). This cannot be undone."
        case .resetFunnel: return "Routes stay available on your tailnet but are no longer public (tailscale funnel reset)."
        }
    }

    var confirmTitle: String {
        switch self {
        case .remove: return "Remove"
        case .enableFunnel: return "Make Public"
        case .resetAll: return "Remove All"
        case .resetFunnel: return "Turn Off Funnel"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .enableFunnel: return false
        default: return true
        }
    }
}

/// Attaches one confirmation dialog for `ServePendingAction` and runs the confirmed action through `AppStore`.
private struct ServeConfirmations: ViewModifier {
    @EnvironmentObject var store: AppStore
    @Binding var pending: ServePendingAction?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button(action.confirmTitle, role: action.isDestructive ? .destructive : nil) { run(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
    }

    private func run(_ action: ServePendingAction) {
        Task {
            switch action {
            case .remove(let rule):
                await store.remove(rule: rule)
            case .enableFunnel(let rule):
                var updated = rule
                updated.funnel = true
                await store.apply(rule: updated, replacing: rule)
            case .resetAll:
                await store.resetServe()
            case .resetFunnel:
                await store.runTailscale(ServeCommands.funnelResetArgs(), refresh: .serve)
            }
        }
    }
}

extension View {
    /// Confirmation dialogs for removing routes, enabling Funnel and the reset commands.
    func serveConfirmations(_ pending: Binding<ServePendingAction?>) -> some View {
        modifier(ServeConfirmations(pending: pending))
    }
}

// MARK: - Row

/// One route: mode badge, port, mount, target, Funnel state and actions. Used by the Serve and Services pages.
struct ServeRuleRow: View {
    @EnvironmentObject var store: AppStore

    let rule: ServeRule
    /// Show the quick Funnel switch for eligible rules.
    var showFunnelToggle = true
    var onEdit: (ServeRule) -> Void
    var onDuplicate: (ServeRule) -> Void
    @Binding var pending: ServePendingAction?

    private var url: String? { rule.url(dnsName: store.selfDNSName) }

    private var address: String? {
        guard !rule.mode.isWeb else { return nil }
        guard let host = rule.service == nil ? (store.selfDNSName ?? rule.host) : rule.host else { return nil }
        return "\(host):\(rule.port)"
    }

    private var copyText: String? { url ?? address }

    private var targetIcon: String {
        switch rule.target {
        case .proxy: return "network"
        case .path: return "folder"
        case .text: return "text.quote"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(":" + String(rule.port))
                        .font(.system(.body, design: .monospaced).weight(.medium))
                    if rule.mode.isWeb {
                        Text(rule.normalizedMount)
                            .font(.system(.body, design: .monospaced))
                    }
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("forwards to")
                    Image(systemName: targetIcon)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(rule.target.display)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(rule.target.display)
                }
                if let detail = detailLine {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if rule.isForeground {
                Label("Foreground", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help("Started with serve in a terminal (without --bg). It stops when that session ends, so it cannot be edited or removed here.")
            }
            funnelIndicator
            if showFunnelToggle && rule.serveFunnelEligible {
                Toggle("Funnel", isOn: Binding(get: { rule.funnel }, set: { setFunnel($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(store.isBusy)
                    .help(rule.funnel ? "Stop sharing publicly" : "Share publicly with Funnel")
                    .accessibilityLabel("Funnel for \(rule.summary)")
            }
            actions
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture(count: 2).onEnded { if canModify { onEdit(rule) } })
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
    }

    private var canModify: Bool { !rule.isForeground && !store.isBusy }

    private var badge: some View {
        Text(rule.mode.serveBadgeTitle)
            .font(.caption.weight(.semibold))
            .foregroundStyle(rule.mode.serveBadgeColor)
            .frame(width: 58)
            .padding(.vertical, 3)
            .background(Capsule().fill(rule.mode.serveBadgeColor.opacity(0.15)))
            .accessibilityLabel(rule.mode.title)
    }

    private var detailLine: String? {
        var parts: [String] = []
        if let text = url ?? address { parts.append(text) }
        if let pp = rule.proxyProtocol { parts.append("PROXY protocol v\(pp)") }
        if !rule.acceptAppCaps.isEmpty { parts.append("Capabilities: " + rule.acceptAppCaps.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var funnelIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
            Text(rule.funnel ? "Public" : "Tailnet only")
        }
        .font(.caption)
        .foregroundStyle(rule.funnel ? Color.orange : Color.secondary)
        .fixedSize()
        .help(rule.funnel ? "Funnel is on: reachable from the public internet." : "Only reachable from devices on your tailnet.")
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if let url, let link = URL(string: url) {
                Button { NSWorkspace.shared.open(link) } label: { Image(systemName: "safari") }
                    .help("Open in browser")
                    .accessibilityLabel("Open in browser")
            }
            if let copyText {
                CopyButton(text: copyText)
                    .help(rule.mode.isWeb ? "Copy URL" : "Copy address")
            }
            if !rule.isForeground {
                Button { onEdit(rule) } label: { Image(systemName: "pencil") }
                    .disabled(store.isBusy)
                    .help("Edit route")
                    .accessibilityLabel("Edit route")
            }
            Menu { menuItems } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var menuItems: some View {
        if let url, let link = URL(string: url) {
            Button { NSWorkspace.shared.open(link) } label: { Label("Open in Browser", systemImage: "safari") }
        }
        if let copyText {
            Button { Clipboard.copy(copyText) } label: { Label(rule.mode.isWeb ? "Copy URL" : "Copy Address", systemImage: "doc.on.doc") }
        }
        Button { Clipboard.copy(rule.serveCommandLine) } label: { Label("Copy CLI Command", systemImage: "terminal") }
        if !rule.isForeground {
            Divider()
            Button { onEdit(rule) } label: { Label("Edit…", systemImage: "pencil") }
                .disabled(store.isBusy)
            Button { onDuplicate(rule) } label: { Label("Duplicate…", systemImage: "plus.square.on.square") }
                .disabled(store.isBusy)
            if showFunnelToggle && rule.serveFunnelEligible {
                Button { setFunnel(!rule.funnel) } label: {
                    Label(rule.funnel ? "Turn Funnel Off" : "Turn Funnel On", systemImage: "globe")
                }
                .disabled(store.isBusy)
            }
            Divider()
            Button(role: .destructive) { pending = .remove(rule) } label: { Label("Remove…", systemImage: "trash") }
                .disabled(store.isBusy)
        }
    }

    private func setFunnel(_ on: Bool) {
        guard !store.isBusy else { return }
        if on {
            pending = .enableFunnel(rule)
        } else {
            var updated = rule
            updated.funnel = false
            Task { await store.apply(rule: updated, replacing: rule) }
        }
    }
}
