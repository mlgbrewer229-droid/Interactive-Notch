import AppKit
import SwiftUI
import XCTest
@testable import InteractiveNotch

@MainActor
final class MediaModelsTests: XCTestCase {
    func testSourceResolutionUsesOnlyTheReportedPlayer() {
        for source in ["com.apple.Safari", "com.google.Chrome", "com.operasoftware.Opera", "com.apple.Music", "com.spotify.client"] {
            var requested: [String] = []
            let snapshot = MediaSnapshot(hasMedia: true, bundleIdentifier: source)
            let expected = URL(fileURLWithPath: "/Applications/ReportedPlayer.app")
            let result = MediaSourceApplication.url(for: snapshot) { identifier in
                requested.append(identifier)
                return expected
            }
            XCTAssertEqual(result, expected)
            XCTAssertEqual(requested, [source])
        }
    }

    func testUnknownSourceDoesNotFallBackToSpotify() {
        var requested: [String] = []
        let snapshot = MediaSnapshot(hasMedia: true, bundleIdentifier: "example.unavailable.player")
        let result = MediaSourceApplication.url(for: snapshot) { identifier in
            requested.append(identifier)
            return identifier == "com.spotify.client" ? URL(fileURLWithPath: "/Applications/Spotify.app") : nil
        }
        XCTAssertNil(result)
        XCTAssertEqual(requested, ["example.unavailable.player"])
    }

    func testMissingOrIdleSourceDoesNotResolveAnApplication() {
        for snapshot in [MediaSnapshot(), MediaSnapshot(hasMedia: true, bundleIdentifier: " \n"), MediaSnapshot(hasMedia: false, bundleIdentifier: "com.spotify.client")] {
            XCTAssertNil(MediaSourceApplication.url(for: snapshot) { _ in
                XCTFail("A missing or idle source must not open an application")
                return nil
            })
        }
        XCTAssertEqual(MediaSnapshot(hasMedia: true, bundleIdentifier: " com.apple.Safari\n").sourceBundleIdentifier, "com.apple.Safari")
    }

