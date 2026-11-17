import AppKit
import SwiftUI

// MARK: - Row model

/// One machine of the tailnet as shown in the Devices table. Sort keys are plain comparable values.
struct DevicesRow: Identifiable, Hashable {
    let id: String
    let peer: PeerStatus
    let isSelf: Bool
    let owner: String

    init(peer: PeerStatus, isSelf: Bool, owner: String) {
        let base = peer.publicKey.isEmpty ? (peer.id.isEmpty ? peer.dnsName : peer.id) : peer.publicKey
        self.id = (isSelf ? "self-" : "peer-") + base
        self.peer = peer
        self.isSelf = isSelf
        self.owner = owner
    }

    var name: String { peer.displayName }
    var sortName: String { name.lowercased() }
    var onlineRank: Int { peer.online ? 0 : 1 }
    var os: String { peer.os }
    var ip: String { peer.primaryIP ?? "" }
    var lastSeenSort: Date { isSelf || peer.online ? .distantFuture : (peer.lastSeen ?? .distantPast) }
    var tagsText: String { peer.tags.map { $0.hasPrefix("tag:") ? String($0.dropFirst(4)) : $0 }.joined(separator: ", ") }

    /// "Direct · 203.0.113.5:41641", "Relay · fra", or an em dash when there is no traffic path yet.
    var connection: String {
        if isSelf { return "This device" }
        if !peer.online { return "—" }
        if !peer.curAddr.isEmpty { return "Direct · \(peer.curAddr)" }
        if !peer.relay.isEmpty { return "Relay · \(peer.relay)" }
        return "Idle"
    }

    /// Online state with the traffic path, for the table: "Online · Direct", "Online · Relay fra", "Offline".
    var statusText: String {
        if peer.expired { return "Key expired" }
        if !peer.online { return "Offline" }
        if isSelf { return "Online" }
        if !peer.curAddr.isEmpty { return "Online · Direct" }
        if !peer.relay.isEmpty { return "Online · Relay \(peer.relay)" }
        return "Online · Idle"
    }

    /// Host used for SSH, Taildrop and the browser: MagicDNS name, else the first IP.
    var host: String {
        let dns = peer.dnsNameTrimmed
        return dns.isEmpty ? (peer.primaryIP ?? peer.hostName) : dns
    }

    /// Subnet routes this node advertises (its own addresses are left out).
    var routes: [String] {
        let own = Set(peer.tailscaleIPs.flatMap { [$0 + "/32", $0 + "/128", $0] })
        var seen = Set<String>(), out: [String] = []
        for route in peer.primaryRoutes + peer.allowedIPs where !own.contains(route) && seen.insert(route).inserted {
            out.append(route)
        }
        return out
    }
}

enum DevicesFilter: String, CaseIterable, Identifiable {
    case all = "All", online = "Online", offline = "Offline", exitNodes = "Exit nodes", shared = "Shared in"
    var id: String { rawValue }

    func matches(_ row: DevicesRow) -> Bool {
        switch self {
        case .all: return true
        case .online: return row.peer.online
        case .offline: return !row.peer.online
        case .exitNodes: return row.peer.exitNodeOption
        case .shared: return row.peer.shareeNode
        }
    }
}

/// What the inspector's console currently shows.
enum DevicesConsoleKind: Equatable {
    case ping, whois, send
    var title: String {
        switch self {
        case .ping: return "Ping"
        case .whois: return "Whois"
        case .send: return "Send files"
        }
    }
}

// MARK: - Inspector

/// Detail pane for the selected device: facts, copyable addresses, actions and an inline console.
struct DevicesInspector: View {
    let row: DevicesRow
    let consoleKind: DevicesConsoleKind?
    let consoleText: String
    let isPinging: Bool
    let busy: Bool
    var onClose: () -> Void
    var onPing: () -> Void
    var onStopPing: () -> Void
    var onWhois: () -> Void
    var onSend: () -> Void
    var onClearConsole: () -> Void

