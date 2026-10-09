import CmuxCloud
import Foundation
import Testing

@Suite("Cloud SSH loopback forward process")
struct CloudSSHLoopbackForwardProcessTests {
    @Test("A process publishes its loopback port and stops cleanly")
    func readinessAndStop() async throws {
        let fixture = try Fixture(script: "printf '%s\\n' 'http://127.0.0.1:43210'; exec /bin/sleep 60")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let process = CloudSSHLoopbackForwardProcess(startupTimeout: .seconds(5))

        let port = try await process.start(
            client: fixture.client,
            arguments: [],
            environment: [:],
            standardInput: .nullDevice,
            expectedPort: 43210,
            onTermination: {}
        )
        #expect(port == 43210)
        #expect(await process.readyPort == 43210)

        await process.stop()
        #expect(await process.readyPort == nil)
    }

    @Test("A process must report the reserved listener port")
    func rejectsUnexpectedPort() async throws {
        let fixture = try Fixture(script: "printf '%s\\n' 'http://127.0.0.1:43211'; exec /bin/sleep 60")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let process = CloudSSHLoopbackForwardProcess(startupTimeout: .seconds(5))

        do {
            _ = try await process.start(
                client: fixture.client,
                arguments: [],
                environment: [:],
                standardInput: .nullDevice,
                expectedPort: 43210,
                onTermination: {}
            )
            Issue.record("The child must not replace the app-owned listener port")
        } catch let error as CloudSSHLoopbackForwardProcess.StartupError {
            #expect(error == .portMismatch)
        }
        #expect(await process.readyPort == nil)
    }

    @Test("A process that exits before readiness fails promptly")
    func exitsBeforeReadiness() async throws {
        let fixture = try Fixture(script: "exit 17")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let process = CloudSSHLoopbackForwardProcess(startupTimeout: .seconds(5))

        do {
            _ = try await process.start(
                client: fixture.client,
                arguments: [],
                environment: [:],
                standardInput: .nullDevice,
                expectedPort: 43210,
                onTermination: {}
            )
            Issue.record("A child that exits before readiness must fail")
        } catch let error as CloudSSHLoopbackForwardProcess.StartupError {
            #expect(error == .endedBeforeReady)
        }
    }

    @Test("A canceled stop still waits for grace, kill, and child exit", .timeLimit(.minutes(1)))
    func canceledStopStillKillsChild() async throws {
        let fixture = try Fixture(script: "trap '' TERM; printf '%s\\n' 'http://127.0.0.1:43210'; exec /bin/sleep 2")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let process = CloudSSHLoopbackForwardProcess(
            startupTimeout: .seconds(5),
            terminationGracePeriod: .milliseconds(250)
        )
        let clock = ContinuousClock()
        let terminatedAt = CloudLinkFirstValue<ContinuousClock.Instant>()
        let stopReturnedAt = CloudLinkFirstValue<ContinuousClock.Instant>()
        _ = try await process.start(
            client: fixture.client,
            arguments: [],
            environment: [:],
            standardInput: .nullDevice,
            expectedPort: 43210,
            onTermination: { terminatedAt.resolve(clock.now) }
        )

        let stopStartedAt = clock.now
        let stop = Task {
            await process.stop()
            stopReturnedAt.resolve(clock.now)
        }
        stop.cancel()
        let ended = await terminatedAt.result
        #expect(ended != nil, "A canceled caller must not suppress forced child termination")
        if let ended {
            let elapsed = stopStartedAt.duration(to: ended)
            #expect(elapsed >= .milliseconds(200), "Caller cancellation must not skip the grace period")
            #expect(elapsed < .seconds(1), "The child should be killed before its own two-second exit")
        }
        await stop.value
        let returned = await stopReturnedAt.result
        #expect(returned != nil)
        if let ended, let returned {
            #expect(ended <= returned, "stop() must not return before the child exits")
            #expect(stopStartedAt.duration(to: returned) < .seconds(1))
        }
    }

