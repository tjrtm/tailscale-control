import Foundation

/// Errors from talking to the `tailscale` CLI.
enum TailscaleError: LocalizedError {
    /// No usable `tailscale` binary was found.
    case notInstalled
    /// The CLI ran but exited non-zero (or timed out).
    case commandFailed(CommandResult)
    /// Output could not be parsed.
    case decoding(String)
    /// The binary exists but could not be started.
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The Tailscale command-line tool was not found. Install Tailscale, or set its path in Settings."
        case .commandFailed(let result):
            return "`\(result.commandLine)` failed: \(result.errorSummary)"
        case .decoding(let detail):
            return "Could not read Tailscale's output: \(detail)"
        case .launchFailed(let detail):
            return detail
        }
    }
}

/// Binary resolution and typed, read-only wrappers around the `tailscale` CLI.
///
/// All functions are `async` and never block the main thread. Sub-arguments never include the binary itself.
enum TailscaleCLI {
    /// UserDefaults key holding an optional user-chosen path to the `tailscale` binary.
    static let pathDefaultsKey = "tailscalePath"

    /// Fallback locations searched (in order) after the user override.
    static let candidatePaths = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    /// The user-provided override path, if set (may not exist).
    static var overridePath: String? {
        let value = UserDefaults.standard.string(forKey: pathDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    /// Resolve the binary: executable override first, then the candidate list. Nil when none exists.
    /// Always nil in demo mode: no real binary is ever looked up or used.
    static func resolveBinary() -> String? {
        if DemoMode.isEnabled { return nil }
        let fm = FileManager.default
        if let override = overridePath, fm.isExecutableFile(atPath: (override as NSString).expandingTildeInPath) {
            return (override as NSString).expandingTildeInPath
        }
        return candidatePaths.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Run `tailscale <subArgs>`. A non-zero exit is **not** thrown: check `CommandResult.succeeded`.
    /// Throws `TailscaleError.notInstalled` / `.launchFailed`.
    static func run(_ subArgs: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        if let demo = DemoMode.backend { return await demo.run(subArgs) }
        guard let binary = resolveBinary() else { throw TailscaleError.notInstalled }
        do {
            return try await CommandRunner.run([binary] + subArgs, timeout: timeout)
        } catch let error as CommandRunnerError {
            if case .notExecutable = error { throw TailscaleError.notInstalled }
            throw TailscaleError.launchFailed(error.localizedDescription)
        }
    }

    /// Like `run`, but throws `TailscaleError.commandFailed` on a non-zero exit or timeout.
    static func runChecked(_ subArgs: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        let result = try await run(subArgs, timeout: timeout)
        guard result.succeeded else { throw TailscaleError.commandFailed(result) }
        return result
    }

    /// Arguments for a streaming run (ping, netcheck, `up` login flows): `[binary] + subArgs`.
    /// Pass the result to `CommandRunner.runStreaming`. Throws `.notInstalled`.
    static func streamingArgs(_ subArgs: [String]) throws -> [String] {
        guard let binary = resolveBinary() else { throw TailscaleError.notInstalled }
        return [binary] + subArgs
    }

    /// Start `tailscale <subArgs>` as a streamed command (ping, netcheck, login flows, the Tools screen).
    /// `onOutput` and `onFinish` are called on the main queue. Throws `.notInstalled`.
    /// In demo mode the output is simulated and no process is started.
    static func stream(_ subArgs: [String], timeout: TimeInterval?,
                       onOutput: @escaping (String) -> Void,
                       onFinish: ((CommandResult) -> Void)?) throws -> CommandStream {
        if let demo = DemoMode.backend {
            return demo.stream(subArgs, timeout: timeout, onOutput: onOutput, onFinish: onFinish)
        }
        let args = try streamingArgs(subArgs)
        return CommandRunner.runStreaming(args, timeout: timeout, onOutput: onOutput, onFinish: onFinish)
    }

    // MARK: Typed readers

    /// `tailscale status --json`.
    static func status() async throws -> TailscaleStatus {
        let result = try await runChecked(["status", "--json"], timeout: 15)
        return try decode(TailscaleStatus.self, from: result.stdout)
    }

    /// `tailscale serve status --json`. Empty output / "No serve config" yields an empty config.
    static func serveConfig() async throws -> ServeConfig {
        let result = try await runChecked(["serve", "status", "--json"], timeout: 15)
        return try parseServeConfig(result.stdout)
    }

    /// Parse serve-status output; non-JSON "no config" text maps to an empty config.
    static func parseServeConfig(_ output: String) throws -> ServeConfig {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || !trimmed.hasPrefix("{") { return ServeConfig() }
        return try decode(ServeConfig.self, from: trimmed)
    }

    /// `tailscale get --json`.
    static func prefs() async throws -> TailscalePrefs {
        let result = try await runChecked(["get", "--json"], timeout: 15)
        return try decode(TailscalePrefs.self, from: result.stdout)
    }

    /// Peers that offer to be exit nodes (derived from `status --json`).
    static func exitNodes() async throws -> [PeerStatus] {
        try await status().exitNodeOptions
    }

    /// Accounts from `tailscale switch --list --json`.
    static func profiles() async throws -> [TailscaleProfile] {
        let result = try await runChecked(["switch", "--list", "--json"], timeout: 15)
        return TailscaleProfile.parse(result.stdout)
    }

    /// `tailscale version`.
    static func version() async throws -> TailscaleVersionInfo {
        let result = try await runChecked(["version"], timeout: 10)
        return TailscaleVersionInfo.parse(result.stdout)
    }

    /// Decode JSON text with a clear error.
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let data = text.data(using: .utf8) else { throw TailscaleError.decoding("output was not UTF-8") }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw TailscaleError.decoding(error.localizedDescription) }
    }
}
