import Foundation

// MARK: - Raw config (decoded from `tailscale serve status --json`)

/// `TCP` map entry: how a port is handled.
struct ServeTCPHandler: Decodable, Hashable, Sendable {
    var https = false
    var http = false
    /// `host:port` the raw TCP forwarder sends to.
    var tcpForward: String?
    /// Non-nil when TLS is terminated by Tailscale for TCP forwarding.
    var terminateTLS: String?
    var proxyProtocol: Int?

    enum CodingKeys: String, CodingKey {
        case https = "HTTPS", http = "HTTP", tcpForward = "TCPForward", terminateTLS = "TerminateTLS", proxyProtocol = "ProxyProtocol"
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        https = c.lenientBool(.https) ?? false
        http = c.lenientBool(.http) ?? false
        tcpForward = c.lenientString(.tcpForward)
        terminateTLS = c.lenientString(.terminateTLS)
        proxyProtocol = c.lenientInt(.proxyProtocol)
    }
}

/// One mount-path handler inside a `Web` entry.
struct ServeWebHandler: Decodable, Hashable, Sendable {
    var proxy: String?
    var path: String?
    var text: String?
    var redirect: String?
    var acceptAppCaps: [String] = []

    enum CodingKeys: String, CodingKey {
        case proxy = "Proxy", path = "Path", text = "Text", redirect = "Redirect", acceptAppCaps = "AcceptAppCaps"
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        proxy = c.lenientString(.proxy)
        path = c.lenientString(.path)
        text = c.lenientString(.text)
        redirect = c.lenientString(.redirect)
        acceptAppCaps = c.lenientStrings(.acceptAppCaps)
    }
}

/// `Web` map entry for one `host:port`.
struct ServeWebServer: Decodable, Hashable, Sendable {
    var handlers: [String: ServeWebHandler] = [:]
    enum CodingKeys: String, CodingKey { case handlers = "Handlers" }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handlers = c.lenientDictionary(ServeWebHandler.self, .handlers)
    }
}

/// The TCP/Web/AllowFunnel trio used by the node itself, by each service, and by each foreground session.
struct ServeBlock: Decodable, Hashable, Sendable {
    /// Port handlers keyed by port number.
    var tcp: [Int: ServeTCPHandler] = [:]
    /// Web servers keyed by `host:port`.
    var web: [String: ServeWebServer] = [:]
    /// Funnel flags keyed by `host:port`.
    var allowFunnel: [String: Bool] = [:]
    /// Service only: forward all traffic to this machine.
    var tun = false

    enum CodingKeys: String, CodingKey { case tcp = "TCP", web = "Web", allowFunnel = "AllowFunnel", tun = "Tun" }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawTCP = c.lenientDictionary(ServeTCPHandler.self, .tcp)
        for (key, value) in rawTCP { if let port = Int(key) { tcp[port] = value } }
        web = c.lenientDictionary(ServeWebServer.self, .web)
        allowFunnel = c.lenientDictionary(Bool.self, .allowFunnel)
        tun = c.lenientBool(.tun) ?? false
    }

    var isEmpty: Bool { tcp.isEmpty && web.isEmpty && !tun }
}

/// Parsed `tailscale serve status --json`. All keys optional; `{}` is an empty config.
struct ServeConfig: Decodable, Hashable, Sendable {
    /// Config of the node itself (top-level `TCP`, `Web`, `AllowFunnel`).
    var node = ServeBlock()
    /// Tailscale Services keyed by `svc:name`.
    var services: [String: ServeBlock] = [:]
    /// Foreground (`serve` without `--bg`) sessions keyed by session ID.
    var foreground: [String: ServeBlock] = [:]

    enum CodingKeys: String, CodingKey { case services = "Services", foreground = "Foreground" }
    init() {}
    init(from decoder: Decoder) throws {
        node = (try? ServeBlock(from: decoder)) ?? ServeBlock()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        services = c.lenientDictionary(ServeBlock.self, .services)
        foreground = c.lenientDictionary(ServeBlock.self, .foreground)
    }

    var isEmpty: Bool { node.isEmpty && services.values.allSatisfy(\.isEmpty) && foreground.values.allSatisfy(\.isEmpty) }

