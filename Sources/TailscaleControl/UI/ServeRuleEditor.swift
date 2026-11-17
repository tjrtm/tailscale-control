import AppKit
import SwiftUI

// MARK: - Editor request

/// Describes one editor sheet: what to prefill and whether it replaces an existing route.
struct ServeEditorRequest: Identifiable {
    let id = UUID()
    /// Initial values.
    var rule: ServeRule
    /// The route being edited; nil when adding or duplicating.
    var replacing: ServeRule?
    /// The Service name is mandatory (adding a service route).
    var requireService = false
    /// The Service name is fixed and cannot be changed.
    var lockService = false
    var title: String

    static func add(_ rule: ServeRule, title: String = "Add Route", requireService: Bool = false, lockService: Bool = false) -> ServeEditorRequest {
        ServeEditorRequest(rule: rule, replacing: nil, requireService: requireService, lockService: lockService, title: title)
    }

    static func edit(_ rule: ServeRule) -> ServeEditorRequest {
        ServeEditorRequest(rule: rule, replacing: rule, title: "Edit Route")
    }

    /// A copy of `rule` that does not overwrite the original: it takes the first free public port, and Funnel starts off.
    static func duplicate(_ rule: ServeRule, existing: [ServeRule]) -> ServeEditorRequest {
        var copy = rule
        copy.funnel = false
        copy.isForeground = false
        let taken = Set(existing.filter { !$0.isForeground }.map(\.identity))
        if taken.contains(copy.identity) {
            let candidates = ServeRule.funnelPorts + [80, 8080, 8000]
            for port in candidates {
                copy.port = port
                if !taken.contains(copy.identity) { break }
            }
            if taken.contains(copy.identity), copy.mode.isWeb {
                copy.mountPath = (copy.normalizedMount == "/" ? "" : copy.normalizedMount) + "/copy"
            }
        }
        return ServeEditorRequest(rule: copy, replacing: nil, title: "Duplicate Route")
    }
}

// MARK: - Form fields

/// Editable text/enum state behind the editor. Composes (and validates) a `ServeRule`.
struct ServeRuleFields: Equatable {
    enum TargetKind: String, CaseIterable, Identifiable {
        case localPort, url, path, text
        var id: String { rawValue }
        var title: String {
            switch self {
            case .localPort: return "Local port"
            case .url: return "URL or proxy"
            case .path: return "File or folder"
            case .text: return "Static text"
            }
        }
    }

    static let webSchemes = ["http", "https", "https+insecure"]

    var mode: ServeRule.Mode = .https
    var portText = "443"
    var mountPath = "/"
    var funnel = false
    var kind: TargetKind = .localPort
    var scheme = "http"
    var host = "127.0.0.1"
    var localPort = ""
    var url = ""
    var path = ""
    var text = ""
    var service = ""
    /// 0 = none.
    var proxyProtocol = 0
    var caps = ""

    init(rule: ServeRule) {
        mode = rule.mode
        portText = String(rule.port)
        mountPath = rule.normalizedMount
        funnel = rule.funnel
        service = rule.service ?? ""
        proxyProtocol = rule.proxyProtocol ?? 0
        caps = rule.acceptAppCaps.joined(separator: ", ")
        switch rule.target {
        case .proxy(let raw):
            if let parsed = Self.parseLocal(raw) {
                kind = .localPort; scheme = parsed.scheme; host = parsed.host; localPort = parsed.port
            } else {
                kind = .url; url = raw
            }
        case .path(let p): kind = .path; path = p
        case .text(let t): kind = .text; text = t
        }
    }

