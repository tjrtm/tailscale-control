import AppKit
import SwiftUI

/// UserDefaults key (and `@AppStorage` key) for the menu bar icon toggle. Default: true.
let showMenuBarIconKey = "showMenuBarIcon"
/// Identifier of the main window scene (use with `openWindow(id:)`).
let mainWindowID = "main"

final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [showMenuBarIconKey: true])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Come to the front on launch, also when started directly from a terminal or script
        // (a non-activated launch can leave the window parked as a miniature on recent macOS).
        NSApp.activate(ignoringOtherApps: true)
        guard CommandLine.arguments.contains("--close-self-test") else { return }
        // Smoke test: make sure a window opened, then quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let opened = NSApp.windows.contains { $0.canBecomeMain && $0.isVisible }
            print(opened ? "PASS close-self-test (window opened)" : "FAIL close-self-test (no visible window)")
            exit(opened ? 0 : 2)
        }
    }

    /// Keep running in the menu bar when the icon is enabled; otherwise quit with the last window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !UserDefaults.standard.bool(forKey: showMenuBarIconKey)
    }
}

struct TailscaleControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @AppStorage(showMenuBarIconKey) private var showMenuBarIcon = true

    var body: some Scene {
        Window("Tailscale Control", id: mainWindowID) {
            RootView()
                .environmentObject(store)
        }
        .defaultSize(width: 1040, height: 700)
        .commands { AppCommands(store: store) }

        MenuBarExtra("Tailscale Control", systemImage: "point.3.connected.trianglepath.dotted", isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            AppSettingsView()
                .environmentObject(store)
        }
    }
}

/// Menu bar commands: Refresh (⌘R) and section navigation (⌘1…⌘8).
struct AppCommands: Commands {
    let store: AppStore

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Refresh") { Task { await store.refreshAll() } }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { section.navigate() }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}

/// App settings (⌘,).
struct AppSettingsView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage(showMenuBarIconKey) private var showMenuBarIcon = true
    @AppStorage(TailscaleCLI.pathDefaultsKey) private var tailscalePath = ""

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show icon in the menu bar", isOn: $showMenuBarIcon)
                Text("When the icon is hidden, closing the window quits the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tailscale command-line tool") {
                TextField("Custom path (optional)", text: $tailscalePath, prompt: Text("/usr/local/bin/tailscale"))
                    .onSubmit { Task { await store.refreshAll() } }
                LabeledContent("In use") {
                    Text(DemoMode.isEnabled ? "Demo mode (nothing is run)" : (TailscaleCLI.resolveBinary() ?? "Not found"))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 300)
    }
}
