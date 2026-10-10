import Foundation
import Testing
@testable import ZDEEP

struct EnvironmentTests {
    @Test func test_exact_environment_urls() {
        let local = AppEnvironment.local.endpoints
        let test = AppEnvironment.test.endpoints
        let prod = AppEnvironment.prod.endpoints

        #expect(local.web.absoluteString == "http://localhost:4005")
        #expect(local.backend.absoluteString == "http://localhost:4002")
        #expect(test.web.absoluteString == "https://5e9afe68-2ddd-4e58-8e57-5942cfa16099.website.twcstorage.ru")
        #expect(test.backend.absoluteString == "https://api.zdeep.ru/testing/")
        #expect(prod.web.absoluteString == "https://webview2.zdeep.ru")
        #expect(prod.backend.absoluteString == "https://api.zdeep.ru")
    }

    @Test func test_testing_api_path_is_preserved() {
        #expect(AppEnvironment.test.endpoints.backend.absoluteString == "https://api.zdeep.ru/testing/")
    }

    @Test func test_default_environment_matches_build_destination() {
        #expect(LaunchConfiguration.defaultEnvironment(isSimulator: true) == .local)
        #expect(LaunchConfiguration.defaultEnvironment(isSimulator: false) == .test)
    }

    @Test func test_launch_configuration_selects_environment_and_local_overrides() {
        let configuration = LaunchConfiguration(
            arguments: ["--environment", "local", "--web-url", "http://127.0.0.1:9000", "--api-url", "http://127.0.0.1:9001"],
            variables: ["ZDEEP_ENVIRONMENT": "test"]
        )

        #expect(configuration.environment == .local)
        #expect(configuration.endpoints(for: .local).web.absoluteString == "http://127.0.0.1:9000")
        #expect(configuration.endpoints(for: .local).backend.absoluteString == "http://127.0.0.1:9001")
        #expect(configuration.endpoints(for: .test) == AppEnvironment.test.endpoints)
    }
}