    /// Flatten into rules, sorted by service (none first), port, mount path; foreground sessions last.
    /// - Parameter selfDNSName: this node's MagicDNS name (trailing dot optional); used as the host of TCP rules.
    func rules(selfDNSName: String? = nil) -> [ServeRule] {
        let host = selfDNSName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.flatMap { $0.isEmpty ? nil : $0 }
        var all = node.rules(service: nil, foreground: false, nodeHost: host)
        for (name, block) in services { all += block.rules(service: name, foreground: false, nodeHost: nil) }
        for (_, block) in foreground { all += block.rules(service: nil, foreground: true, nodeHost: host) }
        return all.sorted {
            if $0.isForeground != $1.isForeground { return !$0.isForeground }
            let ls = $0.service ?? "", rs = $1.service ?? ""
            if ls != rs { return ls < rs }
            if $0.port != $1.port { return $0.port < $1.port }
            if $0.mountPath != $1.mountPath { return $0.mountPath < $1.mountPath }
            return $0.mode.rawValue < $1.mode.rawValue
        }
    }
}

extension ServeBlock {
    fileprivate func rules(service: String?, foreground: Bool, nodeHost: String?) -> [ServeRule] {
        var out: [ServeRule] = []
        var webPorts = Set<Int>()
        for (hostPort, server) in web {
            guard let colon = hostPort.lastIndex(of: ":"), let port = Int(hostPort[hostPort.index(after: colon)...]) else { continue }
            webPorts.insert(port)
            let host = String(hostPort[..<colon])
            let handler = tcp[port]
            let mode: ServeRule.Mode = (handler?.https == false && handler?.http == true) ? .http : .https
            for (mount, h) in server.handlers {
                let target: ServeRule.Target
                if let proxy = h.proxy, !proxy.isEmpty { target = .proxy(proxy) }
                else if let path = h.path, !path.isEmpty { target = .path(path) }
                else if let text = h.text { target = .text(text) }
                else { continue }   // redirect handlers (set-config only) are not representable
                out.append(ServeRule(mode: mode, port: port, mountPath: mount.isEmpty ? "/" : mount, target: target,
                                     funnel: allowFunnel[hostPort] == true, service: service,
                                     proxyProtocol: nil, acceptAppCaps: h.acceptAppCaps, host: host, isForeground: foreground))
            }
        }
        for (port, handler) in tcp where !webPorts.contains(port) {
            guard let forward = handler.tcpForward, !forward.isEmpty else { continue }
            let tls = (handler.terminateTLS ?? "").isEmpty == false
            let funnel = allowFunnel.contains { $0.value && $0.key.hasSuffix(":\(port)") }
            out.append(ServeRule(mode: tls ? .tlsTerminatedTCP : .tcp, port: port, mountPath: "/", target: .proxy("tcp://\(forward)"),
                                 funnel: funnel, service: service, proxyProtocol: handler.proxyProtocol, acceptAppCaps: [],
                                 host: nodeHost, isForeground: foreground))
        }
        return out
    }
}

// MARK: - ServeRule

/// Problem with a rule's fields, with a user-friendly message.
struct ServeValidationError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// One serve/funnel route (one mount of a web port, or one TCP forwarder), editable and convertible to CLI arguments.
struct ServeRule: Identifiable, Hashable, Sendable {
    /// Maps to `--https`, `--http`, `--tcp`, `--tls-terminated-tcp`.
    enum Mode: String, CaseIterable, Hashable, Sendable {
        case https, http, tcp, tlsTerminatedTCP

        /// CLI flag name without value, e.g. `--https`.
        var flag: String {
            switch self {
            case .https: return "--https"
            case .http: return "--http"
            case .tcp: return "--tcp"
            case .tlsTerminatedTCP: return "--tls-terminated-tcp"
            }
        }
        /// Label for pickers.
        var title: String {
            switch self {
            case .https: return "HTTPS"
            case .http: return "HTTP"
            case .tcp: return "TCP"
            case .tlsTerminatedTCP: return "TLS-terminated TCP"
            }
        }
        /// True for https/http (mount paths, path/text targets, app caps apply).
        var isWeb: Bool { self == .https || self == .http }
    }

    /// What the rule points at.
    enum Target: Hashable, Sendable {
        /// e.g. `http://127.0.0.1:3000`, `https+insecure://localhost:8443`, `tcp://localhost:5432`, `3000`, `unix:/path.sock`.
        case proxy(String)
        /// Absolute file or directory path.
        case path(String)
        /// Literal text to serve (CLI syntax `text:<string>`).
        case text(String)