    /// `http://127.0.0.1:3000`, `tcp://host:5432` or a bare `3000` split into parts; nil for anything else.
    static func parseLocal(_ raw: String) -> (scheme: String, host: String, port: String)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty, s.allSatisfy(\.isNumber) { return ("http", "127.0.0.1", s) }
        let pattern = #"^(https\+insecure|https|http|tcp)://(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9_.\-]+):([0-9]{1,5})/?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges == 4 else { return nil }
        var host = ns.substring(with: m.range(at: 2))
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return (ns.substring(with: m.range(at: 1)), host, ns.substring(with: m.range(at: 3)))
    }

    var availableKinds: [TargetKind] { mode.isWeb ? TargetKind.allCases : [.localPort, .url] }

    /// Scheme actually used for a "Local port" target.
    var effectiveScheme: String {
        mode.isWeb ? (Self.webSchemes.contains(scheme) ? scheme : "http") : "tcp"
    }

    var capsList: [String] {
        caps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var normalizedService: String? {
        let s = service.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        return s.hasPrefix("svc:") ? s : "svc:" + s
    }

    /// Why Funnel cannot be used with the current fields; nil when it can.
    var funnelBlockReason: String? {
        if mode == .http { return "Funnel needs HTTPS, TCP or TLS-terminated TCP. Plain HTTP cannot be public." }
        if let port = Int(portText.trimmingCharacters(in: .whitespaces)), ServeRule.funnelPorts.contains(port) {} else {
            return "Funnel only works on ports 443, 8443 and 10000."
        }
        if normalizedService != nil { return "Funnel cannot be combined with a Tailscale Service." }
        if mode.isWeb, !capsList.isEmpty { return "Funnel does not support app capabilities." }
        return nil
    }

    /// Build and validate the rule. Exactly one of the two results is non-nil.
    func compose(requireService: Bool = false) -> (rule: ServeRule?, message: String?) {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)) else {
            return (nil, "Enter the Tailscale port as a number from 1 to 65535.")
        }
        if requireService, normalizedService == nil {
            return (nil, "Enter a service name, for example svc:web.")
        }
        let target: ServeRule.Target
        switch kind {
        case .localPort:
            let h = host.trimmingCharacters(in: .whitespaces)
            guard !h.isEmpty else { return (nil, "Enter a host name or IP address for the target.") }
            let hostPart = (h.contains(":") && !h.hasPrefix("[")) ? "[\(h)]" : h
            target = .proxy("\(effectiveScheme)://\(hostPart):\(localPort.trimmingCharacters(in: .whitespaces))")
        case .url:
            target = .proxy(url.trimmingCharacters(in: .whitespacesAndNewlines))
        case .path:
            let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
            target = .path(p.hasPrefix("~") ? (p as NSString).expandingTildeInPath : p)
        case .text:
            target = .text(text)
        }
        let rule = ServeRule(
            mode: mode, port: port, mountPath: mode.isWeb ? mountPath : "/", target: target,
            funnel: funnel && funnelBlockReason == nil, service: normalizedService,
            proxyProtocol: (!mode.isWeb && proxyProtocol != 0) ? proxyProtocol : nil,
            acceptAppCaps: mode.isWeb ? capsList : [])
        do { try rule.validate() } catch { return (nil, error.localizedDescription) }
        return (rule, nil)
    }
}

// MARK: - Editor view

