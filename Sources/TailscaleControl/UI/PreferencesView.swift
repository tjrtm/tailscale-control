import SwiftUI

/// Every `tailscale set` preference as native controls. Edits are collected in a local draft and applied together.
struct PreferencesView: View {
    @EnvironmentObject var store: AppStore

    /// What the user is editing.
    @State private var draft = TailscalePrefs()
    /// The preferences the draft was last synchronised with.
    @State private var baseline: TailscalePrefs?
    @State private var newRoute = ""
    @State private var newEndpoint = ""
    @State private var riskTypes: [String] = []
    @State private var riskMessage = ""
    @State private var showRiskDialog = false

    // MARK: Derived

    private var changes: [PrefChange] {
        guard let baseline else { return [] }
        return PrefsCommands.changes(from: baseline, to: draft)
    }

    /// Problems that make the current draft impossible to apply.
    private var issues: [String] {
        var out: [String] = []
        for route in draft.advertiseRoutes { if let p = PreferencesValidation.routeProblem(route) { out.append(p) } }
        for endpoint in draft.relayServerStaticEndpoints { if let p = PreferencesValidation.endpointProblem(endpoint) { out.append(p) } }
        if let p = PreferencesValidation.relayPortProblem(draft.relayServerPort) { out.append(p) }
        return out
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Preferences", subtitle: "Settings applied with “tailscale set”.", systemImage: "gearshape")
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)
            if baseline == nil {
                if !store.cliAvailable {
                    EmptyStateView("Tailscale not found", systemImage: "exclamationmark.triangle",
                                   message: "Install Tailscale from tailscale.com/download, or set the path to the command-line tool in Settings.")
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Loading preferences…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                form
                applyBar
            }
        }
        .onAppear { adoptStorePrefs(force: baseline == nil) }
        .onChange(of: store.prefs) { _ in adoptStorePrefs(force: false) }
        .confirmationDialog("Accept the risk?", isPresented: $showRiskDialog, titleVisibility: .visible) {
            Button("Apply Anyway", role: .destructive) { apply(acceptRisk: riskTypes) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tailscale flagged this change as risky (\(riskTypes.joined(separator: ", "))):\n\(riskMessage)\nApplying it will add --accept-risk=\(riskTypes.joined(separator: ",")).")
        }
    }

    // MARK: Form

