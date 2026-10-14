import AppKit
import AVFoundation
import Combine
import Foundation
import OSLog

@MainActor
final class NotchViewModel: ObservableObject {
    private let logger = Logger(subsystem: "local.InteractiveNotch", category: "Playback")
    enum InteractionHold: Hashable {
        case slider
        case contextMenu
        case calendarPermission
        case weatherPermission
        case mirrorPermission
        case settingsNavigation
    }

    @Published private(set) var presentation: NotchPresentation = .hidden
    @Published private(set) var media = MediaSnapshot()
    @Published private(set) var playbackFeedback: PlaybackFeedback?
    @Published private(set) var battery = BatterySnapshot()
    @Published private(set) var volume: Float = 0
    @Published private(set) var isVolumeAvailable = false
    @Published private(set) var isVolumeActivityVisible = false
    @Published var displayedElapsedTime: TimeInterval = 0
    @Published private(set) var currentDate = Date()
    @Published private(set) var timer = TimerSnapshot()
    @Published private(set) var calendar = CalendarSnapshot()
    @Published private(set) var weather = WeatherSnapshot()
    @Published private(set) var weatherForecastMode: WeatherForecastMode = .days
    @Published private(set) var selectedWeatherDate = Calendar.current.startOfDay(for: Date())
    @Published private(set) var mirrorState: MirrorCameraState = .preview
    @Published private(set) var dashboardWidgets: [DashboardWidget]
    @Published private(set) var notchWidth: CGFloat = 190
    @Published private(set) var notchHeight: CGFloat = 32
    @Published private(set) var accentColor = NSColor.systemGreen
    @Published private(set) var chargingPulseID = 0
    @Published private(set) var customTimerMinutes = 15
    @Published private(set) var detailRevealProgress: CGFloat = 0
    @Published private(set) var selectedCalendarDate = Calendar.current.startOfDay(for: Date())
    @Published private(set) var spectrumLevels = Array(repeating: 0.08, count: SpectrumAnalyzer.bandCount)
    @Published private(set) var spectrumStatus: AudioSpectrumStatus = .stopped
    @Published private(set) var lastDetailModule: DashboardModule = .media

    var onPresentationChanged: ((NotchPresentation) -> Void)?
    var onInteractionHoldChanged: ((Bool) -> Void)?

    var enabledModules: [DashboardModule] { DashboardModule.allCases }
    var isExpanded: Bool { presentation.isExpanded }
    var hasInteractionHold: Bool { !interactionHolds.isEmpty }
    var isSliderHeld: Bool { interactionHolds.contains(.slider) }
    var dashboardHeight: CGFloat { DashboardLayout.height(for: dashboardWidgets, notchHeight: notchHeight) }
    var cameraSession: AVCaptureSession { mirrorCamera.session }

    private let mediaSession: MediaSessionProviding
    private let volumeController: SystemVolumeControlling
    private let batteryMonitor: BatteryMonitoring
    private let timerManager: TimerManaging
    private let calendarProvider: CalendarProviding
    private let weatherProvider: WeatherProviding
    private let mirrorCamera: MirrorCameraProviding
    private let dashboardStore: DashboardConfigurationStore
    private let spectrumProvider: AudioSpectrumProviding
    private var progressTimer: Timer?
    private let playbackScheduler: NotchScheduling
    private var mediaGraceTask: NotchScheduledTask?
    private var playbackFeedbackTask: NotchScheduledTask?
    private var volumeActivityTask: NotchScheduledTask?
    private var hasObservedVolumeState = false
    private var chargingActivityTask: DispatchWorkItem?
    private var startupActivityTask: DispatchWorkItem?
    private var hasShownStartupActivity = false
    private var mediaActivityVisible = false
    private var chargingActivityVisible = false
    private var hasObservedBatteryState = false
    private var isSeeking = false
    private var interactionHolds = Set<InteractionHold>()
    private var spectrumDiagnosticSamples = 0
    private var lastSpectrumDiagnosticAt = Date.distantPast
    private var mirrorPermissionDialogWasShown = false
    private var mirrorPermissionReleaseTask: DispatchWorkItem?
    private var detailCameFromWidgetGallery = false

