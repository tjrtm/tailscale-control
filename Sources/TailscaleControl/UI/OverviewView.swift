import AppKit
import SwiftUI

/// Connection state, identity and accounts of this device at a glance.
struct OverviewView: View {
    @EnvironmentObject var store: AppStore
    @State private var showConnectSheet = false

    private static let downloadURL = URL(string: "https://tailscale.com/download")

    // MARK: Derived

    private var selfNode: PeerStatus? { store.status?.selfNode }
    private var needsLogin: Bool { store.backendState == .needsLogin }
    private var loginURL: URL? { store.authURL }
    private var peers: [PeerStatus] { store.status.map { Array($0.peers.values) } ?? [] }

    // MARK: Body

    var body: some View {
        PageScroll {
            PageHeader("Overview", subtitle: store.tailnetName.map { "Tailnet \($0)" } ?? "Your Tailscale connection at a glance",
                       systemImage: "gauge.with.dots.needle.33percent")
            if !store.cliAvailable {
                notInstalledCard
            } else if store.status == nil {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
                    .padding(.vertical, 20)
            } else {
                if needsLogin || loginURL != nil { loginCard }
                connectionCard
                if !(store.status?.health ?? []).isEmpty { healthCard }
                summaryTiles
                accountsCard
            }
        }
        .sheet(isPresented: $showConnectSheet) {
            OverviewConnectSheet()
        }
        .task {
            // `--show=connect-options` (documentation screenshots): open the sheet once the status is loaded.
            guard LaunchOptions.consumeShow("connect-options") else { return }
            for _ in 0..<50 where store.status == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            showConnectSheet = true
        }
    }

    // MARK: Not installed

