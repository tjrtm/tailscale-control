import Foundation

/// A container port published on the host, usable as a serve target.
struct DockerTarget: Identifiable, Hashable, Sendable {
    let containerName: String
    let image: String
    let hostPort: Int
    /// Container-side port and protocol, e.g. `80/tcp`.
    let containerPort: String

    var id: String { "\(containerName)|\(hostPort)|\(containerPort)" }

    /// One-line label for pickers.
    var label: String { "\(containerName)  —  localhost:\(hostPort) → \(containerPort)  —  \(image)" }

    /// Proxy target for a `ServeRule`.
    var proxyTarget: String { "http://127.0.0.1:\(hostPort)" }
}

enum DockerError: LocalizedError {
    case notInstalled
    case commandFailed(CommandResult)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Docker was not found. Install Docker Desktop or add docker to /usr/local/bin."
        case .commandFailed(let r): return "Docker could not be queried: \(r.errorSummary)"
        case .decoding(let d): return "Could not read Docker's output: \(d)"
        }
    }
}

/// Discovers containers that publish TCP ports on the host.
enum DockerDiscovery {
    static let candidatePaths = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/usr/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]

    /// First executable `docker` binary from the candidate list.
    static func resolveBinary() -> String? {
        if DemoMode.isEnabled { return nil }
        return candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Published TCP port targets of running containers, sorted by name then port.
    /// Returns an empty array when no container is running. Throws `DockerError`.
    static func targets() async throws -> [DockerTarget] {
        if let demo = DemoMode.backend { return demo.dockerTargets }
        guard let docker = resolveBinary() else { throw DockerError.notInstalled }
        let ps: CommandResult
        do { ps = try await CommandRunner.run([docker, "ps", "-q"], timeout: 15) }
        catch { throw DockerError.notInstalled }
        guard ps.succeeded else { throw DockerError.commandFailed(ps) }
        let ids = ps.stdout.split(whereSeparator: \.isNewline).map { String($0) }
        if ids.isEmpty { return [] }
        let inspect: CommandResult
        do { inspect = try await CommandRunner.run([docker, "inspect"] + ids, timeout: 20) }
        catch { throw DockerError.notInstalled }
        guard inspect.succeeded else { throw DockerError.commandFailed(inspect) }
        return try parseInspect(inspect.stdout)
    }

    /// Parse `docker inspect` JSON into targets (UDP ports and duplicate IPv4/IPv6 bindings are dropped).
    static func parseInspect(_ json: String) throws -> [DockerTarget] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DockerError.decoding("docker inspect did not return an array")
        }
        var targets: [DockerTarget] = []
        var seen = Set<String>()
        for container in array {
            let name = ((container["Name"] as? String) ?? "container").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let image = ((container["Config"] as? [String: Any])?["Image"] as? String) ?? "unknown image"
            let ports = ((container["NetworkSettings"] as? [String: Any])?["Ports"] as? [String: Any]) ?? [:]
            for key in ports.keys.sorted() {
                guard key.hasSuffix("/tcp"), let bindings = ports[key] as? [[String: Any]] else { continue }
                for binding in bindings {
                    guard let raw = binding["HostPort"] as? String, let hostPort = Int(raw) else { continue }
                    let target = DockerTarget(containerName: name, image: image, hostPort: hostPort, containerPort: key)
                    if seen.insert(target.id).inserted { targets.append(target) }
                }
            }
        }
        return targets.sorted { ($0.containerName, $0.hostPort) < ($1.containerName, $1.hostPort) }
    }
}
