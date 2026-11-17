import AppKit
import SwiftUI

/// The tailnet's machines: a sortable table plus an inspector for the selected device.
struct DevicesView: View {
    @EnvironmentObject var store: AppStore

    @State private var search = ""
    @State private var filter: DevicesFilter = .all
    @State private var selection: String?
    @State private var sortOrder: [KeyPathComparator<DevicesRow>] = [
        KeyPathComparator(\DevicesRow.onlineRank), KeyPathComparator(\DevicesRow.sortName),
    ]

    @StateObject private var runner = ToolsStreamRunner()
    @State private var consoleKind: DevicesConsoleKind?
    /// Row id the console output belongs to; selecting a different row clears the console.
    @State private var consoleOwner: String?
    @State private var staticOutput = ""
    @State private var pendingSend: DevicesPendingSend?
    @State private var showSendConfirm = false

    // MARK: Data

    private var allRows: [DevicesRow] {
        guard let status = store.status else { return [] }
        func owner(_ peer: PeerStatus) -> String {
            guard let user = status.user(for: peer) else { return "" }
            return user.loginName.isEmpty ? user.displayName : user.loginName
        }
        var rows = status.sortedPeers.map { DevicesRow(peer: $0, isSelf: false, owner: owner($0)) }
        if let me = status.selfNode { rows.insert(DevicesRow(peer: me, isSelf: true, owner: owner(me)), at: 0) }
        return rows
    }

