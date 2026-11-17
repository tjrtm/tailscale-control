import Foundation
import SwiftUI

/// Which read-only data to reload after a command.
struct RefreshScope: OptionSet, Sendable {
    let rawValue: Int
    static let status = RefreshScope(rawValue: 1 << 0)
    static let serve = RefreshScope(rawValue: 1 << 1)
    static let prefs = RefreshScope(rawValue: 1 << 2)
    static let profiles = RefreshScope(rawValue: 1 << 3)
    static let none: RefreshScope = []
    static let all: RefreshScope = [.status, .serve, .prefs, .profiles]
}

/// One user-initiated command in the activity log.
struct ActivityEntry: Identifiable, Hashable {
    /// Rough category, derived from the first argument. Useful for icons and filters.
    enum Kind: String, CaseIterable, Hashable {
        case serve, funnel, prefs, connection, tool, info
        init(args: [String]) {
            switch args.first ?? "" {
            case "serve": self = .serve
            case "funnel": self = .funnel
            case "set": self = .prefs
            case "up", "down", "login", "logout", "switch": self = .connection
            default: self = .tool
            }
        }
        var title: String {
            switch self {
            case .serve: return "Serve"
            case .funnel: return "Funnel"
            case .prefs: return "Preferences"
            case .connection: return "Connection"
            case .tool: return "Tools"
            case .info: return "Info"
            }
        }
        var systemImage: String {
            switch self {
            case .serve: return "arrow.triangle.branch"
            case .funnel: return "globe"
            case .prefs: return "gearshape"
            case .connection: return "bolt.horizontal"
            case .tool: return "wrench.and.screwdriver"
            case .info: return "info.circle"
            }
        }
    }

    let id = UUID()
    let timestamp: Date
    /// Display command line (`tailscale serve ...`), secrets masked.
    let commandLine: String
    /// `nil` for informational entries or commands that never started.
    let exitCode: Int32?
    let output: String
    let kind: Kind
    let duration: TimeInterval

    /// True for exit code 0 and informational entries.
    var succeeded: Bool { exitCode == nil || exitCode == 0 }
}

/// Central, main-actor app state. Views read the `@Published` properties and call the action methods.
///
/// Read-only refreshes are silent; only user-initiated commands (`runTailscale`, `runPlan` and the helpers built on them)
/// are written to `activity`.
@MainActor
final class AppStore: ObservableObject {
    // MARK: Published state

    @Published private(set) var status: TailscaleStatus?
    @Published private(set) var serveConfig: ServeConfig?
    /// `serveConfig` flattened to rules for this node's DNS name.
    @Published private(set) var serveRules: [ServeRule] = []
    @Published private(set) var prefs: TailscalePrefs?
    /// Peers offering to be exit nodes.
    @Published private(set) var exitNodes: [PeerStatus] = []
    @Published private(set) var profiles: [TailscaleProfile] = []
    @Published private(set) var version: TailscaleVersionInfo?
    /// Running containers with published ports, filled by `refreshDocker()`.
    @Published private(set) var dockerTargets: [DockerTarget] = []
    @Published private(set) var dockerError: String?

    /// Latest user-facing error (command failure, validation, or failed refresh). Cleared with `dismissError()`.
    @Published var lastError: String?
    /// True while any refresh is in flight.
    @Published private(set) var isRefreshing = false
    /// True while a user-initiated command is running.
    @Published private(set) var isBusy = false
    /// Display command line of the running command, for progress UI.
    @Published private(set) var busyDescription: String?
    private var busyCount = 0
    /// False when no `tailscale` binary could be found.
    @Published private(set) var cliAvailable = true
    @Published private(set) var lastRefresh: Date?
    /// Newest entries first, capped at `activityLimit`.
    @Published private(set) var activity: [ActivityEntry] = []
    /// Login URL found in the output of a connection command (e.g. `up`), if any.
    @Published var pendingAuthURL: URL?

    static let activityLimit = 300

    // MARK: Derived state

    /// True when launched with `--demo`: all data is fictional and no command is executed.
    var isDemo: Bool { DemoMode.isEnabled }

    /// True when the backend state is `Running`.
    var isRunning: Bool { status?.isRunning ?? false }
    /// Typed connection state (`.noState` before the first refresh).
    var backendState: BackendState { status?.state ?? .noState }
    /// This node's MagicDNS name without the trailing dot, e.g. `host.example.ts.net`.
    var selfDNSName: String? {
        guard let name = status?.selfNode?.dnsName, !name.isEmpty else { return nil }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }
    /// Display name of the current tailnet.
    var tailnetName: String? {
        let name = status?.currentTailnet?.name ?? ""
        return name.isEmpty ? nil : name
    }
    /// Login URL from status (`NeedsLogin`) or from the last connection command.
    var authURL: URL? {
        if let s = status?.authURL, !s.isEmpty, let url = URL(string: s) { return url }
        return pendingAuthURL
    }

