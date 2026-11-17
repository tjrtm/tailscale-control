import Foundation

// MARK: - Result

/// The outcome of one finished process.
///
/// `args` is the full argv (executable first). Output is decoded as UTF-8 (lossy).
struct CommandResult: Hashable, Sendable {
    /// Full argv including the executable path as element 0.
    let args: [String]
    let exitCode: Int32
    let stdout: String
    let stderr: String
    /// Wall-clock run time in seconds.
    let duration: TimeInterval
    /// True when the runner killed the process because `timeout` elapsed.
    var timedOut: Bool = false
    /// True when the process was stopped through `StreamingProcess.cancel()` or task cancellation.
    var wasCancelled: Bool = false

    /// `exitCode == 0` and not timed out.
    var succeeded: Bool { exitCode == 0 && !timedOut && !wasCancelled }

    /// Shell-quoted command line for display only (never execute it). The executable is shown
    /// by its base name (e.g. `tailscale serve --bg ...`) and secrets such as `--auth-key` values are masked.
    var commandLine: String { CommandRunner.displayCommandLine(args) }

    /// stdout followed by stderr (each trimmed), separated by a newline when both are non-empty.
    var combinedOutput: String {
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty { return err }
        if err.isEmpty { return out }
        return out + "\n" + err
    }

    /// One human-readable sentence/paragraph describing a failure (stderr, else stdout, else exit code).
    var errorSummary: String {
        if timedOut { return "The command timed out after \(Int(duration.rounded())) s." }
        if wasCancelled { return "The command was cancelled." }
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        return "The command exited with status \(exitCode)."
    }
}

/// Errors thrown before a process could produce a result.
enum CommandRunnerError: LocalizedError {
    case emptyCommand
    case notExecutable(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand: return "No command was given."
        case .notExecutable(let path): return "Executable not found or not runnable: \(path)"
        case .launchFailed(let detail): return "Could not launch the process: \(detail)"
        }
    }
}

// MARK: - Runner

/// Runs child processes with explicit argv arrays (never a shell).
///
/// * stdout and stderr are drained concurrently, so large output cannot deadlock.
/// * The main thread is never blocked; all waiting happens on background queues.
/// * `timeout` terminates (SIGTERM, then SIGKILL after 3 s) and marks the result `timedOut`.
enum CommandRunner {
    /// Safety net for demo mode: when true no process is ever started (`run` throws, `runStreaming` reports a failure).
    /// Only set through `DemoMode.enable()`.
    static var executionDisabled = false

    static let executionDisabledMessage = "Running commands is disabled in demo mode."

