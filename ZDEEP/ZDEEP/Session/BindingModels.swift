import Foundation

nonisolated struct PendingBinding: Equatable, Sendable {
    let bindingId: UUID
    let publicCertificate: String
}

nonisolated struct RegisteredBinding: Equatable, Sendable {
    let bindingId: UUID
    let publicCertificate: String
    let carId: String
}

nonisolated protocol BindingStoring: Sendable {
    func restore() async throws -> RegisteredBinding?
    func beginRegistration() async throws -> PendingBinding
    func sign(bindingId: UUID, bytes: Data) async throws -> Data
    func completeRegistration(bindingId: UUID, carId: String) async throws -> RegisteredBinding
    func reset() async throws
}

nonisolated enum BindingStoreError: Error, Equatable {
    case restoreRequired
    case invalidTransition
    case invalidRecord
    case storageFailure
    case installMarkerFailure
}
