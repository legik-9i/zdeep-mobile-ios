import Foundation
import Testing
@testable import ZDEEP

@MainActor
@Suite(.serialized)
struct WebLaunchURLTests {
    @Test func test_preserves_environment_path_query_and_fragment() throws {
        for environment in AppEnvironment.allCases {
            var components = try #require(URLComponents(url: environment.endpoints.web, resolvingAgainstBaseURL: false))
            components.path = "/app"
            components.queryItems = [URLQueryItem(name: "keep", value: "one")]
            components.fragment = "section"
            let baseURL = try #require(components.url)
            let result = WebLaunchURL.make(baseURL: baseURL, appVersion: "1.0", bridgeVersion: "0.0.1", theme: "light")
            let resultComponents = try #require(URLComponents(url: result, resolvingAgainstBaseURL: false))
            let items = resultComponents.queryItems ?? []

            #expect(resultComponents.path == "/app")
            #expect(resultComponents.fragment == "section")
            #expect(items.contains(URLQueryItem(name: "keep", value: "one")))
            #expect(items.contains(URLQueryItem(name: "platform", value: "ios")))
            #expect(items.contains(URLQueryItem(name: "nativeAppVersion", value: "1.0")))
            #expect(items.contains(URLQueryItem(name: "bridgeVersion", value: "0.0.1")))
            #expect(items.contains(URLQueryItem(name: "theme", value: "light")))
            #expect(resultComponents.host == baseURL.host)
        }
    }

    @Test func test_replaces_duplicate_host_parameters() throws {
        let baseURL = try #require(URL(string: "https://example.com/?platform=web&theme=old&theme=older&nativeAppVersion=0"))
        let result = WebLaunchURL.make(baseURL: baseURL, appVersion: "1.0", bridgeVersion: "0.0.1", theme: "dark")
        let items = try #require(URLComponents(url: result, resolvingAgainstBaseURL: false)?.queryItems)

        #expect(items.filter { $0.name == "platform" }.map(\.value) == ["ios"])
        #expect(items.filter { $0.name == "theme" }.map(\.value) == ["dark"])
        #expect(items.filter { $0.name == "nativeAppVersion" }.map(\.value) == ["1.0"])
        #expect(items.filter { $0.name == "bridgeVersion" }.map(\.value) == ["0.0.1"])
    }

    @Test func test_light_and_dark_theme() throws {
        let baseURL = try #require(URL(string: "https://example.com/"))
        for theme in ["light", "dark"] {
            let result = WebLaunchURL.make(baseURL: baseURL, appVersion: "1.0", bridgeVersion: "0.0.1", theme: theme)
            let items = try #require(URLComponents(url: result, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(items.first(where: { $0.name == "theme" })?.value == theme)
        }
    }

    @Test func test_keeps_app_version_unchanged() throws {
        let baseURL = try #require(URL(string: "https://example.com/?nativeAppVersion=host"))
        let result = WebLaunchURL.make(baseURL: baseURL, appVersion: "1.0", bridgeVersion: "0.0.1", theme: "light")
        let items = try #require(URLComponents(url: result, resolvingAgainstBaseURL: false)?.queryItems)

        #expect(items.first(where: { $0.name == "nativeAppVersion" })?.value == "1.0")
        #expect(items.first(where: { $0.name == "bridgeVersion" })?.value == "0.0.1")
    }

    @Test func test_theme_change_does_not_reload_current_document() async throws {
        let fixture = try #require(
            Bundle(for: WebLaunchURLFixtureBundleMarker.self).url(forResource: "document-start", withExtension: "html")
        )
        let baseURL = AppEnvironment.local.endpoints.web
        let session = WebSession(trustedURL: baseURL)
        session.configureLaunchURL(baseURL: baseURL, appVersion: "1.0", theme: "light")
        defer { session.close() }
        session.load(url: fixture)
        _ = try await session.waitForJavaScript("document.readyState", equals: .string("complete"), timeout: .seconds(10))
        let document = try #require(session.currentDocument)

        session.updateLaunchTheme("dark")

        #expect(session.currentDocument == document)
        #expect(session.requestedURL == fixture)
    }
}

private final class WebLaunchURLFixtureBundleMarker: NSObject {}