    /// PATH appended to the inherited one so GUI-launched apps can find helper tools (docker credential helpers, ...).
    static let fallbackPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Run `args` (executable path first) to completion.
    ///
    /// A non-zero exit code is **not** an error: inspect `CommandResult.succeeded`.
    /// Throws `CommandRunnerError` when the process cannot be launched, or `CancellationError` if the
    /// calling task is cancelled (the process is terminated).
    static func run(_ args: [String], timeout: TimeInterval = 30, stdin: Data? = nil) async throws -> CommandResult {
        guard let executable = args.first, !executable.isEmpty else { throw CommandRunnerError.emptyCommand }
        if executionDisabled { throw CommandRunnerError.launchFailed(executionDisabledMessage) }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CommandRunnerError.notExecutable(executable)
        }
        ignoreSIGPIPE()
        let job = Job(args: args, timeout: timeout, stdin: stdin)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                job.start(continuation)
            }
        } onCancel: {
            job.cancel()
        }
        if Task.isCancelled { throw CancellationError() }
        return result
    }

    /// Run a long-lived process and stream its output.
    ///
    /// * `onOutput` receives decoded chunks of stdout and stderr (interleaved) **on the main queue**.
    /// * `onFinish` is called on the main queue after the last chunk.
    /// * `timeout` is optional; `nil` means run until exit or `cancel()`.
    /// * Launch failures are reported through `onOutput` and a result with exit code 127.
    @discardableResult
    static func runStreaming(
        _ args: [String],
        timeout: TimeInterval? = nil,
        onOutput: @escaping (String) -> Void,
        onFinish: ((CommandResult) -> Void)? = nil
    ) -> StreamingProcess {
        ignoreSIGPIPE()
        let handle = StreamingProcess(args: args, timeout: timeout, onOutput: onOutput, onFinish: onFinish)
        handle.start()
        return handle
    }

    // MARK: Display helpers

    /// Quote one argument for display in a POSIX shell (never used to execute anything).
    static func shellQuote(_ arg: String) -> String {
        if arg.isEmpty { return "''" }
        let safe = arg.unicodeScalars.allSatisfy { s in
            (s.value >= 48 && s.value <= 57) || (s.value >= 65 && s.value <= 90) || (s.value >= 97 && s.value <= 122)
                || "_@%+=:,./-".unicodeScalars.contains(s)
        }
        if safe { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Flags whose values are secrets and are masked in logs and previews.
    static let secretFlags: Set<String> = ["--auth-key", "--client-secret", "--id-token"]

    /// Returns `args` with the values of secret flags replaced by `REDACTED`
    /// (handles both `--flag=value` and `--flag value`).
    static func redactSecrets(_ args: [String]) -> [String] {
        var out: [String] = []
        var maskNext = false
        for arg in args {
            if maskNext { out.append("REDACTED"); maskNext = false; continue }
            if let eq = arg.firstIndex(of: "="), secretFlags.contains(String(arg[..<eq])) {
                out.append(String(arg[..<eq]) + "=REDACTED")
            } else if secretFlags.contains(arg) {
                out.append(arg); maskNext = true
            } else {
                out.append(arg)
            }
        }
        return out
    }

    /// Display string for an argv: first element by base name, secrets masked, each argument shell-quoted.
    static func displayCommandLine(_ args: [String]) -> String {
        var shown = redactSecrets(args)
        if let first = shown.first, first.contains("/") {
            shown[0] = (first as NSString).lastPathComponent
        }
        return shown.map(shellQuote).joined(separator: " ")
    }

    private static var sigpipeIgnored = false
    private static let sigpipeLock = NSLock()
    private static func ignoreSIGPIPE() {
        sigpipeLock.lock(); defer { sigpipeLock.unlock() }
        if !sigpipeIgnored { signal(SIGPIPE, SIG_IGN); sigpipeIgnored = true }
    }

    fileprivate static func makeProcess(_ args: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        var env = ProcessInfo.processInfo.environment
        let current = env["PATH"] ?? ""
        env["PATH"] = current.isEmpty ? fallbackPath : current + ":" + fallbackPath
        process.environment = env
        return process
    }
}

// MARK: - Internals

/// Thread-safe byte sink.
private final class ByteBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Reads a file handle until EOF on the calling (background) thread.
private func drain(_ handle: FileHandle, _ onChunk: (Data) -> Void) {
    while true {
        guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { return }
        onChunk(chunk)
    }
}

private final class Job: @unchecked Sendable {
    private let args: [String]
    private let timeout: TimeInterval
    private let stdin: Data?
    private let process: Process
    private let lock = NSLock()
    private var timedOut = false
    private var cancelled = false
    private var started = false

    init(args: [String], timeout: TimeInterval, stdin: Data?) {
        self.args = args
        self.timeout = timeout
        self.stdin = stdin
        self.process = CommandRunner.makeProcess(args)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = started && process.isRunning
        lock.unlock()
        if running { process.terminate() }
    }

    func start(_ continuation: CheckedContinuation<CommandResult, Error>) {
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let began = Date()
        do { try process.run() } catch {
            continuation.resume(throwing: CommandRunnerError.launchFailed(error.localizedDescription))
            return
        }
        lock.lock(); started = true; let alreadyCancelled = cancelled; lock.unlock()
        if alreadyCancelled { process.terminate() }

        let out = ByteBuffer(), err = ByteBuffer()
        let readers = DispatchGroup()
        let outHandle = outPipe.fileHandleForReading, errHandle = errPipe.fileHandleForReading
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async { drain(outHandle) { out.append($0) }; readers.leave() }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async { drain(errHandle) { err.append($0) }; readers.leave() }

        if let inPipe, let stdin {
            DispatchQueue.global(qos: .userInitiated).async {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            }
        }

        let pid = process.processIdentifier
        let timer = DispatchWorkItem { [self] in
            guard process.isRunning else { return }
            lock.lock(); timedOut = true; lock.unlock()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(timeout, 0.1), execute: timer)

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            exited.wait()
            timer.cancel()
            // Normally EOF arrives right after exit. If a grandchild keeps the pipe open, don't hang forever.
            _ = readers.wait(timeout: .now() + 2)
            lock.lock(); let didTimeOut = timedOut, wasCancelled = cancelled; lock.unlock()
            let result = CommandResult(
                args: args,
                exitCode: process.terminationStatus,
                stdout: String(decoding: out.snapshot(), as: UTF8.self),
                stderr: String(decoding: err.snapshot(), as: UTF8.self),
                duration: Date().timeIntervalSince(began),
                timedOut: didTimeOut,
                wasCancelled: wasCancelled
            )
            continuation.resume(returning: result)
        }
    }
}

