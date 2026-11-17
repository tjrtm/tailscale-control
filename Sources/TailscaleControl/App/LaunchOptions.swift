import Foundation

/// Launch arguments that open a specific screen state. They exist for documentation screenshots.
///
/// * `--section=<name>`: select a sidebar section (`overview`, `serve`, `services`, `devices`, `exitNodes`, `preferences`, `tools`, `activity`).
/// * `--show=add-route`: open the Serve route editor (implies the Serve section).
/// * `--show=connect-options`: open Overview's "Connect with options" sheet (implies the Overview section).
/// * `--demo`: fictional data, no commands executed (see `DemoMode`).
enum LaunchOptions {
    private static func value(of name: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
    }

    private static var sectionApplied = false

    /// Section requested with `--section=` or implied by `--show=`; returned once so reopening the window keeps the user's choice.
    static func takeSection() -> SidebarSection? {
        guard !sectionApplied else { return nil }
        sectionApplied = true
        return requestedSection
    }

    private static var requestedSection: SidebarSection? {
        if let raw = value(of: "section"), let section = SidebarSection(rawValue: raw) { return section }
        switch value(of: "show") {
        case "add-route": return .serve
        case "connect-options": return .overview
        default: return nil
        }
    }

    private static var consumed = Set<String>()

    /// True once for a `--show=<name>` argument; the view that handles it opens its sheet.
    static func consumeShow(_ name: String) -> Bool {
        guard value(of: "show") == name, !consumed.contains(name) else { return false }
        consumed.insert(name)
        return true
    }
}
