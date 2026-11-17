import Foundation

/// Demo mode (`--demo`): the app shows built-in, entirely fictional data and never starts a process.
///
/// The switch lives at the CLI boundary: `TailscaleCLI.run`, `TailscaleCLI.stream`, `TailscaleCLI.resolveBinary` and
/// `DockerDiscovery` consult `DemoMode.backend` and answer from `DemoBackend` instead of running anything. Everything
/// above that (store, views, activity log) behaves exactly as with a real node.
enum DemoMode {
    /// Output of every simulated command that changes something (it is logged like a real command).
    static let notExecutedNote = "(demo — not executed)"

    /// The active backend; nil in normal operation.
    private(set) static var backend: DemoBackend?
    static var isEnabled: Bool { backend != nil }

    /// True when the process was launched with `--demo`.
    static var requestedOnCommandLine: Bool { CommandLine.arguments.contains("--demo") }

    /// Switch to demo data and block all process execution (`CommandRunner.executionDisabled`).
    static func enable() {
        backend = DemoBackend()
        CommandRunner.executionDisabled = true
    }

    /// Back to normal operation (used by the self-tests).
    static func disable() {
        backend = nil
        CommandRunner.executionDisabled = false
    }
}

/// In-memory fictional tailnet. Reads are answered with the same JSON/text the real CLI prints (so the normal parsers
/// are exercised); mutating commands change the in-memory state where that is trivial and are otherwise only logged.
final class DemoBackend: @unchecked Sendable {
    static let domainSuffix = "example.ts.net"
    static let selfName = "demo-macbook"
    static var selfDNSName: String { "\(selfName).\(domainSuffix)" }

    private let lock = NSLock()
    private var running = true
    private var selectedProfile = "demo1"
    private var prefs: [String: Any] = [
        "accept-dns": true, "accept-routes": false, "advertise-connector": false, "advertise-exit-node": false,
        "advertise-routes": [String](), "auto-update": true, "exit-node": "", "exit-node-allow-lan-access": false,
        "hostname": "", "nickname": "", "operator": "", "relay-server-port": "", "relay-server-static-endpoints": [String](),
        "report-posture": false, "shields-up": false, "ssh": true, "update-check": true, "webclient": false,
    ]
    private var rules: [ServeRule]

    /// Fictional containers for "From Docker…".
    let dockerTargets: [DockerTarget] = [
        DockerTarget(containerName: "demo-web", image: "nginx:alpine", hostPort: 8080, containerPort: "80/tcp"),
        DockerTarget(containerName: "demo-api", image: "ghcr.io/example/api:1.4", hostPort: 8081, containerPort: "8000/tcp"),
        DockerTarget(containerName: "demo-db", image: "postgres:16", hostPort: 5432, containerPort: "5432/tcp"),
    ]

    init() {
        let host = Self.selfDNSName
        rules = [
            ServeRule(mode: .https, port: 443, mountPath: "/", target: .proxy("http://127.0.0.1:3000"), funnel: true, host: host),
            ServeRule(mode: .https, port: 8443, mountPath: "/", target: .proxy("http://127.0.0.1:8080"), host: host),
            ServeRule(mode: .https, port: 8443, mountPath: "/api", target: .proxy("http://127.0.0.1:8081"), host: host),
            ServeRule(mode: .https, port: 8443, mountPath: "/docs", target: .path("/Users/me/Sites/docs"), host: host),
            ServeRule(mode: .http, port: 8050, mountPath: "/", target: .text("Hello from the demo tailnet"), host: host),
            ServeRule(mode: .tcp, port: 5432, mountPath: "/", target: .proxy("tcp://127.0.0.1:5432"), host: host),
            ServeRule(mode: .https, port: 443, mountPath: "/", target: .proxy("http://127.0.0.1:9000"),
                      service: "svc:web-demo", host: "web-demo.\(Self.domainSuffix)"),
        ]
    }

    // MARK: Entry points used by TailscaleCLI

