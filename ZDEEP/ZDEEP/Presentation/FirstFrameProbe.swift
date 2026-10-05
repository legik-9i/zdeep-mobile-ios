import SwiftUI
import UIKit

struct FirstFrameProbe: UIViewRepresentable {
    let scenarioID: UUID
    let onFirstFrame: (UUID) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onFirstFrame = onFirstFrame
        view.scenarioID = scenarioID
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onFirstFrame = onFirstFrame
        if view.scenarioID != scenarioID {
            view.stop()
            view.scenarioID = scenarioID
            view.startIfAttached()
        }
    }

    final class ProbeView: UIView {
        var scenarioID: UUID?
        var onFirstFrame: ((UUID) -> Void)?
        private var displayLink: CADisplayLink?
        private var ticks = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stop() } else { startIfAttached() }
        }

        func startIfAttached() {
            guard window != nil, displayLink == nil else { return }
            ticks = 0
            let link = CADisplayLink(target: self, selector: #selector(didTick))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        func stop() {
            displayLink?.invalidate()
            displayLink = nil
            ticks = 0
        }

        @objc private func didTick() {
            ticks += 1
            guard ticks >= 2, let scenarioID else { return }
            stop()
            onFirstFrame?(scenarioID)
        }
    }
}