    @Test("Concurrent stop callers all wait for the child to exit", .timeLimit(.minutes(1)))
    func concurrentStopsShareShutdown() async throws {
        let fixture = try Fixture(script: "trap '' TERM; printf '%s\\n' 'http://127.0.0.1:43210'; exec /bin/sleep 3")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let clock = ContinuousClock()
        let process = CloudSSHLoopbackForwardProcess(
            startupTimeout: .seconds(5),
            terminationGracePeriod: .seconds(1)
        )
        let terminatedAt = CloudLinkFirstValue<ContinuousClock.Instant>()
        _ = try await process.start(
            client: fixture.client,
            arguments: [],
            environment: [:],
            standardInput: .nullDevice,
            expectedPort: 43210,
            onTermination: { terminatedAt.resolve(clock.now) }
        )

        let firstStop = Task { await process.stop() }
        let startupDeadline = clock.now.advanced(by: .seconds(2))
        while await process.readyPort != nil, clock.now < startupDeadline {
            try await clock.sleep(for: .milliseconds(1))
        }
        #expect(await process.readyPort == nil, "The first stop must enter shutdown before a caller joins")
        let secondStopStartedAt = clock.now
        let secondStopReturnedAt = CloudLinkFirstValue<ContinuousClock.Instant>()
        let secondStop = Task {
            await process.stop()
            secondStopReturnedAt.resolve(clock.now)
        }

        await secondStop.value
        let terminated = await terminatedAt.result
        let returned = await secondStopReturnedAt.result
        #expect(terminated != nil)
        #expect(returned != nil)
        if let terminated, let returned {
            #expect(terminated <= returned, "Every stop caller must await child exit")
            #expect(secondStopStartedAt.duration(to: returned) >= .milliseconds(800),
                    "A concurrent stop caller must join the in-flight shutdown")
            #expect(secondStopStartedAt.duration(to: returned) < .seconds(2))
        }
        await firstStop.value
    }

    @Test("A start that loses a race with stop restores its external listener state")
    func startAfterStopRunsTerminationCallback() async throws {
        let fixture = try Fixture(script: "exit 0")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let process = CloudSSHLoopbackForwardProcess()
        await process.stop()
        let termination = CloudLinkFirstValue<Int32>()

        do {
            _ = try await process.start(
                client: fixture.client,
                arguments: [],
                environment: [:],
                standardInput: .nullDevice,
                expectedPort: 43210,
                onTermination: { termination.resolve(0) }
            )
            Issue.record("A stopped process owner must reject a late start")
        } catch is CancellationError {
            // Expected. The callback still resets state acquired before this actor hop.
        }

        #expect(await termination.result == 0)
    }

    @Test("A process that never publishes readiness respects its startup deadline", .timeLimit(.minutes(1)))
    func startupTimesOut() async throws {
        let fixture = try Fixture(script: "exec /bin/sleep 2")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let process = CloudSSHLoopbackForwardProcess(
            startupTimeout: .milliseconds(25),
            terminationGracePeriod: .milliseconds(25)
        )

        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await process.start(
                client: fixture.client,
                arguments: [],
                environment: [:],
                standardInput: .nullDevice,
                expectedPort: 43210,
                onTermination: {}
            )
            Issue.record("The child must not wait past the startup deadline")
        } catch let error as CloudSSHLoopbackForwardProcess.StartupError {
            #expect(error == .timedOut)
        }
        #expect(start.duration(to: clock.now) < .seconds(1),
                "Timeout cleanup must stop the child before its two-second self-exit")
    }

    private struct Fixture {
        let root: URL
        let client: URL

        init(script: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-cloud-ssh-forward-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            client = root.appendingPathComponent("fake-forward")
            try "#!/bin/sh\n\(script)\n".write(to: client, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
        }
    }
}