    private var peer: PeerStatus { row.peer }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    StatusDot(online: peer.online, size: 11)
                    Text(row.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                    if row.isSelf { badge("This device") }
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Close details")
                        .accessibilityLabel("Close details")
                }
                KeyValueRow("Status", statusText)
                KeyValueRow("MagicDNS name", peer.dnsNameTrimmed, copyable: true)
                KeyValueRow("Operating system", peer.os)
                KeyValueRow("Owner", row.owner)
                if !peer.tags.isEmpty { KeyValueRow("Tags", peer.tags.joined(separator: ", ")) }
            }

            Section("Addresses") {
                if peer.tailscaleIPs.isEmpty {
                    Text("No Tailscale address").foregroundStyle(.secondary)
                }
                ForEach(peer.tailscaleIPs, id: \.self) { ip in
                    KeyValueRow(ip.contains(":") ? "IPv6" : "IPv4", ip, monospaced: true, copyable: true)
                }
            }

            Section("Connection") {
                KeyValueRow("Route", row.connection)
                KeyValueRow("Last seen", peer.online ? "Now" : Fmt.relative(peer.lastSeen))
                KeyValueRow("Last handshake", Fmt.relative(peer.lastHandshake))
                KeyValueRow("Received", Fmt.bytes(peer.rxBytes))
                KeyValueRow("Sent", Fmt.bytes(peer.txBytes))
                KeyValueRow("Created", Fmt.dateTime(peer.created))
                KeyValueRow("Key expiry", expiryText)
            }

            Section("Capabilities") {
                KeyValueRow("Exit node", exitNodeText)
                KeyValueRow("Taildrop", taildropText)
                if row.routes.isEmpty {
                    KeyValueRow("Advertised routes", "None")
                } else {
                    LabeledContent("Advertised routes") {
                        Text(row.routes.joined(separator: "\n"))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            Section("Actions") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if isPinging {
                            Button(action: onStopPing) { Label("Stop", systemImage: "stop.fill") }
                        } else {
                            Button(action: onPing) { Label("Ping", systemImage: "dot.radiowaves.left.and.right") }
                                .disabled(row.isSelf || peer.primaryIP == nil)
                        }
                        Button(action: onWhois) { Label("Whois", systemImage: "person.text.rectangle") }
                            .disabled(peer.primaryIP == nil || busy)
                        Button(action: onSend) { Label("Send file…", systemImage: "paperplane") }
                            .disabled(!peer.canReceiveFiles || row.isSelf || busy)
                            .help(peer.canReceiveFiles ? "Send files with Taildrop" : "This device can't receive Taildrop files")
                    }
                    HStack(spacing: 8) {
                        Menu {
                            Button("Copy “tailscale ssh \(row.host)”") { Clipboard.copy("tailscale ssh " + CommandRunner.shellQuote(row.host)) }
                            Button("Copy “ssh \(row.host)”") { Clipboard.copy("ssh " + CommandRunner.shellQuote(row.host)) }
                        } label: { Label("SSH", systemImage: "terminal") }
                            .fixedSize()
                        Button {
                            if let url = URL(string: "http://" + row.host) { NSWorkspace.shared.open(url) }
                        } label: { Label("Open in Browser", systemImage: "safari") }
                            .disabled(row.host.isEmpty)
                    }
                }
                .buttonStyle(.bordered)
                if !peer.canReceiveFiles && !row.isSelf {
                    Text(peer.noFileSharingReason.isEmpty ? "Taildrop isn't available for this device." : peer.noFileSharingReason)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let consoleKind {
                Section {
                    OutputConsole(text: consoleText, minHeight: 150, autoScroll: true)
                        .frame(height: 190)
                    HStack {
                        if isPinging { ProgressView().controlSize(.small) }
                        Spacer()
                        CopyButton(text: consoleText, title: "Copy")
                        Button("Clear", action: onClearConsole).disabled(isPinging)
                    }
                } header: {
                    Text(consoleKind.title + " · " + row.name)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            .foregroundStyle(Color.accentColor)
    }

    private var statusText: String {
        if peer.expired { return "Key expired" }
        if peer.online { return peer.active ? "Online, active" : "Online" }
        return "Offline"
    }

    private var expiryText: String {
        guard let expiry = peer.keyExpiry else { return peer.expired ? "Expired" : "No expiry" }
        let text = Fmt.dateTime(expiry)
        return expiry < Date() ? "Expired (\(text))" : "\(text) (\(Fmt.relative(expiry)))"
    }

    private var exitNodeText: String {
        if peer.exitNode { return "In use as your exit node" }
        return peer.exitNodeOption ? "Offers to be an exit node" : "Not offered"
    }

    private var taildropText: String {
        if row.isSelf { return "—" }
        return peer.canReceiveFiles ? "Can receive files" : "Not available"
    }
}
