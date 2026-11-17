import Foundation

// MARK: - Lenient decoding helpers

/// Any JSON value. Used to read `tailscale get --json` leniently and to keep unknown data.
enum JSONValue: Decodable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    /// String form of a scalar (numbers without a trailing `.0`); arrays are joined with commas; `nil` for null/objects.
    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .array(let a): return a.compactMap { $0.stringValue }.joined(separator: ",")
        case .null, .object: return nil
        }
    }

    /// Bool form: real booleans, the strings "true"/"false", and non-zero numbers.
    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s):
            switch s.lowercased() { case "true", "1", "yes", "on": return true; case "false", "0", "no", "off", "": return false; default: return nil }
        case .number(let n): return n != 0
        default: return nil
        }
    }

    /// Int form of numbers and numeric strings.
    var intValue: Int? {
        switch self {
        case .number(let n): return Int(exactly: n.rounded())
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
}

/// Decodes `T` but yields `nil` instead of throwing, so one bad element does not fail a whole collection.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    /// Decode `key` as `T`, returning nil when missing, null, or of the wrong type.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
    func lenientJSON(_ key: Key) -> JSONValue? { lenient(JSONValue.self, key) }
    func lenientString(_ key: Key) -> String? { lenientJSON(key)?.stringValue }
    func lenientBool(_ key: Key) -> Bool? { lenientJSON(key)?.boolValue }
    func lenientInt(_ key: Key) -> Int? { lenientJSON(key)?.intValue }
    func lenientStrings(_ key: Key) -> [String] {
        guard let v = lenientJSON(key) else { return [] }
        if case .array(let a) = v { return a.compactMap { $0.stringValue } }
        if let s = v.stringValue, !s.isEmpty { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        return []
    }
    /// Decode a JSON object into a dictionary, dropping entries whose values fail to decode.
    func lenientDictionary<T: Decodable>(_ type: T.Type, _ key: Key) -> [String: T] {
        guard let raw = lenient([String: Lossy<T>].self, key) else { return [:] }
        return raw.compactMapValues { $0.value }
    }
}

/// Parses Tailscale's RFC 3339 timestamps. The zero time (`0001-01-01T00:00:00Z`) maps to nil.
enum TSDate {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty, !s.hasPrefix("0001-") else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }
}

// MARK: - Backend state

/// `BackendState` from `tailscale status --json`.
enum BackendState: String, Hashable, Sendable {
    case running = "Running"
    case stopped = "Stopped"
    case needsLogin = "NeedsLogin"
    case needsMachineAuth = "NeedsMachineAuth"
    case starting = "Starting"
    case noState = "NoState"
    case unknown = "Unknown"

