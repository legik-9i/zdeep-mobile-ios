import Foundation

enum WebLaunchURL {
    static let parameterNames: Set<String> = ["platform", "nativeAppVersion", "bridgeVersion", "theme"]

    static func make(baseURL: URL, appVersion: String, bridgeVersion: String, theme: String) -> URL {
        precondition(theme == "light" || theme == "dark")
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return baseURL }
        components.path = "/index.html"
        let parameters = [
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "nativeAppVersion", value: appVersion),
            URLQueryItem(name: "bridgeVersion", value: bridgeVersion),
            URLQueryItem(name: "theme", value: theme)
        ]
        components.queryItems = (components.queryItems ?? []).filter { !parameterNames.contains($0.name) } + parameters
        return components.url ?? baseURL
    }
}
