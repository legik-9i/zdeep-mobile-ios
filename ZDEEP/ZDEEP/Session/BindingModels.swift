import Foundation
import Security

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
    case keychain(operation: String, status: OSStatus)
    case invalidRecord
    case cryptography
    case installMarker(operation: String)
    case staleBinding
    case registrationNotAllowed
}
