import Foundation
import Testing
@testable import ZDEEP

@MainActor
struct CoordinatorTests {
    @Test func test_select_prod_does_not_load_web() async {
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory
        )

        await coordinator.switchEnvironment(to: .prod)

        #expect(coordinator.environment == .prod)
        #expect(!coordinator.isWebViewOpen)
        #expect(factory.sessions.isEmpty)
    }

    @Test func test_close_then_reopen_creates_new_session() {
        let factory = FakeWebSessionFactory()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: [], variables: [:]),
            sessionFactory: factory
        )

        coordinator.openWebView()
        let firstSession = factory.sessions[0]
        coordinator.closeWebView()
        coordinator.openWebView()

        #expect(factory.sessions.count == 2)
        #expect(firstSession.closeCount == 1)
        #expect(factory.sessions[0].id != factory.sessions[1].id)
    }

    @Test func test_cross_database_switch_requests_clear() async {
        let state = FakeClientState()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: ["--environment", "local"], variables: [:]),
            clearClientState: { await state.clear() }
        )
        coordinator.openWebView()

        await coordinator.switchEnvironment(to: .test)

        #expect(state.clearCount == 1)
        #expect(coordinator.environment == .test)
        #expect(!coordinator.isWebViewOpen)
    }

    @Test func test_test_prod_switch_preserves_store() async {
        let state = FakeClientState()
        let coordinator = AppCoordinator(
            configuration: LaunchConfiguration(arguments: ["--environment", "test"], variables: [:]),
            clearClientState: { await state.clear() }
        )

        await coordinator.switchEnvironment(to: .prod)

        #expect(state.clearCount == 0)
        #expect(coordinator.environment == .prod)
    }
}

@MainActor
private final class FakeWebSessionFactory: WebSessionFactory {
    private(set) var sessions: [FakeWebSession] = []

    func makeSession(for environment: AppEnvironment, endpoints: EnvironmentEndpoints) -> any WebSessionHandle {
        let session = FakeWebSession()
        sessions.append(session)
        return session
    }
}

@MainActor
private final class FakeWebSession: WebSessionHandle {
    let id = UUID()
    private(set) var closeCount = 0

    func close() {
        closeCount += 1
    }
}

@MainActor
private final class FakeClientState {
    private(set) var clearCount = 0

    func clear() async {
        clearCount += 1
    }
}
