import AppKit
@preconcurrency import AVFoundation
import CoreLocation
import EventKit
import Foundation
import MapKit
import OSLog

@MainActor
final class DashboardConfigurationStore {
    private let defaults: UserDefaults
    private let key = "dashboard.widgets.v1"
    private(set) var widgets: [DashboardWidget]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([PersistedWidget].self, from: data) {
            let unique = decoded.reduce(into: [DashboardWidget]()) { result, widget in
                if let module = DashboardModule(rawValue: widget.module),
                   !result.contains(where: { $0.module == module }),
                   result.count < 4 {
                    result.append(DashboardWidget(module: module, size: widget.size))
                }
            }
            widgets = unique.isEmpty ? Self.defaultWidgets : unique
        } else {
            widgets = Self.defaultWidgets
        }
    }

    static var defaultWidgets: [DashboardWidget] {
        [DashboardWidget(module: .media, size: .large), DashboardWidget(module: .today, size: .large)]
    }

    private struct PersistedWidget: Decodable {
        let module: String
        let size: DashboardWidgetSize
    }

    @discardableResult
    func setEnabled(_ module: DashboardModule, enabled: Bool) -> Bool {
        let contains = widgets.contains(where: { $0.module == module })
        if enabled && !contains {
            guard widgets.count < 4 else { return false }
            widgets.append(DashboardWidget(module: module, size: .small))
        } else if !enabled && contains {
            guard widgets.count > 1 else { return false }
            widgets.removeAll { $0.module == module }
        }
        save()
        return true
    }

    func setSize(_ size: DashboardWidgetSize, for module: DashboardModule) {
        guard let index = widgets.firstIndex(where: { $0.module == module }) else { return }
        widgets[index].size = size
        save()
    }

    func move(_ module: DashboardModule, by offset: Int) {
        guard let index = widgets.firstIndex(where: { $0.module == module }) else { return }
        let destination = index + offset
        guard widgets.indices.contains(destination) else { return }
        widgets.swapAt(index, destination)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(widgets) { defaults.set(data, forKey: key) }
    }
}

@MainActor
protocol MirrorCameraProviding: AnyObject {
    var state: MirrorCameraState { get }
    var session: AVCaptureSession { get }
    var onStateChanged: ((MirrorCameraState) -> Void)? { get set }
    func open()
    func close()
    func previewAttached()
    func previewDetached()
}

@MainActor
final class MirrorCameraController: MirrorCameraProviding {
    private let logger = Logger(subsystem: "local.InteractiveNotch", category: "Mirror")
    private(set) var state: MirrorCameraState = .preview
    let session = AVCaptureSession()
    var onStateChanged: ((MirrorCameraState) -> Void)?

    private let sessionQueue = DispatchQueue(label: "InteractiveNotch.MirrorCamera", qos: .userInitiated)
    private var isOpen = false
    private var configured = false
    private var generation = 0
    private var previewIsAttached = false
    private var readyGeneration: Int?
    private var startingGeneration: Int?
    private var failedGeneration: Int?
    private var runtimeErrorObserver: NSObjectProtocol?

