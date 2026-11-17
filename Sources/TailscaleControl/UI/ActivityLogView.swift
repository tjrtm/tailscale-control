import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// History of every command the app ran, newest first.
struct ActivityLogView: View {
    @EnvironmentObject var store: AppStore

    @State private var selection: UUID?
    @State private var search = ""
    @State private var kindFilter: ActivityEntry.Kind?
    @State private var failuresOnly = false
    @State private var confirmClear = false
    @State private var exportMessage: String?

    private var filtered: [ActivityEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.activity.filter { entry in
            if let kindFilter, entry.kind != kindFilter { return false }
            if failuresOnly, entry.succeeded { return false }
            if !query.isEmpty,
               !entry.commandLine.localizedCaseInsensitiveContains(query),
               !entry.output.localizedCaseInsensitiveContains(query) { return false }
            return true
        }
    }

    private var selectedEntry: ActivityEntry? {
        guard let selection else { return nil }
        return store.activity.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader("Activity Log",
                           subtitle: "Everything this app ran on your behalf during this session. Secrets are masked.",
                           systemImage: "list.bullet.rectangle")
                toolbar
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
            Divider()
            if store.activity.isEmpty {
                EmptyStateView("No activity yet", systemImage: "list.bullet.rectangle",
                               message: "Commands you run from Tailscale Control, such as changing settings, pinging a device or using a tool, show up here.")
            } else {
                HSplitView {
                    list
                        .frame(minWidth: 320, idealWidth: 400)
                    detail
                        .frame(minWidth: 300, idealWidth: 420)
                }
            }
        }
        .confirmationDialog("Clear the activity log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Log", role: .destructive) { selection = nil; store.clearActivity() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all \(store.activity.count) entries from this session. It does not undo any command.")
        }
        .alert("Export", isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportMessage ?? "")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search commands and output", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor)))
            .frame(maxWidth: 320)

            Picker("Kind", selection: $kindFilter) {
                Text("All kinds").tag(ActivityEntry.Kind?.none)
                Divider()
                ForEach(ActivityEntry.Kind.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.systemImage).tag(ActivityEntry.Kind?.some(kind))
                }
            }
            .labelsHidden()
            .frame(width: 140)
            .help("Filter by kind")

            Toggle("Failures only", isOn: $failuresOnly)
                .toggleStyle(.checkbox)

            Spacer(minLength: 0)

            Text(countLabel).font(.callout).foregroundStyle(.secondary)

            Button { export() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                .disabled(filtered.isEmpty)
                .help("Save the shown entries as a text file")
            Button(role: .destructive) { confirmClear = true } label: { Label("Clear", systemImage: "trash") }
                .disabled(store.activity.isEmpty)
        }
    }

    private var countLabel: String {
        let shown = filtered.count, total = store.activity.count
        return shown == total ? "\(total) \(total == 1 ? "entry" : "entries")" : "\(shown) of \(total)"
    }

    // MARK: List

    private var list: some View {
        Group {
            if filtered.isEmpty {
                EmptyStateView("No matching entries", systemImage: "line.3.horizontal.decrease.circle",
                               message: "Change the search or filters to see more.",
                               actionTitle: "Reset Filters") { search = ""; kindFilter = nil; failuresOnly = false }
            } else {
                List(filtered, selection: $selection) { entry in
                    ActivityLogRow(entry: entry).tag(entry.id)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let entry = selectedEntry {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: statusSymbol(entry)).foregroundStyle(statusColor(entry))
                    Text(statusText(entry)).font(.headline)
                    Spacer()
                    Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(entry.commandLine)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                HStack(spacing: 12) {
                    Label(entry.kind.title, systemImage: entry.kind.systemImage)
                    if entry.duration > 0 { Label(durationText(entry.duration), systemImage: "stopwatch") }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if entry.output.isEmpty {
                    Text("This command produced no output.").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    OutputConsole(text: entry.output, minHeight: 160)
                }
                HStack {
                    CopyButton(text: entry.commandLine, title: "Copy Command")
                    CopyButton(text: entry.output, title: "Copy Output").disabled(entry.output.isEmpty)
                    Spacer()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            EmptyStateView("Select an entry", systemImage: "text.alignleft",
                           message: "Pick a command on the left to see its full output.")
        }
    }

    private func statusSymbol(_ entry: ActivityEntry) -> String {
        if entry.exitCode == nil { return "info.circle.fill" }
        return entry.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill"
    }

    private func statusColor(_ entry: ActivityEntry) -> Color {
        if entry.exitCode == nil { return .secondary }
        return entry.succeeded ? .green : .red
    }

    private func statusText(_ entry: ActivityEntry) -> String {
        guard let code = entry.exitCode else { return "Note" }
        switch code {
        case 0: return "Succeeded"
        case 124: return "Timed out"
        case 127: return "Could not start"
        default: return "Failed (exit status \(code))"
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.1f s", seconds)
    }

    // MARK: Export

    private func export() {
        let entries = filtered
        guard !entries.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Activity Log"
        panel.nameFieldStringValue = "tailscale-control-activity.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ActivityLogFormat.text(for: entries).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportMessage = "Could not save the file: \(error.localizedDescription)"
        }
    }
}

/// Plain-text rendering of log entries for export.
enum ActivityLogFormat {
    static func text(for entries: [ActivityEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        var out = "Tailscale Control activity log\nExported \(formatter.string(from: Date())) (\(entries.count) entries, newest first)\n"
        for entry in entries {
            out += "\n" + String(repeating: "=", count: 72) + "\n"
            out += "[\(formatter.string(from: entry.timestamp))] \(entry.kind.title)\n"
            out += "$ \(entry.commandLine)\n"
            if let code = entry.exitCode {
                out += "exit status: \(code), duration: \(String(format: "%.2f", entry.duration)) s\n"
            }
            if !entry.output.isEmpty { out += "\n\(entry.output)\n" }
        }
        return out
    }
}

private struct ActivityLogRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.top, 2)
                .accessibilityLabel(entry.kind.title)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.commandLine)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    if entry.duration > 0 {
                        Text(entry.duration < 1 ? "\(Int((entry.duration * 1000).rounded())) ms" : String(format: "%.1f s", entry.duration))
                    }
                    Text(entry.kind.title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            statusIcon
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIcon: some View {
        if entry.exitCode == nil {
            Image(systemName: "info.circle").foregroundStyle(.secondary).accessibilityLabel("Note")
        } else if entry.succeeded {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Succeeded")
        } else {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel("Failed")
        }
    }
}