    // MARK: Init

    init() {}

    private var statusInFlight = false
    private var autoRefreshClients = 0
    private var autoRefreshTask: Task<Void, Never>?

    // MARK: Refresh (silent, read-only)

    /// Reload status, serve config, prefs and profiles concurrently.
    func refreshAll() async { await refresh(.all) }

    /// Reload status (and the exit-node list derived from it).
    func refreshStatus() async { await refresh(.status) }

    /// Reload the serve configuration.
    func refreshServe() async { await refresh(.serve) }

    /// Reload preferences.
    func refreshPrefs() async { await refresh(.prefs) }

    /// Reload the pieces named by `scope` concurrently. Failures set `lastError` but keep previous data.
    func refresh(_ scope: RefreshScope) async {
        if scope.isEmpty { return }
        if scope == .status {
            if statusInFlight { return }
            statusInFlight = true
        }
        defer { if scope == .status { statusInFlight = false } }
        isRefreshing = true
        defer { isRefreshing = false }

        // Plain unstructured tasks (rather than `async let`) so the reads run concurrently.
        let statusTask = scope.contains(.status) ? Task { await Self.capture { try await TailscaleCLI.status() } } : nil
        let serveTask = scope.contains(.serve) ? Task { await Self.capture { try await TailscaleCLI.serveConfig() } } : nil
        let prefsTask = scope.contains(.prefs) ? Task { await Self.capture { try await TailscaleCLI.prefs() } } : nil
        let profilesTask = scope.contains(.profiles) ? Task { await Self.capture { try await TailscaleCLI.profiles() } } : nil
        let s = await statusTask?.value
        let sv = await serveTask?.value
        let p = await prefsTask?.value
        let pr = await profilesTask?.value

        var firstError: Error?
        func note(_ error: Error) { if firstError == nil { firstError = error } }

        if let s {
            switch s {
            case .success(let value): status = value; exitNodes = value.exitNodeOptions; cliAvailable = true
            case .failure(let error): note(error); if case TailscaleError.notInstalled = error { cliAvailable = false }
            }
        }
        if let sv {
            switch sv {
            case .success(let value): serveConfig = value
            case .failure(let error): note(error)
            }
        }
        if let p {
            switch p {
            case .success(let value): prefs = value
            case .failure(let error): note(error)
            }
        }
        if let pr {
            if case .success(let value) = pr { profiles = value }   // profiles are optional; ignore failures
        }
        if s != nil || sv != nil { recomputeRules() }
        if let firstError {
            lastError = Self.describe(firstError)
            errorIsFromRefresh = true
        } else {
            lastRefresh = Date()
            if errorIsFromRefresh { lastError = nil; errorIsFromRefresh = false }
        }
        if version == nil, cliAvailable, scope.contains(.status) {
            version = try? await TailscaleCLI.version()
        }
    }

    private var errorIsFromRefresh = false

    private func recomputeRules() {
        serveRules = serveConfig?.rules(selfDNSName: selfDNSName) ?? []
    }

    private static func capture<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    private static func describe(_ error: Error) -> String {
        if case TailscaleError.commandFailed(let r) = error { return r.errorSummary }
        return error.localizedDescription
    }

    /// Reload Docker targets (published container ports).
    func refreshDocker() async {
        do { dockerTargets = try await DockerDiscovery.targets(); dockerError = nil }
        catch { dockerTargets = []; dockerError = error.localizedDescription }
    }

    // MARK: Auto refresh