    init() {
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, self.isOpen else { return }
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                self.logger.error("camera session failed: \(error?.localizedDescription ?? "unknown error", privacy: .public)")
                self.failedGeneration = self.generation
                self.startingGeneration = nil
                self.publish(.unavailable)
            }
        }
    }

    deinit {
        if let runtimeErrorObserver { NotificationCenter.default.removeObserver(runtimeErrorObserver) }
    }

    func open() {
        if state == .unavailable {
            let session = session
            sessionQueue.async { if session.isRunning { session.stopRunning() } }
        }
        isOpen = true
        generation += 1
        failedGeneration = nil
        let currentGeneration = generation
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start(generation: currentGeneration)
        case .notDetermined:
            publish(.requestingPermission)
            NSApp.activate(ignoringOtherApps: true)
            Task { [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard let self, self.isOpen, self.generation == currentGeneration else { return }
                if granted { self.start(generation: currentGeneration) }
                else { self.publish(.denied) }
            }
        case .denied, .restricted:
            publish(.denied)
        @unknown default:
            publish(.unavailable)
        }
    }

    func close() {
        isOpen = false
        generation += 1
        readyGeneration = nil
        startingGeneration = nil
        failedGeneration = nil
        previewIsAttached = false
        let session = session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
        publish(.preview)
    }

    private func start(generation currentGeneration: Int) {
        guard isOpen else { return }
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        guard let device,
              let input = try? AVCaptureDeviceInput(device: device) else {
            publish(.unavailable)
            return
        }
        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .medium
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                publish(.unavailable)
                return
            }
            session.addInput(input)
            session.commitConfiguration()
            configured = true
        }
        publish(.starting)
        readyGeneration = currentGeneration
        startIfPreviewReady()
    }

    func previewAttached() {
        previewIsAttached = true
        startIfPreviewReady()
    }

    func previewDetached() {
        previewIsAttached = false
    }

    private func startIfPreviewReady() {
        guard isOpen, previewIsAttached, readyGeneration == generation,
              startingGeneration != generation else { return }
        let currentGeneration = generation
        startingGeneration = currentGeneration
        let session = session
        sessionQueue.async { [weak self] in
            if !session.isRunning { session.startRunning() }
            let running = session.isRunning
            Task { @MainActor in
                guard let self, self.isOpen, self.generation == currentGeneration else { return }
                self.startingGeneration = nil
                if !running { self.logger.error("camera session did not start") }
                self.publish(running && self.failedGeneration != currentGeneration ? .running : .unavailable)
            }
        }
    }

    private func publish(_ newState: MirrorCameraState) {
        state = newState
        onStateChanged?(newState)
    }
}

@MainActor
protocol WeatherProviding: AnyObject {
    var snapshot: WeatherSnapshot { get }
    var onSnapshotChanged: ((WeatherSnapshot) -> Void)? { get set }
    func open()
    func refreshIfNeeded()
    func stop()
}

@MainActor
final class LocalWeatherProvider: NSObject, WeatherProviding, @preconcurrency CLLocationManagerDelegate {
    private(set) var snapshot = WeatherSnapshot()
    var onSnapshotChanged: ((WeatherSnapshot) -> Void)?

    private let locationManager = CLLocationManager()
    private var requestTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var hasOpened = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func open() {
        hasOpened = true
        refreshIfNeeded()
    }

    func refreshIfNeeded() {
        guard hasOpened else { return }
        if snapshot.access == .ready,
           let updatedAt = snapshot.updatedAt,
           Date().timeIntervalSince(updatedAt) < 1800 { return }
        guard CLLocationManager.locationServicesEnabled() else {
            publish(.restricted)
            return
        }
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            publish(.loading)
            locationManager.requestLocation()
        case .notDetermined:
            publish(.requestingPermission)
            // This is called only from an explicit Weather open, never at launch.
            NSApp.activate(ignoringOtherApps: true)
            locationManager.requestWhenInUseAuthorization()
        case .denied:
            publish(.denied)
        case .restricted:
            publish(.restricted)
        @unknown default:
            publish(.error)
        }
    }

    func stop() {
        requestTask?.cancel()
        requestTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        locationManager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard hasOpened else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied: publish(.denied)
        case .restricted: publish(.restricted)
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { publish(.error); return }
        resolvePlaceName(for: location)
        fetch(at: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        publish(.error)
    }

    private func fetch(at location: CLLocation) {
        requestTask?.cancel()
        let fahrenheit = Locale.current.measurementSystem == .us
        // Send only rounded, approximate coordinates to the forecast service.
        let latitude = (location.coordinate.latitude * 100).rounded() / 100
        let longitude = (location.coordinate.longitude * 100).rounded() / 100
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "forecast_days", value: "6"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius")
        ]
        guard let url = components.url else { publish(.error); return }
        publish(.loading)
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 12
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let forecast = try JSONDecoder().decode(OpenMeteoForecast.self, from: data)
                guard !Task.isCancelled else { return }
                var updated = forecast.snapshot(usesFahrenheit: fahrenheit)
                updated.placeName = self.snapshot.placeName
                self.snapshot = updated
                self.onSnapshotChanged?(self.snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                self.publish(.error)
            }
        }
    }

    private func resolvePlaceName(for location: CLLocation) {
        guard let request = MKReverseGeocodingRequest(location: location) else { return }
        request.getMapItems { [weak self] items, _ in
            Task { @MainActor in
                guard let self else { return }
                let name = items?.first?.addressRepresentations?.cityName
                guard let name, !name.isEmpty else { return }
                self.snapshot.placeName = name
                self.onSnapshotChanged?(self.snapshot)
            }
        }
    }

    private func publish(_ state: WeatherAccessState) {
        snapshot.access = state
        onSnapshotChanged?(snapshot)
        timeoutTask?.cancel()
        timeoutTask = nil
        if state == .loading || state == .requestingPermission {
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self,
                      self.snapshot.access == .loading || self.snapshot.access == .requestingPermission else { return }
                self.publish(.error)
            }
        }
    }
}

