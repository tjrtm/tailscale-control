import AppKit
import SwiftUI

/// Content of the menu bar popover (hosted by a `MenuBarExtra` in window style).
struct MenuBarView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @State private var copiedKey: String?
    @State private var autoRefreshing = false

    private var selfNode: PeerStatus? { store.status?.selfNode }
    private var activeExitNode: PeerStatus? { store.status?.activeExitNode }
    private var ipAddress: String? { selfNode?.primaryIP ?? store.status?.tailscaleIPs.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Divider().padding(.vertical, 4)

            if store.cliAvailable {
                connectionRow
                if store.isRunning { exitNodeMenu }
                if store.isRunning || ipAddress != nil { Divider().padding(.vertical, 4) }
                if let ip = ipAddress {
                    MenuRow("Copy IP address", systemImage: "doc.on.doc", detail: copiedKey == "ip" ? "Copied" : ip) { copy(ip, key: "ip") }
                }
                if let dns = store.selfDNSName {
                    MenuRow("Copy DNS name", systemImage: "doc.on.doc", detail: copiedKey == "dns" ? "Copied" : nil) { copy(dns, key: "dns") }
                }
                MenuRow("Serve routes", systemImage: "arrow.triangle.branch", detail: "\(store.serveRules.count)") { show(.serve) }
                Divider().padding(.vertical, 4)
            } else {
                Text("Install Tailscale or set the path to its command-line tool in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                Divider().padding(.vertical, 4)
            }

            MenuRow("Open Tailscale Control", systemImage: "macwindow") { show(nil) }
            ForEach([SidebarSection.devices, .exitNodes, .preferences, .activity], id: \.self) { section in
                MenuRow(section.title, systemImage: section.systemImage) { show(section) }
            }
            Divider().padding(.vertical, 4)
            MenuRow("Quit Tailscale Control", systemImage: "power") { NSApplication.shared.terminate(nil) }
        }
        .padding(8)
        .frame(width: 280)
        .onAppear {
            if !autoRefreshing { autoRefreshing = true; store.startAutoRefresh() }
            Task { await store.refreshAll() }
        }
        .onDisappear {
            if autoRefreshing { autoRefreshing = false; store.stopAutoRefresh() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if store.cliAvailable {
                    StatusBadge(state: store.backendState)
                } else {
                    HStack(spacing: 6) { StatusDot(color: .red); Text("Tailscale not found").font(.callout) }
                }
                Spacer()
                if store.isRefreshing || store.isBusy { ProgressView().controlSize(.small) }
            }
            if let name = selfNode?.displayName, store.cliAvailable {
                Text(store.tailnetName.map { "\(name) · \($0)" } ?? name)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    // MARK: Connection

    @ViewBuilder
    private var connectionRow: some View {
        switch store.backendState {
        case .running:
            MenuRow("Disconnect", systemImage: "power", disabled: store.isBusy) { Task { await store.disconnect() } }
        case .needsLogin:
            if let url = store.authURL {
                MenuRow("Open login page", systemImage: "safari") { NSWorkspace.shared.open(url) }
            }
            MenuRow("Log in…", systemImage: "arrow.right.circle", disabled: store.isBusy) {
                Task {
                    store.pendingAuthURL = nil
                    await store.runTailscale(PrefsCommands.loginArgs(), timeout: 20)
                }
            }
        default:
            MenuRow("Connect", systemImage: "power", disabled: store.isBusy || store.backendState == .starting) {
                Task { await store.connect() }
            }
        }
    }

    // MARK: Exit nodes

    private var exitNodeMenu: some View {
        let configured = store.prefs?.exitNode ?? ""
        let isAuto = configured.hasPrefix("auto:")
        let currentTitle = activeExitNode?.displayName ?? (isAuto ? "Automatic" : (configured.isEmpty ? "None" : configured))
        return Menu {
            Button {
                Task { await store.runTailscale(PrefsCommands.clearExitNodeArgs(), refresh: [.status, .prefs]) }
            } label: {
                if activeExitNode == nil && configured.isEmpty { Label("None", systemImage: "checkmark") } else { Text("None") }
            }
            Button {
                Task { await store.runTailscale(PrefsCommands.exitNodeArgs("auto:any"), refresh: [.status, .prefs]) }
            } label: {
                if isAuto { Label("Automatic (auto:any)", systemImage: "checkmark") } else { Text("Automatic (auto:any)") }
            }
            if !store.exitNodes.isEmpty { Divider() }
            ForEach(store.exitNodes) { node in
                Button {
                    Task { await store.runTailscale(PrefsCommands.exitNodeArgs(node.primaryIP ?? node.dnsNameTrimmed), refresh: [.status, .prefs]) }
                } label: {
                    let title = menuTitle(for: node)
                    if node.exitNode { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
                .disabled(!node.online)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.right.circle").frame(width: 18)
                Text("Exit node")
                Spacer()
                Text(currentTitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .disabled(store.isBusy)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private func menuTitle(for node: PeerStatus) -> String {
        guard let location = node.location else { return node.displayName }
        let place = [location.city, location.country].filter { !$0.isEmpty }.joined(separator: ", ")
        return place.isEmpty ? node.displayName : "\(node.displayName) (\(place))"
    }

    // MARK: Actions

    private func copy(_ text: String, key: String) {
        Clipboard.copy(text)
        copiedKey = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copiedKey == key { copiedKey = nil } }
    }

    /// Bring the main window forward (opening it if needed), then optionally switch to `section`.
    private func show(_ section: SidebarSection?) {
        // Remembered as pending when the window is closed; an open window switches right away.
        section?.navigate()
        openWindow(id: mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// One full-width row of the popover with a hover highlight.
private struct MenuRow: View {
    var title: String
    var systemImage: String
    var detail: String?
    var shortcut: String?
    var disabled: Bool
    var action: () -> Void
    @State private var hovering = false

    init(_ title: String, systemImage: String, detail: String? = nil, shortcut: String? = nil, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.shortcut = shortcut
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).frame(width: 18)
                Text(title)
                Spacer()
                if let detail { Text(detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering && !disabled ? Color.accentColor.opacity(0.18) : Color.clear))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}
