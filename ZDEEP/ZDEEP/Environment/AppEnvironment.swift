import Foundation

enum AppEnvironment: String, CaseIterable, Identifiable {
    case local
    case test
    case prod

    var id: String { rawValue }

    var endpoints: EnvironmentEndpoints {
        switch self {
        case .local:
            EnvironmentEndpoints(
                web: URL(string: "http://localhost:4005")!,
                backend: URL(string: "http://localhost:4002")!
            )
        case .test:
            EnvironmentEndpoints(
                web: URL(string: "https://5e9afe68-2ddd-4e58-8e57-5942cfa16099.website.twcstorage.ru")!,
                backend: URL(string: "https://api.zdeep.ru/testing/")!
            )
        case .prod:
            EnvironmentEndpoints(
                web: URL(string: "https://webview2.zdeep.ru")!,
                backend: URL(string: "https://api.zdeep.ru")!
            )
        }
    }

    var databaseScope: DatabaseScope {
        switch self {
        case .local: .local
        case .test, .prod: .shared
        }
    }
}

struct EnvironmentEndpoints: Equatable {
    let web: URL
    let backend: URL
}

enum DatabaseScope {
    case local
    case shared
}
