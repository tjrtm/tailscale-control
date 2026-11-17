import Foundation

/// One preference change for `tailscale set`. Booleans become `--flag=true|false`, strings `--flag=value`.
/// An empty string clears string preferences (for example `.exitNode("")` stops using an exit node).
enum PrefChange: Hashable, Sendable {
    case acceptDNS(Bool)
    case acceptRoutes(Bool)
    case advertiseConnector(Bool)
    case advertiseExitNode(Bool)
    /// CIDR routes; an empty array stops advertising routes.
    case advertiseRoutes([String])
    case autoUpdate(Bool)
    /// IP, base name or `auto:any`; empty to clear.
    case exitNode(String)
    case exitNodeAllowLANAccess(Bool)
    case hostname(String)
    case nickname(String)
    case operatorUser(String)
    /// UDP port (`0` = random); empty disables the relay server.
    case relayServerPort(String)
    /// `IP:port` endpoints; an empty array clears them.
    case relayServerStaticEndpoints([String])
    case reportPosture(Bool)
    case shieldsUp(Bool)
    case ssh(Bool)
    case updateCheck(Bool)
    case webclient(Bool)

    /// Flag name without dashes, identical to the key in `tailscale get --json`.
    var name: String {
        switch self {
        case .acceptDNS: return "accept-dns"
        case .acceptRoutes: return "accept-routes"
        case .advertiseConnector: return "advertise-connector"
        case .advertiseExitNode: return "advertise-exit-node"
        case .advertiseRoutes: return "advertise-routes"
        case .autoUpdate: return "auto-update"
        case .exitNode: return "exit-node"
        case .exitNodeAllowLANAccess: return "exit-node-allow-lan-access"
        case .hostname: return "hostname"
        case .nickname: return "nickname"
        case .operatorUser: return "operator"
        case .relayServerPort: return "relay-server-port"
        case .relayServerStaticEndpoints: return "relay-server-static-endpoints"
        case .reportPosture: return "report-posture"
        case .shieldsUp: return "shields-up"
        case .ssh: return "ssh"
        case .updateCheck: return "update-check"
        case .webclient: return "webclient"
        }
    }

    /// The flag with its value, e.g. `--ssh=true`.
    var argument: String {
        let value: String
        switch self {
        case .acceptDNS(let b), .acceptRoutes(let b), .advertiseConnector(let b), .advertiseExitNode(let b),
             .autoUpdate(let b), .exitNodeAllowLANAccess(let b), .reportPosture(let b), .shieldsUp(let b),
             .ssh(let b), .updateCheck(let b), .webclient(let b):
            value = b ? "true" : "false"
        case .exitNode(let s), .hostname(let s), .nickname(let s), .operatorUser(let s), .relayServerPort(let s):
            value = s
        case .advertiseRoutes(let list), .relayServerStaticEndpoints(let list):
            value = list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ",")
        }
        return "--\(name)=\(value)"
    }
}

/// Options for `tailscale up` / `tailscale login`. `nil` means "do not pass the flag".
///
/// Note: `tailscale up` with any setting flag requires the *complete* set of desired settings, unless `reset` is true.
struct UpOptions: Hashable, Sendable {
    var acceptDNS: Bool?
    var acceptRisk: [String] = []          // lose-ssh, mac-app-connector, all
    var acceptRoutes: Bool?
    var advertiseConnector: Bool?
    var advertiseExitNode: Bool?
    var advertiseRoutes: [String]?
    var advertiseTags: [String]?           // "tag:" prefix optional
    var audience: String?
    /// Secret; masked in logs. May be `file:/path`.
    var authKey: String?
    var clientID: String?
    /// Secret; masked in logs.
    var clientSecret: String?
    var exitNode: String?
    var exitNodeAllowLANAccess: Bool?
    var forceReauth: Bool?
    var hostname: String?
    /// Secret; masked in logs.
    var idToken: String?
    var json: Bool?
    var loginServer: String?
    var nickname: String?                  // login only
    var operatorUser: String?
    var qr: Bool?
    var qrFormat: String?                  // auto, ascii, large, small
    var reportPosture: Bool?
    var reset: Bool?
    var shieldsUp: Bool?
    var ssh: Bool?
    /// Maximum seconds to wait for the Running state (flag value like `30s`).
    var timeout: TimeInterval?

    init() {}
}

/// Pure builders for connection and preference commands. All return sub-arguments (after the binary).
enum PrefsCommands {
    /// `set` with the given changes, in order, e.g. `["set","--ssh=true"]`.
    /// - Parameter acceptRisk: values for `--accept-risk` (`lose-ssh`, `mac-app-connector`, `all`).
    static func setArgs(_ changes: [PrefChange], acceptRisk: [String] = []) -> [String] {
        var args = ["set"] + changes.map(\.argument)
        if !acceptRisk.isEmpty { args.append("--accept-risk=\(acceptRisk.joined(separator: ","))") }
        return args
    }

    /// `set --exit-node=<node>` (optionally with `--exit-node-allow-lan-access`). Pass `nil`/empty to stop using one.
    static func exitNodeArgs(_ node: String?, allowLAN: Bool? = nil) -> [String] {
        var changes: [PrefChange] = [.exitNode(node ?? "")]
        if let allowLAN { changes.append(.exitNodeAllowLANAccess(allowLAN)) }
        return setArgs(changes)
    }

    /// `set --exit-node=` — stop using an exit node.
    static func clearExitNodeArgs() -> [String] { exitNodeArgs(nil) }