    /// Answer `tailscale <subArgs>` without running anything.
    func run(_ subArgs: [String]) async -> CommandResult {
        let began = Date()
        let reply = respond(subArgs)
        if reply.mutating { try? await Task.sleep(nanoseconds: 150_000_000) }   // a visible "busy" moment
        return CommandResult(args: ["tailscale"] + subArgs, exitCode: 0, stdout: reply.output, stderr: "",
                             duration: Date().timeIntervalSince(began))
    }

    /// Simulated streaming command: output arrives over time on the main queue, like a real process.
    func stream(_ subArgs: [String], timeout: TimeInterval?, onOutput: @escaping (String) -> Void,
                onFinish: ((CommandResult) -> Void)?) -> CommandStream {
        let script = streamScript(subArgs)
        return DemoStream(args: ["tailscale"] + subArgs, script: script, timeout: timeout, onOutput: onOutput, onFinish: onFinish)
    }

    // MARK: Command interpretation

    private struct Reply { var output: String; var mutating: Bool }

    private func read(_ text: String) -> Reply { Reply(output: text, mutating: false) }
    /// A command that is only logged (and, where trivial, applied to the in-memory data by the caller).
    private func simulated() -> Reply { Reply(output: DemoMode.notExecutedNote, mutating: true) }

    private func respond(_ args: [String]) -> Reply {
        lock.lock(); defer { lock.unlock() }
        let json = args.contains("--json")
        let rest = Array(args.dropFirst())
        switch args.first ?? "" {
        case "status":
            return read(json ? statusJSON() : statusText())
        case "get":
            return read(json ? prefsJSON() : "")
        case "version":
            return read("1.80.2\n  tailscale commit: 0000000000000000000000000000000000000000\n  go version: go1.23.4")
        case "ip":
            if rest.contains("-6") { return read("fd7a:115c:a1e0::1") }
            if rest.contains("-4") { return read("100.64.0.1") }
            return read("100.64.0.1\nfd7a:115c:a1e0::1")
        case "whois":
            return read(whois(for: rest.last ?? ""))
        case "service" where rest.first == "list":
            let names = Set(rules.compactMap(\.service)).sorted()
            return read(names.isEmpty ? "" : "Service\tAddress\n" + names.enumerated().map { "\($1)\t100.100.0.\($0 + 1)" }.joined(separator: "\n"))
        case "exit-node" where rest.first == "suggest":
            return read("Suggested exit node: gateway-fra.\(Self.domainSuffix).")
        case "serve", "funnel":
            return rest.first == "status" ? read(json ? serveJSON() : serveText()) : applyServe(args)
        case "switch":
            if args.contains("--list") { return read(profilesJSON()) }
            if let id = rest.first(where: { !$0.hasPrefix("-") }) { selectedProfile = profiles.contains { $0.id == id } ? id : selectedProfile; return simulated() }
            return simulated()
        case "up":
            applyPrefFlags(rest); running = true
            return simulated()
        case "down":
            running = false
            return simulated()
        case "set":
            applyPrefFlags(rest)
            return simulated()
        default:
            return simulated()
        }
    }

    // MARK: Streaming scripts

