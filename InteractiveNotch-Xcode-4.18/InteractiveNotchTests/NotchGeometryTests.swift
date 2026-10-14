import AppKit
import XCTest
@testable import InteractiveNotch

final class NotchGeometryTests: XCTestCase {
    func testUsesAuxiliaryAreasToInferPhysicalNotch() throws {
        let screen = ScreenDescriptor(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaInsets: NSEdgeInsets(top: 32, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 660, height: 32),
            auxiliaryTopRightArea: CGRect(x: 852, y: 950, width: 660, height: 32),
            isBuiltIn: true
        )

        let geometry = try XCTUnwrap(NotchGeometry.calculate(for: screen))
        XCTAssertEqual(geometry.notchFrame, CGRect(x: 660, y: 950, width: 192, height: 32))
        XCTAssertEqual(geometry.activationFrame, CGRect(x: 657, y: 947, width: 198, height: 35))
        XCTAssertEqual(geometry.maximumPanelFrame.size, CGSize(width: 680, height: 460))
        XCTAssertEqual(geometry.expandedFrame.size, CGSize(width: 520, height: 190))
        XCTAssertEqual(geometry.expandedFrame.maxY, screen.frame.maxY)
        XCTAssertTrue(geometry.containsPointer(
            CGPoint(x: geometry.notchFrame.midX, y: geometry.notchFrame.midY),
            presentation: .hidden
        ))
        XCTAssertTrue(geometry.containsPointer(
            CGPoint(x: geometry.expandedFrame.midX, y: geometry.expandedFrame.midY),
            presentation: .dashboard
        ))

        let leftMenuBarLane = CGPoint(
            x: geometry.expandedFrame.minX + 8,
            y: geometry.expandedFrame.maxY - 8
        )
        XCTAssertTrue(geometry.containsPointer(leftMenuBarLane, presentation: .dashboard))
        XCTAssertTrue(geometry.shouldReturnHome(at: CGPoint(x: 756, y: 965), presentation: .detail(.media)))
        XCTAssertTrue(geometry.shouldReturnHome(at: CGPoint(x: 756, y: 965), presentation: .mirror))
        XCTAssertFalse(geometry.shouldReturnHome(at: CGPoint(x: 756, y: 965), presentation: .dashboard))

        let compact = geometry.surfaceFrame(for: .compactMedia)
        XCTAssertEqual(compact.maxY, screen.frame.maxY)
        XCTAssertEqual(compact.width, geometry.notchFrame.width + 104)
        let charging = geometry.surfaceFrame(for: .compactCharging)
        XCTAssertEqual(charging.width, 322)
        XCTAssertEqual(charging.height, 136)
        XCTAssertEqual(charging.maxY, screen.frame.maxY)
        XCTAssertEqual(geometry.surfaceFrame(for: .customize).size, CGSize(width: 520, height: 220))

        let fullScreenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let reanchored = geometry.reanchored(to: fullScreenFrame)
        XCTAssertEqual(reanchored.notchFrame.size, geometry.notchFrame.size)
        XCTAssertEqual(reanchored.maximumPanelFrame.maxY, fullScreenFrame.maxY)
    }

    func testRejectsExternalDisplay() {
        let screen = ScreenDescriptor(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            safeAreaInsets: NSEdgeInsets(top: 32, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            isBuiltIn: false
        )
        XCTAssertNil(NotchGeometry.calculate(for: screen))
    }

    func testRejectsDisplayWithoutTopSafeArea() {
        let screen = ScreenDescriptor(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaInsets: NSEdgeInsetsZero,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            isBuiltIn: true
        )
        XCTAssertNil(NotchGeometry.calculate(for: screen))
    }

    func testFallsBackWhenAuxiliaryAreasAreUnavailable() throws {
        let screen = ScreenDescriptor(
            frame: CGRect(x: 100, y: 0, width: 1512, height: 982),
            safeAreaInsets: NSEdgeInsets(top: 32, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            isBuiltIn: true
        )
        let geometry = try XCTUnwrap(NotchGeometry.calculate(for: screen))
        XCTAssertEqual(geometry.notchFrame.width, 190)
        XCTAssertEqual(geometry.notchFrame.midX, screen.frame.midX)
    }
}
