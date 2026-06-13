import AppKit
import Foundation

let appName = "Tailscale Control"

struct CommandResult {
    let args: [String]
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var display: String {
        let command = args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        return "Command: \(command)\nExit: \(exitCode)\n\nSTDOUT:\n\(stdout.isEmpty ? "(empty)" : stdout)\n\nSTDERR:\n\(stderr.isEmpty ? "(empty)" : stderr)"
    }
}

enum ControlError: Error, LocalizedError {
    case invalidPort(String, String)
    case invalidHost(String)
    case unsupportedMode(String)
    case missingCommand(String)
    case commandFailed(String, CommandResult)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let label, let value): return "\(label) must be a number from 1 to 65535. Got: \(value)"
        case .invalidHost(let host): return "Target host must be a simple host/IP, not a URL or path. Got: \(host)"
        case .unsupportedMode(let mode): return "Unsupported mode: \(mode). Use HTTPS or HTTP."
        case .missingCommand(let name): return "Command not found: \(name). Install it or adjust PATH."
        case .commandFailed(let prefix, let result): return "\(prefix)\n\n\(result.display)"
        case .invalidJSON(let detail): return "Invalid JSON: \(detail)"
        }
    }
}

struct RouteConfig {
    var serveMode: String = "https"
    var exposePort: String = "443"
    var targetScheme: String = "http"
    var targetHost: String = "127.0.0.1"
    var targetPort: String = "8080"

    func command(tailscalePath: String) throws -> [String] {
        let mode = serveMode.lowercased()
        guard mode == "https" || mode == "http" else { throw ControlError.unsupportedMode(serveMode) }
        let exposed = try validatePort(exposePort, label: "Tailscale exposed port")
        let target = try targetURL()
        return [tailscalePath, "serve", "--bg", "--yes", "--\(mode)=\(exposed)", target]
    }

    func targetURL() throws -> String {
        let host = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.range(of: #"^[a-zA-Z0-9_.:-]+$"#, options: .regularExpression) != nil else {
            throw ControlError.invalidHost(targetHost)
        }
        let port = try validatePort(targetPort, label: "Target port")
        let scheme = targetScheme.lowercased()
        guard ["http", "https", "https+insecure"].contains(scheme) else { throw ControlError.unsupportedMode(targetScheme) }
        return "\(scheme)://\(host):\(port)"
    }
}

func validatePort(_ raw: String, label: String) throws -> Int {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let port = Int(trimmed), port >= 1, port <= 65535 else {
        throw ControlError.invalidPort(label, raw)
    }
    return port
}

