import CmuxCloud
import Foundation

/// Composes the app-owned SSH listener with CmuxCloud's process lifecycle service.
actor SSHTuiLoopbackForwardProcess {
    private let process = CloudSSHLoopbackForwardProcess()
    // Test hook pauses after listener handoff to exercise a racing stop.
    private let onListenerPrepared: (@Sendable () async -> Void)?
    private var stopped = false

    init(onListenerPrepared: (@Sendable () async -> Void)? = nil) {
        self.onListenerPrepared = onListenerPrepared
    }

    var readyPort: UInt16? {
        get async { await process.readyPort }
    }

    func start(
        client: URL,
        arguments: [String],
        environment: [String: String]?,
        listener: SSHTuiLoopbackListenerLease
    ) async throws -> UInt16 {
        guard !stopped else { throw CancellationError() }
        // Duplicate the descriptor before changing the listener's rejection
        // state. A failed duplication must leave the existing 503 handler in place.
        let childInput = try listener.makeChildInput()
        let listenerGeneration = listener.prepareForChild()
        if let onListenerPrepared {
            await onListenerPrepared()
        }
        do {
            return try await process.start(
                client: client,
                arguments: arguments,
                environment: environment,
                standardInput: childInput,
                expectedPort: listener.port,
                onTermination: { listener.childDidStop(generation: listenerGeneration) }
            )
        } catch let error as CloudSSHLoopbackForwardProcess.StartupError {
            throw Self.linkError(for: error)
        }
    }

    func stop() async {
        stopped = true
        await process.stop()
    }

    private static func linkError(
        for error: CloudSSHLoopbackForwardProcess.StartupError
    ) -> CloudMachineLink.LinkError {
        switch error {
        case .timedOut:
            return .timedOut
        case .endedBeforeReady:
            return .failureMessage(String(
                localized: "ssh.tui.browserListener.forwardEnded",
                defaultValue: "The SSH port forward ended before it became ready."
            ))
        case .portMismatch:
            return .failureMessage(String(
                localized: "ssh.tui.browserListener.portMismatch",
                defaultValue: "The SSH helper reported a different browser listener port."
            ))
        }
    }
}
