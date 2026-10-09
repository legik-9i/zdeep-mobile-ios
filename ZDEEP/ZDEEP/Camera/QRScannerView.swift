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
            .ignoresSafeArea(.container)

            scanGuidance
                .allowsHitTesting(false)

            Button("Закрыть") {
                if gate.cancel() { onCancel() }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.black.opacity(0.65), in: Capsule())
            .padding()
        }
    }

    private var scanGuidance: some View {
        GeometryReader { geometry in
            let side = max(0, min(geometry.size.width - 48, geometry.size.height * 0.45))
            let frame = CGRect(
                x: (geometry.size.width - side) / 2,
                y: (geometry.size.height - side) / 2,
                width: side,
                height: side
            )

            Path { path in
                path.addRect(CGRect(origin: .zero, size: geometry.size))
                path.addRect(frame)
            }
            .fill(.black.opacity(0.3), style: FillStyle(eoFill: true))
            .accessibilityHidden(true)

            Path { path in
                let length = min(28, side / 4)
                for (x, y, dx, dy) in [
                    (frame.minX, frame.minY, 1.0, 1.0),
                    (frame.maxX, frame.minY, -1.0, 1.0),
                    (frame.minX, frame.maxY, 1.0, -1.0),
                    (frame.maxX, frame.maxY, -1.0, -1.0),
                ] {
                    path.move(to: CGPoint(x: x + dx * length, y: y))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x, y: y + dy * length))
                }
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .accessibilityHidden(true)

            Text("Поместите QR-код в рамку")
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .frame(width: geometry.size.width)
                .padding(.top, frame.maxY + 20)
        }
    }
}
