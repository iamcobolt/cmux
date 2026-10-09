import Darwin
import Foundation

/// Owns the child process that carries one SSH browser loopback forward.
///
/// The app retains ownership of the reserved listener and supplies its duplicated
/// descriptor. This service owns process startup, readiness parsing, pipe readers,
/// timeout handling, and termination.
public actor CloudSSHLoopbackForwardProcess {
    /// Failure reported while starting an SSH browser forward.
    public enum StartupError: Error, Sendable, Equatable {
        /// The process did not publish a listener before the injected clock deadline.
        case timedOut
        /// The process exited before publishing a listener.
        case endedBeforeReady
        /// The reported listener did not match the app-owned listener.
        case portMismatch
    }

    private var process: Process?
    private var exit: CloudLinkFirstValue<Int32>?
    private var localPort: UInt16?
    private var stopped = false
    private var stdoutReader: Task<Void, Never>?
    private var stderrReader: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private let clock: any Clock<Duration>
    private let startupTimeout: Duration
    private let terminationGracePeriod: Duration

    /// Creates a process owner with injectable timing for deterministic tests.
    public init(
        clock: any Clock<Duration> = ContinuousClock(),
        startupTimeout: Duration = .seconds(60),
        terminationGracePeriod: Duration = .seconds(3)
    ) {
        self.clock = clock
        self.startupTimeout = startupTimeout
        self.terminationGracePeriod = terminationGracePeriod
    }

    /// The port reported by a live child, or `nil` while it is not ready.
    public var readyPort: UInt16? {
        !stopped && process?.isRunning == true ? localPort : nil
    }

    /// Starts a child and waits for its loopback readiness URL.
    ///
    /// - Parameters:
    ///   - client: Executable URL for the SSH TUI client.
    ///   - arguments: Arguments for its `remote forward` command.
    ///   - environment: Environment captured from the owning SSH connection.
    ///   - standardInput: A duplicated descriptor for the app-owned listener.
    ///   - expectedPort: The port reserved by that listener.
    ///   - onTermination: Called when the child exits so the app can resume rejecting traffic.
    /// - Returns: The validated loopback port reported by the child.
    public func start(
        client: URL,
        arguments: [String],
        environment: [String: String]?,
        standardInput: FileHandle,
        expectedPort: UInt16,
        onTermination: @escaping @Sendable () -> Void
    ) async throws -> UInt16 {
        guard !stopped else {
            onTermination()
            throw CancellationError()
        }
        let child = Process()
        let output = Pipe()
        let errors = Pipe()
        let ended = CloudLinkFirstValue<Int32>()
        let ready = CloudLinkFirstValue<UInt16>()
        child.executableURL = client
        child.arguments = arguments
        child.environment = CloudBrowserProxyProcess.sanitizedEnvironment(
            environment ?? ProcessInfo.processInfo.environment
        )
        child.standardInput = standardInput
        child.standardOutput = output
        child.standardError = errors
        child.terminationHandler = { terminated in
            onTermination()
            ended.resolve(terminated.terminationStatus)
            ready.resolve(nil)
        }
        do {
            try child.run()
        } catch {
            onTermination()
            throw error
        }
        process = child
        exit = ended

        let lines = CloudLinkPipe.lines(from: output.fileHandleForReading)
        stdoutReader = Task {
            for await line in lines {
                guard let url = URLComponents(string: line),
                      url.scheme == "http",
                      ["127.0.0.1", "::1"].contains(
                        url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() ?? ""
                      ),
                      let port = url.port, port > 0, port <= Int(UInt16.max) else { continue }
                ready.resolve(UInt16(port))
            }
            ready.resolve(nil)
        }
        // Drain stderr until process termination so the child cannot block on its pipe.
        let errorLines = CloudLinkPipe.lines(from: errors.fileHandleForReading)
        stderrReader = Task { for await _ in errorLines {} }

        do {
            let port = try await withThrowingTaskGroup(of: UInt16?.self) { group in
                group.addTask { await ready.result }
                group.addTask {
                    try await self.clock.sleep(for: self.startupTimeout)
                    throw StartupError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            try Task.checkCancellation()
            guard !stopped, child.isRunning, let port else { throw StartupError.endedBeforeReady }
            guard port == expectedPort else { throw StartupError.portMismatch }
            localPort = port
            return port
        } catch {
            await stop()
            throw error
        }
    }

    /// Stops the child, escalating after the injected grace period if it remains alive.
    public func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard !stopped else { return }
        stopped = true
        localPort = nil
        let child = self.process
        let exitSignal = self.exit
        let stdoutTask = self.stdoutReader
        let stderrTask = self.stderrReader
        let clock = self.clock
        let gracePeriod = terminationGracePeriod
        let shutdown = Task.detached {
            if let child, let exitSignal {
                if child.isRunning { child.terminate() }
                let processIdentifier = child.processIdentifier
                let finished = Task.detached { await exitSignal.result }
                let forceStop = Task.detached {
                    do { try await clock.sleep(for: gracePeriod) } catch { return }
                    if child.isRunning { kill(processIdentifier, SIGKILL) }
                }
                _ = await finished.value
                forceStop.cancel()
            }
            stdoutTask?.cancel()
            stderrTask?.cancel()
            if let stdoutTask { await stdoutTask.value }
            if let stderrTask { await stderrTask.value }
        }
        stopTask = shutdown
        await shutdown.value
        process = nil
        exit = nil
        stdoutReader = nil
        stderrReader = nil
        stopTask = nil
    }
}