    /// Changes needed to go from `old` to `new` (only differing fields), in a stable order.
    static func changes(from old: TailscalePrefs, to new: TailscalePrefs) -> [PrefChange] {
        var out: [PrefChange] = []
        if old.acceptDNS != new.acceptDNS { out.append(.acceptDNS(new.acceptDNS)) }
        if old.acceptRoutes != new.acceptRoutes { out.append(.acceptRoutes(new.acceptRoutes)) }
        if old.advertiseConnector != new.advertiseConnector { out.append(.advertiseConnector(new.advertiseConnector)) }
        if old.advertiseExitNode != new.advertiseExitNode { out.append(.advertiseExitNode(new.advertiseExitNode)) }
        if old.advertiseRoutes != new.advertiseRoutes { out.append(.advertiseRoutes(new.advertiseRoutes)) }
        if old.autoUpdate != new.autoUpdate { out.append(.autoUpdate(new.autoUpdate)) }
        if old.exitNode != new.exitNode { out.append(.exitNode(new.exitNode)) }
        if old.exitNodeAllowLANAccess != new.exitNodeAllowLANAccess { out.append(.exitNodeAllowLANAccess(new.exitNodeAllowLANAccess)) }
        if old.hostname != new.hostname { out.append(.hostname(new.hostname)) }
        if old.nickname != new.nickname { out.append(.nickname(new.nickname)) }
        if old.operatorUser != new.operatorUser { out.append(.operatorUser(new.operatorUser)) }
        if old.relayServerPort != new.relayServerPort { out.append(.relayServerPort(new.relayServerPort)) }
        if old.relayServerStaticEndpoints != new.relayServerStaticEndpoints { out.append(.relayServerStaticEndpoints(new.relayServerStaticEndpoints)) }
        if old.reportPosture != new.reportPosture { out.append(.reportPosture(new.reportPosture)) }
        if old.shieldsUp != new.shieldsUp { out.append(.shieldsUp(new.shieldsUp)) }
        if old.ssh != new.ssh { out.append(.ssh(new.ssh)) }
        if old.updateCheck != new.updateCheck { out.append(.updateCheck(new.updateCheck)) }
        if old.webclient != new.webclient { out.append(.webclient(new.webclient)) }
        return out
    }

    /// `up [flags]` from `options`.
    static func upArgs(options: UpOptions = UpOptions()) -> [String] { ["up"] + flags(for: options, includeNickname: false) }

    /// `login [flags]` from `options` (same flags as `up`, plus `--nickname`).
    static func loginArgs(options: UpOptions = UpOptions()) -> [String] { ["login"] + flags(for: options, includeNickname: true) }

    /// `down [--reason=...]`.
    static func downArgs(reason: String? = nil, acceptRisk: [String] = []) -> [String] {
        var args = ["down"]
        if let reason, !reason.isEmpty { args.append("--reason=\(reason)") }
        if !acceptRisk.isEmpty { args.append("--accept-risk=\(acceptRisk.joined(separator: ","))") }
        return args
    }

    /// `logout [--reason=...]` — expires this node's key; requires re-authentication.
    static func logoutArgs(reason: String? = nil) -> [String] {
        var args = ["logout"]
        if let reason, !reason.isEmpty { args.append("--reason=\(reason)") }
        return args
    }

    /// `switch <profileID>`.
    static func switchArgs(profileID: String) -> [String] { ["switch", profileID] }

    /// `switch --list --json` (read-only).
    static func switchListArgs() -> [String] { ["switch", "--list", "--json"] }

    /// First `https://` URL in some output (for example the login URL printed by `tailscale up`).
    static func authURL(in output: String) -> URL? {
        guard let range = output.range(of: #"https://[^\s"'<>]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(output[range]))
    }

    private static func flags(for o: UpOptions, includeNickname: Bool) -> [String] {
        var a: [String] = []
        func bool(_ name: String, _ v: Bool?) { if let v { a.append("--\(name)=\(v ? "true" : "false")") } }
        func str(_ name: String, _ v: String?) { if let v { a.append("--\(name)=\(v)") } }
        func list(_ name: String, _ v: [String]?) {
            if let v { a.append("--\(name)=\(v.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ","))") }
        }
        bool("accept-dns", o.acceptDNS)
        if !o.acceptRisk.isEmpty { a.append("--accept-risk=\(o.acceptRisk.joined(separator: ","))") }
        bool("accept-routes", o.acceptRoutes)
        bool("advertise-connector", o.advertiseConnector)
        bool("advertise-exit-node", o.advertiseExitNode)
        list("advertise-routes", o.advertiseRoutes)
        list("advertise-tags", o.advertiseTags)
        str("audience", o.audience)
        str("auth-key", o.authKey)
        str("client-id", o.clientID)
        str("client-secret", o.clientSecret)
        str("exit-node", o.exitNode)
        bool("exit-node-allow-lan-access", o.exitNodeAllowLANAccess)
        bool("force-reauth", o.forceReauth)
        str("hostname", o.hostname)
        str("id-token", o.idToken)
        bool("json", o.json)
        str("login-server", o.loginServer)
        if includeNickname { str("nickname", o.nickname) }
        str("operator", o.operatorUser)
        bool("qr", o.qr)
        str("qr-format", o.qrFormat)
        bool("report-posture", o.reportPosture)
        bool("reset", o.reset)
        bool("shields-up", o.shieldsUp)
        bool("ssh", o.ssh)
        if let t = o.timeout { a.append("--timeout=\(Int(t))s") }
        return a
    }
}
