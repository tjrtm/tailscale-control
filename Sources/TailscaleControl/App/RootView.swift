import SwiftUI

/// Sidebar sections of the main window.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview, serve, services, devices, exitNodes, preferences, tools, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .serve: return "Serve & Funnel"
        case .services: return "Services"
        case .devices: return "Devices"
        case .exitNodes: return "Exit Nodes"
        case .preferences: return "Preferences"
        case .tools: return "Tools"
        case .activity: return "Activity Log"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .serve: return "arrow.triangle.branch"
        case .services: return "square.stack.3d.up"
        case .devices: return "laptopcomputer.and.iphone"
        case .exitNodes: return "arrow.up.right.circle"
        case .preferences: return "gearshape"
        case .tools: return "wrench.and.screwdriver"
        case .activity: return "list.bullet.rectangle"
        }
    }

    /// A section requested while no window was listening (for example from the menu bar while the window is closed).
    /// The main window applies it when it appears.
    private(set) static var pendingNavigation: SidebarSection?

    /// Take (and clear) the pending section.
    static func takePendingNavigation() -> SidebarSection? {
        defer { pendingNavigation = nil }
        return pendingNavigation
    }

    /// Switch the main window to this section (works from any view or command, with or without an open window).
    func navigate() {
        SidebarSection.pendingNavigation = self
        NotificationCenter.default.post(name: .navigateToSection, object: rawValue)
    }
}

extension Notification.Name {
    /// Posted with the `SidebarSection.rawValue` as `object`.
    static let navigateToSection = Notification.Name("TailscaleControl.navigateToSection")
}

/// Main window content: sidebar plus the selected section.
struct RootView: View {
    @EnvironmentObject var store: AppStore
    @SceneStorage("selectedSection") private var selectedRaw = SidebarSection.overview.rawValue

    private var selection: Binding<SidebarSection?> {
        Binding(
            get: { SidebarSection(rawValue: selectedRaw) ?? .overview },
            set: { if let value = $0 { selectedRaw = value.rawValue } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            VStack(spacing: 0) {
                ErrorBanner()
                detail(for: SidebarSection(rawValue: selectedRaw) ?? .overview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle((SidebarSection(rawValue: selectedRaw) ?? .overview).title)
            .toolbar {
                if store.isDemo {
                    ToolbarItem(placement: .primaryAction) { DemoBadge() }
                }
                ToolbarItem(placement: .primaryAction) { ConnectionIndicator() }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await store.refreshAll() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Refresh (⌘R)")
                        .disabled(store.isRefreshing)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSection)) { note in
            if let raw = note.object as? String, SidebarSection(rawValue: raw) != nil {
                selectedRaw = raw
                _ = SidebarSection.takePendingNavigation()
            }
        }
        .task { await store.refreshAll() }
        .onAppear {
            // `--section=<name>` / `--show=<sheet>` open a specific screen at launch (see `LaunchOptions`).
            if let section = LaunchOptions.takeSection() { selectedRaw = section.rawValue }
            // A navigation request made while the window was closed.
            if let pending = SidebarSection.takePendingNavigation() { selectedRaw = pending.rawValue }
            store.startAutoRefresh()
        }
        .onDisappear { store.stopAutoRefresh() }
    }

    @ViewBuilder
    private func detail(for section: SidebarSection) -> some View {
        switch section {
        case .overview: OverviewView()
        case .serve: ServeView()
        case .services: ServicesView()
        case .devices: DevicesView()
        case .exitNodes: ExitNodesView()
        case .preferences: PreferencesView()
        case .tools: ToolsView()
        case .activity: ActivityLogView()
        }
    }
}