        /// Exactly what is passed to the CLI as the final argument.
        var cliArgument: String {
            switch self {
            case .proxy(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines)
            case .path(let s): return s
            case .text(let s): return "text:" + s
            }
        }
        /// Human-readable description for tables.
        var display: String {
            switch self {
            case .proxy(let s): return s
            case .path(let s): return s
            case .text(let s): return "text: \(s)"
            }
        }
        /// Short kind label ("Proxy", "Path", "Text").
        var kindTitle: String {
            switch self { case .proxy: return "Proxy"; case .path: return "Path"; case .text: return "Text" }
        }
        /// Interpret user input: `text:...` is text, a leading `/` or `~` is a path, anything else a proxy target.
        init(userInput raw: String) {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("text:") { self = .text(String(s.dropFirst(5))) }
            else if s.hasPrefix("/") || s.hasPrefix("~") { self = .path((s as NSString).expandingTildeInPath) }
            else { self = .proxy(s) }
        }
    }

    /// The fields that identify a rule on the node. Changing any of them means a different route.
    struct Identity: Hashable, Sendable {
        var service: String?
        var mode: Mode
        var port: Int
        var mountPath: String
    }

    var mode: Mode
    var port: Int
    /// `"/"` by default; only used for https/http (`--set-path`).
    var mountPath: String
    var target: Target
    /// Exposed to the public internet via `tailscale funnel`.
    var funnel: Bool
    /// `svc:name` for Tailscale Services (`--service=`).
    var service: String?
    /// 1 or 2; tcp modes only (`--proxy-protocol`).
    var proxyProtocol: Int?
    /// App capabilities forwarded to the backend (`--accept-app-caps`); http/https only.
    var acceptAppCaps: [String]
    /// Host name from status, display only.
    var host: String?
    /// Comes from a foreground session (`serve` without `--bg`); cannot be removed with `off`.
    var isForeground: Bool

    init(mode: Mode = .https, port: Int = 443, mountPath: String = "/", target: Target,
         funnel: Bool = false, service: String? = nil, proxyProtocol: Int? = nil,
         acceptAppCaps: [String] = [], host: String? = nil, isForeground: Bool = false) {
        self.mode = mode; self.port = port; self.mountPath = mountPath; self.target = target
        self.funnel = funnel; self.service = service; self.proxyProtocol = proxyProtocol
        self.acceptAppCaps = acceptAppCaps; self.host = host; self.isForeground = isForeground
    }

    /// The default quick route: HTTPS :443 to `http://127.0.0.1:8080`.
    static let quickRoute = ServeRule(target: .proxy("http://127.0.0.1:8080"))

    /// HTTPS rule on `port` proxying to `http://127.0.0.1:<localPort>`.
    static func localProxy(exposePort: Int = 443, localPort: Int) -> ServeRule {
        ServeRule(mode: .https, port: exposePort, target: .proxy("http://127.0.0.1:\(localPort)"))
    }

    var id: String { "\(isForeground ? "fg:" : "")\(service ?? "")|\(mode.rawValue)|\(port)|\(normalizedMount)" }

    var identity: Identity { Identity(service: service, mode: mode, port: port, mountPath: normalizedMount) }

    /// Mount path as used on the command line: `"/"` for non-web modes and empty input.
    var normalizedMount: String {
        guard mode.isWeb else { return "/" }
        let m = mountPath.trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? "/" : m
    }

    /// Funnel on public ports.
    static let funnelPorts = [443, 8443, 10000]

    // MARK: Validation