    private var form: some View {
        FormPage {
            Section("Networking") {
                prefToggle("Accept DNS settings", isOn: $draft.acceptDNS,
                           help: "Use the DNS configuration from the admin console, including MagicDNS.")
                prefToggle("Accept subnet routes", isOn: $draft.acceptRoutes,
                           help: "Use routes advertised by other devices on your tailnet.")
                prefToggle("Shields up", isOn: $draft.shieldsUp,
                           help: "Block all incoming connections from other devices.")
                prefToggle("Allow local network access with an exit node", isOn: $draft.exitNodeAllowLANAccess,
                           help: "Keep direct access to your local network while traffic goes through an exit node.")
            }

            Section("Sharing this device") {
                prefToggle("Advertise as exit node", isOn: $draft.advertiseExitNode,
                           help: "Offer this device as an exit node for internet traffic. An admin must approve it.")
                StringListEditor(
                    title: "Advertise routes",
                    help: "Subnets this device offers to the tailnet, in CIDR form such as 192.168.1.0/24.",
                    placeholder: "192.168.1.0/24",
                    items: $draft.advertiseRoutes,
                    newItem: $newRoute,
                    problem: PreferencesValidation.routeProblem)
                prefToggle("Advertise as app connector", isOn: $draft.advertiseConnector,
                           help: "Offer to be an app connector for domain-specific traffic on the tailnet.")
                prefField("Relay server port", text: $draft.relayServerPort, prompt: "Empty to disable",
                          help: "UDP port for this device to relay traffic for others. 0 picks a random free port; empty turns the relay server off.",
                          problem: PreferencesValidation.relayPortProblem(draft.relayServerPort))
                StringListEditor(
                    title: "Relay server static endpoints",
                    help: "Fixed IP:port endpoints to advertise as relay candidates, for example 192.0.2.1:40000.",
                    placeholder: "192.0.2.1:40000",
                    items: $draft.relayServerStaticEndpoints,
                    newItem: $newEndpoint,
                    problem: PreferencesValidation.endpointProblem)
            }

            Section("Access") {
                prefToggle("Tailscale SSH server", isOn: $draft.ssh,
                           help: "Run an SSH server on this device, with access governed by your tailnet policy.")
                prefToggle("Web client", isOn: $draft.webclient,
                           help: "Expose a web interface for managing this device over Tailscale, on port 5252.")
                prefToggle("Report device posture", isOn: $draft.reportPosture,
                           help: "Let the management service collect device posture information.")
                prefField("Operator user", text: $draft.operatorUser, prompt: "None",
                          help: "Unix user allowed to operate the Tailscale daemon without sudo.")
            }

            Section("Identity") {
                prefField("Hostname", text: $draft.hostname, prompt: "Use the system name",
                          help: "Name to use in the tailnet instead of the one provided by macOS.")
                prefField("Account nickname", text: $draft.nickname, prompt: "None",
                          help: "A nickname for the current account, shown when switching accounts.")
            }

            Section("Updates") {
                prefToggle("Update automatically", isOn: $draft.autoUpdate,
                           help: "Install the latest Tailscale version automatically.")
                prefToggle("Check for updates", isOn: $draft.updateCheck,
                           help: "Notify when a new Tailscale version is available.")
            }

            Section {
                Text("Some preferences are not supported by every Tailscale variant on macOS. If the command-line tool rejects a change, its message is shown above and the setting stays as it was.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(store.isBusy)
    }

    private func prefToggle(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: isOn).toggleStyle(.switch)
            Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func prefField(_ title: String, text: Binding<String>, prompt: String, help: String, problem: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField(title, text: text, prompt: Text(prompt))
                .autocorrectionDisabled()
            Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
    }

    // MARK: Apply bar

    private var applyBar: some View {
        let pending = changes
        let problems = issues
        return VStack(alignment: .leading, spacing: 8) {
            Divider()
            if pending.isEmpty {
                Text("No pending changes.").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 20)
            } else {
                CommandPreview(args: PrefsCommands.setArgs(pending)).padding(.horizontal, 20)
            }
            if let first = problems.first {
                Label(first, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
            }
            HStack {
                if store.isBusy {
                    ProgressView().controlSize(.small)
                    Text(store.busyDescription ?? "Working…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Revert") { revert() }
                    .disabled(pending.isEmpty || store.isBusy)
                Button("Apply") { apply(acceptRisk: []) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(pending.isEmpty || !problems.isEmpty || store.isBusy)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .background(.bar)
    }

    // MARK: Actions

    /// Take over the stored preferences when the user has no unapplied edits (or when `force` is set).
    private func adoptStorePrefs(force: Bool) {
        guard let latest = store.prefs else { return }
        if force || baseline == nil || draft == baseline || PrefsCommands.changes(from: latest, to: draft).isEmpty {
            draft = latest
            baseline = latest
        }
    }

    private func revert() {
        if let baseline { draft = baseline }
        newRoute = ""
        newEndpoint = ""
    }

    private func apply(acceptRisk: [String]) {
        let pending = changes
        guard !pending.isEmpty else { return }
        Task {
            let ok = await store.setPrefs(pending, acceptRisk: acceptRisk)
            if ok {
                if let latest = store.prefs { draft = latest; baseline = latest }
                newRoute = ""
                newEndpoint = ""
            } else if acceptRisk.isEmpty, let message = store.lastError {
                let types = PreferencesValidation.acceptRiskTypes(in: message)
                if !types.isEmpty {
                    riskTypes = types
                    riskMessage = message
                    showRiskDialog = true
                }
            }
        }
    }
}

/// Editable list of strings (CIDR routes, endpoints): existing items with a remove button and a validated "add" field.
struct StringListEditor: View {
    var title: String
    var help: String
    var placeholder: String
    @Binding var items: [String]
    @Binding var newItem: String
    /// Returns a message when the text is not acceptable.
    var problem: (String) -> String?

    private var trimmed: String { newItem.trimmingCharacters(in: .whitespaces) }

    private var addProblem: String? {
        if trimmed.isEmpty { return nil }
        if items.contains(trimmed) { return "“\(trimmed)” is already in the list." }
        return problem(trimmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if items.isEmpty {
                Text("None").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack {
                    Text(item).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    if let issue = problem(item) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(issue)
                            .accessibilityLabel(issue)
                    }
                    Spacer()
                    Button {
                        if items.indices.contains(index) { items.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(item)")
                    .accessibilityLabel("Remove \(item)")
                }
            }
            HStack {
                TextField("Add", text: $newItem, prompt: Text(placeholder))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(trimmed.isEmpty || addProblem != nil)
            }
            if let addProblem { Text(addProblem).font(.caption).foregroundStyle(.red) }
        }
    }

    private func add() {
        guard !trimmed.isEmpty, addProblem == nil else { return }
        items.append(trimmed)
        newItem = ""
    }
}
