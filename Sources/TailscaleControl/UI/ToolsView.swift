import AppKit
import SwiftUI

/// Remembers input values per tool, the custom-command text and its history while the screen is alive.
final class ToolsModel: ObservableObject {
    @Published var selectedID: String? = ToolsCatalog.all.first?.id
    @Published var values: [String: ToolsValues] = [:]
    @Published var customText = ""
    @Published var history: [String] = []

    static let historyLimit = 20

    /// Inputs with their defaults filled in.
    func resolved(_ tool: ToolDefinition) -> ToolsValues {
        var result = ToolsValues()
        for input in tool.inputs { result.raw[input.id] = input.defaultValue }
        for (key, value) in values[tool.id]?.raw ?? [:] { result.raw[key] = value }
        return result
    }

    func binding(_ tool: ToolDefinition, _ input: ToolsInput) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.values[tool.id]?.raw[input.id] ?? input.defaultValue },
            set: { [weak self] in self?.values[tool.id, default: ToolsValues()].raw[input.id] = $0 })
    }

    func remember(_ command: String) {
        guard !command.isEmpty else { return }
        history.removeAll { $0 == command }
        history.insert(command, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }
}

/// Native front-ends for the rest of the `tailscale` command line.
struct ToolsView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var model = ToolsModel()
    @StateObject private var runner = ToolsStreamRunner()

    var body: some View {
        HSplitView {
            toolList
                .frame(minWidth: 180, idealWidth: 210, maxWidth: 260)
            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.selectedID) { _ in runner.reset() }
        .onDisappear { runner.cancel() }
    }

    private var toolList: some View {
        List(selection: $model.selectedID) {
            ForEach(ToolDefinition.Category.allCases) { category in
                let tools = ToolsCatalog.all.filter { $0.category == category }
                if !tools.isEmpty {
                    Section(category.rawValue) {
                        ForEach(tools) { tool in
                            Label(tool.title, systemImage: tool.systemImage)
                                .tag(tool.id as String?)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if model.selectedID == ToolsCatalog.customID {
            ToolsCustomPane(model: model, runner: runner)
        } else if let tool = ToolsCatalog.tool(id: model.selectedID) {
            ToolsPane(tool: tool, model: model, runner: runner)
                .id(tool.id)
        } else {
            EmptyStateView("Choose a tool", systemImage: "wrench.and.screwdriver",
                           message: "Pick a diagnostic from the list.")
        }
    }
}

// MARK: - One tool

struct ToolsPane: View {
    @EnvironmentObject var store: AppStore
    let tool: ToolDefinition
    @ObservedObject var model: ToolsModel
    @ObservedObject var runner: ToolsStreamRunner

    @State private var pending: ToolsConfirmation?
    @State private var showConfirm = false

    private var values: ToolsValues { model.resolved(tool) }

    private var context: ToolsContext {
        var ctx = ToolsContext()
        guard let status = store.status else { return ctx }
        ctx.certDomains = status.certDomains
        var peers: [ToolsPeerOption] = []
        if let me = status.selfNode, let ip = me.primaryIP { peers.append(ToolsPeerOption(name: me.displayName + " (this device)", ip: ip)) }
        for peer in status.sortedPeers {
            if let ip = peer.primaryIP { peers.append(ToolsPeerOption(name: peer.displayName, ip: ip)) }
        }
        ctx.peers = peers
        return ctx
    }

    private var built: ToolsBuild { tool.build(values, context) }

    /// The address the web tool printed, else the configured one.
    private var browserURL: URL? {
        guard tool.browserURL != nil, runner.isRunning else { return nil }
        return ToolsPane.firstURL(in: runner.output) ?? tool.browserURL?(values)
    }

    var body: some View {
        let ctx = context
        let current = values
        VStack(spacing: 0) {
            PageHeader(tool.title, subtitle: tool.summary, systemImage: tool.systemImage)
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
            Form {
                if let note = tool.note {
                    Section {
                        Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    }
                }
                let visibleInputs = tool.inputs.filter { $0.visible(current) }
                if !visibleInputs.isEmpty {
                    Section("Options") {
                        ForEach(visibleInputs) { input in
                            ToolsInputRow(input: input, value: model.binding(tool, input), context: ctx)
                                .disabled(runner.isRunning)
                        }
                    }
                }
                Section("Command") {
                    switch tool.build(current, ctx) {
                    case .ready(let args): CommandPreview(args: args)
                    case .invalid(let message): Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    runBar
                }
                Section("Output") {
                    OutputConsole(text: runner.output, minHeight: 200, autoScroll: true)
                        .frame(height: 280)
                    HStack {
                        if let result = runner.lastResult, !runner.isRunning {
                            Label(result.succeeded ? "Finished" : "Failed", systemImage: result.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .font(.callout)
                                .foregroundStyle(result.succeeded ? Color.green : Color.red)
                        }
                        Spacer()
                        CopyButton(text: runner.output, title: "Copy")
                            .disabled(runner.output.isEmpty)
                        Button("Clear") { runner.clearOutput() }
                            .disabled(runner.output.isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .confirmationDialog(pending?.title ?? "Run this tool?", isPresented: $showConfirm, titleVisibility: .visible, presenting: pending) { _ in
            Button(pending?.button ?? "Run") { execute() }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var runBar: some View {
        HStack(spacing: 10) {
            if runner.isRunning {
                Button { runner.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                ProgressView().controlSize(.small)
            } else {
                Button { run() } label: { Label(tool.runTitle, systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isReady || (tool.confirmation != nil && store.isBusy))
            }
            Spacer()
            if let url = browserURL {
                Button { NSWorkspace.shared.open(url) } label: { Label("Open in Browser", systemImage: "safari") }
                    .help(url.absoluteString)
            }
        }
    }

    private var isReady: Bool {
        if case .ready = built { return true }
        return false
    }

    private func run() {
        guard !runner.isRunning, case .ready = built else { return }
        if let confirmation = tool.confirmation?(values) {
            pending = confirmation
            showConfirm = true
        } else {
            execute()
        }
    }

    private func execute() {
        guard case .ready(let args) = built else { return }
        runner.start(args, timeout: tool.timeout(values), store: store)
    }

    /// First http(s) URL in `text`.
    static func firstURL(in text: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s\"'<>]+") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), let r = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[r]))
    }
}

// MARK: - Input control

/// Renders one `ToolsInput` as a native control.
struct ToolsInputRow: View {
    let input: ToolsInput
    @Binding var value: String
    let context: ToolsContext

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            control
            if let help = input.help {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch input.kind {
        case .text(let prompt):
            TextField(input.label, text: $value, prompt: Text(prompt))
                .disableAutocorrection(true)
        case .peer(let prompt):
            HStack {
                TextField(input.label, text: $value, prompt: Text(prompt))
                    .disableAutocorrection(true)
                Menu {
                    if context.peers.isEmpty {
                        Text("No devices")
                    } else {
                        ForEach(context.peers) { peer in
                            Button("\(peer.name) · \(peer.ip)") { value = peer.ip }
                        }
                    }
                } label: {
                    Image(systemName: "laptopcomputer.and.iphone")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose a device")
                .accessibilityLabel("Choose a device")
            }
        case .toggle:
            Toggle(input.label, isOn: Binding(get: { value == "1" }, set: { value = $0 ? "1" : "" }))
        case .menu(let choices):
            Picker(input.label, selection: $value) {
                ForEach(choices) { Text($0.title).tag($0.value) }
            }
        case .segmented(let choices):
            Picker(input.label, selection: $value) {
                ForEach(choices) { Text($0.title).tag($0.value) }
            }
            .pickerStyle(.segmented)
        case .stepper(let range, let unit, let zeroLabel):
            let number = Binding<Int>(
                get: { min(max(Int(value) ?? range.lowerBound, range.lowerBound), range.upperBound) },
                set: { value = String($0) })
            Stepper(value: number, in: range) {
                LabeledContent(input.label) {
                    Text(number.wrappedValue == 0 && zeroLabel != nil ? (zeroLabel ?? "") : "\(number.wrappedValue) \(unit)")
                        .monospacedDigit()
                }
            }
        case .directory:
            LabeledContent(input.label) {
                HStack(spacing: 8) {
                    Text(value.isEmpty ? "No folder chosen" : (value as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(value.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Choose…") { chooseDirectory() }
                }
            }
        case .certDomain:
            if context.certDomains.isEmpty {
                LabeledContent(input.label) {
                    Text("None available").foregroundStyle(.secondary)
                }
            } else {
                Picker(input.label, selection: Binding(
                    get: { value.isEmpty ? (context.certDomains.first ?? "") : value },
                    set: { value = $0 })) {
                    ForEach(context.certDomains, id: \.self) { Text($0).tag($0) }
                }
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = input.label
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !value.isEmpty { panel.directoryURL = URL(fileURLWithPath: value) }
        if panel.runModal() == .OK, let url = panel.url { value = url.path }
    }
}
