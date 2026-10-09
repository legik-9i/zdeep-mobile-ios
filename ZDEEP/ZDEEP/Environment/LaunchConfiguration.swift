import Foundation

struct LaunchConfiguration {
#if targetEnvironment(simulator)
    private static let isSimulatorTarget = true
#else
    private static let isSimulatorTarget = false
#endif

    let environment: AppEnvironment
    let usbDiagnosticsEnabled: Bool
    let usbDiagnosticsOpenWebViewEnabled: Bool
    private let localWebOverride: URL?
    private let localBackendOverride: URL?

    init(arguments: [String], variables: [String: String]) {
        let selected = Self.value(for: "--environment", in: arguments) ?? variables["ZDEEP_ENVIRONMENT"]
        environment = selected.flatMap(AppEnvironment.init(rawValue:)) ?? Self.defaultEnvironment(isSimulator: Self.isSimulatorTarget)
#if DEBUG
        let requested = arguments.contains("--usb-diagnostics") || variables["ZDEEP_USB_DIAGNOSTICS"] == "1"
#if targetEnvironment(simulator)
        usbDiagnosticsEnabled = requested && (environment == .local || environment == .test)
        usbDiagnosticsOpenWebViewEnabled = usbDiagnosticsEnabled && arguments.contains("--usb-diagnostics-open-webview")
#else
        usbDiagnosticsEnabled = requested && environment == .test
        usbDiagnosticsOpenWebViewEnabled = false
#endif
#else
        usbDiagnosticsEnabled = false
        usbDiagnosticsOpenWebViewEnabled = false
#endif
        localWebOverride = Self.validURL(
            Self.value(for: "--web-url", in: arguments) ?? variables["ZDEEP_WEB_URL"]
        )
        localBackendOverride = Self.validURL(
            Self.value(for: "--api-url", in: arguments) ?? variables["ZDEEP_API_URL"]
        )
    }

    static func defaultEnvironment(isSimulator: Bool) -> AppEnvironment {
        isSimulator ? .local : .test
    }

    static var current: LaunchConfiguration {
#if DEBUG
        LaunchConfiguration(
            arguments: ProcessInfo.processInfo.arguments,
            variables: ProcessInfo.processInfo.environment
        )
#else
        LaunchConfiguration(arguments: ["--environment", AppEnvironment.prod.rawValue], variables: [:])
#endif
    }

    func isUSBDiagnosticsEnabled(in environment: AppEnvironment) -> Bool {
#if DEBUG
        guard usbDiagnosticsEnabled else { return false }
#if targetEnvironment(simulator)
        return environment == .local || environment == .test
#else
        return environment == .test
#endif
#else
        return false
#endif
    }

    func endpoints(for environment: AppEnvironment) -> EnvironmentEndpoints {
        guard environment == .local else { return environment.endpoints }
        let defaults = environment.endpoints
        return EnvironmentEndpoints(
            web: localWebOverride ?? defaults.web,
            backend: localBackendOverride ?? defaults.backend
        )
    }

    private static func value(for key: String, in arguments: [String]) -> String? {
        if let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) {
            return arguments[index + 1]
        }
        let prefix = key + "="
        return arguments.first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
    }

    private static func validURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme != nil, url.host != nil else {
            return nil
        }
        return url
    }
}