/// Incrementally decodes UTF-8 chunks, holding back incomplete trailing sequences.
private struct UTF8ChunkDecoder {
    private var pending = Data()
    mutating func feed(_ chunk: Data) -> String {
        pending.append(chunk)
        var cut = pending.count
        while cut > 0 && cut >= pending.count - 3 {
            if let s = String(data: pending.prefix(cut), encoding: .utf8) {
                pending = Data(pending.dropFirst(cut))
                return s
            }
            cut -= 1
        }
        let s = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return s
    }
}

/// A running streamed command: a real process (`StreamingProcess`) or a simulated one in demo mode.
protocol CommandStream: AnyObject {
    /// True until the command has finished and all output was delivered.
    var isRunning: Bool { get }
    /// Ask the command to stop. Safe to call repeatedly or after it finished.
    func cancel()
}

/// Handle for a process started with `CommandRunner.runStreaming`.
final class StreamingProcess: CommandStream, @unchecked Sendable {
    private let args: [String]
    private let timeout: TimeInterval?
    private let onOutput: (String) -> Void
    private let onFinish: ((CommandResult) -> Void)?
    private let process: Process
    private let lock = NSLock()
    private var cancelled = false
    private var timedOut = false
    private var started = false
    private var finalResult: CommandResult?
    private var waiters: [CheckedContinuation<CommandResult, Never>] = []

    fileprivate init(args: [String], timeout: TimeInterval?, onOutput: @escaping (String) -> Void, onFinish: ((CommandResult) -> Void)?) {
        self.args = args
        self.timeout = timeout
        self.onOutput = onOutput
        self.onFinish = onFinish
        self.process = args.first.map { _ in CommandRunner.makeProcess(args) } ?? Process()
    }

    /// True until the process has exited and all output was delivered.
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return finalResult == nil }

    /// Ask the process to stop (SIGTERM, then SIGKILL after 3 s). Safe to call repeatedly or after exit.
    func cancel() {
        lock.lock()
        cancelled = true
        let running = started && process.isRunning
        lock.unlock()
        guard running else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Suspends until the process finished and returns its result (immediately if already finished).
    func waitForResult() async -> CommandResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
            lock.lock()
            if let finalResult { lock.unlock(); continuation.resume(returning: finalResult) }
            else { waiters.append(continuation); lock.unlock() }
        }
    }

    fileprivate func start() {
        let began = Date()
        if CommandRunner.executionDisabled {
            let message = CommandRunner.executionDisabledMessage
            finish(CommandResult(args: args, exitCode: 127, stdout: "", stderr: message, duration: 0), message: message + "\n")
            return
        }
        guard let executable = args.first, FileManager.default.isExecutableFile(atPath: executable) else {
            finish(CommandResult(args: args, exitCode: 127, stdout: "", stderr: "Executable not found: \(args.first ?? "(none)")", duration: 0),
                   message: "Executable not found: \(args.first ?? "(none)")\n")
            return
        }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            let message = "Could not launch the process: \(error.localizedDescription)"
            finish(CommandResult(args: args, exitCode: 127, stdout: "", stderr: message, duration: 0), message: message + "\n")
            return
        }
        lock.lock(); started = true; let early = cancelled; lock.unlock()
        if early { cancel() }

        let out = ByteBuffer(), err = ByteBuffer()
        let readers = DispatchGroup()
        for (handle, buffer) in [(outPipe.fileHandleForReading, out), (errPipe.fileHandleForReading, err)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async { [onOutput] in
                var decoder = UTF8ChunkDecoder()
                drain(handle) { chunk in
                    buffer.append(chunk)
                    let text = decoder.feed(chunk)
                    if !text.isEmpty { DispatchQueue.main.async { onOutput(text) } }
                }
                readers.leave()
            }
        }

        let pid = process.processIdentifier
        var timer: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem { [self] in
                guard process.isRunning else { return }
                lock.lock(); timedOut = true; lock.unlock()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
            timer = item
            DispatchQueue.global().asyncAfter(deadline: .now() + max(timeout, 0.1), execute: item)
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            exited.wait()
            timer?.cancel()
            _ = readers.wait(timeout: .now() + 2)
            lock.lock(); let didTimeOut = timedOut, wasCancelled = cancelled; lock.unlock()
            let result = CommandResult(
                args: args,
                exitCode: process.terminationStatus,
                stdout: String(decoding: out.snapshot(), as: UTF8.self),
                stderr: String(decoding: err.snapshot(), as: UTF8.self),
                duration: Date().timeIntervalSince(began),
                timedOut: didTimeOut,
                wasCancelled: wasCancelled
            )
            finish(result, message: nil)
        }
    }

    private func finish(_ result: CommandResult, message: String?) {
        DispatchQueue.main.async { [self] in
            if let message { onOutput(message) }
            lock.lock()
            finalResult = result
            let pending = waiters
            waiters = []
            lock.unlock()
            onFinish?(result)
            for waiter in pending { waiter.resume(returning: result) }
        }
    }
}
