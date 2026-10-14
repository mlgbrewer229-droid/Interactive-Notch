import AVFoundation
import SwiftUI
import XCTest
@testable import InteractiveNotch

@MainActor
final class NotchModelsTests: XCTestCase {
    func testClosedNotchVolumeChangesNeverOpenOrQueueFeedback() {
        let fixture = NotchViewModelFixture()
        fixture.playback.onVolumeChanged?(0.5, true)
        fixture.playback.onVolumeChanged?(0.75, true)
        XCTAssertEqual(fixture.model.presentation, .hidden)
        XCTAssertFalse(fixture.model.isVolumeActivityVisible)
        XCTAssertEqual(fixture.model.volume, 0.75)
        fixture.playback.emit(playing: true)
        fixture.playback.onVolumeChanged?(0.6, true)
        XCTAssertEqual(fixture.model.presentation, .compactMedia)
        XCTAssertFalse(fixture.model.isVolumeActivityVisible)
        fixture.model.expandDashboard()
        XCTAssertFalse(fixture.model.isVolumeActivityVisible)
    }

    func testOpenVolumeChangeExpiresExactlyWithoutNavigating() {
        let scheduler = PlaybackTestScheduler()
        let fixture = NotchViewModelFixture(scheduler: scheduler)
        fixture.model.expandDashboard()
        fixture.playback.onVolumeChanged?(0.5, true)
        XCTAssertFalse(fixture.model.isVolumeActivityVisible)
        fixture.playback.onVolumeChanged?(0.75, true)
        XCTAssertTrue(fixture.model.isVolumeActivityVisible)
        XCTAssertEqual(fixture.model.presentation, .dashboard)
        scheduler.advance(by: 1.249)
        XCTAssertTrue(fixture.model.isVolumeActivityVisible)
        scheduler.advance(by: 0.001)
        XCTAssertFalse(fixture.model.isVolumeActivityVisible)
        XCTAssertEqual(fixture.model.presentation, .dashboard)
    }

    func testVolumeActivityRendersNormalAndMutedStates() throws {
        let fixture = NotchViewModelFixture()
        fixture.model.expandDashboard()
        fixture.playback.onVolumeChanged?(0.5, true)
        fixture.playback.onVolumeChanged?(0.75, true)
        try attachRenderedNotch(fixture.model, name: "Open Home volume 75 percent")
        fixture.playback.onVolumeChanged?(0, true)
        try attachRenderedNotch(fixture.model, name: "Open Home muted volume")
    }

    func testRepeatedOpenVolumeChangesExtendDeadline() {
        let scheduler = PlaybackTestScheduler()
        let fixture = NotchViewModelFixture(scheduler: scheduler)
        fixture.model.expandDashboard()
        fixture.playback.onVolumeChanged?(0.5, true)
        fixture.playback.onVolumeChanged?(0.6, true)
        scheduler.advance(by: 1)
        fixture.playback.onVolumeChanged?(0.7, true)
        scheduler.advance(by: 0.25)
        XCTAssertTrue(fixture.model.isVolumeActivityVisible)
        scheduler.advance(by: 1)
        XCTAssertFalse(fixture.model.isVolumeActivityVisible)
        XCTAssertEqual(fixture.model.presentation, .dashboard)
    }

    func testCollapseClearsVolumeAndReopenDoesNotReplayIt() {
        let scheduler = PlaybackTestScheduler()
        let fixture = NotchViewModelFixture(scheduler: scheduler)
        fixture.playback.onVolumeChanged?(0.5, true)
        fixture.model.openDetail(.today)
        fixture.playback.onVolumeChanged?(0, true)
        XCTAssertEqual(fixture.model.presentation, .detail(.today))
        XCTAssertTrue(fixture.model.isVolumeActivityVisible)
        fixture.model.collapseToActivity()
        XCTAssertEqual(fixture.model.presentation, .hidden)
        XCTAssertFalse(fixture.model.isVolumeActivityVisible)
        fixture.model.expandDashboard()
        XCTAssertFalse(fixture.model.isVolumeActivityVisible)
        scheduler.advance(by: 2)
        XCTAssertEqual(fixture.model.presentation, .dashboard)
    }

