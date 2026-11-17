import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Tailscale Services (`--service=svc:name`) hosted by this node, the services it can reach, and config import/export.
struct ServicesView: View {
    @EnvironmentObject var store: AppStore

    @State private var editor: ServeEditorRequest?
    @State private var pending: ServePendingAction?
    @State private var listOutput: String?
    @State private var listError: String?
    @State private var listLoading = false

    private var serviceNames: [String] { (store.serveConfig?.services.keys.sorted()) ?? [] }

    var body: some View {
        PageScroll {
            PageHeader("Services",
                       subtitle: "Host named, load-balanced endpoints (svc:name) on your tailnet.",
                       systemImage: "square.stack.3d.up")

            hostedSection
            availableSection
            ServicesConfigCard(serviceNames: serviceNames)
        }
        .serveConfirmations($pending)
        .sheet(item: $editor) { request in
            ServeRuleEditor(request: request).environmentObject(store)
        }
        .task { await loadServiceList() }
    }

    // MARK: Hosted services

    @ViewBuilder
    private var hostedSection: some View {
        HStack {
            Text("Hosted by this node").font(.headline)
            Spacer()
            Button {
                let draft = ServeRule(mode: .https, port: 443, target: .proxy("http://127.0.0.1:8080"), service: nil)
                editor = .add(draft, title: "Add Service Route", requireService: true)
            } label: { Label("Add Service Route", systemImage: "plus") }
                .disabled(store.isBusy || !store.cliAvailable)
        }

        if serviceNames.isEmpty {
            SectionCard {
                EmptyStateView(
                    "No services hosted here",
                    systemImage: "square.stack.3d.up",
                    message: "A Tailscale Service gives a group of backends one stable name (svc:my-app). Define it in the admin console, then add a route here to host it on this node.",
                    actionTitle: "Add Service Route",
                    action: {
                        editor = .add(ServeRule(target: .proxy("http://127.0.0.1:8080")), title: "Add Service Route", requireService: true)
                    })
                    .frame(minHeight: 180)
            }
        } else {
            ForEach(serviceNames, id: \.self) { name in
                ServicesCard(name: name, block: store.serveConfig?.services[name], pending: $pending, editor: $editor)
            }
        }
    }

    // MARK: Available services

    private var availableSection: some View {
        SectionCard("Available to this node",
                    subtitle: "Services in your tailnet that this device can reach (tailscale service list).",
                    systemImage: "network") {
            if listLoading && listOutput == nil {
                HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
            } else if let listError {
                Label(listError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            } else if let output = listOutput {
                if output.isEmpty {
                    Text("No services are available to this node.").foregroundStyle(.secondary)
                } else {
                    OutputConsole(text: output, minHeight: 80)
                        .frame(maxHeight: 220)
                }
            }
            Button { Task { await loadServiceList() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(listLoading || !store.cliAvailable)
        }
    }

    private func loadServiceList() async {
        listLoading = true
        defer { listLoading = false }
        do {
            let result = try await TailscaleCLI.run(["service", "list"], timeout: 15)
            if result.succeeded {
                listOutput = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                listError = nil
            } else {
                listError = result.errorSummary
            }
        } catch {
            listError = error.localizedDescription
        }
    }
}

// MARK: - One hosted service

private struct ServicesCard: View {
    @EnvironmentObject var store: AppStore
    let name: String
    let block: ServeBlock?
    @Binding var pending: ServePendingAction?
    @Binding var editor: ServeEditorRequest?

    private var rules: [ServeRule] { store.serveRules.filter { $0.service == name } }

    var body: some View {
        SectionCard {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(.tint).accessibilityHidden(true)
                Text(name).font(.headline).textSelection(.enabled)
                CopyButton(text: name).help("Copy service name")
                Spacer()
                Button { run(ServeCommands.advertiseArgs(service: name)) } label: { Label("Advertise", systemImage: "megaphone") }
                    .help("Advertise this node as a host for the service (use after a drain)")
                Button { run(ServeCommands.drainArgs(service: name)) } label: { Label("Drain", systemImage: "arrow.down.to.line") }
                    .help("Stop accepting new connections; existing ones continue")
                ConfirmButton("Clear", systemImage: "trash",
                              message: "Remove all routes of \(name) from this node?",
                              confirmTitle: "Clear Service") { run(ServeCommands.clearArgs(service: name)) }
                    .help("Remove all handlers of this service from this node")
            }
            .disabled(store.isBusy)

            if rules.isEmpty {
                Text(block?.tun == true ? "Forwards all traffic to this machine (TUN mode)." : "No routes configured.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { Divider() }
                        ServeRuleRow(
                            rule: rule,
                            showFunnelToggle: false,
                            onEdit: { editor = .edit($0) },
                            onDuplicate: { editor = .duplicate($0, existing: store.serveRules) },
                            pending: $pending)
                    }
                }
            }

            Button {
                let draft = ServeRule(mode: .https, port: 443, target: .proxy("http://127.0.0.1:8080"), service: name)
                editor = .add(draft, title: "Add Route to \(name)", requireService: true, lockService: true)
            } label: { Label("Add Route", systemImage: "plus") }
                .disabled(store.isBusy)
        }
    }

    private func run(_ args: [String]) {
        Task { await store.runTailscale(args, refresh: .serve) }
    }
}

// MARK: - Config export / import

private struct ServicesConfigCard: View {
    @EnvironmentObject var store: AppStore
    let serviceNames: [String]