    func testVideoAndMusicArtworkHaveIdenticalCroppedBoundsAtEverySize() throws {
        for size: CGFloat in [20, 24, 30, 54, 104] {
            for aspect: CGFloat in [1, 16.0 / 9, 9.0 / 16] {
                let source = NSImage(size: NSSize(width: 160 * aspect, height: 160))
                source.lockFocus()
                NSColor.systemRed.setFill()
                NSRect(origin: .zero, size: source.size).fill()
                source.unlockFocus()
                let renderer = ImageRenderer(content: MediaArtworkView(image: source, size: size, cornerRadius: 5)
                    .padding(12).background(Color.black))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.nsImage)
                XCTAssertEqual(image.size.width, size + 24, accuracy: 0.1)
                XCTAssertEqual(image.size.height, size + 24, accuracy: 0.1)
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
                for point in [(2, Int(size / 2 + 12)), (Int(size + 21), Int(size / 2 + 12)), (Int(size / 2 + 12), 2), (Int(size / 2 + 12), Int(size + 21))] {
                    let color = try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.deviceRGB))
                    XCTAssertLessThan(color.redComponent, 0.05, "Artwork must not bleed outside its square, aspect \(aspect), size \(size)")
                }
                let center = try XCTUnwrap(bitmap.colorAt(x: Int(size / 2 + 12), y: Int(size / 2 + 12))?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(center.redComponent, 0.5)
            }
        }
    }

    func testElapsedTimeAdvancesWhilePlaying() {
        let baseline = Date(timeIntervalSince1970: 1_000)
        let snapshot = MediaSnapshot(
            integrationAvailable: true,
            hasMedia: true,
            duration: 100,
            elapsedTime: 12,
            playbackRate: 1,
            isPlaying: true,
            updatedAt: baseline
        )
        XCTAssertEqual(snapshot.estimatedElapsedTime(at: baseline.addingTimeInterval(3.5)), 15.5)
    }

    func testElapsedTimeDoesNotAdvanceWhilePaused() {
        let baseline = Date(timeIntervalSince1970: 1_000)
        let snapshot = MediaSnapshot(
            integrationAvailable: true,
            hasMedia: true,
            duration: 100,
            elapsedTime: 12,
            playbackRate: 0,
            isPlaying: false,
            updatedAt: baseline
        )
        XCTAssertEqual(snapshot.estimatedElapsedTime(at: baseline.addingTimeInterval(30)), 12)
    }

    func testElapsedTimeIsClampedToDuration() {
        let baseline = Date(timeIntervalSince1970: 1_000)
        let snapshot = MediaSnapshot(
            integrationAvailable: true,
            hasMedia: true,
            duration: 15,
            elapsedTime: 14,
            playbackRate: 1,
            isPlaying: true,
            updatedAt: baseline
        )
        XCTAssertEqual(snapshot.estimatedElapsedTime(at: baseline.addingTimeInterval(30)), 15)
    }

    func testVolumeClamping() {
        XCTAssertEqual(VolumeMath.clamped(-1), 0)
        XCTAssertEqual(VolumeMath.clamped(0.42), 0.42)
        XCTAssertEqual(VolumeMath.clamped(2), 1)
    }

    func testBatterySymbols() {
        XCTAssertEqual(BatterySnapshot(isAvailable: true, percentage: 14, isCharging: false).symbolName, "battery.25percent")
        XCTAssertEqual(BatterySnapshot(isAvailable: true, percentage: 95, isCharging: true).symbolName, "battery.100percent.bolt")
    }

    func testBatteryTimeRemainingFormatting() {
        XCTAssertEqual(
            BatterySnapshot(isAvailable: true, percentage: 70, isCharging: false, timeRemaining: 9_180).timeRemainingDescription,
            "2h 33m left"
        )
        XCTAssertEqual(
            BatterySnapshot(isAvailable: true, percentage: 70, isCharging: true, timeRemaining: nil).timeRemainingDescription,
            "On power"
        )
        XCTAssertEqual(
            BatterySnapshot(isAvailable: true, percentage: 100, isCharging: false, isOnExternalPower: true).timeRemainingDescription,
            "On power"
        )
    }

    func testDarkArtworkUsesItsBrightestColorForTheSpectrum() {
        let dark = NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.02, alpha: 1)
        let redHighlight = NSColor(calibratedRed: 0.75, green: 0.04, blue: 0.06, alpha: 1)
        let result = ArtworkAccentColor.choose(from: Array(repeating: dark, count: 20) + [redHighlight])!
            .usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(result.redComponent, 0.65)
        XCTAssertLessThan(result.greenComponent, 0.2)
    }

    func testBlackArtworkStillProducesVisibleBars() {
        let black = NSColor(calibratedWhite: 0, alpha: 1)
        let result = ArtworkAccentColor.choose(from: [black])!.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(result.redComponent, 0.9)
        XCTAssertGreaterThan(result.greenComponent, 0.9)
    }

    func testArtworkUsesMostCommonVisibleColorNotBrightestPixel() {
        let dark = NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.02, alpha: 1)
        let blue = NSColor(calibratedRed: 0.12, green: 0.54, blue: 0.82, alpha: 1)
        let yellow = NSColor(calibratedRed: 1, green: 0.94, blue: 0.1, alpha: 1)
        let result = ArtworkAccentColor.choose(from:
            Array(repeating: dark, count: 30) + Array(repeating: blue, count: 14) + [yellow]
        )!.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(result.blueComponent, result.greenComponent)
        XCTAssertGreaterThan(result.greenComponent, result.redComponent)
    }

    func testArtworkImageFeedsItsColorToTheSpectrum() {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        for x in 0..<4 {
            for y in 0..<4 {
                bitmap.setColor(NSColor(calibratedRed: 0.05, green: 0.2, blue: 0.8, alpha: 1), atX: x, y: y)
            }
        }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.addRepresentation(bitmap)
        let result = image.preferredSpectrumColor()!.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(result.blueComponent, result.redComponent)
        XCTAssertGreaterThan(result.blueComponent, result.greenComponent)
    }

    func testAdapterPayloadMapsToMediaSnapshot() {
        let payload: [String: Any] = [
            "title": "Test Track",
            "artist": "Test Artist",
            "album": "Test Album",
            "bundleIdentifier": "com.spotify.client",
            "duration": 210.5,
            "elapsedTime": 42.25,
            "playbackRate": 1,
            "playing": true,
            "timestamp": "2026-09-16T20:15:00Z"
        ]

        let snapshot = MediaRemotePayloadDecoder.snapshot(from: payload)

        XCTAssertTrue(snapshot.integrationAvailable)
        XCTAssertTrue(snapshot.hasMedia)
        XCTAssertEqual(snapshot.title, "Test Track")
        XCTAssertEqual(snapshot.artist, "Test Artist")
        XCTAssertEqual(snapshot.album, "Test Album")
        XCTAssertEqual(snapshot.bundleIdentifier, "com.spotify.client")
        XCTAssertEqual(snapshot.duration, 210.5)
        XCTAssertEqual(snapshot.elapsedTime, 42.25)
        XCTAssertEqual(snapshot.playbackRate, 1)
        XCTAssertTrue(snapshot.isPlaying)
        XCTAssertEqual(snapshot.updatedAt.timeIntervalSince1970, 1_789_589_700)
    }

    func testEmptyAdapterPayloadIsAvailableButIdle() {
        let snapshot = MediaRemotePayloadDecoder.snapshot(from: [:])
        XCTAssertTrue(snapshot.integrationAvailable)
        XCTAssertFalse(snapshot.hasMedia)
    }

    func testOneShotMediaResponseRestoresPlayingState() {
        let response = Data(#"{"title":"Test Track","artist":"Test Artist","playing":true,"playbackRate":1}"#.utf8)
        let snapshot = MediaRemotePayloadDecoder.snapshot(fromGetResponse: response)
        XCTAssertEqual(snapshot?.title, "Test Track")
        XCTAssertTrue(snapshot?.isPlaying == true)
    }

    func testOneShotNullResponseIsIdle() {
        let snapshot = MediaRemotePayloadDecoder.snapshot(fromGetResponse: Data("null".utf8))
        XCTAssertTrue(snapshot?.integrationAvailable == true)
        XCTAssertFalse(snapshot?.hasMedia == true)
        XCTAssertNil(MediaRemotePayloadDecoder.snapshot(fromGetResponse: Data("not JSON".utf8)))
    }
}
