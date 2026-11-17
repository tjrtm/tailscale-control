import AppKit
import SwiftUI

// Shared building blocks for all section views. They use system colors, SF Symbols and standard
// controls so they adapt to light/dark mode automatically.

// MARK: - Formatting

/// Small formatting helpers for tables and detail rows.
enum Fmt {
    /// `1.5 MB`-style byte count.
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
    /// "5 minutes ago" / "in 2 days"; `fallback` when `date` is nil.
    static func relative(_ date: Date?, fallback: String = "—") -> String {
        guard let date else { return fallback }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
    /// Medium date + short time.
    static func dateTime(_ date: Date?, fallback: String = "—") -> String {
        guard let date else { return fallback }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Clipboard

enum Clipboard {
    /// Put plain text on the general pasteboard.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Status

extension BackendState {
    /// System color representing the state.
    var color: Color {
        switch self {
        case .running: return .green
        case .starting, .needsMachineAuth: return .orange
        case .needsLogin: return .yellow
        case .stopped: return .gray
        case .noState, .unknown: return .secondary
        }
    }
}

/// Colored circle for connection/online state.
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 9

    init(state: BackendState, size: CGFloat = 9) { self.color = state.color; self.size = size }
    /// Green when online, gray otherwise.
    init(online: Bool, size: CGFloat = 9) { self.color = online ? .green : .gray; self.size = size }
    init(color: Color, size: CGFloat = 9) { self.color = color; self.size = size }

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Dot + short label for a backend state (used in the toolbar and headers).
struct StatusBadge: View {
    var state: BackendState
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(state: state)
            Text(state.title).font(.callout)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Buttons

/// Copies `text` to the clipboard and briefly shows a checkmark.
struct CopyButton: View {
    var text: String
    /// Optional visible label next to the icon.
    var title: String?
    @State private var copied = false

    init(text: String, title: String? = nil) { self.text = text; self.title = title }

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            if let title {
                Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .buttonStyle(.borderless)
        .help("Copy to clipboard")
        .accessibilityLabel(title ?? "Copy")
    }
}

/// A button that asks for confirmation (macOS confirmation dialog) before running a destructive action.
struct ConfirmButton: View {
    var title: String
    var systemImage: String?
    /// Dialog title.
    var message: String
    /// Label of the confirming button.
    var confirmTitle: String
    var role: ButtonRole?
    var action: () -> Void
    @State private var showing = false

    init(_ title: String, systemImage: String? = nil, message: String, confirmTitle: String = "Confirm",
         role: ButtonRole? = .destructive, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.message = message
        self.confirmTitle = confirmTitle; self.role = role; self.action = action
    }

    var body: some View {
        Button(role: role) { showing = true } label: {
            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
        }
        .confirmationDialog(message, isPresented: $showing, titleVisibility: .visible) {
            Button(confirmTitle, role: role, action: action)
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Command preview & console

/// Monospaced, selectable preview of a `tailscale` command with a copy button.
/// Pass the sub-arguments (without the binary), e.g. `rule.applyArgs()`.
struct CommandPreview: View {
    var args: [String]
    var prefix: String = "tailscale"

    init(args: [String], prefix: String = "tailscale") { self.args = args; self.prefix = prefix }

    private var line: String { CommandRunner.displayCommandLine([prefix] + args) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(text: line)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }
}

/// Monospaced, scrollable, selectable text area for command output.
struct OutputConsole: View {
    var text: String
    var minHeight: CGFloat = 120
    /// Keep the end of the text in view as it grows (for streaming output).
    var autoScroll = false

    init(text: String, minHeight: CGFloat = 120, autoScroll: Bool = false) {
        self.text = text; self.minHeight = minHeight; self.autoScroll = autoScroll
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? " " : text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("console-end")
                }
                .padding(8)
            }
            .onChange(of: text) { _ in
                if autoScroll { proxy.scrollTo("console-end", anchor: .bottom) }
            }
        }
        .frame(minHeight: minHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }
}

// MARK: - Layout helpers

/// Title block at the top of a section view.
struct PageHeader: View {
    var title: String
    var subtitle: String?
    var systemImage: String?

    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.title = title; self.subtitle = subtitle; self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage).font(.title).foregroundStyle(.tint).frame(width: 32)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A titled rounded card for free-form (non-`Form`) pages.
struct SectionCard<Content: View>: View {
    var title: String?
    var subtitle: String?
    var systemImage: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, subtitle: String? = nil, systemImage: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.subtitle = subtitle; self.systemImage = systemImage; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title {
                        if let systemImage { Label(title, systemImage: systemImage).font(.headline) }
                        else { Text(title).font(.headline) }
                    }
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

/// Scrollable page container with standard padding, for pages built from `PageHeader` and `SectionCard`s.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content() }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Grouped-`Form` page: standard native settings look. Use `Section` inside.
struct FormPage<Content: View>: View {
    @ViewBuilder var content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    var body: some View {
        Form { content() }
            .formStyle(.grouped)
    }
}

/// Label on the left, selectable value on the right, optional copy button. For use inside `Form` or cards.
struct KeyValueRow: View {
    var label: String
    var value: String
    var monospaced = false
    var copyable = false

    init(_ label: String, _ value: String, monospaced: Bool = false, copyable: Bool = false) {
        self.label = label; self.value = value; self.monospaced = monospaced; self.copyable = copyable
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(value.isEmpty ? "—" : value)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
                if copyable && !value.isEmpty { CopyButton(text: value) }
            }
        }
    }
}

// MARK: - Empty / error states

/// Centered placeholder for empty lists and not-yet-available data.
struct EmptyStateView: View {
    var title: String
    var systemImage: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    init(_ title: String, systemImage: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title; self.systemImage = systemImage; self.message = message
        self.actionTitle = actionTitle; self.action = action
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).padding(.top, 4)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Red banner showing `store.lastError` with a dismiss button. Renders nothing when there is no error.
struct ErrorBanner: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if let message = store.lastError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyButton(text: message)
                Button { store.dismissError() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss error")
            }
            .padding(10)
            .background(Color.red.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

/// Small capsule shown in the toolbar while the app runs in demo mode (`--demo`).
struct DemoBadge: View {
    var body: some View {
        Text("Demo")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.2)))
            .foregroundStyle(Color.orange)
            .help("Demo mode: fictional data, no commands are executed")
            .accessibilityLabel("Demo mode")
    }
}

/// Toolbar item content: connection dot, label and a spinner while refreshing or running a command.
struct ConnectionIndicator: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 8) {
            if store.isRefreshing || store.isBusy { ProgressView().controlSize(.small) }
            if store.cliAvailable {
                StatusBadge(state: store.backendState)
            } else {
                HStack(spacing: 6) { StatusDot(color: .red); Text("Tailscale not found").font(.callout) }
            }
        }
        .help(store.selfDNSName ?? "Tailscale connection state")
    }
}
