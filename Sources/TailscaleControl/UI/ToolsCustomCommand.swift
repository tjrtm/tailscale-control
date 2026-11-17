import AppKit
import SwiftUI

// MARK: - Tokenizer

/// Splits a command line into arguments the way a POSIX shell would for quotes and backslashes,
/// but never expands anything (no variables, globs, pipes or substitutions). The result is passed as argv.
enum ToolsTokenizer {
    enum Failure: LocalizedError {
        case unterminatedQuote
        case trailingBackslash
        var errorDescription: String? {
            switch self {
            case .unterminatedQuote: return "A quote is not closed."
            case .trailingBackslash: return "The line ends with a backslash."
            }
        }
    }

    static func tokenize(_ line: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if let q = quote {
                if ch == q {
                    quote = nil
                } else if ch == "\\" && q == "\"" {
                    // Inside double quotes a backslash only escapes these characters.
                    if i + 1 < chars.count, "\\\"$`".contains(chars[i + 1]) {
                        current.append(chars[i + 1]); i += 1
                    } else {
                        current.append(ch)
                    }
                } else {
                    current.append(ch)
                }
            } else if ch == "'" || ch == "\"" {
                quote = ch; inToken = true
            } else if ch == "\\" {
                guard i + 1 < chars.count else { throw Failure.trailingBackslash }
                current.append(chars[i + 1]); inToken = true; i += 1
            } else if ch.isWhitespace {
                if inToken { tokens.append(current); current = ""; inToken = false }
            } else {
                current.append(ch); inToken = true
            }
            i += 1
        }
        if quote != nil { throw Failure.unterminatedQuote }
        if inToken { tokens.append(current) }
        return tokens
    }

    /// Tokenize and drop a leading `tailscale` the user may have typed out of habit.
    static func arguments(from line: String) throws -> [String] {
        var tokens = try tokenize(line)
        if tokens.first == "tailscale" { tokens.removeFirst() }
        return tokens
    }
}

// MARK: - Safety

/// Decides whether a custom command can skip the confirmation dialog.
enum ToolsCommandSafety {
    static let readOnlyCommands: Set<String> = [
        "status", "ip", "version", "netcheck", "whois", "whoami", "ping", "dns", "licenses", "get", "exit-node", "appc-routes",
    ]
    /// Commands that are read-only only for these subcommands.
    static let readOnlySubcommands: [String: Set<String>] = [
        "serve": ["status"], "funnel": ["status"], "lock": ["status", "log"], "syspolicy": ["list"],
        "metrics": ["print"], "service": ["list"],
    ]

    static func isReadOnly(_ args: [String]) -> Bool {
        guard let first = args.first else { return false }
        if args.contains(where: { $0 == "--help" || $0 == "-h" || $0 == "-help" }) { return true }
        if args.contains("--web") { return false }
        if readOnlyCommands.contains(first) { return true }
        if let allowed = readOnlySubcommands[first], args.count > 1 { return allowed.contains(args[1]) }
        return false
    }
}

// MARK: - Pane

/// "Custom command" tool: arbitrary `tailscale` arguments, confirmation for anything not known to be read-only.
struct ToolsCustomPane: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var model: ToolsModel
    @ObservedObject var runner: ToolsStreamRunner

    @State private var pending: [String]?
    @State private var showConfirm = false
    @FocusState private var fieldFocused: Bool

    private enum Parsed {
        case empty
        case failed(String)
        case ready([String])
    }

    private var parsed: Parsed {
        if model.customText.trimmingCharacters(in: .whitespaces).isEmpty { return .empty }
        do {
            let args = try ToolsTokenizer.arguments(from: model.customText)
            return args.isEmpty ? .empty : .ready(args)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader("Custom Command", subtitle: "Run any tailscale command. Arguments are passed directly, never through a shell.",
                       systemImage: "terminal")
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
            Form {
                Section("Command") {
                    HStack(spacing: 8) {
                        Text("tailscale").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        TextField("Arguments", text: $model.customText, prompt: Text("status --json"))
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .focused($fieldFocused)
                            .disableAutocorrection(true)
                            .onSubmit { run() }
                        Menu {
                            if model.history.isEmpty {
                                Text("No history yet")
                            } else {
                                ForEach(model.history, id: \.self) { entry in
                                    Button(entry) { model.customText = entry }
                                }
                                Divider()
                                Button("Clear History") { model.history = [] }
                            }
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Recent commands")
                        .accessibilityLabel("Command history")
                    }
                    switch parsed {
                    case .empty:
                        Text("Type the arguments, for example “ip -4” or “whois 100.64.0.1”. Quote values that contain spaces.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                    case .ready(let args):
                        CommandPreview(args: args)
                        if ToolsCommandSafety.isReadOnly(args) {
                            Label("Read-only command", systemImage: "eye").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label("Not on the read-only list. You'll be asked to confirm.", systemImage: "exclamationmark.shield")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    HStack {
                        if runner.isRunning {
                            Button { runner.cancel() } label: { Label("Stop", systemImage: "stop.fill") }
                            ProgressView().controlSize(.small)
                        } else {
                            Button { run() } label: { Label("Run", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.return, modifiers: .command)
                                .disabled(!isReady || store.isBusy)
                        }
                        Spacer()
                    }
                }
                Section("Output") {
                    OutputConsole(text: runner.output, minHeight: 220, autoScroll: true)
                        .frame(height: 300)
                    HStack {
                        Spacer()
                        CopyButton(text: runner.output, title: "Copy")
                        Button("Clear") { runner.clearOutput() }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .confirmationDialog("Run this command?", isPresented: $showConfirm, titleVisibility: .visible, presenting: pending) { args in
            Button("Run") { execute(args) }
            Button("Cancel", role: .cancel) {}
        } message: { args in
            Text(CommandRunner.displayCommandLine(["tailscale"] + args)
                 + "\n\nThis command isn't on the read-only list, so it may change settings or state.")
        }
        .onAppear { fieldFocused = true }
    }

    private var isReady: Bool {
        if case .ready = parsed { return true }
        return false
    }

    private func run() {
        guard !runner.isRunning, !store.isBusy, case .ready(let args) = parsed else { return }
        if ToolsCommandSafety.isReadOnly(args) {
            execute(args)
        } else {
            pending = args
            showConfirm = true
        }
    }

    private func execute(_ args: [String]) {
        model.remember(model.customText.trimmingCharacters(in: .whitespacesAndNewlines))
        // Mutating commands reload the app's data when they finish.
        runner.start(args, timeout: nil, store: store, refreshAfter: !ToolsCommandSafety.isReadOnly(args))
    }
}