    /// Start (or join) the 10-second status refresh loop. Calls are reference-counted: every `startAutoRefresh()`
    /// needs a matching `stopAutoRefresh()`. Intended for "window is visible".
    func startAutoRefresh(interval: TimeInterval = 10) {
        autoRefreshClients += 1
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                guard let self else { return }
                if !self.isBusy { await self.refreshStatus() }
            }
        }
    }

    /// Release one `startAutoRefresh()`; the loop stops when no clients remain.
    func stopAutoRefresh() {
        autoRefreshClients = max(0, autoRefreshClients - 1)
        if autoRefreshClients == 0 { autoRefreshTask?.cancel(); autoRefreshTask = nil }
    }

    // MARK: Running commands (logged)

    /// Run `tailscale <subArgs>`, log it to `activity`, set `lastError` on failure and refresh afterwards.
    /// - Returns: the result, or nil when the CLI could not be started at all (`lastError` is set).
    @discardableResult
    func runTailscale(_ subArgs: [String], refresh scope: RefreshScope = .all, timeout: TimeInterval = 30) async -> CommandResult? {
        beginBusy(CommandRunner.displayCommandLine(["tailscale"] + subArgs))
        defer { endBusy() }
        lastError = nil
        errorIsFromRefresh = false
        let kind = ActivityEntry.Kind(args: subArgs)
        do {
            let result = try await TailscaleCLI.run(subArgs, timeout: timeout)
            log(result, kind: kind)
            var capturedAuthURL = false
            if kind == .connection, let url = PrefsCommands.authURL(in: result.combinedOutput) {
                pendingAuthURL = url
                capturedAuthURL = true
            }
            // Login flows block until the user finishes in the browser. A timeout that already printed the
            // sign-in URL is the expected outcome, not an error.
            if !result.succeeded, !(result.timedOut && capturedAuthURL) { lastError = result.errorSummary }
            await refresh(scope)
            return result
        } catch {
            let line = CommandRunner.displayCommandLine(["tailscale"] + subArgs)
            appendActivity(ActivityEntry(timestamp: Date(), commandLine: line, exitCode: 127, output: error.localizedDescription, kind: kind, duration: 0))
            lastError = error.localizedDescription
            if case TailscaleError.notInstalled = error { cliAvailable = false }
            return nil
        }
    }

    /// Mark the store busy until the matching `endBusy()`. Used by `runTailscale` and by commands that run through
    /// the streaming runner (custom commands in Tools). Calls nest.
    func beginBusy(_ description: String) {
        busyCount += 1
        isBusy = true
        busyDescription = description
    }

    /// Release one `beginBusy`.
    func endBusy() {
        busyCount = max(0, busyCount - 1)
        if busyCount == 0 { isBusy = false; busyDescription = nil }
    }

    /// Run steps one after another, stopping at the first failure. Refreshes everything at the end.
    /// - Returns: true when every step succeeded.
    @discardableResult
    func runPlan(_ plan: [[String]], timeout: TimeInterval = 30) async -> Bool {
        var ok = true
        for step in plan {
            guard let result = await runTailscale(step, refresh: .none, timeout: timeout), result.succeeded else { ok = false; break }
        }
        await refresh(.all)
        return ok
    }

    /// Connect (`tailscale up`). If login is needed, `authURL` / `pendingAuthURL` will hold the sign-in URL.
    @discardableResult
    func connect() async -> Bool {
        pendingAuthURL = nil
        let result = await runTailscale(PrefsCommands.upArgs(), timeout: 20)
        return result?.succeeded ?? false
    }

    /// Disconnect (`tailscale down`).
    @discardableResult
    func disconnect() async -> Bool {
        let result = await runTailscale(PrefsCommands.downArgs())
        return result?.succeeded ?? false
    }

    /// Validate, then create or update a rule. When `replacing` is given and the identity changed, the old rule is removed first.
    @discardableResult
    func apply(rule: ServeRule, replacing old: ServeRule? = nil) async -> Bool {
        do { try rule.validate() } catch { lastError = error.localizedDescription; return false }
        return await runPlan(ServeRule.editPlan(from: old, to: rule))
    }

    /// Remove a rule (`serve ... off`).
    @discardableResult
    func remove(rule: ServeRule) async -> Bool {
        await runPlan([rule.removeArgs()])
    }

    /// `serve reset`: removes the whole serve configuration of this node.
    @discardableResult
    func resetServe() async -> Bool {
        let result = await runTailscale(ServeCommands.resetArgs(), refresh: .serve)
        return result?.succeeded ?? false
    }

    /// `tailscale set ...` for the given changes (no-op for an empty list).
    @discardableResult
    func setPrefs(_ changes: [PrefChange], acceptRisk: [String] = []) async -> Bool {
        guard !changes.isEmpty else { return true }
        let result = await runTailscale(PrefsCommands.setArgs(changes, acceptRisk: acceptRisk), refresh: [.status, .prefs])
        return result?.succeeded ?? false
    }

    // MARK: Activity log

    /// Append a finished command to the activity log (for tools that run commands themselves, e.g. streaming).
    func log(_ result: CommandResult, kind: ActivityEntry.Kind? = nil) {
        appendActivity(ActivityEntry(
            timestamp: Date(), commandLine: result.commandLine, exitCode: result.timedOut ? 124 : result.exitCode,
            output: result.combinedOutput, kind: kind ?? ActivityEntry.Kind(args: Array(result.args.dropFirst())), duration: result.duration))
    }

    /// Append an informational line to the activity log.
    func logInfo(_ message: String) {
        appendActivity(ActivityEntry(timestamp: Date(), commandLine: message, exitCode: nil, output: "", kind: .info, duration: 0))
    }

    func clearActivity() { activity.removeAll() }

    func dismissError() { lastError = nil; errorIsFromRefresh = false }

    private func appendActivity(_ entry: ActivityEntry) {
        activity.insert(entry, at: 0)
        if activity.count > Self.activityLimit { activity.removeLast(activity.count - Self.activityLimit) }
    }
}
