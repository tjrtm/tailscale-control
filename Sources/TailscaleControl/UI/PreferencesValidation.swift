import Darwin
import Foundation

/// Input validation for `tailscale set` / `tailscale up` values. Pure functions, no UI.
enum PreferencesValidation {
    /// Raw bytes of an IPv4 or IPv6 address literal, or nil when it is not one.
    static func addressBytes(_ text: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }

    /// A human-readable problem with `route` as an advertised CIDR route, or nil when it is fine.
    static func routeProblem(_ route: String) -> String? {
        let text = route.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "Enter a route such as 192.168.1.0/24." }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bytes = addressBytes(String(parts[0])) else {
            return "“\(text)” is not a CIDR route such as 192.168.1.0/24 or fd00::/64."
        }
        guard let prefix = Int(parts[1]), prefix >= 0, prefix <= bytes.count * 8 else {
            return "The prefix length in “\(text)” must be between 0 and \(bytes.count * 8)."
        }
        // Host bits beyond the prefix must be zero, otherwise the CLI rejects the route.
        for (index, byte) in bytes.enumerated() {
            let bitsBefore = index * 8
            let keep = max(0, min(8, prefix - bitsBefore))
            let hostMask = UInt8(truncatingIfNeeded: 0xFF >> keep)
            if keep < 8 && byte & hostMask != 0 {
                return "“\(text)” has host bits set. Use the network address instead."
            }
        }
        return nil
    }

    /// A problem with `endpoint` as an `IP:port` relay endpoint (`[v6]:port` for IPv6), or nil when it is fine.
    static func endpointProblem(_ endpoint: String) -> String? {
        let text = endpoint.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "Enter an endpoint such as 192.0.2.1:40000." }
        let host: String
        let port: Substring
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return "“\(text)” is missing a closing bracket." }
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard rest.hasPrefix(":") else { return "“\(text)” needs a port, for example [2001:db8::1]:40000." }
            port = rest.dropFirst()
        } else {
            guard let colon = text.lastIndex(of: ":") else { return "“\(text)” needs a port, for example 192.0.2.1:40000." }
            host = String(text[..<colon])
            port = text[text.index(after: colon)...]
        }
        guard addressBytes(host) != nil else { return "“\(host)” is not an IP address." }
        guard let number = Int(port), (1...65535).contains(number) else { return "The port in “\(text)” must be between 1 and 65535." }
        return nil
    }

    /// A problem with the relay server port (empty disables the relay; 0 picks a random port), or nil.
    static func relayPortProblem(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        guard let port = Int(text), (0...65535).contains(port) else { return "The relay server port must be a number from 0 to 65535, or empty to disable it." }
        return nil
    }

    /// `--accept-risk` values mentioned in a CLI error message (for example `--accept-risk=lose-ssh`).
    static func acceptRiskTypes(in message: String) -> [String] {
        guard message.contains("accept-risk") else { return [] }
        let known = ["lose-ssh", "mac-app-connector", "all"]
        var found: [String] = []
        if let range = message.range(of: #"--accept-risk[= ]([A-Za-z,-]+)"#, options: .regularExpression) {
            let value = message[range].replacingOccurrences(of: "--accept-risk", with: "").dropFirst()
            found = value.split(separator: ",").map(String.init).filter { known.contains($0) }
        }
        if found.isEmpty {
            found = known.filter { $0 != "all" && message.contains($0) }
        }
        return found
    }
}
