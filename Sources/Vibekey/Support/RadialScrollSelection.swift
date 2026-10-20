import AppKit
import SwiftUI
import VibekeyCore

/// Keep native wheel delivery scoped to the diagram without intercepting clicks.
@MainActor struct RadialScrollSelection<Content: View>: NSViewRepresentable {
    var enabled = true
    let onRotate: @MainActor (Int) -> Void
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> RadialScrollHostingView<Content> {
        let view = RadialScrollHostingView(rootView: content)
        view.scrollEnabled = enabled; view.rotate = onRotate
        return view
    }

    func updateNSView(_ view: RadialScrollHostingView<Content>, context: Context) {
        view.rootView = content; view.scrollEnabled = enabled; view.rotate = onRotate
    }
}

@MainActor final class RadialScrollHostingView<Content: View>: NSHostingView<Content> {
    var rotate: (@MainActor (Int) -> Void)?
    var scrollEnabled = true {
        didSet { if !scrollEnabled { resetScroll() } }
    }
    private var input = RadialScrollInput()

    func resetScroll() { input.reset() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); resetScroll()
    }

    override func scrollWheel(with event: NSEvent) {
        guard scrollEnabled else { resetScroll(); return }
        if event.phase.contains(.began) || event.phase.contains(.cancelled) { resetScroll() }
        guard !event.phase.contains(.cancelled) else { return }
        let delta = input.consume(deltaY: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas)
        if delta != 0 { rotate?(delta) }
        if event.phase.contains(.ended) { resetScroll() }
    }
}