struct OpenMeteoForecast: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double
        let weather_code: Int
        let is_day: Int
    }
    struct Hourly: Decodable {
        let time: [Int]
        let temperature_2m: [Double]
        let precipitation_probability: [Int]
        let weather_code: [Int]
        let is_day: [Int]?
    }
    struct Daily: Decodable {
        let time: [Int]
        let weather_code: [Int]
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        let precipitation_probability_max: [Int]
    }
    let current: Current
    let hourly: Hourly
    let daily: Daily?

    func snapshot(usesFahrenheit: Bool) -> WeatherSnapshot {
        let count = min(hourly.time.count, hourly.temperature_2m.count,
                        hourly.precipitation_probability.count, hourly.weather_code.count)
        let hours = (0..<count).map { index in
            WeatherHour(
                time: Date(timeIntervalSince1970: TimeInterval(hourly.time[index])),
                temperature: Int(hourly.temperature_2m[index].rounded()),
                precipitationChance: max(0, min(hourly.precipitation_probability[index], 100)),
                conditionCode: hourly.weather_code[index],
                isDay: hourly.is_day.flatMap { $0.indices.contains(index) ? $0[index] != 0 : nil } ?? true
            )
        }
        let dayCount = min(5, daily?.time.count ?? 0, daily?.weather_code.count ?? 0,
                           daily?.temperature_2m_max.count ?? 0, daily?.temperature_2m_min.count ?? 0,
                           daily?.precipitation_probability_max.count ?? 0)
        let days: [WeatherDay] = (0..<dayCount).compactMap { index in
            guard let daily else { return nil }
            return WeatherDay(
                date: Date(timeIntervalSince1970: TimeInterval(daily.time[index])),
                high: Int(daily.temperature_2m_max[index].rounded()),
                low: Int(daily.temperature_2m_min[index].rounded()),
                precipitationChance: max(0, min(daily.precipitation_probability_max[index], 100)),
                conditionCode: daily.weather_code[index]
            )
        }
        return WeatherSnapshot(
            access: .ready,
            temperature: Int(current.temperature_2m.rounded()),
            usesFahrenheit: usesFahrenheit,
            conditionCode: current.weather_code,
            isDay: current.is_day != 0,
            hours: hours,
            days: days,
            updatedAt: Date()
        )
    }
}

protocol DateProviding: AnyObject {
    var now: Date { get }
}

final class SystemDateProvider: DateProviding {
    var now: Date { Date() }
}

@MainActor
protocol TimerManaging: AnyObject {
    var snapshot: TimerSnapshot { get }
    var onSnapshotChanged: ((TimerSnapshot) -> Void)? { get set }

    func start()
    func stop()
    func start(minutes: Int)
    func pause()
    func resume()
    func addMinute()
    func cancel()
    func acknowledge()
    func reconcile()
}