    init(
        mediaSession: MediaSessionProviding,
        volumeController: SystemVolumeControlling,
        batteryMonitor: BatteryMonitoring,
        timerManager: TimerManaging,
        calendarProvider: CalendarProviding,
        weatherProvider: WeatherProviding,
        mirrorCamera: MirrorCameraProviding,
        dashboardStore: DashboardConfigurationStore,
        spectrumProvider: AudioSpectrumProviding,
        playbackScheduler: NotchScheduling? = nil
    ) {
        self.mediaSession = mediaSession
        self.volumeController = volumeController
        self.batteryMonitor = batteryMonitor
        self.timerManager = timerManager
        self.calendarProvider = calendarProvider
        self.weatherProvider = weatherProvider
        self.mirrorCamera = mirrorCamera
        self.dashboardStore = dashboardStore
        dashboardWidgets = dashboardStore.widgets
        self.spectrumProvider = spectrumProvider
        self.playbackScheduler = playbackScheduler ?? DispatchNotchScheduler()
        media = mediaSession.snapshot
        volume = volumeController.volume
        isVolumeAvailable = volumeController.isAvailable
        battery = batteryMonitor.snapshot
        timer = timerManager.snapshot
        calendar = calendarProvider.snapshot
        weather = weatherProvider.snapshot
        mirrorState = mirrorCamera.state
        mediaActivityVisible = media.isPlaying
        presentation = Self.activityPresentation(mediaVisible: mediaActivityVisible, timer: timer)

        mediaSession.onSnapshotChanged = { [weak self] snapshot in self?.receiveMedia(snapshot) }
        volumeController.onVolumeChanged = { [weak self] volume, available in
            self?.receiveVolume(volume, available: available)
        }
        batteryMonitor.onSnapshotChanged = { [weak self] snapshot in self?.receiveBattery(snapshot) }
        timerManager.onSnapshotChanged = { [weak self] snapshot in
            guard let self else { return }
            self.timer = snapshot
            self.refreshActivityPresentation()
        }
        calendarProvider.onSnapshotChanged = { [weak self] snapshot in self?.calendar = snapshot }
        weatherProvider.onSnapshotChanged = { [weak self] snapshot in
            guard let self else { return }
            self.weather = snapshot
            if !snapshot.days.isEmpty && !snapshot.days.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: self.selectedWeatherDate) }) {
                self.selectedWeatherDate = Calendar.current.startOfDay(for: snapshot.days[0].date)
            }
            if snapshot.access != .requestingPermission { self.setInteractionHold(.weatherPermission, active: false) }
        }
        mirrorCamera.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.mirrorState = state
            if state == .requestingPermission {
                self.mirrorPermissionDialogWasShown = true
            } else if self.mirrorPermissionDialogWasShown && self.presentation == .mirror {
                // The pointer is normally over macOS's consent sheet when it closes.
                // Give it time to return before hover collapse resumes.
                self.mirrorPermissionReleaseTask?.cancel()
                let release = DispatchWorkItem { [weak self] in
                    Task { @MainActor in
                        self?.mirrorPermissionDialogWasShown = false
                        self?.setInteractionHold(.mirrorPermission, active: false)
                    }
                }
                self.mirrorPermissionReleaseTask = release
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: release)
            } else {
                self.setInteractionHold(.mirrorPermission, active: false)
            }
        }
        spectrumProvider.onLevelsChanged = { [weak self] levels in
            guard let self else { return }
            self.spectrumLevels = levels
            let now = Date()
            if self.spectrumDiagnosticSamples < 3,
               now.timeIntervalSince(self.lastSpectrumDiagnosticAt) >= 2 {
                self.lastSpectrumDiagnosticAt = now
                self.spectrumDiagnosticSamples += 1
                let peak = levels.max() ?? 0
                self.logger.notice("spectrum peak level: \(peak, privacy: .public)")
            }
        }
        spectrumProvider.onStatusChanged = { [weak self] status in
            self?.spectrumStatus = status
            self?.logger.notice("spectrum status: \(status.label, privacy: .public)")
            if status == .starting { self?.spectrumDiagnosticSamples = 0 }
        }
    }

    func start() {
        if !hasShownStartupActivity {
            hasShownStartupActivity = true
            setPresentation(.startup)
            // A display can be disconnected or the view can be unmounted.
            // Never leave the startup presentation waiting for its animation.
            let task = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.finishStartupActivity() }
            }
            startupActivityTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: task)
        }
        mediaSession.start()
        volumeController.start()
        batteryMonitor.start()
        timerManager.start()
        calendarProvider.start()
        if media.isPlaying { spectrumProvider.start() }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentDate = Date()
                if !self.isSeeking {
                    self.displayedElapsedTime = self.media.estimatedElapsedTime(at: self.currentDate)
                }
            }
        }
    }

    func stop() {
        volumeActivityTask?.cancel()
        volumeActivityTask = nil
        isVolumeActivityVisible = false
        hasObservedVolumeState = false
        progressTimer?.invalidate()
        progressTimer = nil
        mediaGraceTask?.cancel()
        mediaGraceTask = nil
        playbackFeedbackTask?.cancel()
        playbackFeedbackTask = nil
        playbackFeedback = nil
        startupActivityTask?.cancel()
        startupActivityTask = nil
        chargingActivityTask?.cancel()
        chargingActivityTask = nil
        chargingActivityVisible = false
        refreshActivityPresentation()
        mediaSession.stop()
        volumeController.stop()
        batteryMonitor.stop()
        timerManager.stop()
        calendarProvider.stop()
        weatherProvider.stop()
        mirrorCamera.close()
        spectrumProvider.stop()
    }

    func expandDashboard() {
        detailCameFromWidgetGallery = false
        setPresentation(.dashboard)
    }

    func finishStartupActivity() {
        guard presentation == .startup else { return }
        setPresentation(currentActivityPresentation)
    }

    func collapseToActivity() {
        detailCameFromWidgetGallery = false
        mirrorCamera.close()
        setPresentation(currentActivityPresentation)
    }

    func openDetail(_ module: DashboardModule) {
        if module == .mirror { openMirror(); return }
        mirrorCamera.close()
        lastDetailModule = module
        detailRevealProgress = 0
        setPresentation(.detail(module))
        DispatchQueue.main.async { [weak self] in
            self?.detailRevealProgress = 1
        }
        if module == .today, calendar.access == .preview { requestCalendarAccess() }
        if module == .weather {
            selectedWeatherDate = Calendar.current.startOfDay(for: Date())
            weatherForecastMode = .days
            if weather.access == .preview { setInteractionHold(.weatherPermission, active: true) }
            weatherProvider.open()
        }
    }

    func openWeatherDay(_ date: Date) {
        if presentation != .detail(.weather) { openDetail(.weather) }
        selectedWeatherDate = Calendar.current.startOfDay(for: date)
        weatherForecastMode = .hours
    }

    func setWeatherForecastMode(_ mode: WeatherForecastMode) {
        weatherForecastMode = mode
    }

    var selectedWeatherDay: WeatherDay? {
        weather.days.first { Calendar.current.isDate($0.date, inSameDayAs: selectedWeatherDate) }
    }

    var selectedWeatherHours: [WeatherHour] {
        weather.hours(on: selectedWeatherDate)
    }

    func weatherDay(by offset: Int) -> WeatherDay? {
        guard let index = weather.days.firstIndex(where: {
            Calendar.current.isDate($0.date, inSameDayAs: selectedWeatherDate)
        }), weather.days.indices.contains(index + offset) else { return nil }
        return weather.days[index + offset]
    }

    func moveWeatherDay(by offset: Int) {
        guard let day = weatherDay(by: offset) else { return }
        openWeatherDay(day.date)
    }

    func openGalleryPreview(_ module: DashboardModule) {
        detailCameFromWidgetGallery = true
        openDetail(module)
    }

    func returnFromDetail() {
        if detailCameFromWidgetGallery {
            openCustomize()
        } else {
            showDashboard()
        }
    }

    func showDashboard() {
        detailCameFromWidgetGallery = false
        mirrorCamera.close()
        detailRevealProgress = 0
        setPresentation(.dashboard)
    }

    func openCustomize() {
        detailCameFromWidgetGallery = false
        mirrorCamera.close()
        setPresentation(.customize)
    }

    func openMirror() {
        setPresentation(.mirror)
        if mirrorCamera.state == .preview { setInteractionHold(.mirrorPermission, active: true) }
        mirrorCamera.open()
    }

    func mirrorPreviewAttached() { mirrorCamera.previewAttached() }

    func mirrorPreviewDetached() { mirrorCamera.previewDetached() }

    @discardableResult
    func setWidgetEnabled(_ module: DashboardModule, enabled: Bool) -> Bool {
        let changed = dashboardStore.setEnabled(module, enabled: enabled)
        dashboardWidgets = dashboardStore.widgets
        return changed
    }

    func setWidgetSize(_ size: DashboardWidgetSize, for module: DashboardModule) {
        dashboardStore.setSize(size, for: module)
        dashboardWidgets = dashboardStore.widgets
    }

    func moveWidget(_ module: DashboardModule, by offset: Int) {
        dashboardStore.move(module, by: offset)
        dashboardWidgets = dashboardStore.widgets
    }

    func togglePlayPause() { mediaSession.togglePlayPause() }
    func previousTrack() { mediaSession.previousTrack() }
    func nextTrack() { mediaSession.nextTrack() }

    func openMediaApp() {
        let workspace = NSWorkspace.shared
        guard let url = MediaSourceApplication.url(for: media, resolve: {
            workspace.urlForApplication(withBundleIdentifier: $0)
        }) else { return }
        workspace.openApplication(at: url, configuration: .init())
    }

    func updateSeek(_ value: Double) { displayedElapsedTime = value }

    func setSeeking(_ seeking: Bool) {
        isSeeking = seeking
        setInteractionHold(.slider, active: seeking)
        if !seeking { mediaSession.seek(to: displayedElapsedTime) }
    }

    func setVolume(_ value: Float) { volumeController.setVolume(value) }
    func setVolumeEditing(_ editing: Bool) { setInteractionHold(.slider, active: editing) }

    func finishInterruptedPointerDrag() {
        if isSeeking { setSeeking(false) }
        setInteractionHold(.slider, active: false)
    }
    func toggleMute() { volumeController.toggleMute() }
    func restartMediaIntegration() { mediaSession.restart() }
    func restartAudioSpectrum() { spectrumProvider.restart() }

    func openAudioCaptureSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ]
        for value in urls {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
        let settingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.openApplication(at: settingsURL, configuration: .init())
    }

    func setNotchGeometry(width: CGFloat, height: CGFloat) {
        notchWidth = max(width, 80)
        notchHeight = max(height, 1)
    }

    func startTimer(minutes: Int) { timerManager.start(minutes: minutes) }
    func adjustCustomTimerMinutes(by amount: Int) {
        customTimerMinutes = min(max(customTimerMinutes + amount, 1), 180)
    }
    func startCustomTimer() { timerManager.start(minutes: customTimerMinutes) }
    func pauseTimer() { timerManager.pause() }
    func resumeTimer() { timerManager.resume() }
    func addTimerMinute() { timerManager.addMinute() }
    func cancelTimer() { timerManager.cancel() }
    func acknowledgeTimer() { timerManager.acknowledge() }

    func openInternetAccounts() {
        let urls = [
            "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.internetaccounts"
        ]
        for value in urls {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
        let settingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.openApplication(at: settingsURL, configuration: .init())
    }

    func selectCalendarDate(_ date: Date) {
        selectedCalendarDate = Calendar.current.startOfDay(for: date)
        calendarProvider.refresh(for: selectedCalendarDate)
    }

    func moveCalendarSelection(byDays days: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: selectedCalendarDate) else { return }
        selectCalendarDate(date)
    }

    func openClock() {
        let clockURL = URL(fileURLWithPath: "/System/Applications/Clock.app")
        NSWorkspace.shared.openApplication(at: clockURL, configuration: .init())
    }

    func refreshWeather() {
        weatherProvider.open()
    }

    func openLocationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ]
        for value in urls {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/System Settings.app"), configuration: .init())
    }

    func openCameraSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        ]
        for value in urls {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/System Settings.app"), configuration: .init())
    }

    func setInteractionHold(_ hold: InteractionHold, active: Bool) {
        let previouslyHeld = hasInteractionHold
        if active { interactionHolds.insert(hold) } else { interactionHolds.remove(hold) }
        if previouslyHeld != hasInteractionHold { onInteractionHoldChanged?(hasInteractionHold) }
    }

    func reconcileAfterWake() {
        timerManager.reconcile()
        calendarProvider.refresh()
        weatherProvider.refreshIfNeeded()
        // MediaRemote's stream can stay alive but stop publishing after sleep.
        // Recreate it so playback state and spectrum start conditions refresh.
        mediaSession.restart()
        spectrumProvider.resumeAfterWake()
        if presentation == .mirror { mirrorCamera.open() }
    }

    func prepareForSleep() {
        finishStartupActivity()
        spectrumProvider.suspendForSleep()
        if presentation == .mirror { mirrorCamera.close() }
    }

    static func activityPresentation(mediaVisible: Bool, timer: TimerSnapshot, chargingVisible: Bool = false) -> NotchPresentation {
        if timer.isFinished { return .timerFinished }
        if chargingVisible { return .compactCharging }
        if timer.isActive && mediaVisible { return .compactMediaAndTimer }
        if timer.isActive { return .compactTimer }
        if mediaVisible { return .compactMedia }
        return .hidden
    }

    private func receiveMedia(_ snapshot: MediaSnapshot) {
        let wasPlaying = media.isPlaying
        if media.isPlaying != snapshot.isPlaying || media.hasMedia != snapshot.hasMedia ||
            media.integrationAvailable != snapshot.integrationAvailable {
            logger.notice("media state: available=\(snapshot.integrationAvailable) hasMedia=\(snapshot.hasMedia) playing=\(snapshot.isPlaying)")
        }
        media = snapshot
        if !isSeeking { displayedElapsedTime = snapshot.estimatedElapsedTime(at: Date()) }
        accentColor = snapshot.artwork?.preferredSpectrumColor() ?? .systemGreen

        if snapshot.isPlaying {
            mediaGraceTask?.cancel()
            mediaGraceTask = nil
            if !wasPlaying {
                playbackFeedbackTask?.cancel()
                playbackFeedback = .play
                playbackFeedbackTask = playbackScheduler.schedule(after: PlaybackFeedback.duration) { [weak self] in
                    guard let self, self.media.isPlaying else { return }
                    self.playbackFeedback = nil
                    self.playbackFeedbackTask = nil
                }
            }
            if spectrumProvider.status == .stopped { spectrumProvider.start() }
            mediaActivityVisible = true
            refreshActivityPresentation()
        } else if mediaActivityVisible, mediaGraceTask == nil {
            playbackFeedbackTask?.cancel()
            playbackFeedbackTask = nil
            // A missing track can be a hand-off, not a deliberate pause.
            // Repeated paused snapshots must not restart either deadline.
            playbackFeedback = snapshot.hasMedia ? .pause : nil
            let delay = snapshot.hasMedia ? PlaybackFeedback.duration : 1.5
            mediaGraceTask = playbackScheduler.schedule(after: delay) { [weak self] in
                guard let self, !self.media.isPlaying else { return }
                self.mediaGraceTask = nil
                self.playbackFeedback = nil
                self.mediaActivityVisible = false
                self.spectrumProvider.stop()
                self.refreshActivityPresentation()
            }
        }
    }

    private func receiveBattery(_ snapshot: BatterySnapshot) {
        let newlyConnected = hasObservedBatteryState && snapshot.isOnExternalPower && !battery.isOnExternalPower
        hasObservedBatteryState = true
        battery = snapshot
        guard newlyConnected else { return }

        chargingPulseID += 1
        chargingActivityVisible = true
        refreshActivityPresentation()
        chargingActivityTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.chargingActivityVisible = false
            self.chargingActivityTask = nil
            self.refreshActivityPresentation()
        }
        chargingActivityTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: task)
    }

    private func requestCalendarAccess() {
        setInteractionHold(.calendarPermission, active: true)
        Task { [weak self] in
            guard let self else { return }
            await self.calendarProvider.requestAccess()
            self.setInteractionHold(.calendarPermission, active: false)
        }
    }

    private func refreshActivityPresentation() {
        guard !presentation.isExpanded, presentation != .startup else { return }
        setPresentation(currentActivityPresentation)
    }

    private var currentActivityPresentation: NotchPresentation {
        return Self.activityPresentation(mediaVisible: mediaActivityVisible, timer: timer, chargingVisible: chargingActivityVisible)
    }

    private func receiveVolume(_ value: Float, available: Bool) {
        let next = VolumeMath.clamped(value)
        let changed = hasObservedVolumeState && isVolumeAvailable && available && abs(next - volume) > 0.0001
        volume = next
        isVolumeAvailable = available
        hasObservedVolumeState = true
        if !available {
            volumeActivityTask?.cancel()
            volumeActivityTask = nil
            isVolumeActivityVisible = false
            refreshActivityPresentation()
            return
        }
        // Closed live activities never open or queue feedback for a later hover.
        guard changed, presentation.isExpanded else { return }
        isVolumeActivityVisible = true
        volumeActivityTask?.cancel()
        volumeActivityTask = playbackScheduler.schedule(after: 1.25) { [weak self] in
            guard let self else { return }
            self.volumeActivityTask = nil
            self.isVolumeActivityVisible = false
            self.refreshActivityPresentation()
        }
    }

    private func setPresentation(_ newValue: NotchPresentation) {
        guard presentation != newValue else { return }
        if newValue != .startup {
            startupActivityTask?.cancel()
            startupActivityTask = nil
        }
        presentation = newValue
        if !newValue.isExpanded {
            volumeActivityTask?.cancel()
            volumeActivityTask = nil
            isVolumeActivityVisible = false
        }
        if newValue != .mirror {
            mirrorPermissionReleaseTask?.cancel()
            mirrorPermissionReleaseTask = nil
            mirrorPermissionDialogWasShown = false
            setInteractionHold(.mirrorPermission, active: false)
        }
        logger.notice("presentation: \(String(describing: newValue), privacy: .public)")
        onPresentationChanged?(newValue)
    }

}