    private func visible(_ rows: [DevicesRow]) -> [DevicesRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = rows.filter { row in
            guard filter.matches(row) else { return false }
            if query.isEmpty { return true }
            let haystack = [row.name, row.peer.dnsNameTrimmed, row.os, row.owner, row.tagsText, row.peer.tailscaleIPs.joined(separator: " ")]
            return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return matching.sorted(using: sortOrder)
    }

    private var consoleText: String { consoleKind == .ping ? runner.output : staticOutput }

    // MARK: Body

    var body: some View {
        let rows = allRows
        let shown = visible(rows)
        let selected = rows.first { $0.id == selection }

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader("Devices", subtitle: subtitle(rows: rows, shown: shown), systemImage: "laptopcomputer.and.iphone")
                if store.status != nil && store.isRunning { controls }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
            Divider()
            content(rows: rows, shown: shown, selected: selected)
        }
        .onChange(of: selection) { newValue in
            if consoleOwner != newValue { resetConsole() }
        }
        .onDisappear { runner.cancel() }
        .confirmationDialog(sendTitle, isPresented: $showSendConfirm, titleVisibility: .visible, presenting: pendingSend) { pending in
            Button("Send") { send(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(sendMessage(pending))
        }
    }

    private func subtitle(rows: [DevicesRow], shown: [DevicesRow]) -> String {
        guard store.status != nil, store.isRunning else { return "Machines in your tailnet." }
        let online = rows.filter { $0.peer.online }.count
        let count = shown.count == rows.count ? "\(rows.count) devices" : "\(shown.count) of \(rows.count) devices"
        return "\(count) · \(online) online"
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name, address, owner, tag", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
            .frame(maxWidth: 260)

            Picker("Filter", selection: $filter) {
                ForEach(DevicesFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)

            Menu {
                Button("Online first, then name") { sortOrder = [KeyPathComparator(\DevicesRow.onlineRank), KeyPathComparator(\DevicesRow.sortName)] }
                Button("Name") { sortOrder = [KeyPathComparator(\DevicesRow.sortName)] }
                Button("Last seen, newest first") { sortOrder = [KeyPathComparator(\DevicesRow.lastSeenSort, order: .reverse)] }
                Button("Operating system") { sortOrder = [KeyPathComparator(\DevicesRow.os), KeyPathComparator(\DevicesRow.sortName)] }
                Button("Owner") { sortOrder = [KeyPathComparator(\DevicesRow.owner), KeyPathComparator(\DevicesRow.sortName)] }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .fixedSize()
            .help("Sort devices (you can also click a column header)")

            Spacer(minLength: 0)
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(rows: [DevicesRow], shown: [DevicesRow], selected: DevicesRow?) -> some View {
        if store.status == nil {
            if !store.cliAvailable {
                EmptyStateView("Tailscale not found", systemImage: "questionmark.circle",
                               message: "Install Tailscale, or set the path to the command-line tool in Settings.")
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading devices…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if !store.isRunning {
            stoppedState
        } else {
            HSplitView {
                tableArea(rows: rows, shown: shown)
                    .frame(minWidth: 400, idealWidth: 600)
                if let selected {
                    DevicesInspector(
                        row: selected,
                        consoleKind: consoleOwner == selected.id ? consoleKind : nil,
                        consoleText: consoleText,
                        isPinging: runner.isRunning,
                        busy: store.isBusy,
                        onClose: { selection = nil },
                        onPing: { startPing(selected) },
                        onStopPing: { runner.cancel() },
                        onWhois: { startWhois(selected) },
                        onSend: { chooseFiles(for: selected) },
                        onClearConsole: { resetConsole() }
                    )
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 480)
                }
            }
        }
    }

    @ViewBuilder
    private var stoppedState: some View {
        switch store.backendState {
        case .stopped:
            EmptyStateView("Tailscale is disconnected", systemImage: "bolt.slash",
                           message: "Connect to see the devices in your tailnet.",
                           actionTitle: "Connect") { Task { await store.connect() } }
        case .needsLogin:
            EmptyStateView("Sign-in required", systemImage: "person.crop.circle.badge.exclamationmark",
                           message: "Sign in to Tailscale to see your devices.")
        case .needsMachineAuth:
            EmptyStateView("Waiting for approval", systemImage: "hourglass",
                           message: "An admin needs to approve this device before the tailnet is visible.")
        default:
            EmptyStateView("Devices unavailable", systemImage: "laptopcomputer.slash",
                           message: "Tailscale is \(store.backendState.title.lowercased()). Devices appear once it is connected.")
        }
    }

    @ViewBuilder
    private func tableArea(rows: [DevicesRow], shown: [DevicesRow]) -> some View {
        if shown.isEmpty {
            EmptyStateView(rows.isEmpty ? "No devices" : "No matching devices", systemImage: "laptopcomputer.slash",
                           message: rows.isEmpty ? "No machines were reported by Tailscale." : "Change the search or filter to see more.",
                           actionTitle: rows.isEmpty ? nil : "Reset Filters") { search = ""; filter = .all }
        } else {
            Table(shown, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.sortName) { row in
                    HStack(spacing: 6) {
                        Text(row.name).fontWeight(row.isSelf ? .semibold : .regular).lineLimit(1)
                        if row.isSelf {
                            Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                                .help("This device").accessibilityLabel("This device")
                        }
                        if row.peer.exitNode {
                            Image(systemName: "arrow.up.right.circle.fill").foregroundStyle(.tint)
                                .help("Your exit node").accessibilityLabel("Current exit node")
                        }
                    }
                }
                .width(min: 100, ideal: 140)
                TableColumn("Status", value: \.onlineRank) { row in
                    HStack(spacing: 5) {
                        StatusDot(online: row.peer.online)
                        Text(row.statusText).foregroundStyle(row.peer.online ? .primary : .secondary).lineLimit(1)
                    }
                    .help(row.connection)
                }
                .width(min: 90, ideal: 125)
                TableColumn("OS", value: \.os) { row in Text(row.os.isEmpty ? "—" : row.os).lineLimit(1) }
                    .width(min: 50, ideal: 65)
                TableColumn("Tailscale IP", value: \.ip) { row in
                    Text(row.ip.isEmpty ? "—" : row.ip).font(.system(.body, design: .monospaced)).lineLimit(1)
                }
                .width(min: 90, ideal: 110)
                TableColumn("Last seen", value: \.lastSeenSort) { row in
                    Text(row.isSelf || row.peer.online ? "Now" : Fmt.relative(row.peer.lastSeen)).lineLimit(1)
                }
                .width(min: 70, ideal: 100)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let row = shown.first(where: { $0.id == id }) {
                    rowMenu(row)
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ row: DevicesRow) -> some View {
        if let ip = row.peer.primaryIP { Button("Copy IP Address") { Clipboard.copy(ip) } }
        if !row.peer.dnsNameTrimmed.isEmpty { Button("Copy MagicDNS Name") { Clipboard.copy(row.peer.dnsNameTrimmed) } }
        Divider()
        Button("Ping") { startPing(row) }.disabled(row.isSelf || row.peer.primaryIP == nil)
        Button("Whois") { startWhois(row) }.disabled(row.peer.primaryIP == nil || store.isBusy)
        Button("Send File…") { chooseFiles(for: row) }.disabled(!row.peer.canReceiveFiles || row.isSelf || store.isBusy)
        Divider()
        Button("Copy “tailscale ssh” Command") { Clipboard.copy("tailscale ssh " + CommandRunner.shellQuote(row.host)) }
        Button("Open in Browser") { if let url = URL(string: "http://" + row.host) { NSWorkspace.shared.open(url) } }
    }

    // MARK: Actions

    private func focus(_ row: DevicesRow, _ kind: DevicesConsoleKind) {
        runner.reset()
        staticOutput = ""
        selection = row.id
        consoleOwner = row.id
        consoleKind = kind
    }

    private func resetConsole() {
        runner.reset()
        consoleKind = nil
        consoleOwner = nil
        staticOutput = ""
    }

    private func startPing(_ row: DevicesRow) {
        guard let ip = row.peer.primaryIP else { return }
        focus(row, .ping)
        runner.start(["ping", ip], timeout: 90, store: store)
    }

    private func startWhois(_ row: DevicesRow) {
        guard let ip = row.peer.primaryIP else { return }
        focus(row, .whois)
        staticOutput = "Running…\n"
        Task {
            let result = await store.runTailscale(["whois", ip], refresh: .none, timeout: 20)
            guard consoleOwner == row.id, consoleKind == .whois else { return }
            if let result {
                staticOutput = result.succeeded ? result.combinedOutput : result.errorSummary
            } else {
                staticOutput = store.lastError ?? "Could not run tailscale."
            }
        }
    }

    private func chooseFiles(for row: DevicesRow) {
        let panel = NSOpenPanel()
        panel.title = "Send to \(row.name)"
        panel.prompt = "Choose"
        panel.message = "Choose the files to send with Taildrop."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        pendingSend = DevicesPendingSend(row: row, urls: panel.urls)
        showSendConfirm = true
    }

    private var sendTitle: String {
        guard let pending = pendingSend else { return "Send files?" }
        let n = pending.urls.count
        return "Send \(n) \(n == 1 ? "file" : "files") to \(pending.row.name)?"
    }

    private func sendMessage(_ pending: DevicesPendingSend) -> String {
        let names = pending.urls.prefix(5).map(\.lastPathComponent)
        let more = pending.urls.count > 5 ? "\n… and \(pending.urls.count - 5) more" : ""
        return names.joined(separator: "\n") + more + "\n\nThe files are sent end-to-end encrypted to the other device."
    }

    private func send(_ pending: DevicesPendingSend) {
        focus(pending.row, .send)
        staticOutput = "Sending…\n"
        let row = pending.row
        let count = pending.urls.count
        Task {
            let args = ["file", "cp"] + pending.urls.map(\.path) + [row.host + ":"]
            let result = await store.runTailscale(args, refresh: .none, timeout: 3600)
            guard consoleOwner == row.id, consoleKind == .send else { return }
            if let result {
                if result.succeeded {
                    let out = result.combinedOutput
                    staticOutput = out.isEmpty ? "Sent \(count) \(count == 1 ? "file" : "files") to \(row.name)." : out
                } else {
                    staticOutput = result.errorSummary
                }
            } else {
                staticOutput = store.lastError ?? "Could not run tailscale."
            }
        }
    }
}

struct DevicesPendingSend: Identifiable {
    let id = UUID()
    let row: DevicesRow
    let urls: [URL]
}
