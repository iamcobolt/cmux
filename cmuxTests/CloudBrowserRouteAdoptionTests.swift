import CmuxCloud
import Foundation
import CmuxSurfaceCatalogModel
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud browser route adoption")
struct CloudBrowserRouteAdoptionTests {
    @Test("Removing a queued SSH loopback navigation prevents stale rule installation")
    func removedQueuedLoopbackProtectionCannotInstallOrNavigate() async throws {
        let target = CloudPortForwardTarget(host: "127.0.0.1", port: 3000)
        let model = CloudPortAccessModel(
            target: target, coordinator: nil, wake: {},
            startForward: { _ in 42_000 }, stopForward: {}, route: .loopback, allowsLoopback: true
        )
        model.connect()
        try #require(await wait { model.isReady })

        // Positive control: the same ready model compiles and attaches its rule.
        let control = BrowserPanel(workspaceId: UUID())
        defer { control.close() }
        control.cloudAccess.configure(model: model, url: URL(string: "http://127.0.0.1:3000/")!)
        control.bindCloudBrowserNavigation()
        let controlTask = try #require(control.cloudLoopbackProtectionTask)
        await controlTask.value
        #expect(control.cloudLoopbackContentRuleList != nil)
        #expect(control.cloudAccess.navigationURL?.port == 42_000)
        #expect(control.webView.url?.port == 42_000)

        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        panel.cloudAccess.configure(model: model, url: URL(string: "http://127.0.0.1:3000/")!)
        panel.bindCloudBrowserNavigation()
        let queuedTask = try #require(panel.cloudLoopbackProtectionTask)
        panel.removeManagedSSHLoopbackProtection()
        let invalidatedGeneration = panel.cloudLoopbackProtectionGeneration
        await queuedTask.value

        #expect(panel.cloudLoopbackProtectionGeneration == invalidatedGeneration)
        #expect(panel.cloudLoopbackContentRuleList == nil)
        #expect(panel.cloudLoopbackScriptConfigurationKey == nil)
        #expect(panel.cloudAccess.navigationURL?.port == 42_000)
        #expect(panel.webView.url?.port != 42_000)
        await model.retire()
    }

    @Test("A committed same-VM redirect retains readiness without replaying navigation")
    func committedRouteIsObservedInPlace() async throws {
        let state = CloudBrowserAccessState()
        let endpoint = CloudBrowserProxyEndpoint(
            host: "127.0.0.1", port: 48_001,
            username: "fixture", password: "fixture"
        )
        let model = CloudPortAccessModel(
            target: .init(host: "10.16.0.70", port: 6901),
            coordinator: nil,
            wake: {},
            startForward: { _ in throw CancellationError() },
            stopForward: {},
            startBrowserProxy: { endpoint }
        )
        let initial = URL(string: "http://10.16.0.70:6901/vnc.html")!
        let redirected = URL(string: "http://10.16.0.70:6902/vnc.html")!
        let resource = SurfaceResourceID(machine: .cloud("route-adoption"), kind: .display, key: "display:1")
        var navigationRequests = 0
        state.automaticallyNavigate { _ in navigationRequests += 1 }
        state.configure(model: model, url: initial, resourceID: resource)
        state.adoptCommittedRoute(model: model, url: redirected, resourceID: resource)
        model.connect()
        try #require(await AppKitTestEventPump().waitUntil { model.isReady })

        #expect(state.navigationURL == redirected)
        #expect(state.hasCommittedNavigation)
        #expect(state.model === model)
        #expect(state.remoteURL == redirected)
        #expect(navigationRequests == 0)
    }

    private func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }
}
