import SwiftUI

@MainActor
struct AppRootView: View {
    @StateObject private var coordinator: AppCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init() {
#if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-empty-binding") {
            let configuration = LaunchConfiguration.current
            let store = EmptyUITestBindingStore()
            let clock = ContinuousSessionClock()
            let client = AuthClient(
                bindingStore: store, transport: URLSessionAuthHTTPTransport(), clock: clock,
                endpoints: configuration.endpoints(for: configuration.environment)
            )
            let manager = SessionManager(bindingStore: store, authClient: client, clock: clock)
            _coordinator = StateObject(wrappedValue: AppCoordinator(
                configuration: configuration, bindingStore: store, sessionManager: manager
            ))
            return
        }
#endif
        _coordinator = StateObject(wrappedValue: AppCoordinator())
    }

    var body: some View {
        ContentView(coordinator: coordinator)
            .task { await coordinator.start() }
            .onChange(of: scenePhase) { _, phase in coordinator.setActive(phase == .active) }
    }
}