    private func streamScript(_ args: [String]) -> [(delay: TimeInterval, text: String)] {
        switch args.first ?? "" {
        case "ping":
            let target = args.dropFirst().last(where: { !$0.hasPrefix("-") }) ?? "100.64.0.2"
            let info = peerTable().first { $0.ips.contains(target) || target.hasPrefix($0.name) || target == "\($0.name).\(Self.domainSuffix)" }
            let name = info?.name ?? target
            let ip = info?.ips.first ?? target
            let path = info.map { $0.relay.isEmpty ? "via \($0.curAddr)" : "via DERP(\($0.relay))" } ?? "via 203.0.113.9:41641"
            var lines: [(TimeInterval, String)] = [(0.05, "(demo — simulated output, no packets were sent)\n")]
            for (i, ms) in [31, 12, 11, 13].enumerated() {
                lines.append((i == 0 ? 0.4 : 0.6, "pong from \(name) (\(ip)) \(path) in \(ms)ms\n"))
            }
            return lines
        case "netcheck":
            return [(0.05, "(demo — simulated output, no probes were sent)\n"), (0.6, """

            Report:
            \t* Time: 2025-01-01T12:00:00Z
            \t* UDP: true
            \t* IPv4: yes, 203.0.113.9:41641
            \t* IPv6: no, but OS has support
            \t* MappingVariesByDestIP: false
            \t* PortMapping: UPnP, NAT-PMP
            \t* Nearest DERP: Frankfurt
            \t* DERP latency:
            \t\t- fra: 12.3ms  (Frankfurt)
            \t\t- ams: 17.9ms  (Amsterdam)
            \t\t- lhr: 24.6ms  (London)
            \t\t- nyc: 88.1ms  (New York City)

            """)]
        default:
            return [(0.15, respond(args).output + "\n")]
        }
    }

    // MARK: Fixture: peers, users, profiles

    private struct PeerInfo {
        let name: String, key: String, os: String, ips: [String]
        let online: Bool, lastSeenAgo: TimeInterval, curAddr: String, relay: String
        let user: Int, tags: [String], exitOption: Bool, routes: [String], taildrop: Int, rx: Int, tx: Int, createdDaysAgo: Double
    }

    private func peerTable() -> [PeerInfo] {
        [
            PeerInfo(name: "nas-01", key: "nodekey:6e61732d30310000000000000000000000000000000000000000000000000001", os: "linux",
                     ips: ["100.64.0.2", "fd7a:115c:a1e0::2"], online: true, lastSeenAgo: 30, curAddr: "198.51.100.20:41641", relay: "",
                     user: 1003, tags: ["tag:server"], exitOption: true, routes: ["192.168.50.0/24"], taildrop: 0,
                     rx: 48_302_113, tx: 9_120_550, createdDaysAgo: 210),
            PeerInfo(name: "gateway-fra", key: "nodekey:67617465776179000000000000000000000000000000000000000000000002", os: "linux",
                     ips: ["100.64.0.3", "fd7a:115c:a1e0::3"], online: true, lastSeenAgo: 20, curAddr: "", relay: "fra",
                     user: 1003, tags: ["tag:exit"], exitOption: true, routes: [], taildrop: 0,
                     rx: 1_204_552_901, tx: 310_882_004, createdDaysAgo: 95),
            PeerInfo(name: "iphone-demo", key: "nodekey:6970686f6e650000000000000000000000000000000000000000000000000003", os: "iOS",
                     ips: ["100.64.0.4", "fd7a:115c:a1e0::4"], online: true, lastSeenAgo: 5, curAddr: "203.0.113.45:52311", relay: "",
                     user: 1001, tags: [], exitOption: false, routes: [], taildrop: 1,
                     rx: 2_551_044, tx: 1_870_231, createdDaysAgo: 400),
            PeerInfo(name: "win-desktop", key: "nodekey:77696e0000000000000000000000000000000000000000000000000000000004", os: "windows",
                     ips: ["100.64.0.5", "fd7a:115c:a1e0::5"], online: false, lastSeenAgo: 3 * 3600, curAddr: "", relay: "",
                     user: 1002, tags: [], exitOption: false, routes: [], taildrop: 1,
                     rx: 802_113_440, tx: 95_311_002, createdDaysAgo: 330),
            PeerInfo(name: "pi-garage", key: "nodekey:7069000000000000000000000000000000000000000000000000000000000005", os: "linux",
                     ips: ["100.64.0.6", "fd7a:115c:a1e0::6"], online: true, lastSeenAgo: 45, curAddr: "", relay: "ams",
                     user: 1003, tags: ["tag:iot"], exitOption: false, routes: [], taildrop: 0,
                     rx: 3_120_990, tx: 5_004_811, createdDaysAgo: 150),
            PeerInfo(name: "pixel-demo", key: "nodekey:706978656c000000000000000000000000000000000000000000000000000006", os: "android",
                     ips: ["100.64.0.7", "fd7a:115c:a1e0::7"], online: false, lastSeenAgo: 2 * 86400, curAddr: "", relay: "",
                     user: 1001, tags: [], exitOption: false, routes: [], taildrop: 1,
                     rx: 120_550, tx: 88_410, createdDaysAgo: 60),
        ]
    }

