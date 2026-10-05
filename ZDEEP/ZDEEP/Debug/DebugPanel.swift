import SwiftUI

#if DEBUG
struct DebugPanel: View {
    @ObservedObject var coordinator: AppCoordinator
    let eventStore: DiagnosticEventStore
    @Environment(\.dismiss) private var dismiss
    @State private var javaScript = "JSON.stringify({ url: location.href, native: typeof window.ZdeepNative })"
    @State private var javaScriptResult = ""
    @State private var isExecuting = false
    @State private var activeJavaScriptOperationID: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Окружение") {
                    Picker("Контур", selection: Binding(
                        get: { coordinator.environment },
                        set: { selected in Task { await coordinator.switchEnvironment(to: selected) } }
                    )) {
                        ForEach(AppEnvironment.allCases) { environment in
                            Text(environment.rawValue).tag(environment)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("environment-picker")
                    .disabled(!isEnvironmentPickerEnabled)
                    LabeledContent("Web", value: coordinator.endpoints.web.absoluteString)
                        .textSelection(.enabled)
                    LabeledContent("API", value: coordinator.endpoints.backend.absoluteString)
                        .textSelection(.enabled)
                }

                Section("WebView") {
                    LabeledContent("Состояние") {
                        Text(webViewState).accessibilityIdentifier("webview-state")
                    }
                    LabeledContent("URL", value: coordinator.activeWebSession?.currentURL?.absoluteString ?? "Не открыт")
                        .textSelection(.enabled)
                    if coordinator.isWebPrepared {
                        Button("Закрыть WebView") {
                            coordinator.closeWebView()
                            dismiss()
                        }
                        .accessibilityIdentifier("close-webview")
                        .disabled(coordinator.isTransitioning)
                    } else {
                        Button("Открыть WebView") {
                            coordinator.openWebView()
                            dismiss()
                        }
                        .accessibilityIdentifier("open-webview")
                        .disabled(coordinator.isTransitioning)
                    }
                    if let error = coordinator.activeWebSession?.navigationError {
                        Text(error).foregroundStyle(.red)
                            .accessibilityIdentifier("webview-error")
                    }
                    Button("Перезагрузить") { coordinator.activeWebSession?.reload() }
                        .accessibilityIdentifier("reload-webview")
                        .disabled(coordinator.activeWebSession == nil || coordinator.isTransitioning)
                    Button("Сбросить данные приложения", role: .destructive) {
                        Task { await coordinator.resetClientData() }
                    }
                    .accessibilityIdentifier("reset-client-data")
                    .disabled(coordinator.isTransitioning)
                }

                Section("JavaScript") {
                    TextField("Код JavaScript", text: $javaScript, axis: .vertical)
                        .lineLimit(3...8)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("js-input")
                    Button(isExecuting ? "Выполнение…" : "Выполнить") { executeJavaScript() }
                        .accessibilityIdentifier("execute-js")
                        .disabled(isExecuting || coordinator.activeWebSession == nil || !coordinator.isWebViewOpen)
                    Text(javaScriptResult.isEmpty ? "Результат появится здесь" : javaScriptResult)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("js-result")
                    Text("Результаты JS показываются только здесь и автоматически не сохраняются.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Последние события") {
                    let events = eventStore.snapshot().suffix(12).reversed()
                    if events.isEmpty {
                        Text("Событий пока нет").foregroundStyle(.secondary)
                    }
                    ForEach(Array(events)) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.category).font(.caption.weight(.semibold))
                            Text(event.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .accessibilityIdentifier("close-debug-panel")
                }
            }
            .onChange(of: coordinator.activeWebSession?.id) { _, _ in
                clearJavaScriptResult()
            }
            .onDisappear {
                clearJavaScriptResult()
            }
        }
    }

    var isEnvironmentPickerEnabled: Bool {
        !coordinator.isTransitioning
    }

    private var webViewState: String {
        guard let session = coordinator.activeWebSession else { return "Закрыт" }
        if session.isLoading { return "Загрузка (скрыт)" }
        if session.navigationError != nil { return "Ошибка (скрыт)" }
        return "Подготовлен (скрыт)"
    }

    private func executeJavaScript() {
        guard let session = coordinator.activeWebSession else { return }
        isExecuting = true
        javaScriptResult = ""
        let operationID = UUID().uuidString
        activeJavaScriptOperationID = operationID
        let sessionID = session.id
        eventStore.record(category: "javascript.started", operationID: operationID, fields: ["sessionID": session.id.uuidString])
        Task {
            do {
                let result = try await session.executeJavaScript(javaScript, timeout: .seconds(15))
                guard activeJavaScriptOperationID == operationID,
                      coordinator.activeWebSession?.id == sessionID else { return }
                javaScriptResult = Self.display(result)
                eventStore.record(category: "javascript.finished", operationID: operationID, fields: ["success": true, "resultSaved": false])
            } catch {
                guard activeJavaScriptOperationID == operationID,
                      coordinator.activeWebSession?.id == sessionID else { return }
                javaScriptResult = error.localizedDescription
                eventStore.record(category: "javascript.failed", operationID: operationID, fields: ["success": false, "resultSaved": false])
            }
            if activeJavaScriptOperationID == operationID {
                activeJavaScriptOperationID = nil
                isExecuting = false
            }
        }
    }

    private func clearJavaScriptResult() {
        javaScriptResult = ""
        isExecuting = false
        activeJavaScriptOperationID = nil
    }

    private static func display(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return string
    }
}
#endif
