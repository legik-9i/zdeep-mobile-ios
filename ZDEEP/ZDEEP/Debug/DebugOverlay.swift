import SwiftUI

#if DEBUG
struct DebugOverlay: View {
    let action: () -> Void
    @State private var dragOffset = CGSize.zero
    @State private var settledOffset = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            Button(action: action) {
                Label("Debug", systemImage: "ladybug")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.secondary.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("debug-button")
            .position(
                x: min(max(proxy.size.width - 48 + settledOffset.width + dragOffset.width, 48), proxy.size.width - 48),
                y: min(max(proxy.size.height - 70 + settledOffset.height + dragOffset.height, 32), proxy.size.height - 32)
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { dragOffset = $0.translation }
                    .onEnded { value in
                        settledOffset.width += value.translation.width
                        settledOffset.height += value.translation.height
                        dragOffset = .zero
                    }
            )
        }
        .allowsHitTesting(true)
    }
}
#endif