extension NSImage {
    func preferredSpectrumColor() -> NSColor? {
        guard let data = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return nil }
        let stepX = max(bitmap.pixelsWide / 24, 1)
        let stepY = max(bitmap.pixelsHigh / 24, 1)
        var samples: [NSColor] = []
        for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
                if let color = bitmap.colorAt(x: x, y: y) { samples.append(color) }
            }
        }
        return ArtworkAccentColor.choose(from: samples)
    }
}

enum ArtworkAccentColor {
    static func choose(from samples: [NSColor]) -> NSColor? {
        struct Bucket {
            var count = 0
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var color: NSColor {
                NSColor(red: red / CGFloat(count), green: green / CGFloat(count), blue: blue / CGFloat(count), alpha: 1)
            }
        }
        var buckets: [Int: Bucket] = [:]
        for sample in samples {
            guard let color = sample.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
            // Quantization groups small artwork variations before counting colors.
            let r = min(Int(color.redComponent * 6), 5)
            let g = min(Int(color.greenComponent * 6), 5)
            let b = min(Int(color.blueComponent * 6), 5)
            let key = r * 36 + g * 6 + b
            var bucket = buckets[key, default: Bucket()]
            bucket.count += 1
            bucket.red += color.redComponent
            bucket.green += color.greenComponent
            bucket.blue += color.blueComponent
            buckets[key] = bucket
        }
        guard !buckets.isEmpty else { return nil }
        let ranked = buckets.values.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return luminance(lhs.color) > luminance(rhs.color)
        }
        let selected = ranked.first { bucket in
            let color = bucket.color
            return color.brightnessComponent >= 0.38 && luminance(color) >= 0.16
        }?.color ?? ranked.max(by: { luminance($0.color) < luminance($1.color) })!.color
        guard luminance(selected) > 0.03 else { return .white }
        // Boost the chosen artwork hue only enough for thin bars on pure black.
        return NSColor(
            hue: selected.hueComponent,
            saturation: min(selected.saturationComponent, 0.88),
            brightness: max(selected.brightnessComponent, 0.68),
            alpha: 1
        )
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }
}
