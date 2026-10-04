import Foundation
import Testing
@testable import ZDEEP

@MainActor
@Suite(.serialized)
struct WebSessionIntegrationTests {
    private var environment: AppEnvironment {
        let rawValue = ProcessInfo.processInfo.environment["ZDEEP_ENVIRONMENT"] ?? "local"
        return AppEnvironment(rawValue: rawValue) ?? .local
    }

    @Test func test_real_web_url_and_native_object() async throws {
        let session = WebSession()
        defer { session.close() }
        session.load(url: environment.endpoints.web)

        _ = try await session.waitForJavaScript(
            "document.readyState",
            equals: .string("complete"),
            timeout: .seconds(60)
        )
        let location = try await session.executeJavaScript("location.href", timeout: .seconds(10))
        let nativeType = try await session.executeJavaScript("typeof window.ZdeepNative", timeout: .seconds(10))

        #expect(session.requestedURL == environment.endpoints.web)
        guard case .string(let pageURL) = location else {
            Issue.record("Expected location.href to be a string")
            return
        }
        #expect(URL(string: pageURL)?.scheme == environment.endpoints.web.scheme)
        #expect(URL(string: pageURL)?.host == environment.endpoints.web.host)
        #expect(session.redirectChain.first == environment.endpoints.web)
        #expect(session.redirectChain.last == session.currentURL)
        #expect(session.responseStatusCode.map { (200..<400).contains($0) } == true)
        #expect(nativeType == .string("object"))
    }

    @Test func test_js_value_and_error() async throws {
        let session = try await makeLoadedSession()
        defer { session.close() }

        let value = try await session.executeJavaScript("({ answer: 42, enabled: true })", timeout: .seconds(10))
        #expect(value == .object(["answer": .number(42), "enabled": .bool(true)]))

        do {
            _ = try await session.executeJavaScript("(() => { throw new Error('expected failure'); })()", timeout: .seconds(10))
            Issue.record("Expected JavaScript execution to fail")
        } catch let error as DiagnosticError {
            guard case .javascriptExecutionFailed(let message) = error else {
                Issue.record("Unexpected diagnostic error: \(error)")
                return
            }
            #expect(message.contains("expected failure"))
        }
    }

    @Test func test_timeout_records_last_value() async throws {
        let session = try await makeLoadedSession()
        defer { session.close() }

        do {
            _ = try await session.waitForJavaScript("false", equals: .bool(true), timeout: .milliseconds(250))
            Issue.record("Expected the wait to time out")
        } catch let error as DiagnosticError {
            #expect(error == .timedOut(lastValue: .bool(false)))
        }
    }

    @Test func test_reload_reinjects_object() async throws {
        let session = try await makeLoadedSession()
        defer { session.close() }
        _ = try await session.executeJavaScript("window.ZdeepNative = null", timeout: .seconds(10))

        session.reload()
        _ = try await session.waitForJavaScript(
            "document.readyState",
            equals: .string("complete"),
            timeout: .seconds(60)
        )

        let nativeType = try await session.executeJavaScript("typeof window.ZdeepNative", timeout: .seconds(10))
        #expect(nativeType == .string("object"))
    }

    @Test func test_closed_session_cannot_apply_result() async throws {
        let session = WebSession()
        let fixture = try #require(
            Bundle(for: HostedFixtureBundleMarker.self).url(
                forResource: "document-start",
                withExtension: "html"
            )
        )
        session.load(url: fixture)
        _ = try await session.waitForJavaScript(
            "document.readyState",
            equals: .string("complete"),
            timeout: .seconds(5)
        )

        let pendingResult = Task {
            try await session.executeJavaScript(
                "new Promise(resolve => setTimeout(() => resolve('late'), 1500))",
                timeout: .seconds(5)
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        session.close()

        do {
            _ = try await pendingResult.value
            Issue.record("A closed session must not return a late JavaScript result")
        } catch let error as DiagnosticError {
            #expect(error == .sessionClosed)
        }
    }

    @Test func test_full_reset_clears_web_cookie_and_local_storage() async throws {
        let coordinator = AppCoordinator(configuration: LaunchConfiguration(
            arguments: ["--environment", environment.rawValue],
            variables: [:]
        ))
        coordinator.openWebView()
        let initialSession = try #require(coordinator.activeWebSession)
        _ = try await initialSession.waitForJavaScript(
            "document.readyState",
            equals: .string("complete"),
            timeout: .seconds(60)
        )
        _ = try await initialSession.executeJavaScript(
            "localStorage.setItem('__zdeep_reset_probe', 'present'); document.cookie = '__zdeep_reset_cookie=present; path=/'; true",
            timeout: .seconds(10)
        )
        let seeded = try await initialSession.executeJavaScript(
            "localStorage.getItem('__zdeep_reset_probe') === 'present' && document.cookie.includes('__zdeep_reset_cookie=present')",
            timeout: .seconds(10)
        )
        #expect(seeded == .bool(true))

        await coordinator.resetClientData()
        coordinator.openWebView()
        let resetSession = try #require(coordinator.activeWebSession)
        defer { coordinator.closeWebView() }
        _ = try await resetSession.waitForJavaScript(
            "document.readyState",
            equals: .string("complete"),
            timeout: .seconds(60)
        )
        let remains = try await resetSession.executeJavaScript(
            "localStorage.getItem('__zdeep_reset_probe') !== null || document.cookie.includes('__zdeep_reset_cookie=present')",
            timeout: .seconds(10)
        )
        #expect(remains == .bool(false))
    }

    private func makeLoadedSession() async throws -> WebSession {
        let session = WebSession()
        session.load(url: environment.endpoints.web)
        _ = try await session.waitForJavaScript(
            "document.readyState",
            equals: .string("complete"),
            timeout: .seconds(60)
        )
        return session
    }
}

private final class HostedFixtureBundleMarker: NSObject {}