/// Sheet for adding, editing and duplicating a serve/funnel route.
struct ServeRuleEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let request: ServeEditorRequest
    @State private var f: ServeRuleFields
    @State private var showAdvanced: Bool
    @State private var saving = false

    init(request: ServeEditorRequest) {
        self.request = request
        let fields = ServeRuleFields(rule: request.rule)
        _f = State(initialValue: fields)
        let advanced = fields.normalizedService != nil || fields.proxyProtocol != 0 || !fields.capsList.isEmpty || request.requireService
        _showAdvanced = State(initialValue: advanced)
    }

    private var composed: (rule: ServeRule?, message: String?) { f.compose(requireService: request.requireService) }

    /// A different existing route that saving would overwrite.
    private var conflict: ServeRule? {
        guard let rule = composed.rule else { return nil }
        if request.replacing?.identity == rule.identity { return nil }
        return store.serveRules.first { !$0.isForeground && $0.identity == rule.identity }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(request.title)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 0)

            Form {
                exposureSection
                targetSection
                advancedSection
            }
            .formStyle(.grouped)
            .disabled(store.isBusy)

            Divider()
            footer
        }
        .frame(width: 600)
        .frame(minHeight: 460, idealHeight: 600, maxHeight: 680)
        .onAppear { store.dismissError() }
        .onChange(of: f.mode) { newMode in
            if !newMode.isWeb, f.kind == .path || f.kind == .text { f.kind = .localPort }
            if !newMode.isWeb { f.mountPath = "/" }
        }
    }

    // MARK: Sections

    private var exposureSection: some View {
        Section {
            Picker("Type", selection: $f.mode) {
                ForEach(ServeRule.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            LabeledContent("Port") {
                HStack(spacing: 6) {
                    TextField("Port", text: $f.portText, prompt: Text("443"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    ForEach([443, 8443, 10000, 80], id: \.self) { port in
                        Button(String(port)) { f.portText = String(port) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel(Text(verbatim: "Use port \(port)"))
                    }
                }
            }
            if f.mode.isWeb {
                TextField("Mount path", text: $f.mountPath, prompt: Text("/"))
            }
            Toggle(isOn: Binding(
                get: { f.funnel && f.funnelBlockReason == nil },
                set: { f.funnel = $0 }
            )) {
                Label("Share publicly with Funnel", systemImage: "globe")
            }
            .disabled(f.funnelBlockReason != nil)
        } header: {
            Text("Exposure")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(modeDescription)
                if let reason = f.funnelBlockReason {
                    Text(reason)
                } else if f.funnel {
                    Label("Anyone on the internet can reach this route.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text("Only devices on your tailnet can reach this route.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var modeDescription: String {
        switch f.mode {
        case .https: return "Serves a web app over HTTPS with an automatic Tailscale certificate."
        case .http: return "Serves a web app over plain HTTP inside your tailnet."
        case .tcp: return "Forwards raw TCP connections, such as a database or SSH."
        case .tlsTerminatedTCP: return "Terminates TLS with a Tailscale certificate, then forwards the plain TCP stream."
        }
    }

    private var targetSection: some View {
        Section {
            Picker("Target", selection: $f.kind) {
                ForEach(f.availableKinds) { Text($0.title).tag($0) }
            }
            switch f.kind {
            case .localPort:
                LabeledContent("Address") {
                    HStack(spacing: 4) {
                        if f.mode.isWeb {
                            Picker("Scheme", selection: $f.scheme) {
                                Text("http").tag("http")
                                Text("https").tag("https")
                                Text("https, skip certificate check").tag("https+insecure")
                            }
                            .labelsHidden()
                            .fixedSize()
                            Text("://").foregroundStyle(.secondary)
                        }
                        TextField("Host", text: $f.host, prompt: Text("127.0.0.1"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(minWidth: 100, maxWidth: .infinity)
                        Text(":").foregroundStyle(.secondary)
                        TextField("Port", text: $f.localPort, prompt: Text("3000"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                    }
                    .font(.system(.body, design: .monospaced))
                }
            case .url:
                TextField("Address", text: $f.url, prompt: Text(f.mode.isWeb ? "http://127.0.0.1:3000" : "tcp://127.0.0.1:5432"))
                    .font(.system(.body, design: .monospaced))
            case .path:
                HStack {
                    TextField("Path", text: $f.path, prompt: Text("/path/to/folder"))
                    Button("Choose…", action: choosePath)
                }
            case .text:
                TextField("Text", text: $f.text, prompt: Text("Hello from Tailscale"), axis: .vertical)
                    .lineLimit(2...6)
            }
        } header: {
            Text("Target")
        } footer: {
            // The local-port form explains itself; the other target kinds get a short hint.
            if f.kind != .localPort { Text(targetHint).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var targetHint: String {
        switch f.kind {
        case .localPort: return f.mode.isWeb ? "A service running on this Mac, usually 127.0.0.1." : "A TCP service, usually on this Mac."
        case .url:
            return f.mode.isWeb
                ? "http://, https://, https+insecure:// (skips certificate checks), host:port or unix:/path/to.sock."
                : "tcp://host:port or just host:port."
        case .path: return "An absolute path to a file or folder. Folders are served as a static site."
        case .text: return "Serves this text as the response."
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                if request.lockService {
                    LabeledContent("Service") { Text(f.service).font(.system(.body, design: .monospaced)) }
                } else {
                    TextField("Service", text: $f.service, prompt: Text("svc:my-service"))
                }
                Text(request.requireService
                     ? "This route is hosted as a Tailscale Service."
                     : "Optional. Host this route as a Tailscale Service instead of on this node.")
                    .font(.caption).foregroundStyle(.secondary)

                if f.mode.isWeb {
                    TextField("App capabilities", text: $f.caps, prompt: Text("example.com/cap/foo, example.com/cap/bar"))
                    Text("Comma-separated. Passed to the backend in the Tailscale-App-Capabilities header.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("PROXY protocol", selection: $f.proxyProtocol) {
                        Text("None").tag(0)
                        Text("Version 1").tag(1)
                        Text("Version 2").tag(2)
                    }
                    Text("Sends the client's address to the backend using the PROXY protocol.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = composed.message {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let conflict {
                Label("This replaces the existing route \(conflict.summary).", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let rule = composed.rule {
                VStack(spacing: 6) {
                    ForEach(Array(ServeRule.editPlan(from: request.replacing, to: rule).enumerated()), id: \.offset) { _, step in
                        CommandPreview(args: step)
                    }
                }
            } else {
                Text("The command appears here once the route is valid.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = store.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    CopyButton(text: error)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
            }

            HStack {
                if store.isBusy || saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.replacing == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(composed.rule == nil || store.isBusy || saving)
            }
        }
        .padding(16)
    }

    // MARK: Actions

    private func save() {
        guard let rule = composed.rule, !store.isBusy, !saving else { return }
        saving = true
        Task {
            let ok = await store.apply(rule: rule, replacing: request.replacing)
            saving = false
            if ok { dismiss() }
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the file or folder to serve."
        if panel.runModal() == .OK, let url = panel.url { f.path = url.path }
    }
}
