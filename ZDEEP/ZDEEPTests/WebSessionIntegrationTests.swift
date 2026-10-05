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

    @Test func test_prepare_commit_and_reload_have_distinct_documents() async throws {
        let fixture = try #require(
            Bundle(for: HostedFixtureBundleMarker.self).url(forResource: "document-start", withExtension: "html")
        )
        let session = WebSession(trustedURL: environment.endpoints.web)
        defer { session.close() }
        session.load(url: fixture)
        _ = try await session.waitForJavaScript(
            "document.readyState", equals: .string("complete"), timeout: .seconds(5)
        )
        let prepared = try #require(session.currentDocument)
        #expect(session.isCurrentDocumentCommitted)

        session.reload()
        _ = try await session.waitForJavaScript(
            "document.readyState", equals: .string("complete"), timeout: .seconds(60)
        )
        let reloaded = try #require(session.currentDocument)
        #expect(reloaded != prepared)
    }

    @Test func test_file_fixture_has_no_real_session() async throws {
        let fixture = try #require(
            Bundle(for: HostedFixtureBundleMarker.self).url(forResource: "document-start", withExtension: "html")
        )
        let session = WebSession(trustedURL: environment.endpoints.web)
        _ = NativeBridge(session: session, manager: BridgeTestSessionManager()) { _, _ in }
        defer { session.close() }
        session.load(url: fixture)
        _ = try await session.waitForJavaScript(
            "document.readyState", equals: .string("complete"), timeout: .seconds(5)
        )
        let nativeType = try await session.executeJavaScript("typeof window.ZdeepNative", timeout: .seconds(5))
        #expect(nativeType == .string("object"))
        #expect(session.currentDocument?.containerId == session.id)
        #expect(session.currentDocument?.documentId != nil)
        let fileOriginResult = try await session.executeJavaScript(
            "window.ZdeepNative.getSession().then(() => 'received').catch(() => 'rejected')",
            timeout: .seconds(5)
        )
        #expect(fileOriginResult == .string("rejected"))
    }

    @Test func test_foreign_server_redirect_does_not_commit_document() async throws {
        let fixture = try HTTPRedirectFixtureServer(
            location: URL(string: "https://outside.invalid/final")!
        )
        let redirect = try await fixture.start()
        var session: WebSession? = WebSession(trustedURL: redirect)
        weak var oldWebView = session?.webView
        var committed = false
        var failed = false
        session?.onEvent = { event in
            switch event {
            case .documentCommitted:
                committed = true
            case .documentFailed:
                failed = true
            default:
                break
            }
        }
        session?.load(url: redirect)
        for _ in 0..<100 where session?.isLoading == true && !failed {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(failed)
        #expect(!committed)
        session?.close()
        session = nil
        for _ in 0..<20 where oldWebView != nil {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(oldWebView == nil)
    }

    @Test func test_unsupported_user_link_preserves_current_document() async throws {
        var session: WebSession? = try await makeLoadedSession()
        weak var oldWebView = session?.webView
        var failed = false
        session?.onEvent = { event in
            if case .documentFailed = event { failed = true }
        }

        _ = try await session?.executeJavaScript(
            "const link = document.createElement('a'); link.href = 'mailto:help@example.com'; document.body.append(link); link.click(); true",
            timeout: .seconds(5)
        )
        try await Task.sleep(for: .milliseconds(250))

        #expect(!failed)
        #expect(session?.isCurrentDocumentCommitted == true)
        session?.close()
        session = nil
        #expect(oldWebView == nil)
    }

    @Test func test_unsupported_form_submission_fails_current_document() async throws {
        let session = try await makeLoadedSession()
        defer { session.close() }
        let document = try #require(session.currentDocument)
        var failed = false
        session.onEvent = { event in
            if case .documentFailed = event { failed = true }
        }

        _ = try await session.executeJavaScript(
            "const form = document.createElement('form'); form.action = 'mailto:help@example.com'; document.body.append(form); form.requestSubmit(); true",
            timeout: .seconds(5)
        )
        try await Task.sleep(for: .milliseconds(250))

        #expect(failed)
        #expect(session.currentDocument == document)
        #expect(!session.isCurrentDocumentCommitted)
    }

    @Test func test_close_releases_old_webview_and_history() async throws {
        let fixture = try #require(
            Bundle(for: HostedFixtureBundleMarker.self).url(forResource: "document-start", withExtension: "html")
        )
        var session: WebSession? = WebSession(trustedURL: environment.endpoints.web)
        weak var oldWebView = session?.webView
        session?.load(url: fixture)
        _ = try await session?.waitForJavaScript(
            "document.readyState", equals: .string("complete"), timeout: .seconds(5)
        )
        let hasHistory = try await session?.executeJavaScript(
            "history.pushState({}, '', '#close-history'); history.length > 1",
            timeout: .seconds(5)
        )
        #expect(hasHistory == .bool(true))
        session?.close()
        session = nil
        for _ in 0..<20 where oldWebView != nil {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(oldWebView == nil)
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
        let initialSession = WebSession(trustedURL: environment.endpoints.web)
        defer { initialSession.close() }
        initialSession.load(url: environment.endpoints.web)
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

        initialSession.close()
        await coordinator.resetClientData()
        let resetSession = WebSession(trustedURL: environment.endpoints.web)
        defer { resetSession.close() }
        resetSession.load(url: environment.endpoints.web)
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
