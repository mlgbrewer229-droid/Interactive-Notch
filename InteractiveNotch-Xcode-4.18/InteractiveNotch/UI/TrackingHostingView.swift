import AppKit
import SwiftUI

final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?
    var onRightClick: (() -> Void)?

    private var pointerTrackingArea: NSTrackingArea?

    // The window is intentionally mounted in NSScreen's top safe area. Without
    // this override NSHostingView inserts the menu-bar/notch inset a second time,
    // making the black surface appear to float below the hardware cutout.
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onPointerEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onPointerExited?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}
