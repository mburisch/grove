import AppKit
import SwiftUI

/// Scrolls the enclosing list while a drag hovers near its top or bottom edge, which SwiftUI's
/// `dropDestination` doesn't do on its own. Place it as the list's background and set `active`
/// when a drag enters the list; it switches itself off when the mouse button is released.
struct DragAutoScroller: NSViewRepresentable {
    @Binding var active: Bool

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onFinish = { active = false }
        if active { view.start() } else { view.stop() }
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) { view.stop() }

    final class ProbeView: NSView {
        /// Height of the hot zone at each edge, and the fastest scroll step per tick.
        private let edge: CGFloat = 36
        private let maxStep: CGFloat = 18
        private var timer: Timer?
        var onFinish: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func start() {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            // .common so it also fires while AppKit runs the drag's tracking loop.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func tick() {
            guard NSEvent.pressedMouseButtons & 1 != 0 else {
                stop()
                onFinish?()
                return
            }
            guard let window, let scrollView = enclosingList() else { return }
            let frame = scrollView.convert(scrollView.bounds, to: nil)
            let mouse = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            guard mouse.x >= frame.minX, mouse.x <= frame.maxX else { return }

            // Window coordinates grow upwards: positive = towards the top of the list.
            var direction: CGFloat = 0
            if mouse.y > frame.maxY - edge, mouse.y < frame.maxY + edge {
                direction = min(1, (mouse.y - (frame.maxY - edge)) / edge)
            } else if mouse.y < frame.minY + edge, mouse.y > frame.minY - edge {
                direction = -min(1, ((frame.minY + edge) - mouse.y) / edge)
            }
            guard direction != 0 else { return }

            let clip = scrollView.contentView
            var origin = clip.bounds.origin
            let step = max(2, abs(direction) * maxStep)
            // In a flipped clip view, scrolling up means a smaller y.
            origin.y += (direction > 0) == clip.isFlipped ? -step : step
            origin = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
            guard origin != clip.bounds.origin else { return }
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }

        /// The list's scroll view: the nearest one in the surrounding hierarchy that overlaps this view.
        private func enclosingList() -> NSScrollView? {
            let mine = convert(bounds, to: nil)
            var ancestor = superview
            while let view = ancestor {
                if let found = Self.scrollView(in: view, overlapping: mine) { return found }
                ancestor = view.superview
            }
            return nil
        }

        private static func scrollView(in view: NSView, overlapping rect: NSRect) -> NSScrollView? {
            for sub in view.subviews {
                if let scroll = sub as? NSScrollView, scroll.convert(scroll.bounds, to: nil).intersects(rect) {
                    return scroll
                }
                if let found = scrollView(in: sub, overlapping: rect) { return found }
            }
            return nil
        }
    }
}