@MainActor
final class PersistentTimerManager: TimerManaging {
    private struct StoredTimer: Codable {
        var state: CountdownState
        var totalDuration: TimeInterval
        var remaining: TimeInterval
        var endDate: Date?
    }

    private let clock: DateProviding
    private let defaults: UserDefaults
    private let sound: () -> Void
    private let storageKey = "countdown.timer.v2"
    private var updateTimer: Timer?
    private var completionSoundPlayed = false

    private(set) var snapshot = TimerSnapshot()
    var onSnapshotChanged: ((TimerSnapshot) -> Void)?

    init(
        clock: DateProviding = SystemDateProvider(),
        defaults: UserDefaults = .standard,
        sound: @escaping () -> Void = {
            if NSSound(named: NSSound.Name("Glass"))?.play() != true {
                NSSound.beep()
            }
        }
    ) {
        self.clock = clock
        self.defaults = defaults
        self.sound = sound
        restore()
    }

    func start() {
        guard updateTimer == nil else { return }
        reconcile()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        updateTimer?.invalidate()
        updateTimer = nil
        persist()
    }

    func start(minutes: Int) {
        let duration = TimeInterval(max(minutes, 1) * 60)
        snapshot = TimerSnapshot(
            state: .running,
            totalDuration: duration,
            remaining: duration,
            endDate: clock.now.addingTimeInterval(duration)
        )
        completionSoundPlayed = false
        publishAndPersist()
    }

    func pause() {
        guard snapshot.state == .running else { return }
        updateRemaining()
        snapshot.state = .paused
        snapshot.endDate = nil
        publishAndPersist()
    }

    func resume() {
        guard snapshot.state == .paused, snapshot.remaining > 0 else { return }
        snapshot.state = .running
        snapshot.endDate = clock.now.addingTimeInterval(snapshot.remaining)
        publishAndPersist()
    }

    func addMinute() {
        switch snapshot.state {
        case .running:
            updateRemaining()
            snapshot.remaining += 60
            snapshot.totalDuration += 60
            snapshot.endDate = clock.now.addingTimeInterval(snapshot.remaining)
        case .paused:
            snapshot.remaining += 60
            snapshot.totalDuration += 60
        case .finished:
            start(minutes: 1)
            return
        case .idle:
            return
        }
        publishAndPersist()
    }

    func cancel() {
        snapshot = TimerSnapshot()
        completionSoundPlayed = false
        publishAndPersist()
    }

    func acknowledge() {
        guard snapshot.state == .finished else { return }
        cancel()
    }

    func reconcile() {
        tick()
    }

    private func tick() {
        guard snapshot.state == .running else { return }
        updateRemaining()
        if snapshot.remaining <= 0 {
            snapshot.state = .finished
            snapshot.remaining = 0
            snapshot.endDate = nil
            if !completionSoundPlayed {
                completionSoundPlayed = true
                sound()
            }
            publishAndPersist()
        } else {
            onSnapshotChanged?(snapshot)
        }
    }

    private func updateRemaining() {
        guard snapshot.state == .running, let endDate = snapshot.endDate else { return }
        snapshot.remaining = max(endDate.timeIntervalSince(clock.now), 0)
    }

    private func restore() {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(StoredTimer.self, from: data) else { return }
        snapshot = TimerSnapshot(
            state: stored.state,
            totalDuration: stored.totalDuration,
            remaining: stored.remaining,
            endDate: stored.endDate
        )
        completionSoundPlayed = stored.state == .finished
        if snapshot.state == .running {
            updateRemaining()
            if snapshot.remaining <= 0 {
                snapshot.state = .finished
                snapshot.endDate = nil
                completionSoundPlayed = true
            }
        }
    }

    private func publishAndPersist() {
        persist()
        onSnapshotChanged?(snapshot)
    }

