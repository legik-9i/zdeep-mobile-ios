import AVFoundation
import CodeScanner
import SwiftUI

final class ScannerResultGate {
    private var isClosed = false

    func finish(_ result: Result<String, Error>, deliver: (Result<String, Error>) -> Void) {
        guard !isClosed else { return }
        isClosed = true
        deliver(result)
    }

    func cancel() -> Bool {
        guard !isClosed else { return false }
        isClosed = true
        return true
    }
}

struct QRScannerView: View {
    let onResult: (Result<String, Error>) -> Void
    let onCancel: () -> Void
    @State private var gate = ScannerResultGate()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CodeScannerView(codeTypes: [.qr], scanMode: .once) { result in
                let mapped: Result<String, Error>
                switch result {
                case .success(let scan): mapped = .success(scan.string)
                case .failure(let error): mapped = .failure(error)
                }
                gate.finish(mapped, deliver: onResult)
            }
            Button("Закрыть") {
                if gate.cancel() { onCancel() }
            }
            .padding()
        }
    }
}