    func testUnavailableOutputClearsFeedbackWithoutClosingWidget() {
        let fixture = NotchViewModelFixture()
        fixture.playback.onVolumeChanged?(0.5, true)
        fixture.model.openDetail(.system)
        fixture.playback.onVolumeChanged?(0.7, true)
        fixture.playback.onVolumeChanged?(0, false)
        XCTAssertFalse(fixture.model.isVolumeActivityVisible)
        XCTAssertEqual(fixture.model.presentation, .detail(.system))
    }

    func testDuplicateVolumeCallbacksDoNotExtendDeadlineAndStopCancelsIt() {
        let scheduler = PlaybackTestScheduler()
        let fixture = NotchViewModelFixture(scheduler: scheduler)
        fixture.model.expandDashboard()
        fixture.playback.onVolumeChanged?(0.5, true)
        fixture.playback.onVolumeChanged?(0.6, true)
        scheduler.advance(by: 1)
        fixture.playback.onVolumeChanged?(0.6, true)
        scheduler.advance(by: 0.25)
        XCTAssertFalse(fixture.model.isVolumeActivityVisible)
        fixture.playback.onVolumeChanged?(0.7, true)
        fixture.model.stop()
        scheduler.advance(by: 2)
        XCTAssertFalse(fixture.model.isVolumeActivityVisible)
    }

    func testActivityPresentationPrecedence() {
        var timer = TimerSnapshot()
        XCTAssertEqual(NotchViewModel.activityPresentation(mediaVisible: false, timer: timer), .hidden)
        XCTAssertEqual(NotchViewModel.activityPresentation(mediaVisible: true, timer: timer), .compactMedia)

        timer.state = .running
        timer.remaining = 60
        XCTAssertEqual(NotchViewModel.activityPresentation(mediaVisible: false, timer: timer), .compactTimer)
        XCTAssertEqual(NotchViewModel.activityPresentation(mediaVisible: true, timer: timer), .compactMediaAndTimer)

        timer.state = .finished
        XCTAssertEqual(NotchViewModel.activityPresentation(mediaVisible: true, timer: timer), .timerFinished)
        XCTAssertEqual(
            NotchViewModel.activityPresentation(mediaVisible: true, timer: timer, chargingVisible: true),
            .timerFinished
        )

        timer.state = .idle
        XCTAssertEqual(
            NotchViewModel.activityPresentation(mediaVisible: true, timer: timer, chargingVisible: true),
            .compactCharging
        )
    }

    func testWeatherConditionSymbols() {
        XCTAssertEqual(WeatherCondition.symbol(for: 0), "sun.max.fill")
        XCTAssertEqual(WeatherCondition.symbol(for: 0, isDay: false), "moon.stars.fill")
        XCTAssertEqual(WeatherCondition.symbol(for: 63), "cloud.rain.fill")
        XCTAssertEqual(WeatherCondition.description(for: 73), "Snow")
    }

    func testFogUsesMistSymbolRatherThanRain() {
        XCTAssertEqual(WeatherCondition.symbol(for: 45), "cloud.fog.fill")
        XCTAssertEqual(WeatherCondition.symbol(for: 48), "cloud.fog.fill")
        XCTAssertEqual(WeatherCondition.description(for: 45), "Foggy")
        XCTAssertNotEqual(WeatherCondition.symbol(for: 45), WeatherCondition.symbol(for: 61))
    }

    func testWeatherPagesContainFiveItemsAndKeepPartialPage() {
        XCTAssertEqual(ForecastPaging.itemsPerPage, 5)
        XCTAssertEqual(ForecastPaging.pageCount(for: 0), 0)
        XCTAssertEqual(ForecastPaging.pageCount(for: 5), 1)
        XCTAssertEqual(ForecastPaging.pageCount(for: 6), 2)
        XCTAssertEqual(ForecastPaging.pageCount(for: 10), 2)
        XCTAssertEqual(ForecastPaging.pageCount(for: 24), 5)
        XCTAssertEqual(ForecastPaging.pageCount(for: 25), 5)
    }