    /// Short label for UI.
    var title: String {
        switch self {
        case .running: return "Connected"
        case .stopped: return "Disconnected"
        case .needsLogin: return "Login required"
        case .needsMachineAuth: return "Awaiting approval"
        case .starting: return "Starting"
        case .noState: return "No state"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Status

/// One node in the tailnet (this device's `Self` or an entry of `Peer`).
struct PeerStatus: Decodable, Hashable, Identifiable, Sendable {
    var id: String = ""
    var nodeID: Int?
    var publicKey: String = ""
    var hostName: String = ""
    /// Fully qualified MagicDNS name, usually with a trailing dot.
    var dnsName: String = ""
    var os: String = ""
    var userID: Int?
    var tailscaleIPs: [String] = []
    var allowedIPs: [String] = []
    var curAddr: String = ""
    /// DERP region code (e.g. `fra`) or empty.
    var relay: String = ""
    var rxBytes: Int = 0
    var txBytes: Int = 0
    var created: Date?
    var lastSeen: Date?
    var lastHandshake: Date?
    var online: Bool = false
    /// True when this node is the exit node currently in use.
    var exitNode: Bool = false
    /// True when this node offers to be an exit node.
    var exitNodeOption: Bool = false
    var active: Bool = false
    var expired: Bool = false
    var keyExpiry: Date?
    var tags: [String] = []
    /// Subnet routes this node is primary for.
    var primaryRoutes: [String] = []
    var shareeNode: Bool = false
    /// 0 = no, 1 = yes, 2 = yes but different user (Taildrop).
    var taildropTarget: Int = 0
    var noFileSharingReason: String = ""
    var peerAPIURL: [String] = []
    var location: PeerLocation?

    enum CodingKeys: String, CodingKey {
        case id = "ID", nodeID = "NodeID", publicKey = "PublicKey", hostName = "HostName", dnsName = "DNSName", os = "OS"
        case userID = "UserID", tailscaleIPs = "TailscaleIPs", allowedIPs = "AllowedIPs", curAddr = "CurAddr", relay = "Relay"
        case rxBytes = "RxBytes", txBytes = "TxBytes", created = "Created", lastSeen = "LastSeen", lastHandshake = "LastHandshake"
        case online = "Online", exitNode = "ExitNode", exitNodeOption = "ExitNodeOption", active = "Active", expired = "Expired"
        case keyExpiry = "KeyExpiry", tags = "Tags", primaryRoutes = "PrimaryRoutes", shareeNode = "ShareeNode"
        case taildropTarget = "TaildropTarget", noFileSharingReason = "NoFileSharingReason", peerAPIURL = "PeerAPIURL", location = "Location"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientString(.id) ?? ""
        nodeID = c.lenientInt(.nodeID)
        publicKey = c.lenientString(.publicKey) ?? ""
        hostName = c.lenientString(.hostName) ?? ""
        dnsName = c.lenientString(.dnsName) ?? ""
        os = c.lenientString(.os) ?? ""
        userID = c.lenientInt(.userID)
        tailscaleIPs = c.lenientStrings(.tailscaleIPs)
        allowedIPs = c.lenientStrings(.allowedIPs)
        curAddr = c.lenientString(.curAddr) ?? ""
        relay = c.lenientString(.relay) ?? ""
        rxBytes = c.lenientInt(.rxBytes) ?? 0
        txBytes = c.lenientInt(.txBytes) ?? 0
        created = TSDate.parse(c.lenientString(.created))
        lastSeen = TSDate.parse(c.lenientString(.lastSeen))
        lastHandshake = TSDate.parse(c.lenientString(.lastHandshake))
        online = c.lenientBool(.online) ?? false
        exitNode = c.lenientBool(.exitNode) ?? false
        exitNodeOption = c.lenientBool(.exitNodeOption) ?? false
        active = c.lenientBool(.active) ?? false
        expired = c.lenientBool(.expired) ?? false
        keyExpiry = TSDate.parse(c.lenientString(.keyExpiry))
        tags = c.lenientStrings(.tags)
        primaryRoutes = c.lenientStrings(.primaryRoutes)
        shareeNode = c.lenientBool(.shareeNode) ?? false
        taildropTarget = c.lenientInt(.taildropTarget) ?? 0
        noFileSharingReason = c.lenientString(.noFileSharingReason) ?? ""
        peerAPIURL = c.lenientStrings(.peerAPIURL)
        location = c.lenient(PeerLocation.self, .location)
    }

    /// DNS name without the trailing dot.
    var dnsNameTrimmed: String { dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName }
    /// Best display name: host name, else first DNS label, else the first IP.
    var displayName: String {
        if !hostName.isEmpty { return hostName }
        if let label = dnsNameTrimmed.split(separator: ".").first { return String(label) }
        return tailscaleIPs.first ?? id
    }
    /// First IPv4 Tailscale address, else the first address.
    var primaryIP: String? { tailscaleIPs.first { !$0.contains(":") } ?? tailscaleIPs.first }
    /// True when the node can receive Taildrop files from this device.
    var canReceiveFiles: Bool { taildropTarget == 1 && noFileSharingReason.isEmpty }
}

/// Geographic location of an exit node (Mullvad nodes and others that advertise it).
struct PeerLocation: Decodable, Hashable, Sendable {
    var country: String = ""
    var countryCode: String = ""
    var city: String = ""
    var cityCode: String = ""
    var priority: Int = 0
    enum CodingKeys: String, CodingKey {
        case country = "Country", countryCode = "CountryCode", city = "City", cityCode = "CityCode", priority = "Priority"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        country = c.lenientString(.country) ?? ""
        countryCode = c.lenientString(.countryCode) ?? ""
        city = c.lenientString(.city) ?? ""
        cityCode = c.lenientString(.cityCode) ?? ""
        priority = c.lenientInt(.priority) ?? 0
    }
}

/// A tailnet user from the `User` map.
struct TailscaleUser: Decodable, Hashable, Identifiable, Sendable {
    var id: Int = 0
    var loginName: String = ""
    var displayName: String = ""
    var profilePicURL: String = ""
    enum CodingKeys: String, CodingKey { case id = "ID", loginName = "LoginName", displayName = "DisplayName", profilePicURL = "ProfilePicURL" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt(.id) ?? 0
        loginName = c.lenientString(.loginName) ?? ""
        displayName = c.lenientString(.displayName) ?? ""
        profilePicURL = c.lenientString(.profilePicURL) ?? ""
    }
}

/// `CurrentTailnet` from status.
struct TailnetInfo: Decodable, Hashable, Sendable {
    var name: String = ""
    var magicDNSSuffix: String = ""
    var magicDNSEnabled: Bool = false
    enum CodingKeys: String, CodingKey { case name = "Name", magicDNSSuffix = "MagicDNSSuffix", magicDNSEnabled = "MagicDNSEnabled" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenientString(.name) ?? ""
        magicDNSSuffix = c.lenientString(.magicDNSSuffix) ?? ""
        magicDNSEnabled = c.lenientBool(.magicDNSEnabled) ?? false
    }
}

/// Parsed output of `tailscale status --json`. Every field is optional/defaulted; unknown keys are ignored.
struct TailscaleStatus: Decodable, Hashable, Sendable {
    var version: String = ""
    /// Raw backend state string (`Running`, `Stopped`, `NeedsLogin`, ...). See `state`.
    var backendState: String = ""
    /// Login URL when `backendState == "NeedsLogin"`.
    var authURL: String = ""
    var tailscaleIPs: [String] = []
    var selfNode: PeerStatus?
    var health: [String] = []
    var magicDNSSuffix: String = ""
    var currentTailnet: TailnetInfo?
    var certDomains: [String] = []
    /// Peers keyed by node public key.
    var peers: [String: PeerStatus] = [:]
    /// Users keyed by numeric user ID (as a string).
    var users: [String: TailscaleUser] = [:]

    enum CodingKeys: String, CodingKey {
        case version = "Version", backendState = "BackendState", authURL = "AuthURL", tailscaleIPs = "TailscaleIPs", selfNode = "Self"
        case health = "Health", magicDNSSuffix = "MagicDNSSuffix", currentTailnet = "CurrentTailnet", certDomains = "CertDomains"
        case peers = "Peer", users = "User"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lenientString(.version) ?? ""
        backendState = c.lenientString(.backendState) ?? ""
        authURL = c.lenientString(.authURL) ?? ""
        tailscaleIPs = c.lenientStrings(.tailscaleIPs)
        selfNode = c.lenient(PeerStatus.self, .selfNode)
        health = c.lenientStrings(.health)
        magicDNSSuffix = c.lenientString(.magicDNSSuffix) ?? ""
        currentTailnet = c.lenient(TailnetInfo.self, .currentTailnet)
        certDomains = c.lenientStrings(.certDomains)
        peers = c.lenientDictionary(PeerStatus.self, .peers)
        users = c.lenientDictionary(TailscaleUser.self, .users)
    }

    /// Typed backend state (`.unknown` for unrecognised strings, `.noState` for empty).
    var state: BackendState { backendState.isEmpty ? .noState : (BackendState(rawValue: backendState) ?? .unknown) }
    var isRunning: Bool { state == .running }

    /// Peers sorted online-first, then by display name.
    var sortedPeers: [PeerStatus] {
        peers.values.sorted {
            if $0.online != $1.online { return $0.online && !$1.online }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Peers that offer to be exit nodes, sorted by location then name.
    var exitNodeOptions: [PeerStatus] {
        peers.values.filter { $0.exitNodeOption }.sorted {
            let l = ($0.location?.country ?? "", $0.location?.city ?? "", $0.displayName)
            let r = ($1.location?.country ?? "", $1.location?.city ?? "", $1.displayName)
            return l < r
        }
    }

    /// The exit node currently in use, if any.
    var activeExitNode: PeerStatus? { peers.values.first { $0.exitNode } }

    /// The user record for a node, if the status contains it.
    func user(for peer: PeerStatus) -> TailscaleUser? { peer.userID.flatMap { users[String($0)] } }
}

// MARK: - Prefs

/// Parsed output of `tailscale get --json`. The keys match the `tailscale set` flag names.
/// Missing values fall back to `false` / empty.
struct TailscalePrefs: Decodable, Hashable, Sendable {
    var acceptDNS = false
    var acceptRoutes = false
    var advertiseConnector = false
    var advertiseExitNode = false
    /// CIDR routes; empty when none advertised.
    var advertiseRoutes: [String] = []
    var autoUpdate = false
    /// Exit node IP / name, or empty for none.
    var exitNode = ""
    var exitNodeAllowLANAccess = false
    var hostname = ""
    var nickname = ""
    /// Unix user allowed to operate tailscaled without sudo (flag `--operator`).
    var operatorUser = ""
    var relayServerPort = ""
    var relayServerStaticEndpoints: [String] = []
    var reportPosture = false
    var shieldsUp = false
    var ssh = false
    var updateCheck = false
    var webclient = false
    /// Every key/value exactly as returned (including keys this version does not model).
    var raw: [String: JSONValue] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        var all: [String: JSONValue] = [:]
        for key in c.allKeys { all[key.stringValue] = (try? c.decode(JSONValue.self, forKey: key)) ?? .null }
        raw = all
        func bool(_ k: String) -> Bool { all[k]?.boolValue ?? false }
        func string(_ k: String) -> String { all[k]?.stringValue ?? "" }
        func list(_ k: String) -> [String] {
            guard let v = all[k] else { return [] }
            if case .array(let a) = v { return a.compactMap { $0.stringValue } }
            return (v.stringValue ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        acceptDNS = bool("accept-dns"); acceptRoutes = bool("accept-routes")
        advertiseConnector = bool("advertise-connector"); advertiseExitNode = bool("advertise-exit-node")
        advertiseRoutes = list("advertise-routes"); autoUpdate = bool("auto-update")
        exitNode = string("exit-node"); exitNodeAllowLANAccess = bool("exit-node-allow-lan-access")
        hostname = string("hostname"); nickname = string("nickname"); operatorUser = string("operator")
        relayServerPort = string("relay-server-port"); relayServerStaticEndpoints = list("relay-server-static-endpoints")
        reportPosture = bool("report-posture"); shieldsUp = bool("shields-up"); ssh = bool("ssh")
        updateCheck = bool("update-check"); webclient = bool("webclient")
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

// MARK: - Profiles & version

/// One account from `tailscale switch --list`.
struct TailscaleProfile: Hashable, Identifiable, Sendable {
    /// Short ID accepted by `tailscale switch <id>`.
    var id: String
    var nickname: String = ""
    var tailnet: String = ""
    var account: String = ""
    /// True for the active account.
    var selected: Bool = false

    /// Name to show in lists.
    var title: String { tailnet.isEmpty ? (nickname.isEmpty ? id : nickname) : tailnet }

    /// Parses `tailscale switch --list --json`; falls back to the plain-text table
    /// (`ID  Tailnet  Account` with `*` marking the active account).
    static func parse(_ output: String) -> [TailscaleProfile] {
        if let data = output.data(using: .utf8), let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return TailscaleProfile(
                    id: id,
                    nickname: item["nickname"] as? String ?? "",
                    tailnet: item["tailnet"] as? String ?? "",
                    account: item["account"] as? String ?? "",
                    selected: item["selected"] as? Bool ?? false
                )
            }
        }
        var result: [TailscaleProfile] = []
        for (index, line) in output.split(whereSeparator: \.isNewline).enumerated() where index > 0 {
            let cols = line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard cols.count >= 2 else { continue }
            var account = cols.count > 2 ? cols[2] : ""
            let selected = account.hasSuffix("*")
            if selected { account.removeLast() }
            result.append(TailscaleProfile(id: cols[0], nickname: account, tailnet: cols[1], account: account, selected: selected))
        }
        return result
    }
}

/// Parsed `tailscale version` output.
struct TailscaleVersionInfo: Hashable, Sendable {
    /// Client version, e.g. `1.80.0`.
    var client: String
    /// Daemon version when it differs from the client.
    var daemon: String?
    /// Full command output.
    var raw: String

    static func parse(_ output: String) -> TailscaleVersionInfo {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let daemon = lines.first { $0.lowercased().hasPrefix("daemon version:") }
            .map { $0.dropFirst("daemon version:".count).trimmingCharacters(in: .whitespaces) }
        return TailscaleVersionInfo(client: lines.first ?? "", daemon: daemon, raw: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
