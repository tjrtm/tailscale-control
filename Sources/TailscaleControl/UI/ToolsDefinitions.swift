import Foundation

// The diagnostics tools as plain data. `ToolsView` renders any `ToolDefinition` generically:
// inputs become native controls, `build` turns the values into `tailscale` arguments.

// MARK: - Values and context

/// Current values of a tool's inputs, keyed by `ToolsInput.id`. Toggles are "1" (on) or "" (off).
struct ToolsValues {
    var raw: [String: String] = [:]

    func text(_ key: String) -> String { (raw[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    func flag(_ key: String) -> Bool { raw[key] == "1" }
    func int(_ key: String, _ fallback: Int) -> Int { Int(text(key)) ?? fallback }
}

/// Live data the argument builders may need.
struct ToolsContext {
    var certDomains: [String] = []
    var peers: [ToolsPeerOption] = []
}

struct ToolsPeerOption: Identifiable, Hashable {
    let name: String
    let ip: String
    var id: String { ip + name }
}

struct ToolsChoice: Hashable, Identifiable {
    let value: String
    let title: String
    var id: String { value }
}

// MARK: - Inputs

struct ToolsInput: Identifiable {
    enum Kind {
        case text(prompt: String)
        /// Free text plus a menu of the tailnet's devices (fills in the IP).
        case peer(prompt: String)
        case toggle
        case menu([ToolsChoice])
        case segmented([ToolsChoice])
        /// `zeroLabel` replaces the number when the value is 0 (for example "unlimited").
        case stepper(ClosedRange<Int>, unit: String, zeroLabel: String?)
        /// A folder chosen with the system open panel.
        case directory
        /// One of `status.certDomains`.
        case certDomain
    }

    let id: String
    let label: String
    var kind: Kind
    var defaultValue = ""
    var help: String?
    var visible: (ToolsValues) -> Bool = { _ in true }
}

// MARK: - Definition

enum ToolsBuild {
    case ready([String])
    case invalid(String)
}

/// A confirmation shown before a tool that writes files or sends diagnostics runs.
struct ToolsConfirmation {
    var title: String
    var message: String
    var button: String
}

struct ToolDefinition: Identifiable {
    enum Category: String, CaseIterable, Identifiable {
        case network = "Network"
        case identity = "Identity"
        case files = "Files & certificates"
        case system = "System"
        case advanced = "Advanced"
        var id: String { rawValue }
    }

    let id: String
    let title: String
    let systemImage: String
    let summary: String
    let category: Category
    var inputs: [ToolsInput] = []
    /// Extra explanation shown above the options.
    var note: String?
    var runTitle = "Run"
    /// Seconds before the process is stopped; `nil` runs until it exits or the user taps Stop.
    var timeout: (ToolsValues) -> TimeInterval? = { _ in 60 }
    var confirmation: ((ToolsValues) -> ToolsConfirmation?)?
    /// Address of a locally served page, offered as "Open in Browser" while the tool runs.
    var browserURL: ((ToolsValues) -> URL?)?
    var build: (ToolsValues, ToolsContext) -> ToolsBuild
}

// MARK: - Helpers

enum ToolsArg {
    /// Values typed by the user must not be mistaken for flags.
    static func isSafe(_ value: String) -> Bool { !value.hasPrefix("-") && !value.contains("\n") }
    static let dashMessage = "Values can't start with a dash."

    static func fileName(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && !value.hasPrefix("-") && !value.contains("\n")
    }
}

// MARK: - Catalog

enum ToolsCatalog {
    static let customID = "custom"

    static let all: [ToolDefinition] = [
        netcheck, ping, dns, ip, status,
        whois, whoami,
        certificate, taildropReceive,
        version, metrics, lockStatus, syspolicy, licenses, bugreport, web,
        custom,
    ]

    static func tool(id: String?) -> ToolDefinition? { all.first { $0.id == id } }

    // MARK: Network

    static let netcheck = ToolDefinition(
        id: "netcheck", title: "Network Check", systemImage: "network",
        summary: "Test UDP, IPv4/IPv6 and the latency to each relay (DERP) region.",
        category: .network,
        inputs: [
            ToolsInput(id: "json", label: "JSON output", kind: .toggle),
            ToolsInput(id: "verbose", label: "Verbose logs", kind: .toggle),
        ],
        timeout: { _ in 90 },
        build: { v, _ in
            var args = ["netcheck"]
            if v.flag("json") { args += ["--format", "json"] }
            if v.flag("verbose") { args.append("--verbose") }
            return .ready(args)
        })

    static let ping = ToolDefinition(
        id: "ping", title: "Ping", systemImage: "dot.radiowaves.left.and.right",
        summary: "Ping a device at the Tailscale layer and see whether the path is direct or relayed.",
        category: .network,
        inputs: [
            ToolsInput(id: "target", label: "Target", kind: .peer(prompt: "Device name or 100.x.y.z")),
            ToolsInput(id: "count", label: "Count", kind: .stepper(0...200, unit: "pings", zeroLabel: "Unlimited"), defaultValue: "10"),
            ToolsInput(id: "timeout", label: "Timeout per ping", kind: .stepper(1...60, unit: "s", zeroLabel: nil), defaultValue: "5"),
            ToolsInput(id: "mode", label: "Method", kind: .menu([
                ToolsChoice(value: "", title: "Tailscale (disco)"),
                ToolsChoice(value: "--tsmp", title: "TSMP"),
                ToolsChoice(value: "--icmp", title: "ICMP"),
                ToolsChoice(value: "--peerapi", title: "PeerAPI"),
            ]), help: "TSMP and ICMP go through WireGuard; PeerAPI tries the peer's HTTP service."),
            ToolsInput(id: "untilDirect", label: "Stop once a direct path is found", kind: .toggle, defaultValue: "1"),
        ],
        runTitle: "Ping",
        timeout: { v in
            let count = v.int("count", 10)
            return count == 0 ? nil : TimeInterval(count * (v.int("timeout", 5) + 1) + 15)
        },
        build: { v, _ in
            let target = v.text("target")
            if target.isEmpty { return .invalid("Enter a device name or Tailscale IP address.") }
            if !ToolsArg.isSafe(target) { return .invalid(ToolsArg.dashMessage) }
            var args = ["ping", "--c", String(v.int("count", 10)), "--timeout", "\(v.int("timeout", 5))s"]
            if !v.flag("untilDirect") { args.append("--until-direct=false") }
            let mode = v.text("mode")
            if !mode.isEmpty { args.append(mode) }
            args.append(target)
            return .ready(args)
        })

    static let dns = ToolDefinition(
        id: "dns", title: "DNS", systemImage: "globe.badge.chevron.backward",
        summary: "Inspect Tailscale's DNS settings or resolve a name through the built-in resolver.",
        category: .network,
        inputs: [
            ToolsInput(id: "mode", label: "Action", kind: .segmented([
                ToolsChoice(value: "status", title: "Status"), ToolsChoice(value: "query", title: "Query"),
            ]), defaultValue: "status"),
            ToolsInput(id: "all", label: "Include advanced details", kind: .toggle,
                       visible: { $0.text("mode") != "query" }),
            ToolsInput(id: "name", label: "Name", kind: .text(prompt: "host.example.ts.net"),
                       visible: { $0.text("mode") == "query" }),
            ToolsInput(id: "type", label: "Record type", kind: .menu(
                ["", "AAAA", "CNAME", "MX", "NS", "PTR", "SRV", "TXT"].map { ToolsChoice(value: $0, title: $0.isEmpty ? "A (default)" : $0) }),
                       visible: { $0.text("mode") == "query" }),
            ToolsInput(id: "json", label: "JSON output", kind: .toggle),
        ],
        timeout: { _ in 30 },
        build: { v, _ in
            if v.text("mode") == "query" {
                let name = v.text("name")
                if name.isEmpty { return .invalid("Enter a name to look up.") }
                if !ToolsArg.isSafe(name) { return .invalid(ToolsArg.dashMessage) }
                var args = ["dns", "query"]
                if v.flag("json") { args.append("--json") }
                args.append(name)
                let type = v.text("type")
                if !type.isEmpty { args.append(type) }
                return .ready(args)
            }
            var args = ["dns", "status"]
            if v.flag("all") { args.append("--all") }
            if v.flag("json") { args.append("--json") }
            return .ready(args)
        })

    static let ip = ToolDefinition(
        id: "ip", title: "IP Addresses", systemImage: "number",
        summary: "Show the Tailscale addresses of this device or of a peer.",
        category: .network,
        inputs: [
            ToolsInput(id: "family", label: "Family", kind: .segmented([
                ToolsChoice(value: "", title: "Both"), ToolsChoice(value: "-4", title: "IPv4"), ToolsChoice(value: "-6", title: "IPv6"),
            ])),
            ToolsInput(id: "one", label: "Only the first address", kind: .toggle),
            ToolsInput(id: "peer", label: "Peer (optional)", kind: .peer(prompt: "This device"),
                       help: "Leave empty for this device."),
        ],
        timeout: { _ in 20 },
        build: { v, _ in
            var args = ["ip"]
            let family = v.text("family")
            if !family.isEmpty { args.append(family) }
            if v.flag("one") { args.append("-1") }
            let peer = v.text("peer")
            if !peer.isEmpty {
                if !ToolsArg.isSafe(peer) { return .invalid(ToolsArg.dashMessage) }
                args.append(peer)
            }
            return .ready(args)
        })

    static let status = ToolDefinition(
        id: "status", title: "Status", systemImage: "list.bullet.below.rectangle",
        summary: "The plain-text status table, as printed by the command line.",
        category: .network,
        inputs: [
            ToolsInput(id: "peers", label: "Show peers", kind: .toggle, defaultValue: "1"),
            ToolsInput(id: "self", label: "Show this device", kind: .toggle, defaultValue: "1"),
            ToolsInput(id: "active", label: "Only peers with active sessions", kind: .toggle),
            ToolsInput(id: "header", label: "Column headers", kind: .toggle),
            ToolsInput(id: "json", label: "JSON output", kind: .toggle),
        ],
        timeout: { _ in 30 },
        build: { v, _ in
            var args = ["status"]
            if !v.flag("peers") { args.append("--peers=false") }
            if !v.flag("self") { args.append("--self=false") }
            if v.flag("active") { args.append("--active") }
            if v.flag("header") { args.append("--header") }
            if v.flag("json") { args.append("--json") }
            return .ready(args)
        })

    // MARK: Identity

    static let whois = ToolDefinition(
        id: "whois", title: "Whois", systemImage: "person.text.rectangle",
        summary: "Find the machine and user behind a Tailscale IP address.",
        category: .identity,
        inputs: [
            ToolsInput(id: "target", label: "IP address", kind: .peer(prompt: "100.64.0.1 or 100.64.0.1:22"),
                       help: "A Tailscale IPv4 or IPv6 address, optionally with a port."),
            ToolsInput(id: "json", label: "JSON output", kind: .toggle),
        ],
        timeout: { _ in 20 },
        build: { v, _ in
            let target = v.text("target")
            if target.isEmpty { return .invalid("Enter a Tailscale IP address.") }
            if !ToolsArg.isSafe(target) { return .invalid(ToolsArg.dashMessage) }
            return .ready(["whois"] + (v.flag("json") ? ["--json"] : []) + [target])
        })

    static let whoami = ToolDefinition(
        id: "whoami", title: "This Device", systemImage: "person.crop.circle",
        summary: "The machine and user identity of this Mac, as the tailnet sees it.",
        category: .identity,
        inputs: [ToolsInput(id: "json", label: "JSON output", kind: .toggle)],
        timeout: { _ in 20 },
        build: { v, _ in .ready(["whoami"] + (v.flag("json") ? ["--json"] : [])) })

    // MARK: Files & certificates

    static let certificate = ToolDefinition(
        id: "cert", title: "Certificates", systemImage: "lock.doc",
        summary: "Get a TLS certificate for one of this device's HTTPS names and save it to a folder.",
        category: .files,
        inputs: [
            ToolsInput(id: "domain", label: "Domain", kind: .certDomain),
            ToolsInput(id: "dir", label: "Save in", kind: .directory),
            ToolsInput(id: "certName", label: "Certificate file", kind: .text(prompt: "DOMAIN.crt"), help: "Leave empty for the default name."),
            ToolsInput(id: "keyName", label: "Private key file", kind: .text(prompt: "DOMAIN.key")),
        ],
        note: "Writes a certificate and its private key into the folder you choose. HTTPS certificates must be enabled for your tailnet.",
        runTitle: "Get Certificate",
        timeout: { _ in 120 },
        confirmation: { v in
            ToolsConfirmation(
                title: "Write certificate files?",
                message: "This requests a certificate and writes it and its private key to \(v.text("dir")). Keep the key file private.",
                button: "Write Files")
        },
        build: { v, ctx in
            var domain = v.text("domain")
            if domain.isEmpty { domain = ctx.certDomains.first ?? "" }
            if domain.isEmpty { return .invalid("No HTTPS domain is available. Enable HTTPS certificates in your tailnet's DNS settings.") }
            if !ToolsArg.isSafe(domain) { return .invalid(ToolsArg.dashMessage) }
            let dir = v.text("dir")
            if dir.isEmpty { return .invalid("Choose a folder to save the files in.") }
            let certName = v.text("certName").isEmpty ? domain + ".crt" : v.text("certName")
            let keyName = v.text("keyName").isEmpty ? domain + ".key" : v.text("keyName")
            guard ToolsArg.fileName(certName), ToolsArg.fileName(keyName) else {
                return .invalid("File names can't contain slashes or start with a dash.")
            }
            let base = (dir as NSString)
            return .ready(["cert", "--cert-file", base.appendingPathComponent(certName), "--key-file", base.appendingPathComponent(keyName), domain])
        })

    static let taildropReceive = ToolDefinition(
        id: "file-get", title: "Taildrop Receive", systemImage: "tray.and.arrow.down",
        summary: "Move files other devices sent you out of the Taildrop inbox into a folder.",
        category: .files,
        inputs: [
            ToolsInput(id: "dir", label: "Save in", kind: .directory),
            ToolsInput(id: "conflict", label: "If a file already exists", kind: .menu([
                ToolsChoice(value: "skip", title: "Skip it"),
                ToolsChoice(value: "rename", title: "Keep both (rename)"),
                ToolsChoice(value: "overwrite", title: "Overwrite"),
            ]), defaultValue: "skip"),
            ToolsInput(id: "wait", label: "Wait for a file if the inbox is empty", kind: .toggle),
            ToolsInput(id: "loop", label: "Keep receiving until stopped", kind: .toggle),
        ],
        runTitle: "Receive",
        timeout: { v in v.flag("wait") || v.flag("loop") ? nil : 120 },
        confirmation: { v in
            let overwrite = v.text("conflict") == "overwrite"
            return ToolsConfirmation(
                title: "Move received files?",
                message: "Files in your Taildrop inbox are moved to \(v.text("dir")) and removed from the inbox."
                    + (overwrite ? " Existing files with the same name will be overwritten." : ""),
                button: "Receive Files")
        },
        build: { v, _ in
            let dir = v.text("dir")
            if dir.isEmpty { return .invalid("Choose a folder to receive files into.") }
            var args = ["file", "get"]
            let conflict = v.text("conflict")
            if !conflict.isEmpty && conflict != "skip" { args.append("--conflict=" + conflict) }
            if v.flag("wait") { args.append("--wait") }
            if v.flag("loop") { args.append("--loop") }
            args.append("--verbose")
            args.append(dir)
            return .ready(args)
        })

    // MARK: System

    static let version = ToolDefinition(
        id: "version", title: "Version & Updates", systemImage: "arrow.down.app",
        summary: "See which version is installed and whether a newer release exists.",
        category: .system,
        inputs: [
            ToolsInput(id: "mode", label: "Action", kind: .menu([
                ToolsChoice(value: "version", title: "Installed version"),
                ToolsChoice(value: "daemon", title: "Client and daemon versions"),
                ToolsChoice(value: "upstream", title: "Latest published release"),
                ToolsChoice(value: "dryrun", title: "Update (dry run)"),
            ]), defaultValue: "version"),
            ToolsInput(id: "track", label: "Release track", kind: .menu([
                ToolsChoice(value: "", title: "Same as installed"),
                ToolsChoice(value: "stable", title: "Stable"),
                ToolsChoice(value: "release-candidate", title: "Release candidate"),
                ToolsChoice(value: "unstable", title: "Unstable"),
            ]), visible: { $0.text("mode") == "upstream" }),
            ToolsInput(id: "json", label: "JSON output", kind: .toggle,
                       visible: { $0.text("mode") != "dryrun" }),
        ],
        note: "The dry run only prints what an update would do. It never installs anything. To update, use the Tailscale app or your package manager.",
        timeout: { _ in 60 },
        build: { v, _ in
            switch v.text("mode") {
            case "dryrun": return .ready(["update", "--dry-run"])
            case "daemon": return .ready(["version", "--daemon"] + (v.flag("json") ? ["--json"] : []))
            case "upstream":
                var args = ["version", "--upstream"]
                if !v.text("track").isEmpty { args += ["--track", v.text("track")] }
                if v.flag("json") { args.append("--json") }
                return .ready(args)
            default: return .ready(["version"] + (v.flag("json") ? ["--json"] : []))
            }
        })

    static let metrics = ToolDefinition(
        id: "metrics", title: "Metrics", systemImage: "chart.xyaxis.line",
        summary: "Current client metrics in Prometheus text format.",
        category: .system,
        timeout: { _ in 30 },
        build: { _, _ in .ready(["metrics", "print"]) })

    static let lockStatus = ToolDefinition(
        id: "lock", title: "Tailnet Lock", systemImage: "lock.shield",
        summary: "Show whether tailnet lock is on and which keys are trusted. Read-only.",
        category: .system,
        inputs: [ToolsInput(id: "json", label: "JSON output", kind: .toggle)],
        timeout: { _ in 30 },
        build: { v, _ in .ready(["lock", "status"] + (v.flag("json") ? ["--json"] : [])) })

    static let syspolicy = ToolDefinition(
        id: "syspolicy", title: "System Policy", systemImage: "building.2",
        summary: "The effective MDM and system policy settings and where they come from.",
        category: .system,
        inputs: [ToolsInput(id: "json", label: "JSON output", kind: .toggle)],
        timeout: { _ in 30 },
        build: { v, _ in .ready(["syspolicy", "list"] + (v.flag("json") ? ["--json"] : [])) })

    static let licenses = ToolDefinition(
        id: "licenses", title: "Licenses", systemImage: "doc.text",
        summary: "Open source license information for Tailscale.",
        category: .system,
        timeout: { _ in 30 },
        build: { _, _ in .ready(["licenses"]) })

    static let bugreport = ToolDefinition(
        id: "bugreport", title: "Bug Report", systemImage: "ladybug",
        summary: "Create a shareable identifier you can give Tailscale support.",
        category: .system,
        inputs: [
            ToolsInput(id: "note", label: "Note (optional)", kind: .text(prompt: "What went wrong?"),
                       help: "Included with the report marker."),
            ToolsInput(id: "diagnose", label: "Run additional in-depth checks", kind: .toggle),
        ],
        note: "This adds a marker to your device's logs, which are uploaded to Tailscale, and prints an identifier you can share with support.",
        runTitle: "Create Report",
        timeout: { _ in 180 },
        confirmation: { _ in
            ToolsConfirmation(
                title: "Create a bug report?",
                message: "Diagnostic logs from this device are uploaded to Tailscale. Nothing is shared until you give the identifier to someone.",
                button: "Create Report")
        },
        build: { v, _ in
            var args = ["bugreport"]
            if v.flag("diagnose") { args.append("--diagnose") }
            let note = v.text("note")
            if !note.isEmpty {
                if !ToolsArg.isSafe(note) { return .invalid(ToolsArg.dashMessage) }
                args.append(note)
            }
            return .ready(args)
        })

    static let web = ToolDefinition(
        id: "web", title: "Web Interface", systemImage: "safari",
        summary: "Run Tailscale's built-in web interface on this Mac until you stop it.",
        category: .system,
        inputs: [
            ToolsInput(id: "port", label: "Port", kind: .text(prompt: "8088"), defaultValue: "8088"),
            ToolsInput(id: "readonly", label: "Read-only", kind: .toggle, defaultValue: "1",
                       help: "Read-only mode shows status but can't change settings."),
        ],
        note: "Starts a local web server on 127.0.0.1 and keeps running until you tap Stop. Closing this screen also stops it.",
        runTitle: "Start",
        timeout: { _ in nil },
        confirmation: { v in
            v.flag("readonly") ? nil : ToolsConfirmation(
                title: "Start the web interface with editing enabled?",
                message: "Anyone using this Mac can change Tailscale settings through the page while it runs.",
                button: "Start")
        },
        browserURL: { v in
            let port = v.text("port")
            return URL(string: "http://127.0.0.1:" + (port.isEmpty ? "8088" : port))
        },
        build: { v, _ in
            guard let port = Int(v.text("port")), (0...65535).contains(port) else {
                return .invalid("Enter a port between 0 and 65535.")
            }
            var args = ["web", "--listen", "127.0.0.1:\(port)"]
            if v.flag("readonly") { args.append("--readonly") }
            return .ready(args)
        })

    // MARK: Advanced

    /// Placeholder entry; `ToolsView` renders it with `ToolsCustomPane`.
    static let custom = ToolDefinition(
        id: customID, title: "Custom Command", systemImage: "terminal",
        summary: "Run any tailscale command with your own arguments.",
        category: .advanced,
        build: { _, _ in .invalid("") })
}