    private func persist() {
        if snapshot.state == .idle {
            defaults.removeObject(forKey: storageKey)
            return
        }
        let stored = StoredTimer(
            state: snapshot.state,
            totalDuration: snapshot.totalDuration,
            remaining: snapshot.remaining,
            endDate: snapshot.endDate
        )
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

@MainActor
protocol CalendarProviding: AnyObject {
    var snapshot: CalendarSnapshot { get }
    var onSnapshotChanged: ((CalendarSnapshot) -> Void)? { get set }

    func start()
    func stop()
    func requestAccess() async
    func refresh()
    func refresh(for date: Date)
}

@MainActor
final class EventKitCalendarProvider: CalendarProviding {
    private let store: EKEventStore
    private let clock: DateProviding
    private var observers: [NSObjectProtocol] = []
    private var midnightTimer: Timer?
    private var displayedDate: Date

    private(set) var snapshot = CalendarSnapshot()
    var onSnapshotChanged: ((CalendarSnapshot) -> Void)?

    init(store: EKEventStore = EKEventStore(), clock: DateProviding = SystemDateProvider()) {
        self.store = store
        self.clock = clock
        self.displayedDate = clock.now
        updateAccessState()
    }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.scheduleMidnightRefresh()
            }
        })
        updateAccessState()
        if snapshot.access == .authorized { refresh() }
        scheduleMidnightRefresh()
    }

    func stop() {
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
        midnightTimer?.invalidate()
        midnightTimer = nil
    }

    func requestAccess() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            snapshot.access = granted ? .authorized : .denied
            snapshot.errorMessage = nil
            publish()
            if granted { refresh() }
        } catch {
            snapshot.access = .error
            snapshot.errorMessage = error.localizedDescription
            publish()
        }
    }

    func refresh() {
        refresh(for: displayedDate)
    }

    func refresh(for date: Date) {
        displayedDate = date
        snapshot.displayedDate = date
        updateAccessState()
        guard snapshot.access == .authorized else {
            snapshot.events = []
            snapshot.accountNames = []
            publish()
            return
        }

        let calendar = Calendar.current
        let startOfSelectedDay = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: clock.now)
        let intervalStart = startOfSelectedDay == today ? clock.now : startOfSelectedDay
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfSelectedDay) ?? date
        let predicate = store.predicateForEvents(withStart: intervalStart, end: endOfDay, calendars: nil)
        snapshot.accountNames = Array(Set(
            store.calendars(for: .event)
                .map(\.source.title)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )).sorted()
        snapshot.events = store.events(matching: predicate)
            .filter { $0.endDate >= intervalStart }
            .sorted { $0.startDate < $1.startDate }
            .map(Self.mapEvent)
        snapshot.errorMessage = nil
        publish()
    }

    private func updateAccessState() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            snapshot.access = .authorized
        case .denied:
            snapshot.access = .denied
        case .restricted:
            snapshot.access = .restricted
        case .notDetermined, .writeOnly:
            snapshot.access = .preview
        @unknown default:
            snapshot.access = .error
        }
    }

    private static func mapEvent(_ event: EKEvent) -> CalendarEventSnapshot {
        let color = NSColor(cgColor: event.calendar.cgColor)?.usingColorSpace(.deviceRGB)
        return CalendarEventSnapshot(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title?.isEmpty == false ? event.title : "Untitled event",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            color: CalendarEventColor(
                red: Double(color?.redComponent ?? 0.18),
                green: Double(color?.greenComponent ?? 0.55),
                blue: Double(color?.blueComponent ?? 1)
            )
        )
    }

    private func scheduleMidnightRefresh() {
        midnightTimer?.invalidate()
        let calendar = Calendar.current
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: clock.now)) ?? clock.now.addingTimeInterval(86_400)
        midnightTimer = Timer.scheduledTimer(withTimeInterval: max(nextDay.timeIntervalSince(clock.now) + 1, 1), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.scheduleMidnightRefresh()
            }
        }
    }

    private func publish() {
        onSnapshotChanged?(snapshot)
    }
}