    /// Check the rule; throws `ServeValidationError` with a message suitable for display.
    func validate() throws {
        guard (1...65535).contains(port) else { throw ServeValidationError("The Tailscale port must be a number from 1 to 65535.") }
        if let service { try ServeCommands.validateService(service) }
        if funnel {
            if mode == .http { throw ServeValidationError("Funnel does not support plain HTTP. Use HTTPS, TCP or TLS-terminated TCP.") }
            if !Self.funnelPorts.contains(port) { throw ServeValidationError("Funnel can only use ports 443, 8443 and 10000.") }
            if service != nil { throw ServeValidationError("Funnel cannot be combined with a Tailscale Service.") }
            if !acceptAppCaps.isEmpty { throw ServeValidationError("Funnel does not support app capabilities.") }
        }
        if mode.isWeb {
            let m = mountPath.trimmingCharacters(in: .whitespaces)
            if !m.isEmpty {
                guard m.hasPrefix("/") else { throw ServeValidationError("The mount path must start with \"/\" (for example /api).") }
                guard m.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, !m.contains("?"), !m.contains("#") else {
                    throw ServeValidationError("The mount path cannot contain spaces, \"?\" or \"#\".")
                }
            }
        }
        if let pp = proxyProtocol {
            guard !mode.isWeb else { throw ServeValidationError("PROXY protocol only applies to TCP and TLS-terminated TCP.") }
            guard pp == 1 || pp == 2 else { throw ServeValidationError("PROXY protocol version must be 1 or 2.") }
        }
        if !acceptAppCaps.isEmpty {
            guard mode.isWeb else { throw ServeValidationError("App capabilities only apply to HTTP and HTTPS.") }
            for cap in acceptAppCaps where cap.isEmpty || cap.contains(",") || cap.rangeOfCharacter(from: .whitespaces) != nil {
                throw ServeValidationError("Invalid app capability \"\(cap)\". Capabilities are names without spaces or commas.")
            }
        }
        switch target {
        case .proxy(let raw):
            try Self.validateProxy(raw, tcp: !mode.isWeb)
        case .path(let p):
            guard mode.isWeb else { throw ServeValidationError("Files and folders can only be served over HTTP or HTTPS.") }
            guard p.hasPrefix("/") else { throw ServeValidationError("The file or folder path must be absolute (start with \"/\").") }
        case .text(let t):
            guard mode.isWeb else { throw ServeValidationError("Text can only be served over HTTP or HTTPS.") }
            guard !t.isEmpty else { throw ServeValidationError("The text to serve cannot be empty.") }
        }
    }

    /// Sanity-check a proxy target string.
    static func validateProxy(_ raw: String, tcp: Bool) throws {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw ServeValidationError("Enter a target: a port (3000), host:port, or a URL like http://127.0.0.1:3000.") }
        func checkPort(_ p: String) throws {
            guard let n = Int(p), (1...65535).contains(n) else { throw ServeValidationError("The target port must be a number from 1 to 65535. Got: \(p)") }
        }
        if s.hasPrefix("unix:") {
            guard !tcp else { throw ServeValidationError("Unix sockets can only be used with HTTP or HTTPS.") }
            guard s.dropFirst(5).hasPrefix("/"), s.count > 6 else { throw ServeValidationError("A unix socket target looks like unix:/path/to/app.sock.") }
            return
        }
        if s.allSatisfy(\.isNumber) { try checkPort(s); return }
        var rest = s
        if let r = s.range(of: "://") {
            let scheme = String(s[..<r.lowerBound]).lowercased()
            let allowed = tcp ? ["tcp"] : ["http", "https", "https+insecure"]
            guard allowed.contains(scheme) else {
                throw ServeValidationError("Unsupported scheme \"\(scheme)\". Use " + allowed.map { $0 + "://" }.joined(separator: ", ") + ".")
            }
            rest = String(s[r.upperBound...])
        } else if s.contains("/") && tcp {
            throw ServeValidationError("A TCP target is host:port, with no path.")
        }
        var hostPort = rest
        if let slash = rest.firstIndex(of: "/") {
            if tcp { throw ServeValidationError("A TCP target is host:port, with no path.") }
            hostPort = String(rest[..<slash])
        }
        var host = hostPort, portText: String?
        if hostPort.hasPrefix("[") {   // [::1]:8080
            guard let close = hostPort.firstIndex(of: "]") else { throw ServeValidationError("Invalid IPv6 address in the target.") }
            host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            let tail = hostPort[hostPort.index(after: close)...]
            if tail.hasPrefix(":") { portText = String(tail.dropFirst()) }
        } else if let colon = hostPort.lastIndex(of: ":") {
            host = String(hostPort[..<colon]); portText = String(hostPort[hostPort.index(after: colon)...])
        }
        guard !host.isEmpty, host.range(of: #"^[A-Za-z0-9_.:\-]+$"#, options: .regularExpression) != nil else {
            throw ServeValidationError("The target host must be a plain host name or IP address, not \"\(host)\".")
        }
        guard let portText else { throw ServeValidationError("The target needs a port, for example \(host):3000.") }
        try checkPort(portText)
    }

    // MARK: Command builders

    /// Sub-arguments (after the binary) that create/update this rule, e.g.
    /// `["serve","--bg","--yes","--https=443","--set-path=/api","http://127.0.0.1:3000"]`.
    /// Uses `funnel` instead of `serve` when `funnel` is true. Call `validate()` first.
    func applyArgs() -> [String] {
        var args = [funnel ? "funnel" : "serve", "--bg", "--yes", "\(mode.flag)=\(port)"]
        if let service, !funnel { args.append("--service=\(service)") }
        if mode.isWeb, normalizedMount != "/" { args.append("--set-path=\(normalizedMount)") }
        if !mode.isWeb, let proxyProtocol { args.append("--proxy-protocol=\(proxyProtocol)") }
        if mode.isWeb, !acceptAppCaps.isEmpty, !funnel { args.append("--accept-app-caps=\(acceptAppCaps.joined(separator: ","))") }
        args.append(target.cliArgument)
        return args
    }

    /// Sub-arguments that remove this rule, e.g. `["serve","--yes","--https=443","--set-path=/api","off"]`.
    /// Always uses `serve` (it also clears the route when it was a funnel).
    func removeArgs() -> [String] {
        var args = ["serve", "--yes", "\(mode.flag)=\(port)"]
        if let service { args.append("--service=\(service)") }
        if mode.isWeb, normalizedMount != "/" { args.append("--set-path=\(normalizedMount)") }
        args.append("off")
        return args
    }

    /// Ordered CLI steps to turn `old` into `new`. If the identity (service, mode, port, mount path) changed,
    /// the old route is removed first, then the new one applied; otherwise only apply (re-applying with `serve`
    /// instead of `funnel` switches funnel off while keeping the route).
    static func editPlan(from old: ServeRule?, to new: ServeRule) -> [[String]] {
        guard let old else { return [new.applyArgs()] }
        if old.identity != new.identity { return [old.removeArgs(), new.applyArgs()] }
        return [new.applyArgs()]
    }

    // MARK: Display

    /// Public URL for web rules (`https://host/path`, omitting `:443` / `:80`); nil for TCP modes or when no host is known.
    /// - Parameter dnsName: this node's MagicDNS name (trailing dot optional). For service rules the rule's own `host` is used.
    func url(dnsName: String?) -> String? {
        guard mode.isWeb else { return nil }
        var name = service != nil ? host : (dnsName ?? host)
        if let n = name, n.hasSuffix(".") { name = String(n.dropLast()) }
        guard let name, !name.isEmpty else { return nil }
        let scheme = mode == .https ? "https" : "http"
        let defaultPort = mode == .https ? 443 : 80
        let portPart = port == defaultPort ? "" : ":\(port)"
        return "\(scheme)://\(name)\(portPart)\(normalizedMount)"
    }

    /// Short summary like `HTTPS :443 /api → http://127.0.0.1:3000`.
    var summary: String {
        let mount = mode.isWeb && normalizedMount != "/" ? " \(normalizedMount)" : ""
        return "\(mode.title) :\(port)\(mount) → \(target.display)"
    }
}