func resolveCommand(_ name: String) -> String? {
    if name.contains("/") && FileManager.default.isExecutableFile(atPath: name) { return name }
    let candidates = [
        "/usr/local/bin/\(name)",
        "/opt/homebrew/bin/\(name)",
        "/usr/bin/\(name)",
        "/bin/\(name)"
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

@discardableResult
func runCommand(_ args: [String], timeout: TimeInterval = 20) throws -> CommandResult {
    guard let executable = args.first else { throw ControlError.missingCommand("(empty)") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(args.dropFirst())

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning { process.terminate() }
    process.waitUntilExit()

    let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return CommandResult(args: args, exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
}

struct DockerTarget {
    let containerName: String
    let image: String
    let hostPort: Int
    let containerPort: String

    var label: String { "\(containerName)  —  localhost:\(hostPort) → \(containerPort)  —  \(image)" }
}

func loadDockerTargets(dockerPath: String) throws -> ([DockerTarget], String) {
    let ps = try runCommand([dockerPath, "ps", "-q"])
    guard ps.exitCode == 0 else { throw ControlError.commandFailed("Unable to list Docker containers.", ps) }
    let ids = ps.stdout.split(whereSeparator: \.isNewline).map(String.init)
    if ids.isEmpty { return ([], "Docker is reachable, but no containers are running.") }

    let inspect = try runCommand([dockerPath, "inspect"] + ids)
    guard inspect.exitCode == 0 else { throw ControlError.commandFailed("Unable to inspect Docker containers.", inspect) }
    guard let data = inspect.stdout.data(using: .utf8),
          let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        throw ControlError.invalidJSON("docker inspect did not return an array")
    }

    var targets: [DockerTarget] = []
    for container in array {
        let name = ((container["Name"] as? String) ?? "container").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let config = container["Config"] as? [String: Any]
        let image = (config?["Image"] as? String) ?? "unknown image"
        let network = container["NetworkSettings"] as? [String: Any]
        let ports = network?["Ports"] as? [String: Any] ?? [:]
        for key in ports.keys.sorted() {
            guard let bindings = ports[key] as? [[String: Any]] else { continue }
            for binding in bindings {
                guard let hostPortRaw = binding["HostPort"] as? String, let hostPort = Int(hostPortRaw) else { continue }
                targets.append(DockerTarget(containerName: name, image: image, hostPort: hostPort, containerPort: key))
            }
        }
    }
    return (targets, "Found \(targets.count) Docker published port target(s).")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let modePopup = NSPopUpButton()
    let exposeField = NSTextField(string: "443")
    let schemePopup = NSPopUpButton()
    let hostField = NSTextField(string: "127.0.0.1")
    let targetPortField = NSTextField(string: "8080")
    let dockerPopup = NSPopUpButton()
    let messageLabel = NSTextField(labelWithString: "Ready.")
    let outputView = NSTextView()
    var dockerTargets: [DockerTarget] = []

    let tailscalePath = resolveCommand("tailscale") ?? "/usr/local/bin/tailscale"
    let dockerPath = resolveCommand("docker") ?? "/usr/local/bin/docker"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        refreshStatus(nil)
        if CommandLine.arguments.contains("--close-self-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.window.performClose(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if window == nil {
                buildWindow()
            } else {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: appName)
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "About \(appName)", action: #selector(showAbout), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"))
        appMenu.item(withTitle: "Hide Others")?.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(NSMenuItem(title: "Apply Custom Route", action: #selector(startServe), keyEquivalent: "r"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc func showAbout(_ sender: Any?) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: appName,
            .applicationVersion: version,
            .credits: NSAttributedString(string: "Native macOS utility for routing Tailscale Serve to local and Docker-published ports.")
        ])
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = appName
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.minSize = NSSize(width: 680, height: 560)

        modePopup.removeAllItems()
        modePopup.addItems(withTitles: ["https", "http"])
        schemePopup.removeAllItems()
        schemePopup.addItems(withTitles: ["http", "https", "https+insecure"])
        dockerPopup.removeAllItems()
        dockerPopup.addItem(withTitle: "Load Docker targets first")

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Tailscale Control")
        title.font = .systemFont(ofSize: 30, weight: .bold)
        root.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: "One simple job: point your tailnet address at a local app or Docker-published port.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        root.addArrangedSubview(subtitle)

        root.addArrangedSubview(quickRouteCard())
        root.addArrangedSubview(routeCard())
        root.addArrangedSubview(dockerCard())

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 10
        statusRow.addArrangedSubview(button("Refresh Status", #selector(refreshStatus)))
        statusRow.addArrangedSubview(button("Reset Serve", #selector(resetServe)))
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        statusRow.addArrangedSubview(messageLabel)
        root.addArrangedSubview(statusRow)

        outputView.isEditable = false
        outputView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        outputView.string = "Activity log will appear here."
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = outputView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        window.contentView = NSView()
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])
        window.makeKeyAndOrderFront(nil)
    }

    func quickRouteCard() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 16

        let copy = NSStackView()
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 4
        copy.addArrangedSubview(sectionTitle("Quick route"))
        copy.addArrangedSubview(helperText("Tailnet HTTPS :443  →  http://127.0.0.1:8080"))
        stack.addArrangedSubview(copy)
        stack.addArrangedSubview(spacer())
        let primary = button("Apply Quick Route", #selector(applyQuickRoute))
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        stack.addArrangedSubview(primary)
        return card(stack)
    }

    func routeCard() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.addArrangedSubview(sectionTitle("Custom route"))

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .bottom
        row.spacing = 12
        row.addArrangedSubview(fieldGroup("Tailnet", controls: [modePopup, exposeField], hint: "mode + port"))
        let arrow = NSTextField(labelWithString: "→")
        arrow.font = .systemFont(ofSize: 24, weight: .semibold)
        arrow.textColor = .secondaryLabelColor
        row.addArrangedSubview(arrow)
        row.addArrangedSubview(fieldGroup("Target", controls: [schemePopup, hostField, targetPortField], hint: "scheme + host + port"))
        stack.addArrangedSubview(row)

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 10
        actionRow.addArrangedSubview(button("Apply Custom Route", #selector(startServe)))
        actionRow.addArrangedSubview(helperText("Example: https :443 → http://127.0.0.1:3000"))
        stack.addArrangedSubview(actionRow)
        return card(stack)
    }

    func dockerCard() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.addArrangedSubview(sectionTitle("Docker targets"))
        stack.addArrangedSubview(helperText("Use containers that publish a host port, like -p 8080:80. Private container IPs are not used."))

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.addArrangedSubview(button("Load", #selector(loadDocker)))
        row.addArrangedSubview(dockerPopup)
        row.addArrangedSubview(button("Use Selected", #selector(useSelectedDockerTarget)))
        stack.addArrangedSubview(row)
        return card(stack)
    }

    func card(_ content: NSView) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 12
        box.borderWidth = 1
        box.contentViewMargins = NSSize(width: 16, height: 14)
        box.contentView = content
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 620).isActive = true
        return box
    }

    func fieldGroup(_ title: String, controls: [NSView], hint: String) -> NSStackView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        group.addArrangedSubview(label(title))
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        for control in controls {
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: control is NSPopUpButton ? 92 : 96).isActive = true
            row.addArrangedSubview(control)
        }
        group.addArrangedSubview(row)
        group.addArrangedSubview(helperText(hint))
        return group
    }

    func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 16, weight: .semibold)
        return field
    }

    func helperText(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 12)
        return field
    }

    func label(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    func currentConfig() -> RouteConfig {
        RouteConfig(
            serveMode: modePopup.titleOfSelectedItem ?? "https",
            exposePort: exposeField.stringValue,
            targetScheme: schemePopup.titleOfSelectedItem ?? "http",
            targetHost: hostField.stringValue,
            targetPort: targetPortField.stringValue
        )
    }

    func setBusy(_ text: String) {
        messageLabel.stringValue = text
        outputView.string = "Working…"
    }

    func show(_ message: String, _ output: String) {
        DispatchQueue.main.async {
            self.messageLabel.stringValue = message
            self.outputView.string = output
        }
    }

    @objc func applyQuickRoute(_ sender: Any?) {
        modePopup.selectItem(withTitle: "https")
        exposeField.stringValue = "443"
        schemePopup.selectItem(withTitle: "http")
        hostField.stringValue = "127.0.0.1"
        targetPortField.stringValue = "8080"
        startServe(sender)
    }

    @objc func startServe(_ sender: Any?) {
        setBusy("Starting Tailscale Serve…")
        let config = currentConfig()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let args = try config.command(tailscalePath: self.tailscalePath)
                guard FileManager.default.isExecutableFile(atPath: self.tailscalePath) else { throw ControlError.missingCommand("tailscale") }
                let result = try runCommand(args)
                guard result.exitCode == 0 else { throw ControlError.commandFailed("Unable to start Tailscale Serve.", result) }
                let target = try config.targetURL()
                self.show("Serving tailnet \(config.serveMode.uppercased()):\(config.exposePort) → \(target)", result.display)
            } catch {
                self.show("Failed", error.localizedDescription)
            }
        }
    }

    @objc func refreshStatus(_ sender: Any?) {
        setBusy("Refreshing Tailscale status…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard FileManager.default.isExecutableFile(atPath: self.tailscalePath) else { throw ControlError.missingCommand("tailscale") }
                let result = try runCommand([self.tailscalePath, "serve", "status", "--json"])
                self.show(result.exitCode == 0 ? "Tailscale Serve status loaded." : "Tailscale status command returned non-zero.", result.display)
            } catch {
                self.show("Failed", error.localizedDescription)
            }
        }
    }

    @objc func resetServe(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Reset Tailscale Serve?"
        alert.informativeText = "This removes the current Tailscale Serve configuration for this node."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        setBusy("Resetting Tailscale Serve…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard FileManager.default.isExecutableFile(atPath: self.tailscalePath) else { throw ControlError.missingCommand("tailscale") }
                let result = try runCommand([self.tailscalePath, "serve", "reset"])
                guard result.exitCode == 0 else { throw ControlError.commandFailed("Unable to reset Tailscale Serve.", result) }
                self.show("Tailscale Serve reset.", result.display)
            } catch {
                self.show("Failed", error.localizedDescription)
            }
        }
    }

    @objc func loadDocker(_ sender: Any?) {
        setBusy("Loading Docker targets…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard FileManager.default.isExecutableFile(atPath: self.dockerPath) else { throw ControlError.missingCommand("docker") }
                let (targets, message) = try loadDockerTargets(dockerPath: self.dockerPath)
                DispatchQueue.main.async {
                    self.dockerTargets = targets
                    self.dockerPopup.removeAllItems()
                    if targets.isEmpty {
                        self.dockerPopup.addItem(withTitle: "No published Docker ports found")
                    } else {
                        self.dockerPopup.addItems(withTitles: targets.map { $0.label })
                    }
                    self.messageLabel.stringValue = message
                    self.outputView.string = targets.isEmpty ? message : targets.map { $0.label }.joined(separator: "\n")
                }
            } catch {
                self.show("Failed", error.localizedDescription)
            }
        }
    }

    @objc func useSelectedDockerTarget(_ sender: Any?) {
        let index = dockerPopup.indexOfSelectedItem
        guard dockerTargets.indices.contains(index) else {
            show("No Docker target selected.", "Click Load Docker Targets first. Containers must publish host ports, e.g. -p 8080:80.")
            return
        }
        let target = dockerTargets[index]
        hostField.stringValue = "127.0.0.1"
        targetPortField.stringValue = String(target.hostPort)
        schemePopup.selectItem(withTitle: "http")
        show("Selected Docker target localhost:\(target.hostPort).", target.label)
    }
}

func runSelfTest() -> Int32 {
    do {
        let actual = try RouteConfig().command(tailscalePath: "/usr/local/bin/tailscale")
        let expected = ["/usr/local/bin/tailscale", "serve", "--bg", "--yes", "--https=443", "http://127.0.0.1:8080"]
        guard actual == expected else {
            print("FAIL command mismatch\nexpected: \(expected)\nactual:   \(actual)")
            return 1
        }
        _ = try validatePort("65535", label: "port")
        do {
            _ = try validatePort("65536", label: "port")
            print("FAIL invalid port accepted")
            return 1
        } catch {}
        print("PASS self-test")
        print(actual.joined(separator: " "))
        return 0
    } catch {
        print("FAIL \(error.localizedDescription)")
        return 1
    }
}

if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTest())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