    private var profiles: [TailscaleProfile] {
        [
            TailscaleProfile(id: "demo1", nickname: "user@example.com", tailnet: "example.com", account: "user@example.com",
                             selected: selectedProfile == "demo1"),
            TailscaleProfile(id: "demo2", nickname: "user@example.org", tailnet: "sandbox.example.org", account: "user@example.org",
                             selected: selectedProfile == "demo2"),
        ]
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func iso(_ secondsAgo: TimeInterval) -> String { isoFormatter.string(from: Date().addingTimeInterval(-secondsAgo)) }

    private func jsonString(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Status

    private func exitNodeKey() -> String? {
        let wanted = (prefs["exit-node"] as? String) ?? ""
        if wanted.isEmpty { return nil }
        let candidates = peerTable().filter { $0.exitOption }
        if wanted.hasPrefix("auto:") { return candidates.first { $0.online }?.key }
        return candidates.first { $0.ips.contains(wanted) || wanted == $0.name || wanted == "\($0.name).\(Self.domainSuffix)" }?.key
    }

    private func statusJSON() -> String {
        let hostname = ((prefs["hostname"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? Self.selfName
        let selfNode: [String: Any] = [
            "ID": "nDEMOSELFCNTRL", "PublicKey": "nodekey:64656d6f0000000000000000000000000000000000000000000000000000ff00",
            "HostName": hostname, "DNSName": Self.selfDNSName + ".", "OS": "macOS", "UserID": 1001,
            "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"], "Online": running, "Relay": "fra", "Active": false,
            "Created": Self.iso(86400 * 120), "KeyExpiry": Self.iso(-86400 * 140), "ExitNodeOption": false,
        ]
        var peers: [String: Any] = [:]
        if running {
            let exitKey = exitNodeKey()
            for p in peerTable() {
                var dict: [String: Any] = [
                    "ID": "n" + p.name.uppercased().replacingOccurrences(of: "-", with: ""), "PublicKey": p.key, "HostName": p.name,
                    "DNSName": "\(p.name).\(Self.domainSuffix).", "OS": p.os, "UserID": p.user, "TailscaleIPs": p.ips,
                    "AllowedIPs": p.ips.map { $0.contains(":") ? $0 + "/128" : $0 + "/32" } + p.routes,
                    "CurAddr": p.curAddr, "Relay": p.relay, "RxBytes": p.online ? p.rx : 0, "TxBytes": p.online ? p.tx : 0,
                    "Created": Self.iso(86400 * p.createdDaysAgo), "LastSeen": Self.iso(p.lastSeenAgo),
                    "LastHandshake": p.online ? Self.iso(p.lastSeenAgo + 40) : "0001-01-01T00:00:00Z",
                    "Online": p.online, "ExitNode": p.key == exitKey, "ExitNodeOption": p.exitOption,
                    "Active": p.online && !p.curAddr.isEmpty, "TaildropTarget": p.taildrop, "KeyExpiry": Self.iso(-86400 * 90),
                ]
                if !p.tags.isEmpty { dict["Tags"] = p.tags }
                if !p.routes.isEmpty { dict["PrimaryRoutes"] = p.routes }
                if p.taildrop == 0 { dict["NoFileSharingReason"] = "Taildrop is not available for tagged devices." }
                peers[p.key] = dict
            }
        }
        let tailnet = profiles.first { $0.selected }?.tailnet ?? "example.com"
        let status: [String: Any] = [
            "Version": "1.80.2", "BackendState": running ? "Running" : "Stopped", "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"],
            "Self": selfNode, "Health": [String](), "MagicDNSSuffix": Self.domainSuffix,
            "CurrentTailnet": ["Name": tailnet, "MagicDNSSuffix": Self.domainSuffix, "MagicDNSEnabled": true],
            "CertDomains": [Self.selfDNSName], "Peer": peers,
            "User": [
                "1001": ["ID": 1001, "LoginName": "user@example.com", "DisplayName": "Demo User"],
                "1002": ["ID": 1002, "LoginName": "sam@example.com", "DisplayName": "Sam Sample"],
                "1003": ["ID": 1003, "LoginName": "tagged-devices", "DisplayName": "Tagged Devices"],
            ],
        ]
        return jsonString(status)
    }

    private func statusText() -> String {
        var lines = ["100.64.0.1      \(Self.selfName)        user@example.com  macOS   -"]
        if running {
            for p in peerTable() {
                lines.append("\(p.ips[0].padding(toLength: 15, withPad: " ", startingAt: 0)) \(p.name.padding(toLength: 15, withPad: " ", startingAt: 0)) "
                             + "\(p.user == 1003 ? "tagged-devices" : "user@example.com")  \(p.os)   \(p.online ? "-" : "offline")")
            }
        } else {
            lines = ["Tailscale is stopped."]
        }
        return lines.joined(separator: "\n")
    }

    private func whois(for target: String) -> String {
        guard let p = peerTable().first(where: { $0.ips.contains(target) }) else {
            return "Machine:\n  Name:          \(Self.selfDNSName)\n  Addresses:     100.64.0.1, fd7a:115c:a1e0::1\nUser:\n  Name:          user@example.com\n  ID:            1001"
        }
        let owner = p.user == 1003 ? "tagged-devices" : (p.user == 1002 ? "sam@example.com" : "user@example.com")
        return "Machine:\n  Name:          \(p.name).\(Self.domainSuffix)\n  ID:            n\(p.name.uppercased().replacingOccurrences(of: "-", with: ""))\n"
            + "  Addresses:     \(p.ips.joined(separator: ", "))\nUser:\n  Name:          \(owner)\n  ID:            \(p.user)"
    }

    // MARK: Prefs & profiles

    private func prefsJSON() -> String { jsonString(prefs) }

    private func profilesJSON() -> String {
        jsonString(profiles.map { ["id": $0.id, "nickname": $0.nickname, "tailnet": $0.tailnet, "account": $0.account, "selected": $0.selected] as [String: Any] })
    }

    /// Apply `--flag=value` arguments that are preferences (`set`, and the setting flags of `up`).
    private func applyPrefFlags(_ args: [String]) {
        let boolFlags: Set<String> = ["accept-dns", "accept-routes", "advertise-connector", "advertise-exit-node", "auto-update",
                                      "exit-node-allow-lan-access", "report-posture", "shields-up", "ssh", "update-check", "webclient"]
        let stringFlags: Set<String> = ["exit-node", "hostname", "nickname", "operator", "relay-server-port"]
        let listFlags: Set<String> = ["advertise-routes", "relay-server-static-endpoints"]
        for arg in args where arg.hasPrefix("--") {
            let body = arg.dropFirst(2)
            let name: String, value: String
            if let eq = body.firstIndex(of: "=") { name = String(body[..<eq]); value = String(body[body.index(after: eq)...]) }
            else { name = String(body); value = "true" }
            if boolFlags.contains(name) { prefs[name] = (value == "true") }
            else if stringFlags.contains(name) { prefs[name] = value }
            else if listFlags.contains(name) {
                prefs[name] = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
    }

    // MARK: Serve

    private func hostFor(_ service: String?) -> String {
        guard let service else { return Self.selfDNSName }
        return "\(service.hasPrefix("svc:") ? String(service.dropFirst(4)) : service).\(Self.domainSuffix)"
    }

    /// Build `serve status --json` from the rule list.
    private func serveJSON() -> String {
        func block(for service: String?) -> [String: Any]? {
            let group = rules.filter { $0.service == service && !$0.isForeground }
            if group.isEmpty { return nil }
            var tcp: [String: Any] = [:], web: [String: Any] = [:], funnel: [String: Any] = [:]
            let host = hostFor(service)
            for rule in group {
                let key = "\(host):\(rule.port)"
                if rule.mode.isWeb {
                    tcp[String(rule.port)] = rule.mode == .https ? ["HTTPS": true] : ["HTTP": true]
                    var handler: [String: Any] = [:]
                    switch rule.target {
                    case .proxy(let p): handler["Proxy"] = p
                    case .path(let p): handler["Path"] = p
                    case .text(let t): handler["Text"] = t
                    }
                    if !rule.acceptAppCaps.isEmpty { handler["AcceptAppCaps"] = rule.acceptAppCaps }
                    var server = (web[key] as? [String: Any]) ?? ["Handlers": [String: Any]()]
                    var handlers = (server["Handlers"] as? [String: Any]) ?? [:]
                    handlers[rule.normalizedMount] = handler
                    server["Handlers"] = handlers
                    web[key] = server
                } else {
                    var forward = rule.target.cliArgument
                    if forward.hasPrefix("tcp://") { forward = String(forward.dropFirst(6)) }
                    var handler: [String: Any] = ["TCPForward": forward]
                    if rule.mode == .tlsTerminatedTCP { handler["TerminateTLS"] = host }
                    if let pp = rule.proxyProtocol { handler["ProxyProtocol"] = pp }
                    tcp[String(rule.port)] = handler
                }
                if rule.funnel { funnel[key] = true }
            }
            var out: [String: Any] = ["TCP": tcp]
            if !web.isEmpty { out["Web"] = web }
            if !funnel.isEmpty { out["AllowFunnel"] = funnel }
            return out
        }
        var root = block(for: nil) ?? [:]
        var services: [String: Any] = [:]
        for name in Set(rules.compactMap(\.service)) { if let b = block(for: name) { services[name] = b } }
        if !services.isEmpty { root["Services"] = services }
        return root.isEmpty ? "{}" : jsonString(root)
    }

    private func serveText() -> String {
        let node = rules.filter { $0.service == nil }
        if node.isEmpty { return "No serve config" }
        return node.map { "\($0.url(dnsName: Self.selfDNSName) ?? "\(Self.selfDNSName):\($0.port)") \($0.funnel ? "(Funnel on)" : "(tailnet only)")\n|-- \($0.target.display)" }
            .joined(separator: "\n\n")
    }

    /// Interpret `serve`/`funnel` arguments (the same shapes `ServeRule.applyArgs()` / `removeArgs()` produce).
    private func applyServe(_ args: [String]) -> Reply {
        let funnelCommand = args.first == "funnel"
        let rest = Array(args.dropFirst())
        switch rest.first ?? "" {
        case "reset":
            if funnelCommand { for i in rules.indices { rules[i].funnel = false } }
            else { rules.removeAll { $0.service == nil && !$0.isForeground } }
            return simulated()
        case "clear":
            if rest.count > 1 { rules.removeAll { $0.service == rest[1] } }
            return simulated()
        case "drain", "advertise", "get-config", "set-config":
            return simulated()
        default: break
        }

        var mode: ServeRule.Mode?, port = 0, mount = "/", service: String?, proxyProtocol: Int?, caps: [String] = []
        var positional: [String] = []
        for arg in rest {
            guard arg.hasPrefix("--") else { positional.append(arg); continue }
            let body = arg.dropFirst(2)
            let name: String, value: String
            if let eq = body.firstIndex(of: "=") { name = String(body[..<eq]); value = String(body[body.index(after: eq)...]) }
            else { name = String(body); value = "" }
            switch name {
            case "https": mode = .https; port = Int(value) ?? 443
            case "http": mode = .http; port = Int(value) ?? 80
            case "tcp": mode = .tcp; port = Int(value) ?? 0
            case "tls-terminated-tcp": mode = .tlsTerminatedTCP; port = Int(value) ?? 0
            case "set-path": mount = value
            case "service": service = value
            case "proxy-protocol": proxyProtocol = Int(value)
            case "accept-app-caps": caps = value.split(separator: ",").map(String.init)
            default: break
            }
        }
        guard let mode, port > 0, let targetText = positional.last else { return simulated() }

        var probe = ServeRule(mode: mode, port: port, mountPath: mount, target: .proxy(""), service: service)
        probe.mountPath = mount.isEmpty ? "/" : mount
        let identity = probe.identity
        if targetText == "off" {
            rules.removeAll { $0.identity == identity && !$0.isForeground }
            return simulated()
        }

        var target = ServeRule.Target(userInput: targetText)
        if case .proxy(let raw) = target { target = .proxy(Self.normalizeProxy(raw, tcp: !mode.isWeb)) }
        // One port serves one kind of traffic: replace routes of another mode on the same port.
        rules.removeAll { $0.service == service && $0.port == port && $0.mode != mode && !$0.isForeground }
        rules.removeAll { $0.identity == identity && !$0.isForeground }
        rules.append(ServeRule(mode: mode, port: port, mountPath: mount.isEmpty ? "/" : mount, target: target, funnel: funnelCommand,
                               service: service, proxyProtocol: proxyProtocol, acceptAppCaps: caps, host: hostFor(service)))
        // Funnel is a per-port switch, like on a real node.
        if service == nil { for i in rules.indices where rules[i].service == nil && rules[i].port == port { rules[i].funnel = funnelCommand } }
        return simulated()
    }

    /// `3000` -> `http://127.0.0.1:3000`, `localhost:3000` -> `http://localhost:3000` (tcp: `tcp://...`).
    private static func normalizeProxy(_ raw: String, tcp: Bool) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = tcp ? "tcp" : "http"
        if s.hasPrefix("unix:") || s.contains("://") { return s }
        if !s.isEmpty, s.allSatisfy(\.isNumber) { return "\(scheme)://127.0.0.1:\(s)" }
        return "\(scheme)://\(s)"
    }
}

// MARK: - Simulated stream

/// A streamed command that replays scripted output on the main queue; never starts a process.
final class DemoStream: CommandStream {
    private let args: [String]
    private let onFinish: ((CommandResult) -> Void)?
    private var output = ""
    private var items: [DispatchWorkItem] = []
    private var finished = false
    private let began = Date()

    init(args: [String], script: [(delay: TimeInterval, text: String)], timeout: TimeInterval?,
         onOutput: @escaping (String) -> Void, onFinish: ((CommandResult) -> Void)?) {
        self.args = args
        self.onFinish = onFinish
        var at: TimeInterval = 0
        for (delay, text) in script {
            at += delay
            schedule(at) { [weak self] in
                guard let self, !self.finished else { return }
                self.output += text
                onOutput(text)
            }
        }
        let end = at + 0.1
        if let timeout, timeout < end {
            schedule(timeout) { [weak self] in self?.finish(timedOut: true, cancelled: false) }
        }
        schedule(end) { [weak self] in self?.finish(timedOut: false, cancelled: false) }
    }

    var isRunning: Bool { !finished }

    func cancel() {
        DispatchQueue.main.async { [weak self] in self?.finish(timedOut: false, cancelled: true) }
    }

    private func schedule(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        let item = DispatchWorkItem(block: block)
        items.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func finish(timedOut: Bool, cancelled: Bool) {
        guard !finished else { return }
        finished = true
        items.forEach { $0.cancel() }
        let result = CommandResult(args: args, exitCode: cancelled ? 130 : (timedOut ? 124 : 0), stdout: output, stderr: "",
                                   duration: Date().timeIntervalSince(began), timedOut: timedOut, wasCancelled: cancelled)
        onFinish?(result)
    }
}