    private var notInstalledCard: some View {
        SectionCard {
            EmptyStateView("Tailscale not found", systemImage: "exclamationmark.triangle",
                           message: "This app needs the Tailscale command-line tool. Install Tailscale, or choose a custom path to the tool in the app's Settings (⌘,).",
                           actionTitle: "Download Tailscale") {
                if let url = Self.downloadURL { NSWorkspace.shared.open(url) }
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Open Settings…") { Self.openSettings() }
                Button("Check Again") { Task { await store.refreshAll() } }
                Spacer()
            }
        }
    }

    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    // MARK: Login

    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(needsLogin ? "Log in to Tailscale" : "Finish signing in", systemImage: "person.badge.key")
                .font(.headline)
            Text(loginURL == nil
                 ? "This device is not logged in. Choose “Log in…” to get a sign-in link."
                 : "Open the login page in your browser to finish signing in. This page updates when you are done.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                if let url = loginURL {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open login page", systemImage: "safari") }
                        .buttonStyle(.borderedProminent)
                    CopyButton(text: url.absoluteString, title: "Copy link")
                }
                Button { startLogin() } label: { Label("Log in…", systemImage: "arrow.right.circle") }
                    .disabled(store.isBusy)
                if store.isBusy { ProgressView().controlSize(.small) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.yellow.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.5)))
    }

    /// `tailscale login` blocks until sign-in completes, so it is run with a short timeout: the login URL is
    /// printed first and picked up by the store.
    private func startLogin(options: UpOptions = UpOptions()) {
        Task { await runConnectionCommand(PrefsCommands.loginArgs(options: options), timeout: 20) }
    }

    /// Run a connection command; a timeout is expected for flows that wait for browser sign-in.
    @MainActor
    private func runConnectionCommand(_ args: [String], timeout: TimeInterval) async {
        store.pendingAuthURL = nil
        await store.runTailscale(args, timeout: timeout)
    }

    // MARK: Connection card

    private var connectionCard: some View {
        SectionCard {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: store.isRunning ? "lock.shield.fill" : "lock.slash")
                    .font(.system(size: 34))
                    .foregroundStyle(store.backendState.color)
                    .frame(width: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(selfNode?.displayName ?? "This device").font(.title2.weight(.semibold))
                    StatusBadge(state: store.backendState)
                }
                Spacer()
                if store.isBusy { ProgressView().controlSize(.small) }
                connectButtons
            }
            Divider()
            detailRows
            Divider()
            HStack {
                Button { showConnectSheet = true } label: { Label("Connect with options…", systemImage: "slider.horizontal.3") }
                    .disabled(store.isBusy)
                Button { runReauth() } label: { Label("Re-authenticate", systemImage: "key") }
                    .disabled(store.isBusy)
                    .help("Runs “tailscale up --force-reauth” and opens a new sign-in flow.")
                Spacer()
                ConfirmButton("Log out", systemImage: "rectangle.portrait.and.arrow.right",
                              message: "Log out of Tailscale? This device will leave the tailnet and needs to sign in again.",
                              confirmTitle: "Log Out") {
                    Task { await runConnectionCommand(PrefsCommands.logoutArgs(), timeout: 30) }
                }
                .disabled(store.isBusy)
            }
        }
    }

    @ViewBuilder
    private var connectButtons: some View {
        switch store.backendState {
        case .running:
            Button { Task { await store.disconnect() } } label: {
                Label("Disconnect", systemImage: "power").frame(minWidth: 90)
            }
            .controlSize(.large)
            .disabled(store.isBusy)
            .keyboardShortcut(.defaultAction)
        case .needsLogin:
            Button { startLogin() } label: {
                Label("Log in…", systemImage: "arrow.right.circle").frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.isBusy)
        default:
            Button { Task { await runConnect() } } label: {
                Label("Connect", systemImage: "power").frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.isBusy || store.backendState == .starting)
            .keyboardShortcut(.defaultAction)
        }
    }

    @MainActor
    private func runConnect() async {
        await store.connect()
    }

    private func runReauth() {
        var options = UpOptions()
        options.forceReauth = true
        Task { await runConnectionCommand(PrefsCommands.upArgs(options: options), timeout: 30) }
    }

    // MARK: Details

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let dns = store.selfDNSName {
                OverviewInfoRow("MagicDNS name") { Text(dns).textSelection(.enabled); CopyButton(text: dns) }
            }
            let ips = selfNode?.tailscaleIPs.isEmpty == false ? (selfNode?.tailscaleIPs ?? []) : (store.status?.tailscaleIPs ?? [])
            if !ips.isEmpty {
                OverviewInfoRow("Tailscale IPs") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(ips, id: \.self) { ip in
                            HStack(spacing: 6) {
                                Text(ip).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                CopyButton(text: ip)
                            }
                        }
                    }
                }
            }
            if let tailnet = store.tailnetName { OverviewInfoRow("Tailnet") { Text(tailnet).textSelection(.enabled) } }
            if let user = userDescription { OverviewInfoRow("User") { Text(user).textSelection(.enabled) } }
            OverviewInfoRow("Version") { Text(versionText).textSelection(.enabled) }
            OverviewInfoRow("Key expiry") { keyExpiryView }
            if let relay = selfNode?.relay, !relay.isEmpty {
                OverviewInfoRow("Relay region") { Text(relay.uppercased()).textSelection(.enabled) }
            }
        }
    }

    private var userDescription: String? {
        guard let status = store.status, let node = status.selfNode, let user = status.user(for: node) else { return nil }
        if user.displayName.isEmpty { return user.loginName.isEmpty ? nil : user.loginName }
        return user.loginName.isEmpty ? user.displayName : "\(user.displayName) (\(user.loginName))"
    }

    private var versionText: String {
        let client = store.version?.client ?? ""
        let daemon = store.version?.daemon ?? store.status?.version ?? ""
        switch (client.isEmpty, daemon.isEmpty) {
        case (false, false) where client != daemon: return "Client \(client) · Daemon \(daemon)"
        case (false, _): return client
        case (true, false): return "Daemon \(daemon)"
        default: return "—"
        }
    }

    @ViewBuilder
    private var keyExpiryView: some View {
        if let expiry = selfNode?.keyExpiry {
            let expired = expiry < Date() || selfNode?.expired == true
            let soon = !expired && expiry.timeIntervalSinceNow < 14 * 86_400
            HStack(spacing: 6) {
                if expired || soon {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(expired ? .red : .orange)
                        .accessibilityHidden(true)
                }
                Text(expired ? "Expired \(Fmt.relative(expiry)) (\(Fmt.dateTime(expiry)))" : "\(Fmt.relative(expiry)) (\(Fmt.dateTime(expiry)))")
                    .foregroundStyle(expired ? Color.red : (soon ? Color.orange : Color.primary))
                    .textSelection(.enabled)
            }
        } else if selfNode?.expired == true {
            Label("Expired", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        } else {
            Text("No expiry")
        }
    }

    // MARK: Health

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array((store.status?.health ?? []).enumerated()), id: \.offset) { _, message in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).accessibilityHidden(true)
                    Text(message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow.opacity(0.45)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Health warnings: " + (store.status?.health ?? []).joined(separator: ". "))
    }

    // MARK: Summary tiles

    private var summaryTiles: some View {
        let online = peers.filter(\.online).count
        let exitName = store.status?.activeExitNode?.displayName
        return HStack(spacing: 12) {
            SummaryTile(title: "Devices", value: "\(online) of \(peers.count)", caption: "online", systemImage: "laptopcomputer.and.iphone") {
                SidebarSection.devices.navigate()
            }
            SummaryTile(title: "Serve routes", value: "\(store.serveRules.count)", caption: store.serveRules.count == 1 ? "active route" : "active routes",
                        systemImage: "arrow.triangle.branch") {
                SidebarSection.serve.navigate()
            }
            SummaryTile(title: "Exit node", value: exitName ?? "None", caption: exitName == nil ? "direct internet" : "in use",
                        systemImage: "arrow.up.right.circle") {
                SidebarSection.exitNodes.navigate()
            }
        }
    }

    // MARK: Accounts

    private var accountsCard: some View {
        SectionCard("Accounts", subtitle: "Switch between tailnets without logging out.", systemImage: "person.2") {
            if store.profiles.isEmpty {
                Text("No accounts found.").font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, profile in
                    if index > 0 { Divider() }
                    HStack(spacing: 10) {
                        Image(systemName: profile.selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(profile.selected ? Color.accentColor : Color.secondary)
                            .accessibilityLabel(profile.selected ? "Current account" : "Other account")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.title).fontWeight(profile.selected ? .semibold : .regular)
                            if !profile.account.isEmpty && profile.account != profile.title {
                                Text(profile.account).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if profile.selected {
                            Text("Current").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Switch") {
                                Task { await store.runTailscale(PrefsCommands.switchArgs(profileID: profile.id), timeout: 30) }
                            }
                            .disabled(store.isBusy)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            HStack {
                ConfirmButton("Add account…", systemImage: "plus",
                              message: "Add another account? This starts a new sign-in flow and switches to the new account.",
                              confirmTitle: "Add Account", role: nil) {
                    startLogin()
                }
                .disabled(store.isBusy)
                Spacer()
            }
        }
    }
}

// MARK: - Pieces

/// Label column plus arbitrary content, for the detail list of the connection card.
private struct OverviewInfoRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

/// Clickable count tile that jumps to another section.
private struct SummaryTile: View {
    var title: String
    var value: String
    var caption: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: systemImage).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(title)")
    }
}
