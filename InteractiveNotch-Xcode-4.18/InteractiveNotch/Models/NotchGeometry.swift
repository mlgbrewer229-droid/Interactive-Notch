import AppKit
import CoreGraphics

struct ScreenDescriptor {
    let frame: CGRect
    let safeAreaInsets: NSEdgeInsets
    let auxiliaryTopLeftArea: CGRect?
    let auxiliaryTopRightArea: CGRect?
    let isBuiltIn: Bool
}

struct NotchGeometry: Equatable {
    static let maximumPanelSize = CGSize(width: 680, height: 460)
    static let dashboardWidth: CGFloat = 520
    static let detailSize = CGSize(width: 520, height: 220)
    static let mirrorSize = CGSize(width: 680, height: 440)
    // Keep the gallery and detail footprints equal so selecting a bottom-row
    // preview does not leave the pointer outside the destination surface.
    static let customizeSize = detailSize

    let screenFrame: CGRect
    let notchFrame: CGRect
    let activationFrame: CGRect
    let maximumPanelFrame: CGRect

    var expandedFrame: CGRect {
        surfaceFrame(for: .dashboard)
    }

    func surfaceSize(for presentation: NotchPresentation, dashboardHeight: CGFloat = 190) -> CGSize {
        switch presentation {
        case .hidden:
            return notchFrame.size
        case .startup:
            return CGSize(width: min(max(notchFrame.width + 40, 220), 300), height: notchFrame.height + 32)
        case .compactMedia, .compactTimer:
            return CGSize(width: min(notchFrame.width + 104, 330), height: notchFrame.height + 12)
        case .compactMediaAndTimer:
            return CGSize(width: min(notchFrame.width + 138, 360), height: notchFrame.height + 12)
        case .compactCharging:
            return CGSize(width: min(max(notchFrame.width + 130, 300), 380), height: notchFrame.height + 104)
        case .timerFinished:
            return CGSize(width: min(notchFrame.width + 150, 380), height: notchFrame.height + 14)
        case .dashboard:
            return CGSize(width: Self.dashboardWidth, height: dashboardHeight)
        case .detail:
            return CGSize(width: Self.detailSize.width, height: max(Self.detailSize.height, dashboardHeight))
        case .customize:
            return Self.customizeSize
        case .mirror:
            return Self.mirrorSize
        }
    }

    func surfaceFrame(for presentation: NotchPresentation, dashboardHeight: CGFloat = 190) -> CGRect {
        let size = surfaceSize(for: presentation, dashboardHeight: dashboardHeight)
        return CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        ).integral
    }

    func hoverFrame(for presentation: NotchPresentation, dashboardHeight: CGFloat = 190) -> CGRect {
        if presentation == .hidden { return activationFrame }
        return surfaceFrame(for: presentation, dashboardHeight: dashboardHeight).insetBy(dx: -2, dy: -2)
    }

    func containsPointer(_ point: CGPoint, presentation: NotchPresentation, dashboardHeight: CGFloat = 190) -> Bool {
        hoverFrame(for: presentation, dashboardHeight: dashboardHeight).contains(point)
    }

    func shouldReturnHome(at point: CGPoint, presentation: NotchPresentation) -> Bool {
        switch presentation {
        case .detail, .customize, .mirror:
            return activationFrame.insetBy(dx: -10, dy: -8).contains(point)
        default:
            return false
        }
    }

    func reanchored(to newScreenFrame: CGRect) -> NotchGeometry {
        let newNotchFrame = CGRect(
            x: newScreenFrame.midX - notchFrame.width / 2,
            y: newScreenFrame.maxY - notchFrame.height,
            width: notchFrame.width,
            height: notchFrame.height
        ).integral
        let newActivationFrame = CGRect(
            x: newNotchFrame.minX - 3,
            y: newNotchFrame.minY - 3,
            width: newNotchFrame.width + 6,
            height: newNotchFrame.height + 3
        ).integral
        let newMaximumPanelFrame = CGRect(
            x: newScreenFrame.midX - Self.maximumPanelSize.width / 2,
            y: newScreenFrame.maxY - Self.maximumPanelSize.height,
            width: Self.maximumPanelSize.width,
            height: Self.maximumPanelSize.height
        ).integral
        return NotchGeometry(
            screenFrame: newScreenFrame,
            notchFrame: newNotchFrame,
            activationFrame: newActivationFrame,
            maximumPanelFrame: newMaximumPanelFrame
        )
    }

    static func calculate(for screen: ScreenDescriptor) -> NotchGeometry? {
        guard screen.isBuiltIn, screen.safeAreaInsets.top > 0 else { return nil }

        let notchHeight = screen.safeAreaInsets.top
        let inferredWidth: CGFloat

        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            inferredWidth = right.minX - left.maxX
        } else {
            // A top safe-area inset is only present on the built-in display when
            // macOS is reserving camera-housing space. Keep the fallback narrow.
            inferredWidth = 190
        }

        guard inferredWidth >= 80 else { return nil }

        let notchWidth = min(inferredWidth, 240)
        let notchFrame = CGRect(
            x: screen.frame.midX - notchWidth / 2,
            y: screen.frame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        ).integral

        // Keep the hardware cutout itself inside the event window. A very small
        // halo makes entry reliable at the camera-housing edge without exposing
        // any visible idle surface.
        let activationFrame = CGRect(
            x: notchFrame.minX - 3,
            y: notchFrame.minY - 3,
            width: notchFrame.width + 6,
            height: notchFrame.height + 3
        ).integral

        let maximumPanelFrame = CGRect(
            x: screen.frame.midX - maximumPanelSize.width / 2,
            y: screen.frame.maxY - maximumPanelSize.height,
            width: maximumPanelSize.width,
            height: maximumPanelSize.height
        ).integral

        return NotchGeometry(
            screenFrame: screen.frame,
            notchFrame: notchFrame,
            activationFrame: activationFrame,
            maximumPanelFrame: maximumPanelFrame
        )
    }
}

struct NotchGeometryProvider {
    func currentGeometry(fallback: NotchGeometry? = nil) -> NotchGeometry? {
        guard let screen = NSScreen.screens.first(where: Self.isBuiltIn) else { return nil }

        // Some full-screen transitions temporarily report a zero safe-area
        // inset even though the physical camera housing has not changed. Keep
        // the last hardware geometry anchored to the built-in display instead
        // of removing live activities during the transition.
        if screen.safeAreaInsets.top <= 0,
           let fallback,
           fallback.screenFrame.size == screen.frame.size {
            return fallback.reanchored(to: screen.frame)
        }

        let descriptor = ScreenDescriptor(
            frame: screen.frame,
            safeAreaInsets: screen.safeAreaInsets,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            isBuiltIn: true
        )
        return NotchGeometry.calculate(for: descriptor)
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }
}