    func testHourlySummaryUsesVisibleHourRatherThanDailyHigh() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 14, minute: 30)))
        let day = calendar.startOfDay(for: now)
        let hours = (0..<24).map { hour in
            WeatherHour(time: day.addingTimeInterval(Double(hour * 3_600)), temperature: 40 + hour, precipitationChance: 0, conditionCode: 0)
        }
        let snapshot = WeatherSnapshot(hours: hours, days: [WeatherDay(date: day, high: 95, low: 40, precipitationChance: 0, conditionCode: 0)])
        XCTAssertEqual(snapshot.forecastHours(on: day, at: now, calendar: calendar).count, 10)
        XCTAssertEqual(snapshot.summaryHour(on: day, at: now, page: 0, calendar: calendar)?.temperature, 54)
        XCTAssertEqual(snapshot.summaryHour(on: day, at: now, page: 1, calendar: calendar)?.temperature, 59)
        XCTAssertEqual(snapshot.summaryHour(on: day, at: now, page: 999, calendar: calendar)?.temperature, 59)
        XCTAssertNotEqual(snapshot.summaryHour(on: day, at: now, page: 0, calendar: calendar)?.temperature, snapshot.days[0].high)
    }

    func testFutureHourlySummaryStartsAtMidnightAndMissingDataIsSafe() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 14)))
        let tomorrow = calendar.startOfDay(for: now).addingTimeInterval(86_400)
        let hour = WeatherHour(time: tomorrow, temperature: 42, precipitationChance: 0, conditionCode: 0, isDay: false)
        let snapshot = WeatherSnapshot(hours: [hour])
        XCTAssertEqual(snapshot.forecastHours(on: tomorrow, at: now, calendar: calendar), [hour])
        XCTAssertEqual(snapshot.summaryHour(on: tomorrow, at: now, page: -1, calendar: calendar), hour)
        XCTAssertNil(snapshot.summaryHour(on: now, at: now, page: 0, calendar: calendar))
    }

    func testDigitalCountdownRoundsUpAndSupportsLongTimers() {
        let reading = CountdownReading(seconds: 90.1)
        XCTAssertEqual(reading.seconds, 91)
        XCTAssertEqual(reading.formatted, "1:31")
        XCTAssertEqual(CountdownReading(seconds: 3_600).formatted, "60:00")
    }

    func testDigitalCountdownHandlesCompletionAndInvalidTime() {
        for value: Double in [0, -1, .nan, .infinity, .greatestFiniteMagnitude] {
            let reading = CountdownReading(seconds: value)
            XCTAssertEqual(reading.formatted, "0:00")
            XCTAssertEqual(reading.seconds, 0)
        }
    }

    func testPlayFeedbackReturnsToLiveSpectrumAfterThreeHundredMilliseconds() {
        let scheduler = PlaybackTestScheduler()
        let fixture = NotchViewModelFixture(scheduler: scheduler)
        fixture.playback.emit(playing: true)
        XCTAssertEqual(fixture.model.presentation, .compactMedia)
        XCTAssertEqual(fixture.model.playbackFeedback, .play)
        scheduler.advance(by: 0.299)
        fixture.playback.emit(playing: true)
        XCTAssertEqual(fixture.model.playbackFeedback, .play)
        scheduler.advance(by: 0.001)
        XCTAssertNil(fixture.model.playbackFeedback)
        XCTAssertEqual(fixture.model.presentation, .compactMedia)
    }

    func testPauseFeedbackCollapsesWithoutRepeatedSnapshotsExtendingIt() {
        let scheduler = PlaybackTestScheduler()
        let fixture = NotchViewModelFixture(scheduler: scheduler)
        fixture.playback.emit(playing: true)
        fixture.playback.emit(playing: false)
        XCTAssertEqual(fixture.model.playbackFeedback, .pause)
        scheduler.advance(by: 0.299)
        fixture.playback.emit(playing: false)
        XCTAssertEqual(fixture.model.presentation, .compactMedia)
        scheduler.advance(by: 0.001)
        XCTAssertEqual(fixture.model.presentation, .hidden)
        XCTAssertNil(fixture.model.playbackFeedback)
    }

    func testResumeInterruptsPauseWithoutCollapsingOrStoppingCapture() {
        let scheduler = PlaybackTestScheduler()
        let fixture = NotchViewModelFixture(scheduler: scheduler)
        fixture.playback.emit(playing: true)
        fixture.playback.emit(playing: false)
        scheduler.advance(by: 0.15)
        fixture.playback.emit(playing: true)
        scheduler.advance(by: 0.15)
        XCTAssertEqual(fixture.model.presentation, .compactMedia)
        XCTAssertEqual(fixture.model.playbackFeedback, .play)
        XCTAssertEqual(fixture.playback.stopCount, 0)
        scheduler.advance(by: 0.15)
        XCTAssertNil(fixture.model.playbackFeedback)
        XCTAssertEqual(fixture.model.presentation, .compactMedia)
    }

    func testRapidPlaybackChangesOnlyApplyLatestFeedbackDeadline() {
        let scheduler = PlaybackTestScheduler()
        let fixture = NotchViewModelFixture(scheduler: scheduler)
        for _ in 0..<5 {
            fixture.playback.emit(playing: true)
            scheduler.advance(by: 0.04)
            fixture.playback.emit(playing: false)
            scheduler.advance(by: 0.04)
        }
        fixture.playback.emit(playing: true)
        scheduler.advance(by: 0.299)
        XCTAssertEqual(fixture.model.presentation, .compactMedia)
        XCTAssertEqual(fixture.model.playbackFeedback, .play)
        scheduler.advance(by: 0.002)
        XCTAssertNil(fixture.model.playbackFeedback)
        XCTAssertEqual(fixture.playback.stopCount, 0)
    }

    func testMissingTrackRetainsGraceButDoesNotPostponeItForever() {
        let scheduler = PlaybackTestScheduler()
        let fixture = NotchViewModelFixture(scheduler: scheduler)
        fixture.playback.emit(playing: true)
        fixture.playback.emit(playing: false, hasMedia: false)
        XCTAssertNil(fixture.model.playbackFeedback)
        scheduler.advance(by: 1)
        fixture.playback.emit(playing: false, hasMedia: false)
        XCTAssertEqual(fixture.model.presentation, .compactMedia)
        scheduler.advance(by: 0.5)
        XCTAssertEqual(fixture.model.presentation, .hidden)
    }

    func testPauseLeavesRunningTimerActivityVisible() {
        let scheduler = PlaybackTestScheduler()
        let fixture = NotchViewModelFixture(scheduler: scheduler)
        fixture.timer.snapshot.state = .running
        fixture.timer.snapshot.remaining = 60
        fixture.timer.onSnapshotChanged?(fixture.timer.snapshot)
        fixture.playback.emit(playing: true)
        XCTAssertEqual(fixture.model.presentation, .compactMediaAndTimer)
        fixture.playback.emit(playing: false)
        scheduler.advance(by: 0.3)
        XCTAssertEqual(fixture.model.presentation, .compactTimer)
    }

    func testPauseDoesNotCloseDashboardWhileItIsBeingUsed() {
        let scheduler = PlaybackTestScheduler()
        let fixture = NotchViewModelFixture(scheduler: scheduler)
        fixture.playback.emit(playing: true)
        fixture.model.expandDashboard()
        fixture.playback.emit(playing: false)
        scheduler.advance(by: 0.3)
        XCTAssertEqual(fixture.model.presentation, .dashboard)
        XCTAssertNil(fixture.model.playbackFeedback)
    }

    func testStopCancelsPendingPlaybackFeedback() {
        let scheduler = PlaybackTestScheduler()
        let fixture = NotchViewModelFixture(scheduler: scheduler)
        fixture.playback.emit(playing: true)
        fixture.model.stop()
        let stops = fixture.playback.stopCount
        scheduler.advance(by: 1)
        XCTAssertNil(fixture.model.playbackFeedback)
        XCTAssertEqual(fixture.playback.stopCount, stops)
    }

    func testTransportGlyphGeometryRetainsEightBarsAndFitsCompactWing() {
        for feedback: PlaybackFeedback? in [nil, .play, .pause] {
            let bars = (0..<8).map { SpectrumBarGeometry.bar(at: $0, level: 1, playing: true, feedback: feedback) }
            for bar in bars {
                XCTAssertGreaterThanOrEqual(bar.centerX - bar.width / 2, 0)
                XCTAssertLessThanOrEqual(bar.centerX + bar.width / 2, 34)
                XCTAssertGreaterThan(bar.height, 0)
                XCTAssertLessThanOrEqual(bar.height, 22)
            }
            if feedback == .pause {
                XCTAssertTrue(bars.allSatisfy { $0.height == 16 })
                XCTAssertGreaterThan(bars[4].centerX - bars[3].centerX, 6)
            } else if feedback == .play {
                XCTAssertEqual(bars.map(\.height), bars.map(\.height).sorted(by: >))
            }
        }
    }

    func testSpectrumGeometrySanitizesInvalidLevels() {
        for level: Double in [.nan, .infinity, -.infinity, -1, 100] {
            let bar = SpectrumBarGeometry.bar(at: 0, level: level, playing: true, feedback: nil)
            XCTAssertTrue(bar.height.isFinite)
            XCTAssertGreaterThanOrEqual(bar.height, 2)
            XCTAssertLessThanOrEqual(bar.height, 20)
        }
    }

    func testCalendarDaySelectionDoesNotNavigateAwayFromHomeOrDetail() {
        let fixture = NotchViewModelFixture()
        let model = fixture.model
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        model.expandDashboard()
        model.selectCalendarDate(day)
        XCTAssertEqual(model.presentation, .dashboard)
        XCTAssertEqual(fixture.calendar.snapshot.displayedDate, Calendar.current.startOfDay(for: day))
        model.openDetail(.today)
        model.moveCalendarSelection(byDays: 1)
        XCTAssertEqual(model.presentation, .detail(.today))
        XCTAssertEqual(fixture.calendar.snapshot.displayedDate, model.selectedCalendarDate)
    }

    func testTimerMinuteBoundsAndInterruptedInteractionHold() {
        let model = NotchViewModelFixture().model
        model.adjustCustomTimerMinutes(by: -1_000)
        XCTAssertEqual(model.customTimerMinutes, 1)
        model.adjustCustomTimerMinutes(by: 1_000)
        XCTAssertEqual(model.customTimerMinutes, 180)
        model.setVolumeEditing(true)
        XCTAssertTrue(model.hasInteractionHold)
        model.finishInterruptedPointerDrag()
        XCTAssertFalse(model.hasInteractionHold)
    }

    func testWeatherRefreshRemovesSelectionOutsideForecastRange() {
        let fixture = NotchViewModelFixture()
        fixture.model.openWeatherDay(Date.distantPast)
        let today = Calendar.current.startOfDay(for: Date())
        fixture.weather.snapshot.days = [WeatherDay(date: today, high: 90, low: 50, precipitationChance: 0, conditionCode: 0)]
        fixture.weather.onSnapshotChanged?(fixture.weather.snapshot)
        XCTAssertEqual(fixture.model.selectedWeatherDate, today)
        XCTAssertEqual(fixture.model.weatherForecastMode, .hours)
    }

    func testHomeAndGalleryRenderAtFixedPanelSize() throws {
        let fixture = NotchViewModelFixture()
        fixture.model.setWidgetEnabled(.timer, enabled: true)
        fixture.model.setWidgetEnabled(.weather, enabled: true)
        let today = Calendar.current.startOfDay(for: Date())
        fixture.weather.snapshot.temperature = 64
        fixture.weather.snapshot.placeName = "Local forecast"
        fixture.weather.snapshot.days = (0..<5).map { offset in
            WeatherDay(date: Calendar.current.date(byAdding: .day, value: offset, to: today)!, high: 68 + offset, low: 51, precipitationChance: 0, conditionCode: offset == 0 ? 45 : 0)
        }
        fixture.weather.onSnapshotChanged?(fixture.weather.snapshot)
        fixture.model.expandDashboard()
        try attachRenderedNotch(fixture.model, name: "Four-widget Home")
        fixture.model.openCustomize()
        try attachRenderedNotch(fixture.model, name: "Widget gallery")
    }

    func testDetailLayoutsRenderAfterEntranceStateIsReady() async throws {
        let fixture = NotchViewModelFixture()
        let today = Calendar.current.startOfDay(for: Date())
        fixture.weather.snapshot.temperature = 64
        fixture.weather.snapshot.placeName = "Local forecast"
        fixture.weather.snapshot.hours = (0..<48).map { offset in
            WeatherHour(time: today.addingTimeInterval(Double(offset * 3_600)), temperature: 60 + offset % 8, precipitationChance: 10, conditionCode: 45)
        }
        fixture.weather.snapshot.days = [WeatherDay(date: today, high: 85, low: 50, precipitationChance: 10, conditionCode: 45)]
        fixture.weather.onSnapshotChanged?(fixture.weather.snapshot)
        for module: DashboardModule in [.today, .timer, .system, .weather] {
            fixture.model.openDetail(module)
            if module == .weather { fixture.model.setWeatherForecastMode(.hours) }
            let ready = expectation(description: "Detail reveal state ready")
            DispatchQueue.main.async { ready.fulfill() }
            await fulfillment(of: [ready], timeout: 1)
            try attachRenderedNotch(fixture.model, name: "\(module.title) detail")
        }
    }

    private func attachRenderedNotch(_ model: NotchViewModel, name: String) throws {
        let root = NotchView(model: model).environment(\.colorScheme, .dark).transaction { $0.disablesAnimations = true }
        let hosting = NSHostingView(rootView: root)
        let bounds = CGRect(origin: .zero, size: NotchGeometry.maximumPanelSize)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.frame = bounds
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: bounds))
        hosting.cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        XCTAssertEqual(image.size.width, NotchGeometry.maximumPanelSize.width)
        XCTAssertEqual(image.size.height, NotchGeometry.maximumPanelSize.height)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testWeatherForecastMapsAndClampsHourlyAndDailyData() throws {
        let json = """
        {"current":{"temperature_2m":68.6,"weather_code":2,"is_day":1},
         "hourly":{"time":[1000,4600],"temperature_2m":[68.6,70.2],
         "precipitation_probability":[-3,140],"weather_code":[2,61]},
         "daily":{"time":[1000,87400],"weather_code":[0,61],
         "temperature_2m_max":[72.6,66.1],"temperature_2m_min":[54.2,50.6],
         "precipitation_probability_max":[-5,105]}}
        """.data(using: .utf8)!
        let forecast = try JSONDecoder().decode(OpenMeteoForecast.self, from: json)
        let snapshot = forecast.snapshot(usesFahrenheit: true)
        XCTAssertEqual(snapshot.access, .ready)
        XCTAssertEqual(snapshot.temperature, 69)
        XCTAssertEqual(snapshot.hours.count, 2)
        XCTAssertEqual(snapshot.hours.map(\.precipitationChance), [0, 100])
        XCTAssertEqual(snapshot.days.map(\.high), [73, 66])
        XCTAssertEqual(snapshot.days.map(\.low), [54, 51])
        XCTAssertEqual(snapshot.days.map(\.precipitationChance), [0, 100])
    }

    func testDashboardLayoutKeepsFourWidgetsAtFixedHeightAndUsesPriority() {
        let widgets = [
            DashboardWidget(module: .media, size: .large),
            DashboardWidget(module: .today, size: .small),
            DashboardWidget(module: .timer, size: .small),
            DashboardWidget(module: .weather, size: .large)
        ]
        let columns = DashboardLayout.columns(for: widgets)
        XCTAssertEqual(columns.map { $0.map(\.module) }, [[.today], [.media, .timer], [.weather]])
        XCTAssertEqual(DashboardLayout.height(for: widgets, notchHeight: 32), 190)
        XCTAssertEqual(DashboardLayout.height(for: Array(widgets.prefix(2)), notchHeight: 32), 190)
    }

    func testWeatherMappingKeepsHourlyDataAcrossMultipleDays() {
        let timestamps = (0..<48).map { 1_800_000_000 + $0 * 3_600 }
        let forecast = OpenMeteoForecast(
            current: .init(temperature_2m: 60, weather_code: 0, is_day: 0),
            hourly: .init(
                time: timestamps,
                temperature_2m: Array(repeating: 60, count: 48),
                precipitation_probability: Array(repeating: 20, count: 48),
                weather_code: Array(repeating: 0, count: 48),
                is_day: (0..<48).map { $0 % 24 < 6 ? 0 : 1 }
            ),
            daily: nil
        )
        let snapshot = forecast.snapshot(usesFahrenheit: true)
        XCTAssertEqual(snapshot.hours.count, 48)
        XCTAssertEqual(snapshot.hours.last?.time, Date(timeIntervalSince1970: TimeInterval(timestamps.last!)))
        XCTAssertFalse(snapshot.hours[0].isDay)
        XCTAssertTrue(snapshot.hours[8].isDay)
        XCTAssertEqual(WeatherCondition.symbol(for: snapshot.hours[0].conditionCode, isDay: snapshot.hours[0].isDay), "moon.stars.fill")
    }

    func testHourlySelectionIncludesEntireLocalDayAcrossDaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let interval = try XCTUnwrap(calendar.dateInterval(of: .day, for: date))
        XCTAssertEqual(interval.duration, 25 * 3_600)
        let times = (-1...25).map { interval.start.addingTimeInterval(TimeInterval($0 * 3_600)) }
        let snapshot = WeatherSnapshot(hours: times.reversed().map {
            WeatherHour(time: $0, temperature: 60, precipitationChance: 0, conditionCode: 0)
        })
        let selected = snapshot.hours(on: date, calendar: calendar)
        XCTAssertEqual(selected.count, 25)
        XCTAssertEqual(selected.first?.time, interval.start)
        XCTAssertEqual(selected.last?.time, interval.end.addingTimeInterval(-3_600))
        XCTAssertFalse(selected.contains { $0.time == interval.end })
    }

    func testThreeWidgetsEachUseOneEqualColumn() {
        let widgets = [
            DashboardWidget(module: .system, size: .large),
            DashboardWidget(module: .media, size: .small),
            DashboardWidget(module: .weather, size: .small)
        ]
        XCTAssertEqual(
            DashboardLayout.columns(for: widgets).map { $0.map(\.module) },
            [[.system], [.media], [.weather]]
        )
        XCTAssertEqual(DashboardLayout.height(for: widgets, notchHeight: 38), 190)
    }

    func testTwoWidgetsStaySideBySideRegardlessOfStoredSizes() {
        let widgets = [
            DashboardWidget(module: .media, size: .small),
            DashboardWidget(module: .today, size: .small)
        ]
        XCTAssertEqual(DashboardLayout.columns(for: widgets).map { $0.map(\.module) }, [[.media], [.today]])
    }

    func testWidgetSelectionAndSizesPersistWithFourMaximum() {
        let name = "InteractiveNotchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = DashboardConfigurationStore(defaults: defaults)
        XCTAssertEqual(store.widgets.map(\.module), [.media, .today])
        XCTAssertTrue(store.setEnabled(.timer, enabled: true))
        XCTAssertTrue(store.setEnabled(.weather, enabled: true))
        XCTAssertFalse(store.setEnabled(.mirror, enabled: true))
        store.setSize(.large, for: .weather)
        store.move(.weather, by: -1)
        let restored = DashboardConfigurationStore(defaults: defaults)
        XCTAssertEqual(restored.widgets.map(\.module), [.media, .today, .weather, .timer])
        XCTAssertEqual(restored.widgets[2].size, .large)
        XCTAssertTrue(restored.setEnabled(.media, enabled: false))
        XCTAssertTrue(restored.setEnabled(.today, enabled: false))
        XCTAssertTrue(restored.setEnabled(.timer, enabled: false))
        XCTAssertFalse(restored.setEnabled(.weather, enabled: false))
    }

    func testRemovedHealthWidgetDoesNotDiscardOtherPins() {
        let name = "InteractiveNotchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("""
        [{"module":"media","size":"large"},{"module":"health","size":"small"},
         {"module":"today","size":"large"}]
        """.utf8), forKey: "dashboard.widgets.v1")

        let store = DashboardConfigurationStore(defaults: defaults)
        XCTAssertEqual(store.widgets.map(\.module), [.media, .today])
    }
}

@MainActor
private final class NotchViewModelFixture {
    let playback = FixturePlayback()
    let timer = FixtureTimer()
    let calendar = FixtureCalendar()
    let weather = FixtureWeather()
    let model: NotchViewModel
    private let defaults: UserDefaults
    private let suite: String

    init(scheduler: NotchScheduling? = nil) {
        suite = "NotchUIFixture.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        model = NotchViewModel(mediaSession: playback, volumeController: playback, batteryMonitor: FixtureBattery(), timerManager: timer, calendarProvider: calendar, weatherProvider: weather, mirrorCamera: FixtureMirror(), dashboardStore: DashboardConfigurationStore(defaults: defaults), spectrumProvider: playback, playbackScheduler: scheduler)
    }

    deinit { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
private final class FixturePlayback: MediaSessionProviding, SystemVolumeControlling, AudioSpectrumProviding {
    var stopCount = 0
    var snapshot = MediaSnapshot()
    var volume: Float = 0.5
    var isAvailable = true
    var levels = Array(repeating: 0.0, count: 8)
    var status: AudioSpectrumStatus = .stopped
    var onSnapshotChanged: ((MediaSnapshot) -> Void)?
    var onVolumeChanged: ((Float, Bool) -> Void)?
    var onLevelsChanged: (([Double]) -> Void)?
    var onStatusChanged: ((AudioSpectrumStatus) -> Void)?
    func start() {}
    func stop() { stopCount += 1 }
    func restart() {}
    func togglePlayPause() {}
    func previousTrack() {}
    func nextTrack() {}
    func seek(to elapsedTime: TimeInterval) {}
    func setVolume(_ value: Float) { volume = value }
    func toggleMute() {}
    func suspendForSleep() {}
    func resumeAfterWake() {}

    func emit(playing: Bool, hasMedia: Bool = true) {
        snapshot.isPlaying = playing
        snapshot.hasMedia = hasMedia
        onSnapshotChanged?(snapshot)
    }
}

@MainActor
private final class PlaybackTestScheduler: NotchScheduling {
    private final class Scheduled: NotchScheduledTask {
        let deadline: TimeInterval
        var action: (@MainActor () -> Void)?
        init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }
        func cancel() { action = nil }
    }
    private var now: TimeInterval = 0
    private var tasks: [Scheduled] = []
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> NotchScheduledTask {
        let task = Scheduled(deadline: now + delay, action: action)
        tasks.append(task)
        return task
    }
    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = tasks.filter({ $0.action != nil && $0.deadline <= target }).min(by: { $0.deadline < $1.deadline }) {
            now = next.deadline
            let action = next.action
            next.action = nil
            action?()
        }
        now = target
        tasks.removeAll { $0.action == nil }
    }
}

@MainActor
private final class FixtureBattery: BatteryMonitoring {
    var snapshot = BatterySnapshot()
    var onSnapshotChanged: ((BatterySnapshot) -> Void)?
    func start() {}
    func stop() {}
}

@MainActor
private final class FixtureCalendar: CalendarProviding {
    var snapshot = CalendarSnapshot(access: .authorized)
    var onSnapshotChanged: ((CalendarSnapshot) -> Void)?
    func start() {}
    func stop() {}
    func requestAccess() async {}
    func refresh() {}
    func refresh(for date: Date) {
        snapshot.displayedDate = date
        onSnapshotChanged?(snapshot)
    }
}

@MainActor
private final class FixtureWeather: WeatherProviding {
    var snapshot = WeatherSnapshot(access: .ready)
    var onSnapshotChanged: ((WeatherSnapshot) -> Void)?
    func open() {}
    func refreshIfNeeded() {}
    func stop() {}
}

@MainActor
private final class FixtureMirror: MirrorCameraProviding {
    var state: MirrorCameraState = .preview
    let session = AVCaptureSession()
    var onStateChanged: ((MirrorCameraState) -> Void)?
    func open() {}
    func close() {}
    func previewAttached() {}
    func previewDetached() {}
}

@MainActor
private final class FixtureTimer: TimerManaging {
    var snapshot = TimerSnapshot()
    var onSnapshotChanged: ((TimerSnapshot) -> Void)?
    func start() {}
    func stop() {}
    func start(minutes: Int) {}
    func pause() {}
    func resume() {}
    func addMinute() {}
    func cancel() {}
    func acknowledge() {}
    func reconcile() {}
}
