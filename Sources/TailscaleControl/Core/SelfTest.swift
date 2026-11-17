import Foundation

/// Pure self-tests of builders and parsers (no tailscale process is started). Run with `--self-test`.
enum SelfTest {
    private final class Harness {
        var passed = 0
        var failed = 0

        func record(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
            if ok { passed += 1; print("PASS \(name)") }
            else { failed += 1; print("FAIL \(name)\(detail().isEmpty ? "" : "\n     " + detail())") }
        }
        func equal<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
            record(actual == expected, name, "expected: \(expected)\n     actual:   \(actual)")
        }
        func throwsError(_ name: String, containing fragment: String? = nil, _ body: () throws -> Void) {
            do {
                try body()
                record(false, name, "expected an error, none thrown")
            } catch {
                let message = error.localizedDescription
                record(fragment.map { message.localizedCaseInsensitiveContains($0) } ?? true, name, "unexpected message: \(message)")
            }
        }
    }

    /// Run all tests; returns the process exit code (0 = all passed).
    static func run() -> Int32 {
        let t = Harness()
        runnerTests(t)
        serveBuilderTests(t)
        serveDecodingTests(t)
        prefsTests(t)
        statusTests(t)
        dockerTests(t)
        demoTests(t)
        navigationTests(t)
        print(t.failed == 0 ? "PASS self-test (\(t.passed) checks)" : "FAIL self-test (\(t.failed) failed, \(t.passed) passed)")
        return t.failed == 0 ? 0 : 1
    }

    // MARK: CommandRunner

    private static func runnerTests(_ t: Harness) {
        t.equal(CommandRunner.shellQuote("plain-arg_1.0"), "plain-arg_1.0", "shellQuote plain")
        t.equal(CommandRunner.shellQuote("a b"), "'a b'", "shellQuote space")
        t.equal(CommandRunner.shellQuote("it's"), "'it'\\''s'", "shellQuote apostrophe")
        t.equal(CommandRunner.shellQuote(""), "''", "shellQuote empty")
        t.equal(CommandRunner.displayCommandLine(["/usr/local/bin/tailscale", "up", "--auth-key=tskey-secret", "--hostname=my host"]),
                "tailscale up --auth-key=REDACTED '--hostname=my host'", "commandLine redacts secrets and shows base name")
        t.equal(CommandRunner.redactSecrets(["--client-secret", "abc", "x"]), ["--client-secret", "REDACTED", "x"], "redact separate-arg secret")

        // Real process execution of harmless system tools, using the async API from a sync context.
        let echo = blocking { try await CommandRunner.run(["/bin/echo", "hello"], timeout: 5) }
        t.equal(echo?.stdout, "hello\n", "run echo stdout")
        t.equal(echo?.succeeded, true, "run echo succeeded")
        let big = blocking { try await CommandRunner.run(["/bin/sh", "-c", "head -c 3000000 /dev/zero | tr '\\0' 'a'; head -c 500000 /dev/zero | tr '\\0' 'b' 1>&2"], timeout: 20) }
        t.equal(big?.stdout.count, 3_000_000, "run drains large stdout without deadlock")
        t.equal(big?.stderr.count, 500_000, "run drains large stderr")
        let slow = blocking { try await CommandRunner.run(["/bin/sleep", "5"], timeout: 0.5) }
        t.equal(slow?.timedOut, true, "run timeout marks timedOut")
        t.equal(slow?.succeeded, false, "timed out is not succeeded")
        let fed = blocking { try await CommandRunner.run(["/bin/cat"], timeout: 5, stdin: Data("piped".utf8)) }
        t.equal(fed?.stdout, "piped", "run feeds stdin")
        let missing = blocking { try await CommandRunner.run(["/nonexistent/binary"], timeout: 2) }
        t.record(missing == nil, "run throws for a missing executable")
    }

    private final class ResultBox<V>: @unchecked Sendable { var value: V? }

    /// Run an async throwing body to completion from synchronous code (self-test only); nil if it threw.
    private static func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> T? {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached { box.value = try? await body(); done.signal() }
        done.wait()
        return box.value
    }

    // MARK: Serve builders

    private static func serveBuilderTests(_ t: Harness) {
        t.equal(ServeRule.quickRoute.applyArgs(), ["serve", "--bg", "--yes", "--https=443", "http://127.0.0.1:8080"], "quick route applyArgs")
        t.equal(ServeRule(mountPath: "/api", target: .proxy("http://127.0.0.1:3000")).applyArgs(),
                ["serve", "--bg", "--yes", "--https=443", "--set-path=/api", "http://127.0.0.1:3000"], "mount path applyArgs")
        t.equal(ServeRule(mode: .http, port: 8080, target: .proxy("3000")).applyArgs(),
                ["serve", "--bg", "--yes", "--http=8080", "3000"], "http bare port")
        t.equal(ServeRule(port: 8443, target: .proxy("http://127.0.0.1:3000"), funnel: true).applyArgs(),
                ["funnel", "--bg", "--yes", "--https=8443", "http://127.0.0.1:3000"], "funnel applyArgs")
        t.equal(ServeRule(mode: .tcp, port: 5432, target: .proxy("tcp://localhost:5432"), proxyProtocol: 2).applyArgs(),
                ["serve", "--bg", "--yes", "--tcp=5432", "--proxy-protocol=2", "tcp://localhost:5432"], "tcp applyArgs with proxy protocol")
        t.equal(ServeRule(mode: .tlsTerminatedTCP, port: 10000, target: .proxy("tcp://localhost:9000"), funnel: true).applyArgs(),
                ["funnel", "--bg", "--yes", "--tls-terminated-tcp=10000", "tcp://localhost:9000"], "tls-terminated tcp funnel")
        t.equal(ServeRule(target: .path("/Users/me/site"), acceptAppCaps: []).applyArgs(),
                ["serve", "--bg", "--yes", "--https=443", "/Users/me/site"], "path target")
        t.equal(ServeRule(target: .text("hello world")).applyArgs(),
                ["serve", "--bg", "--yes", "--https=443", "text:hello world"], "text target")
        t.equal(ServeRule(target: .proxy("http://127.0.0.1:3000"), service: "svc:web", acceptAppCaps: ["example.com/cap/a", "example.com/cap/b"]).applyArgs(),
                ["serve", "--bg", "--yes", "--https=443", "--service=svc:web", "--accept-app-caps=example.com/cap/a,example.com/cap/b", "http://127.0.0.1:3000"],
                "service + app caps")
        t.equal(ServeRule(mountPath: "/api", target: .proxy("3000")).removeArgs(), ["serve", "--yes", "--https=443", "--set-path=/api", "off"], "removeArgs web")
        t.equal(ServeRule(mode: .tcp, port: 5432, target: .proxy("5432")).removeArgs(), ["serve", "--yes", "--tcp=5432", "off"], "removeArgs tcp")
        t.equal(ServeRule(target: .proxy("3000"), service: "svc:web").removeArgs(), ["serve", "--yes", "--https=443", "--service=svc:web", "off"], "removeArgs service")
        t.equal(ServeCommands.resetArgs(), ["serve", "reset"], "reset")
        t.equal(ServeCommands.funnelResetArgs(), ["funnel", "reset"], "funnel reset")
        t.equal(ServeCommands.drainArgs(service: "svc:web"), ["serve", "drain", "svc:web"], "drain")
        t.equal(ServeCommands.clearArgs(service: "svc:web"), ["serve", "clear", "svc:web"], "clear")
        t.equal(ServeCommands.advertiseArgs(service: "svc:web"), ["serve", "advertise", "svc:web"], "advertise")
        t.equal(ServeCommands.getConfigArgs(file: "/tmp/c.json", service: "svc:web"), ["serve", "get-config", "/tmp/c.json", "--service=svc:web"], "get-config service")
        t.equal(ServeCommands.setConfigArgs(file: "/tmp/c.json", all: true), ["serve", "set-config", "/tmp/c.json", "--all"], "set-config all")

        // editPlan
        let old = ServeRule(mountPath: "/api", target: .proxy("3000"))
        var moved = old; moved.port = 8443
        t.equal(ServeRule.editPlan(from: old, to: moved), [old.removeArgs(), moved.applyArgs()], "editPlan identity change removes then applies")
        var retargeted = old; retargeted.target = .proxy("4000")
        t.equal(ServeRule.editPlan(from: old, to: retargeted), [retargeted.applyArgs()], "editPlan same identity only applies")
        t.equal(ServeRule.editPlan(from: nil, to: old), [old.applyArgs()], "editPlan new rule")
        let funnelOn = ServeRule(port: 443, target: .proxy("3000"), funnel: true)
        var funnelOff = funnelOn; funnelOff.funnel = false
        t.equal(ServeRule.editPlan(from: funnelOn, to: funnelOff).first?.first, "serve", "editPlan funnel off re-applies with serve")

        // url
        t.equal(ServeRule.quickRoute.url(dnsName: "host.example.ts.net."), "https://host.example.ts.net/", "url default port omitted")
        t.equal(ServeRule(port: 8443, mountPath: "/x", target: .proxy("3000")).url(dnsName: "host.example.ts.net"), "https://host.example.ts.net:8443/x", "url custom port and path")
        t.equal(ServeRule(mode: .http, port: 80, target: .proxy("3000")).url(dnsName: "host.example.ts.net"), "http://host.example.ts.net/", "url http :80 omitted")
        t.equal(ServeRule(mode: .tcp, port: 5432, target: .proxy("5432")).url(dnsName: "host.example.ts.net"), nil, "url nil for tcp")

        // validation
        let ok = ServeRule(target: .proxy("http://127.0.0.1:3000"))
        t.record((try? ok.validate()) != nil, "validate accepts a normal rule")
        t.throwsError("validate port 0", containing: "port") { var r = ok; r.port = 0; try r.validate() }
        t.throwsError("validate port 70000", containing: "port") { var r = ok; r.port = 70000; try r.validate() }
        t.throwsError("validate funnel port", containing: "443") { var r = ok; r.funnel = true; r.port = 9000; try r.validate() }
        t.throwsError("validate funnel http", containing: "HTTP") { var r = ok; r.funnel = true; r.mode = .http; try r.validate() }
        t.throwsError("validate funnel service", containing: "Service") { var r = ok; r.funnel = true; r.service = "svc:web"; try r.validate() }
        t.throwsError("validate mount path", containing: "/") { var r = ok; r.mountPath = "api"; try r.validate() }
        t.throwsError("validate empty proxy", containing: "target") { try ServeRule(target: .proxy("  ")).validate() }
        t.throwsError("validate bad proxy port", containing: "port") { try ServeRule(target: .proxy("http://localhost:99999")).validate() }
        t.throwsError("validate proxy needs port", containing: "port") { try ServeRule(target: .proxy("http://localhost")).validate() }
        t.throwsError("validate bad scheme", containing: "scheme") { try ServeRule(target: .proxy("ftp://localhost:21")).validate() }
        t.throwsError("validate empty text", containing: "empty") { try ServeRule(target: .text("")).validate() }
        t.throwsError("validate relative path", containing: "absolute") { try ServeRule(target: .path("site")).validate() }
        t.throwsError("validate service name", containing: "svc:") { var r = ok; r.service = "web"; try r.validate() }
        t.throwsError("validate proxy protocol on https", containing: "PROXY") { var r = ok; r.proxyProtocol = 2; try r.validate() }
        t.throwsError("validate proxy protocol value", containing: "1 or 2") { try ServeRule(mode: .tcp, port: 5432, target: .proxy("5432"), proxyProtocol: 3).validate() }
        t.throwsError("validate path with tcp", containing: "HTTP") { try ServeRule(mode: .tcp, port: 5432, target: .path("/Users/me/site")).validate() }
        t.record((try? ServeRule(mode: .tcp, port: 5432, target: .proxy("tcp://localhost:5432"), proxyProtocol: 1).validate()) != nil, "validate tcp ok")
        t.record((try? ServeRule(target: .proxy("unix:/tmp/app.sock")).validate()) != nil, "validate unix socket ok")
        t.record((try? ServeRule(target: .proxy("https+insecure://localhost:8443")).validate()) != nil, "validate https+insecure ok")
        t.record((try? ServeRule(target: .proxy("localhost:3000"), service: "svc:my-app").validate()) != nil, "validate host:port + service ok")

        // Target parsing
        t.equal(ServeRule.Target(userInput: "text:hi"), .text("hi"), "Target text input")
        t.equal(ServeRule.Target(userInput: "/Users/me/site"), .path("/Users/me/site"), "Target path input")
        t.equal(ServeRule.Target(userInput: " 3000 "), .proxy("3000"), "Target proxy input")
    }

    // MARK: Serve decoding

    private static let serveFixture = """
    {
      "TCP": { "443": {"HTTPS": true}, "8080": {"HTTP": true}, "5432": {"TCPForward": "127.0.0.1:5432", "ProxyProtocol": 2}, "10000": {"TCPForward": "127.0.0.1:9000", "TerminateTLS": "host.example.ts.net"} },
      "Web": {
        "host.example.ts.net:443": { "Handlers": {
          "/": {"Proxy": "http://127.0.0.1:3000"},
          "/files": {"Path": "/Users/me/site"},
          "/hi": {"Text": "hello"},
          "/api": {"Proxy": "http://127.0.0.1:4000", "AcceptAppCaps": ["example.com/cap/a"]} } },
        "host.example.ts.net:8080": { "Handlers": { "/": {"Proxy": "http://127.0.0.1:8081"} } }
      },
      "AllowFunnel": { "host.example.ts.net:443": true, "host.example.ts.net:10000": true }
    }
    """

    private static let servicesFixture = """
    {
      "Services": { "svc:docs": { "TCP": {"443": {"HTTPS": true}}, "Web": {"docs.example.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:5000"}}}} },
                    "svc:vpn": { "Tun": true } },
      "Foreground": { "session-1": { "TCP": {"8443": {"HTTPS": true}}, "Web": {"host.example.ts.net:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:6000"}}}} } },
      "SomethingNew": 42
    }
    """

    private static func serveDecodingTests(_ t: Harness) {
        let empty = try? TailscaleCLI.parseServeConfig("{}")
        t.equal(empty?.isEmpty, true, "empty {} decodes to empty config")
        t.equal(empty?.rules(selfDNSName: "host.example.ts.net").count, 0, "empty config has no rules")
        t.equal((try? TailscaleCLI.parseServeConfig("No serve config\n"))?.isEmpty, true, "non-JSON 'no config' text yields empty config")
        t.equal((try? TailscaleCLI.parseServeConfig(""))?.isEmpty, true, "blank output yields empty config")

        guard let config = try? TailscaleCLI.parseServeConfig(serveFixture) else { t.record(false, "decode serve fixture"); return }
        let rules = config.rules(selfDNSName: "host.example.ts.net.")
        t.equal(rules.map { "\($0.mode.rawValue):\($0.port):\($0.mountPath)" },
                ["https:443:/", "https:443:/api", "https:443:/files", "https:443:/hi", "tcp:5432:/", "http:8080:/", "tlsTerminatedTCP:10000:/"],
                "rules sorted by port then mount path")
        t.equal(rules.first { $0.mountPath == "/files" }?.target, .path("/Users/me/site"), "path handler")
        t.equal(rules.first { $0.mountPath == "/hi" }?.target, .text("hello"), "text handler")
        t.equal(rules.first { $0.mountPath == "/api" }?.acceptAppCaps, ["example.com/cap/a"], "AcceptAppCaps decoded")
        t.equal(rules.first { $0.mountPath == "/api" }?.funnel, true, "funnel flag from AllowFunnel")
        t.equal(rules.first { $0.mode == .http }?.funnel, false, "no funnel on port 8080")
        t.equal(rules.first { $0.mode == .tcp }?.proxyProtocol, 2, "proxy protocol decoded")
        t.equal(rules.first { $0.mode == .tcp }?.target, .proxy("tcp://127.0.0.1:5432"), "tcp forward target")
        t.equal(rules.first { $0.mode == .tlsTerminatedTCP }?.funnel, true, "tls tcp funnel")
        t.equal(rules.first { $0.mode == .tcp }?.host, "host.example.ts.net", "tcp rule host from selfDNSName")

        guard let svc = try? TailscaleCLI.parseServeConfig(servicesFixture) else { t.record(false, "decode services fixture"); return }
        t.equal(svc.services.keys.sorted(), ["svc:docs", "svc:vpn"], "services decoded")
        t.equal(svc.services["svc:vpn"]?.tun, true, "service Tun decoded")
        t.equal(svc.foreground.keys.sorted(), ["session-1"], "foreground decoded")
        let svcRules = svc.rules(selfDNSName: "host.example.ts.net")
        t.equal(svcRules.count, 2, "service + foreground rules flattened")
        t.equal(svcRules.first?.service, "svc:docs", "service rule carries service name")
        t.equal(svcRules.first?.applyArgs().contains("--service=svc:docs"), true, "service rule uses --service")
        t.equal(svcRules.last?.isForeground, true, "foreground rule sorted last and flagged")
        // Wrong types must not crash decoding.
        t.record((try? TailscaleCLI.parseServeConfig(#"{"TCP": {"443": "oops"}, "Web": 5}"#)) != nil, "lenient decoding survives wrong types")
    }

    // MARK: Prefs

    private static func prefsTests(_ t: Harness) {
        t.equal(PrefsCommands.setArgs([.ssh(true), .acceptRoutes(false)]), ["set", "--ssh=true", "--accept-routes=false"], "set bools")
        t.equal(PrefsCommands.setArgs([.hostname("my-node"), .exitNode("")]), ["set", "--hostname=my-node", "--exit-node="], "set strings and clear")
        t.equal(PrefsCommands.setArgs([.advertiseRoutes(["10.0.0.0/8", "192.168.0.0/24"])]), ["set", "--advertise-routes=10.0.0.0/8,192.168.0.0/24"], "set routes list")
        t.equal(PrefsCommands.setArgs([.advertiseRoutes([])]), ["set", "--advertise-routes="], "set routes clear")
        t.equal(PrefsCommands.setArgs([.ssh(false)], acceptRisk: ["lose-ssh"]), ["set", "--ssh=false", "--accept-risk=lose-ssh"], "set accept-risk")
        t.equal(PrefsCommands.exitNodeArgs("100.64.0.1", allowLAN: true), ["set", "--exit-node=100.64.0.1", "--exit-node-allow-lan-access=true"], "exit node with LAN")
        t.equal(PrefsCommands.clearExitNodeArgs(), ["set", "--exit-node="], "clear exit node")
        let allChanges: [PrefChange] = [.acceptDNS(true), .acceptRoutes(true), .advertiseConnector(true), .advertiseExitNode(true), .advertiseRoutes(["10.0.0.0/8"]),
                                        .autoUpdate(true), .exitNode("x"), .exitNodeAllowLANAccess(true), .hostname("h"), .nickname("n"), .operatorUser("me"),
                                        .relayServerPort("0"), .relayServerStaticEndpoints(["192.0.2.1:40000"]), .reportPosture(true), .shieldsUp(true),
                                        .ssh(true), .updateCheck(true), .webclient(true)]
        t.equal(Set(allChanges.map(\.name)).count, 18, "PrefChange covers 18 distinct flags")

        var up = UpOptions()
        up.authKey = "tskey-abc"; up.hostname = "n1"; up.acceptRoutes = true; up.advertiseTags = ["tag:a", "b"]; up.timeout = 30; up.reset = true
        t.equal(PrefsCommands.upArgs(options: up),
                ["up", "--accept-routes=true", "--advertise-tags=tag:a,b", "--auth-key=tskey-abc", "--hostname=n1", "--reset=true", "--timeout=30s"], "upArgs")
        t.equal(PrefsCommands.upArgs(), ["up"], "plain up")
        t.equal(PrefsCommands.downArgs(), ["down"], "down")
        t.equal(PrefsCommands.logoutArgs(reason: "done"), ["logout", "--reason=done"], "logout reason")
        t.equal(PrefsCommands.switchArgs(profileID: "abcd"), ["switch", "abcd"], "switch")
        t.equal(PrefsCommands.authURL(in: "To authenticate, visit:\n\n\thttps://login.example.com/a/abc123\n")?.absoluteString, "https://login.example.com/a/abc123", "authURL extraction")

        let json = """
        {"accept-dns": true, "accept-routes": "false", "advertise-routes": "10.0.0.0/8,192.168.0.0/24", "hostname": "", "relay-server-port": 40000,
         "exit-node": "", "ssh": true, "future-flag": [1, 2]}
        """
        guard let prefs = try? TailscaleCLI.decode(TailscalePrefs.self, from: json) else { t.record(false, "decode prefs"); return }
        t.equal(prefs.acceptDNS, true, "prefs bool")
        t.equal(prefs.acceptRoutes, false, "prefs bool from string")
        t.equal(prefs.advertiseRoutes, ["10.0.0.0/8", "192.168.0.0/24"], "prefs comma list")
        t.equal(prefs.relayServerPort, "40000", "prefs number as string")
        t.equal(prefs.shieldsUp, false, "prefs missing key defaults")
        t.equal(prefs.raw["future-flag"] != nil, true, "prefs keeps unknown keys in raw")
        var changed = prefs; changed.ssh = false; changed.hostname = "new"
        t.equal(PrefsCommands.changes(from: prefs, to: changed), [.hostname("new"), .ssh(false)], "prefs diff")
        t.equal((try? TailscaleCLI.decode(TailscalePrefs.self, from: "{}"))?.ssh, false, "empty prefs decode")
    }

    // MARK: Status / profiles

    private static let statusFixture = """
    {
      "Version": "1.80.0-t000", "BackendState": "Running", "AuthURL": "", "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"],
      "Self": {"ID": "nSELF1", "HostName": "host", "DNSName": "host.example.ts.net.", "OS": "macOS", "TailscaleIPs": ["100.64.0.1"], "Online": true,
               "KeyExpiry": "2030-01-01T00:00:00Z", "LastSeen": "0001-01-01T00:00:00Z", "UserID": 1},
      "Health": ["example warning"], "MagicDNSSuffix": "example.ts.net",
      "CurrentTailnet": {"Name": "user@example.com", "MagicDNSSuffix": "example.ts.net", "MagicDNSEnabled": true},
      "CertDomains": ["host.example.ts.net"],
      "Peer": {
        "nodekey:aaaa": {"ID": "nPEER1", "HostName": "laptop", "DNSName": "laptop.example.ts.net.", "OS": "linux", "TailscaleIPs": ["100.64.0.2"], "Online": true,
                         "ExitNodeOption": true, "ExitNode": true, "RxBytes": 10, "TxBytes": 20, "LastSeen": "2026-01-01T10:00:00.123Z", "UserID": 1,
                         "Tags": ["tag:server"], "PrimaryRoutes": ["10.0.0.0/8"], "TaildropTarget": 1},
        "nodekey:bbbb": {"ID": "nPEER2", "HostName": "phone", "DNSName": "phone.example.ts.net.", "OS": "android", "Online": false, "Weird": {"x": 1}}
      },
      "User": {"1": {"ID": 1, "LoginName": "user@example.com", "DisplayName": "Example User"}}
    }
    """

    private static func statusTests(_ t: Harness) {
        guard let status = try? TailscaleCLI.decode(TailscaleStatus.self, from: statusFixture) else { t.record(false, "decode status fixture"); return }
        t.equal(status.state, .running, "status backend state")
        t.equal(status.selfNode?.dnsNameTrimmed, "host.example.ts.net", "self dns trimmed")
        t.equal(status.selfNode?.lastSeen, nil, "zero date is nil")
        t.equal(status.selfNode?.keyExpiry != nil, true, "key expiry parsed")
        t.equal(status.currentTailnet?.name, "user@example.com", "tailnet name")
        t.equal(status.peers.count, 2, "peers decoded")
        t.equal(status.sortedPeers.first?.displayName, "laptop", "online peers first")
        t.equal(status.exitNodeOptions.map(\.displayName), ["laptop"], "exit node options")
        t.equal(status.activeExitNode?.displayName, "laptop", "active exit node")
        t.equal(status.peers["nodekey:aaaa"]?.lastSeen != nil, true, "fractional-second date parsed")
        t.equal(status.peers["nodekey:aaaa"]?.canReceiveFiles, true, "taildrop target")
        t.equal(status.peers["nodekey:aaaa"]?.primaryRoutes, ["10.0.0.0/8"], "primary routes")
        t.equal(status.peers["nodekey:aaaa"].flatMap { status.user(for: $0) }?.loginName, "user@example.com", "user lookup")
        let bare = try? TailscaleCLI.decode(TailscaleStatus.self, from: "{}")
        t.equal(bare?.state, .noState, "empty status is NoState")
        t.equal((try? TailscaleCLI.decode(TailscaleStatus.self, from: #"{"BackendState":"NeedsLogin","AuthURL":"https://login.example.com/a/x"}"#))?.state, .needsLogin, "NeedsLogin state")
        t.equal((try? TailscaleCLI.decode(TailscaleStatus.self, from: #"{"BackendState":"Brand New"}"#))?.state, .unknown, "unknown state")

        let table = "ID    Tailnet           Account\nab12  user@example.com  user@example.com*\ncd34  other.example     second@example.com\n"
        let fromText = TailscaleProfile.parse(table)
        t.equal(fromText.map(\.id), ["ab12", "cd34"], "profiles text parse ids")
        t.equal(fromText.first?.selected, true, "profiles text selected marker")
        let fromJSON = TailscaleProfile.parse(#"[{"id":"ab12","nickname":"n","tailnet":"example.org","account":"user@example.com","selected":true}]"#)
        t.equal(fromJSON.first?.tailnet, "example.org", "profiles json parse")
        t.equal(TailscaleVersionInfo.parse("1.80.0\n  tailscale commit: abc\n").client, "1.80.0", "version parse")
    }

    // MARK: Docker

    private static func dockerTests(_ t: Harness) {
        let inspect = """
        [{"Name": "/web", "Config": {"Image": "nginx:latest"},
          "NetworkSettings": {"Ports": {"80/tcp": [{"HostIp": "0.0.0.0", "HostPort": "8081"}, {"HostIp": "::", "HostPort": "8081"}], "53/udp": [{"HostIp": "0.0.0.0", "HostPort": "5353"}], "443/tcp": null}}}]
        """
        let targets = (try? DockerDiscovery.parseInspect(inspect)) ?? []
        t.equal(targets.count, 1, "docker: one tcp target, udp/unbound/dupes dropped")
        t.equal(targets.first?.proxyTarget, "http://127.0.0.1:8081", "docker proxy target")
        t.equal(targets.first?.containerName, "web", "docker name trimmed")
    }

    // MARK: Navigation

    private static func navigationTests(_ t: Harness) {
        _ = SidebarSection.takePendingNavigation()
        SidebarSection.devices.navigate()
        t.equal(SidebarSection.takePendingNavigation(), .devices, "navigate remembers a pending section")
        t.record(SidebarSection.takePendingNavigation() == nil, "pending section is consumed once")
    }

    // MARK: Demo mode

    private static func demoTests(_ t: Harness) {
        t.record(!DemoMode.isEnabled, "demo: off by default in tests")
        DemoMode.enable()
        defer { DemoMode.disable() }

        t.record(DemoMode.isEnabled, "demo: enabled")
        t.record(TailscaleCLI.resolveBinary() == nil, "demo: never resolves a real tailscale binary")
        t.record(DockerDiscovery.resolveBinary() == nil, "demo: never resolves a real docker binary")
        t.record(CommandRunner.executionDisabled, "demo: process execution is blocked")
        let blocked = blocking { try await CommandRunner.run(["/bin/echo", "x"], timeout: 2) }
        t.record(blocked == nil, "demo: CommandRunner.run refuses to start a process")

        let status = blocking { try await TailscaleCLI.status() }
        t.equal(status?.isRunning, true, "demo: status is Running")
        t.record((status?.peers.count ?? 0) >= 6, "demo: status has at least 6 peers")
        t.record((status?.exitNodeOptions.count ?? 0) >= 1, "demo: status offers an exit node")
        t.equal(Set((status?.peers.values.map(\.os)) ?? []).count >= 4, true, "demo: peers have mixed operating systems")
        t.record(status?.peers.values.contains { !$0.online } == true && status?.peers.values.contains { $0.online } == true, "demo: peers are online and offline")
        let selfName = status?.selfNode?.dnsNameTrimmed
        t.equal(selfName, "demo-macbook.example.ts.net", "demo: fictional host name")

        let config = blocking { try await TailscaleCLI.serveConfig() }
        let rules = config?.rules(selfDNSName: selfName) ?? []
        t.record(rules.count >= 7, "demo: serve config yields rules", "rules: \(rules.count)")
        t.record(Set(rules.map(\.mode)).isSuperset(of: [.https, .http, .tcp]), "demo: rules cover https, http and tcp")
        t.record(rules.contains { $0.funnel && $0.port == 443 }, "demo: a funnel-enabled 443 route")
        t.record(rules.contains { if case .path = $0.target { return true } else { return false } }, "demo: a file-path target")
        t.record(rules.contains { if case .text = $0.target { return true } else { return false } }, "demo: a text target")
        t.record(rules.contains { $0.service == "svc:web-demo" }, "demo: a svc: service rule")
        t.record(rules.contains { $0.mountPath == "/api" }, "demo: a mount-path rule")
        let prefs = blocking { try await TailscaleCLI.prefs() }
        t.equal(prefs?.ssh, true, "demo: prefs are readable")
        t.equal(blocking { try await TailscaleCLI.profiles() }?.count, 2, "demo: two profiles")
        t.record(blocking { try await DockerDiscovery.targets() }?.isEmpty == false, "demo: docker discovery returns fixture containers")

        // Mutations are logged with the demo note and applied to the in-memory fixture, without any process.
        let added = ServeRule(mode: .https, port: 10000, target: .proxy("http://127.0.0.1:4242"))
        let addResult = blocking { try await TailscaleCLI.run(added.applyArgs(), timeout: 5) }
        t.equal(addResult?.stdout, DemoMode.notExecutedNote, "demo: mutating command output is the demo note")
        t.equal(addResult?.commandLine, "tailscale serve --bg --yes --https=10000 http://127.0.0.1:4242", "demo: command line is logged as usual")
        let afterAdd = (blocking { try await TailscaleCLI.serveConfig() })?.rules(selfDNSName: selfName) ?? []
        t.equal(afterAdd.count, rules.count + 1, "demo: added rule appears")
        _ = blocking { try await TailscaleCLI.run(added.removeArgs(), timeout: 5) }
        let afterRemove = (blocking { try await TailscaleCLI.serveConfig() })?.rules(selfDNSName: selfName) ?? []
        t.equal(afterRemove.count, rules.count, "demo: removed rule disappears")
        _ = blocking { try await TailscaleCLI.run(PrefsCommands.setArgs([.ssh(false)]), timeout: 5) }
        t.equal((blocking { try await TailscaleCLI.prefs() })?.ssh, false, "demo: set changes a preference")
        _ = blocking { try await TailscaleCLI.run(PrefsCommands.downArgs(), timeout: 5) }
        t.equal((blocking { try await TailscaleCLI.status() })?.state, .stopped, "demo: down disconnects")
        let other = blocking { try await TailscaleCLI.run(["cert", "host.example.ts.net"], timeout: 5) }
        t.equal(other?.stdout, DemoMode.notExecutedNote, "demo: unknown commands are only logged")

        // Streaming runs are simulated too.
        var streamed = ""
        var finished: CommandResult?
        let stream = try? TailscaleCLI.stream(["ping", "100.64.0.2"], timeout: 5, onOutput: { streamed += $0 }, onFinish: { finished = $0 })
        t.record(stream != nil, "demo: streaming starts without a binary")
        // Callbacks are delivered on the main queue, which `run()` does not service: pump it.
        let deadline = Date().addingTimeInterval(8)
        while finished == nil && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        t.record(streamed.contains("pong from nas-01"), "demo: simulated ping output")
        t.equal(finished?.exitCode, 0, "demo: simulated stream succeeds")
    }
}