// MARK: - Whole-config commands

/// Builders for serve/funnel commands that are not tied to one rule. All return sub-arguments (after the binary).
enum ServeCommands {
    /// `serve reset` — removes the whole serve config of this node.
    static func resetArgs() -> [String] { ["serve", "reset"] }
    /// `funnel reset` — turns off all funnel exposure.
    static func funnelResetArgs() -> [String] { ["funnel", "reset"] }
    /// `serve drain <svc>` — stop accepting new connections for a service on this node.
    static func drainArgs(service: String) -> [String] { ["serve", "drain", service] }
    /// `serve clear <svc>` — remove all handlers of a service.
    static func clearArgs(service: String) -> [String] { ["serve", "clear", service] }
    /// `serve advertise <svc>` — advertise this node as a host for the service again (after a drain).
    static func advertiseArgs(service: String) -> [String] { ["serve", "advertise", service] }
    /// `serve get-config <file> [--service=<svc> | --all]` — write the service config to a file.
    static func getConfigArgs(file: String, service: String? = nil, all: Bool = false) -> [String] {
        ["serve", "get-config", file] + scopeFlags(service: service, all: all)
    }
    /// `serve set-config <file> [--service=<svc> | --all]` — replace service config from a file.
    static func setConfigArgs(file: String, service: String? = nil, all: Bool = false) -> [String] {
        ["serve", "set-config", file] + scopeFlags(service: service, all: all)
    }

    private static func scopeFlags(service: String?, all: Bool) -> [String] {
        if let service { return ["--service=\(service)"] }
        return all ? ["--all"] : []
    }

    /// Service names look like `svc:<dns-label>` (lowercase letters, digits, hyphens; max 63 chars).
    static func validateService(_ name: String) throws {
        guard name.range(of: #"^svc:[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil else {
            throw ServeValidationError("Service names look like svc:my-service (lowercase letters, digits and hyphens).")
        }
    }
}
