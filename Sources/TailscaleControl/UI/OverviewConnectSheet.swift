import SwiftUI

/// Three-way choice for a boolean flag: leave it out, force on, or force off.
private enum FlagChoice: String, CaseIterable, Identifiable {
    case unset, on, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .unset: return "Default"
        case .on: return "On"
        case .off: return "Off"
        }
    }
    var value: Bool? {
        switch self {
        case .unset: return nil
        case .on: return true
        case .off: return false
        }
    }
}

/// Sheet for `tailscale up` with explicit options and a live command preview.
struct OverviewConnectSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    // Authentication
    @State private var authKey = ""
    @State private var loginServer = ""
    @State private var forceReauth = FlagChoice.unset
    // Identity
    @State private var hostname = ""
    @State private var tags = ""
    // Networking
    @State private var acceptDNS = FlagChoice.unset
    @State private var acceptRoutes = FlagChoice.unset
    @State private var shieldsUp = FlagChoice.unset
    // Access
    @State private var ssh = FlagChoice.unset
    @State private var operatorUser = ""
    @State private var reportPosture = FlagChoice.unset
    // Sharing
    @State private var advertiseExitNode = FlagChoice.unset
    @State private var advertiseRoutes = ""
    @State private var advertiseConnector = FlagChoice.unset
    // Exit node
    @State private var exitNode = ""
    @State private var exitNodeAllowLAN = FlagChoice.unset
    // Behavior
    @State private var reset = false
    @State private var timeoutText = ""
    @State private var acceptRisk = "none"
    @State private var running = false

    // MARK: Derived

    private func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func list(_ text: String) -> [String]? {
        let items = text.split(whereSeparator: { $0 == "," || $0 == " " }).map { String($0) }.filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    private var timeoutSeconds: Int? {
        guard let text = trimmed(timeoutText), let value = Int(text), value > 0 else { return nil }
        return value
    }

    private var options: UpOptions {
        var o = UpOptions()
        o.authKey = trimmed(authKey)
        o.loginServer = trimmed(loginServer)
        o.forceReauth = forceReauth.value
        o.hostname = trimmed(hostname)
        o.advertiseTags = list(tags)
        o.acceptDNS = acceptDNS.value
        o.acceptRoutes = acceptRoutes.value
        o.shieldsUp = shieldsUp.value
        o.ssh = ssh.value
        o.operatorUser = trimmed(operatorUser)
        o.reportPosture = reportPosture.value
        o.advertiseExitNode = advertiseExitNode.value
        o.advertiseRoutes = list(advertiseRoutes)
        o.advertiseConnector = advertiseConnector.value
        o.exitNode = trimmed(exitNode)
        o.exitNodeAllowLANAccess = exitNodeAllowLAN.value
        o.reset = reset ? true : nil
        if let timeoutSeconds { o.timeout = TimeInterval(timeoutSeconds) }
        if acceptRisk != "none" { o.acceptRisk = [acceptRisk] }
        return o
    }

    private var problems: [String] {
        var out: [String] = []
        if let routes = list(advertiseRoutes) {
            for route in routes { if let p = PreferencesValidation.routeProblem(route) { out.append(p) } }
        }
        if !timeoutText.trimmingCharacters(in: .whitespaces).isEmpty, timeoutSeconds == nil {
            out.append("The timeout must be a whole number of seconds.")
        }
        return out
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Connect with options", subtitle: "Runs “tailscale up” with exactly the flags below.", systemImage: "slider.horizontal.3")
                .padding(20)
            Form {
                Section("Authentication") {
                    SecureField("Auth key", text: $authKey, prompt: Text("tskey-auth-… or file:/path"))
                    TextField("Login server", text: $loginServer, prompt: Text("Default (Tailscale)"))
                    flagPicker("Force re-authentication", $forceReauth)
                }
                Section("Identity") {
                    TextField("Hostname", text: $hostname, prompt: Text("Use the system name"))
                    TextField("Advertise tags", text: $tags, prompt: Text("tag:server, tag:prod"))
                }
                Section("Networking") {
                    flagPicker("Accept DNS settings", $acceptDNS)
                    flagPicker("Accept subnet routes", $acceptRoutes)
                    flagPicker("Shields up", $shieldsUp)
                }
                Section("Access") {
                    flagPicker("Tailscale SSH server", $ssh)
                    TextField("Operator user", text: $operatorUser, prompt: Text("None"))
                    flagPicker("Report device posture", $reportPosture)
                }
                Section("Sharing this device") {
                    flagPicker("Advertise as exit node", $advertiseExitNode)
                    TextField("Advertise routes", text: $advertiseRoutes, prompt: Text("192.168.1.0/24, 10.0.0.0/8"))
                    flagPicker("Advertise as app connector", $advertiseConnector)
                }
                Section("Exit node") {
                    TextField("Use exit node", text: $exitNode, prompt: Text("IP, name or auto:any"))
                    flagPicker("Allow local network access", $exitNodeAllowLAN)
                }
                Section("Behavior") {
                    Toggle("Reset unspecified settings to defaults", isOn: $reset)
                    Text("“tailscale up” needs the complete set of settings you want. Without Reset, the CLI refuses flags that would change other non-default settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Timeout (seconds)", text: $timeoutText, prompt: Text("Wait for the connection, e.g. 60"))
                    Picker("Accept risk", selection: $acceptRisk) {
                        Text("None").tag("none")
                        Text("lose-ssh").tag("lose-ssh")
                        Text("mac-app-connector").tag("mac-app-connector")
                        Text("all").tag("all")
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(running)

            VStack(alignment: .leading, spacing: 8) {
                Divider()
                CommandPreview(args: PrefsCommands.upArgs(options: options)).padding(.horizontal, 20)
                if let problem = problems.first {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
                }
                ErrorBanner()
                HStack {
                    if running {
                        ProgressView().controlSize(.small)
                        Text("Waiting for “tailscale up”…").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { authKey = ""; dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(running)
                    Button("Connect") { run() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(running || store.isBusy || !problems.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 560, idealHeight: 720)
        .onAppear { store.dismissError() }
    }

    private func flagPicker(_ title: String, _ selection: Binding<FlagChoice>) -> some View {
        Picker(title, selection: selection) {
            ForEach(FlagChoice.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Run

    private func run() {
        let args = PrefsCommands.upArgs(options: options)
        let flagTimeout = timeoutSeconds ?? 0
        running = true
        Task {
            store.pendingAuthURL = nil
            let result = await store.runTailscale(args, timeout: max(60, TimeInterval(flagTimeout) + 15))
            running = false
            if let result, result.succeeded {
                authKey = ""
                dismiss()
            } else if let result, result.timedOut, store.pendingAuthURL != nil {
                // Waiting for browser sign-in: the login link is shown on the Overview page.
                authKey = ""
                dismiss()
            }
            // Otherwise stay open so the error banner stays visible and the options can be adjusted.
        }
    }
}
