import Foundation
import SwiftUI

/// Runs one `tailscale` command at a time with live output, a Stop action and activity-log integration.
///
/// Used by the Tools screen and by the Devices inspector (ping). All members must be used from the main thread;
/// `CommandRunner.runStreaming` delivers its callbacks on the main queue.
final class ToolsStreamRunner: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var isRunning = false
    @Published private(set) var lastResult: CommandResult?

    private var process: CommandStream?
    private var generation = 0

    /// Upper bound for the kept output (UTF-8 bytes); older text is dropped so endless streams stay cheap.
    private static let outputCap = 400_000

    /// Start `tailscale <subArgs>`. Does nothing while a run is active.
    /// - Parameters:
    ///   - timeout: seconds before the process is stopped; `nil` runs until it exits or `cancel()` is called.
    ///   - refreshAfter: reload all store data once the command finished (for commands that may change state).
    ///     Such commands also mark the store busy while they run.
    func start(_ subArgs: [String], timeout: TimeInterval?, store: AppStore, refreshAfter: Bool = false) {
        guard !isRunning else { return }
        output = ""
        lastResult = nil
        generation += 1
        let current = generation
        isRunning = true
        if refreshAfter {
            let description = CommandRunner.displayCommandLine(["tailscale"] + subArgs)
            Task { @MainActor in store.beginBusy(description) }
        }
        do {
            process = try TailscaleCLI.stream(subArgs, timeout: timeout, onOutput: { [weak self] text in
                guard let self, self.generation == current else { return }
                self.append(text)
            }, onFinish: { [weak self] result in
                Task { @MainActor in
                    store.log(result)
                    if refreshAfter { store.endBusy(); await store.refreshAll() }
                }
                guard let self, self.generation == current else { return }
                if result.timedOut { self.append("\n[Timed out after \(Int(result.duration.rounded())) s]\n") }
                else if result.wasCancelled { self.append("\n[Stopped]\n") }
                else if result.exitCode != 0 { self.append("\n[Exited with status \(result.exitCode)]\n") }
                self.lastResult = result
                self.isRunning = false
                self.process = nil
            })
        } catch {
            if refreshAfter { Task { @MainActor in store.endBusy() } }
            output = error.localizedDescription + "\n"
            isRunning = false
            return
        }
    }

    /// Ask the running process to stop. Output produced until it exits is still shown.
    func cancel() { process?.cancel() }

    /// Stop any run and forget its output (late callbacks are ignored).
    func reset() {
        process?.cancel()
        process = nil
        generation += 1
        isRunning = false
        output = ""
        lastResult = nil
    }

    /// Clear the console without touching a running process.
    func clearOutput() {
        output = ""
        if !isRunning { lastResult = nil }
    }

    private func append(_ text: String) {
        output += text
        if output.utf8.count > Self.outputCap {
            let drop = output.count - Self.outputCap / 2
            if drop > 0 { output = "[Earlier output omitted]\n" + String(output.dropFirst(drop)) }
        }
    }
}
