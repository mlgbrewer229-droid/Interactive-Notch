import Foundation
import XCTest
@testable import InteractiveNotch

@MainActor
final class DashboardServicesTests: XCTestCase {
    func testRunningTimerCompletesAndSoundsExactlyOnce() {
        let suite = "InteractiveNotchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestDateProvider(now: Date(timeIntervalSince1970: 1_000))
        var sounds = 0
        let manager = PersistentTimerManager(clock: clock, defaults: defaults) { sounds += 1 }

        manager.start(minutes: 1)
        clock.now = clock.now.addingTimeInterval(61)
        manager.reconcile()
        manager.reconcile()

        XCTAssertEqual(manager.snapshot.state, .finished)
        XCTAssertEqual(manager.snapshot.remaining, 0)
        XCTAssertEqual(sounds, 1)
    }

    func testPausedTimerSurvivesRestoration() {
        let suite = "InteractiveNotchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestDateProvider(now: Date(timeIntervalSince1970: 2_000))

        let first = PersistentTimerManager(clock: clock, defaults: defaults, sound: {})
        first.start(minutes: 5)
        clock.now = clock.now.addingTimeInterval(40)
        first.pause()
        let pausedRemaining = first.snapshot.remaining

        let restored = PersistentTimerManager(clock: clock, defaults: defaults, sound: {})
        XCTAssertEqual(restored.snapshot.state, .paused)
        XCTAssertEqual(restored.snapshot.remaining, pausedRemaining, accuracy: 0.001)
    }

    func testAddMinuteUpdatesRunningDeadline() {
        let suite = "InteractiveNotchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestDateProvider(now: Date(timeIntervalSince1970: 3_000))
        let manager = PersistentTimerManager(clock: clock, defaults: defaults, sound: {})

        manager.start(minutes: 5)
        manager.addMinute()

        XCTAssertEqual(manager.snapshot.totalDuration, 360)
        XCTAssertEqual(manager.snapshot.remaining, 360, accuracy: 0.001)
    }
}

private final class TestDateProvider: DateProviding {
    var now: Date
    init(now: Date) { self.now = now }
}