    /// Empty string means "all services".
    @State private var exportScope = ""
    @State private var importScope = ""
    @State private var exportMessage: String?
    @State private var exportedPath: String?
    @State private var importFile: URL?

    private func scopeLabel(_ scope: String) -> String { scope.isEmpty ? "All services" : scope }

    var body: some View {
        SectionCard("Configuration files",
                    subtitle: "Back up or declaratively manage the services this node hosts.",
                    systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Export").font(.subheadline.weight(.semibold))
                Text("Saves the current service configuration to a JSON file (tailscale serve get-config).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    scopePicker("Services", selection: $exportScope)
                    Button { export() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                        .disabled(store.isBusy || !store.cliAvailable)
                }
                if let exportMessage {
                    HStack(spacing: 8) {
                        Label(exportMessage, systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(.green).textSelection(.enabled)
                        if let exportedPath {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: exportedPath)])
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Import").font(.subheadline.weight(.semibold))
                Text("Replaces the handlers of the chosen services with the contents of a configuration file (tailscale serve set-config). Existing routes of those services are overwritten.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    scopePicker("Apply to", selection: $importScope)
                    Button { chooseImportFile() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                        .disabled(store.isBusy || !store.cliAvailable)
                }
            }
        }
        .confirmationDialog(
            "Replace service configuration?",
            isPresented: Binding(get: { importFile != nil }, set: { if !$0 { importFile = nil } }),
            titleVisibility: .visible,
            presenting: importFile
        ) { file in
            Button("Replace \(importScope.isEmpty ? "All Services" : importScope)", role: .destructive) { runImport(file) }
            Button("Cancel", role: .cancel) {}
        } message: { file in
            Text("\(scopeLabel(importScope)) will be overwritten with the contents of \(file.lastPathComponent). This cannot be undone.")
        }
        .onChange(of: serviceNames) { names in
            if !exportScope.isEmpty, !names.contains(exportScope) { exportScope = "" }
            if !importScope.isEmpty, !names.contains(importScope) { importScope = "" }
        }
    }

    private func scopePicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("All services").tag("")
            ForEach(serviceNames, id: \.self) { Text($0).tag($0) }
        }
        .frame(maxWidth: 320)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.title = "Export Service Configuration"
        panel.nameFieldStringValue = exportScope.isEmpty
            ? "tailscale-services.json"
            : exportScope.replacingOccurrences(of: "svc:", with: "") + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scope = exportScope
        exportMessage = nil
        exportedPath = nil
        Task {
            let args = ServeCommands.getConfigArgs(file: url.path, service: scope.isEmpty ? nil : scope, all: scope.isEmpty)
            let result = await store.runTailscale(args, refresh: .none)
            if result?.succeeded == true {
                exportMessage = "Saved \(url.lastPathComponent)"
                exportedPath = url.path
            }
        }
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import Service Configuration"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { importFile = url }
    }

    private func runImport(_ file: URL) {
        let scope = importScope
        Task {
            let args = ServeCommands.setConfigArgs(file: file.path, service: scope.isEmpty ? nil : scope, all: scope.isEmpty)
            await store.runTailscale(args, refresh: .all)
        }
    }
}
