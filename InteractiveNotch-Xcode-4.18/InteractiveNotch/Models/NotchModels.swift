import Foundation

enum DashboardModule: String, CaseIterable, Codable, Identifiable {
    case media
    case today
    case timer
    case system
    case weather
    case mirror

    var id: String { rawValue }

    var title: String {
        switch self {
        case .media: return "Media"
        case .today: return "Today"
        case .timer: return "Timer"
        case .system: return "Battery"
        case .weather: return "Weather"
        case .mirror: return "Mirror"
        }
    }

    var symbolName: String {
        switch self {
        case .media: return "waveform"
        case .today: return "calendar"
        case .timer: return "timer"
        case .system: return "battery.100percent"
        case .weather: return "cloud.sun"
        case .mirror: return "web.camera"
        }
    }
}

enum NotchPresentation: Equatable {
    case hidden
    case startup
    case compactMedia
    case compactTimer
    case compactMediaAndTimer
    case compactCharging
    case timerFinished
    case dashboard
    case detail(DashboardModule)
    case customize
    case mirror

    var isExpanded: Bool {
        switch self {
        case .dashboard, .detail, .customize, .mirror: return true
        default: return false
        }
    }

    var isCompact: Bool {
        switch self {
        case .compactMedia, .compactTimer, .compactMediaAndTimer, .compactCharging, .timerFinished: return true
        default: return false
        }
    }
}

enum DashboardWidgetSize: String, Codable, Equatable {
    case small
    case large

    var columns: Int { self == .large ? 2 : 1 }
}

struct DashboardWidget: Codable, Equatable, Identifiable {
    let module: DashboardModule
    var size: DashboardWidgetSize
    var id: DashboardModule { module }
}

enum DashboardLayout {
    // Columns always occupy the same dashboard height. A two-item column
    // stacks its widgets instead of expanding the notch downward.
    static func columns(for widgets: [DashboardWidget]) -> [[DashboardWidget]] {
        let selected = Array(widgets.prefix(4))
        guard selected.count > 2 else { return selected.map { [$0] } }

        if selected.count == 3 { return selected.map { [$0] } }

        let largeCount = 2
        let large = selected.sorted { priority($0.module) < priority($1.module) }.prefix(largeCount)
        let largeModules = Set(large.map(\.module))
        let small = selected.filter { !largeModules.contains($0.module) }

        return [[large[large.startIndex]], small, [large[large.index(after: large.startIndex)]]]
    }

    static func height(for widgets: [DashboardWidget], notchHeight: CGFloat) -> CGFloat {
        190
    }

    static func priority(_ module: DashboardModule) -> Int {
        switch module {
        case .today: return 0
        case .weather: return 1
        case .media: return 2
        case .timer: return 3
        case .mirror: return 4
        case .system: return 5
        }
    }
}

enum CountdownState: String, Codable, Equatable {
    case idle
    case running
    case paused
    case finished
}

struct TimerSnapshot: Equatable {
    var state: CountdownState = .idle
    var totalDuration: TimeInterval = 0
    var remaining: TimeInterval = 0
    var endDate: Date?

    var isActive: Bool { state == .running || state == .paused }
    var isFinished: Bool { state == .finished }
}

enum CalendarAccessState: String, Equatable {
    case preview
    case authorized
    case denied
    case restricted
    case error
}

struct CalendarEventSnapshot: Equatable, Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let color: CalendarEventColor
}

struct CalendarEventColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    static let defaultBlue = CalendarEventColor(red: 0.18, green: 0.55, blue: 1)
}

struct CalendarSnapshot: Equatable {
    var access: CalendarAccessState = .preview
    var displayedDate = Date()
    var events: [CalendarEventSnapshot] = []
    var accountNames: [String] = []
    var errorMessage: String?
}

enum WeatherAccessState: Equatable {
    case preview, requestingPermission, loading, ready, denied, restricted, error
}

enum WeatherForecastMode: String, CaseIterable, Identifiable {
    case days
    case hours
    var id: String { rawValue }
}

enum ForecastPaging {
    static let itemsPerPage = 5

    static func pageCount(for itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return (itemCount - 1) / itemsPerPage + 1
    }
}

enum MirrorCameraState: Equatable {
    case preview, requestingPermission, starting, running, denied, unavailable
}

struct WeatherHour: Equatable, Identifiable {
    let time: Date
    let temperature: Int
    let precipitationChance: Int
    let conditionCode: Int
    var isDay: Bool = true
    var id: Date { time }
}

struct WeatherDay: Equatable, Identifiable {
    let date: Date
    let high: Int
    let low: Int
    let precipitationChance: Int
    let conditionCode: Int
    var id: Date { date }
}

struct WeatherSnapshot: Equatable {
    var access: WeatherAccessState = .preview
    var placeName: String?
    var temperature: Int = 0
    var usesFahrenheit = true
    var conditionCode = 0
    var isDay = true
    var hours: [WeatherHour] = []
    var days: [WeatherDay] = []
    var updatedAt: Date?

    func hours(on date: Date, calendar: Calendar = .current) -> [WeatherHour] {
        guard let interval = calendar.dateInterval(of: .day, for: date) else { return [] }
        return hours.filter { $0.time >= interval.start && $0.time < interval.end }
            .sorted { $0.time < $1.time }
    }

    func forecastHours(on date: Date, at now: Date, calendar: Calendar = .current) -> [WeatherHour] {
        let selected = hours(on: date, calendar: calendar)
        guard calendar.isDate(date, inSameDayAs: now) else { return selected }
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return selected.filter { $0.time >= currentHour }
    }

    func summaryHour(on date: Date, at now: Date, page: Int, calendar: Calendar = .current) -> WeatherHour? {
        let selected = forecastHours(on: date, at: now, calendar: calendar)
        guard !selected.isEmpty else { return nil }
        let safePage = min(max(page, 0), ForecastPaging.pageCount(for: selected.count) - 1)
        return selected[safePage * ForecastPaging.itemsPerPage]
    }
}

struct CountdownReading {
    let seconds: Double
    var formatted: String { "\(Int(seconds) / 60):" + String(format: "%02d", Int(seconds) % 60) }

    init(seconds: TimeInterval) {
        self.seconds = seconds.isFinite && seconds >= 0 && seconds < Double(Int.max / 2) ? seconds.rounded(.up) : 0
    }
}

enum PlaybackFeedback: Equatable {
    case play, pause

    static let duration: TimeInterval = 0.3
}

/// Stable identities let the same eight bars morph into a transport glyph.
/// Geometry is confined to the existing 34 × 22-point compact spectrum wing.
struct SpectrumBarGeometry: Equatable {
    let centerX: CGFloat
    let width: CGFloat
    let height: CGFloat

    static func bar(at index: Int, level: Double, playing: Bool, feedback: PlaybackFeedback?) -> Self {
        let index = min(max(index, 0), 7)
        switch feedback {
        case .pause:
            let origin: CGFloat = index < 4 ? 9 : 20.2
            return Self(centerX: origin + CGFloat(index % 4) * 1.6, width: 1.7, height: 16)
        case .play:
            return Self(centerX: 11 + CGFloat(index) * 1.6, width: 1.8, height: 18 - CGFloat(index) * 2.25)
        case nil:
            let safeLevel = level.isFinite ? min(max(level, 0), 1) : 0
            return Self(centerX: 1.6 + CGFloat(index) * 4.4, width: 2, height: playing ? 2 + pow(safeLevel, 0.8) * 18 : 2)
        }
    }
}

enum WeatherCondition {
    static func description(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Foggy"
        case 51...57: return "Drizzle"
        case 61...67, 80...82: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...99: return "Thunderstorms"
        default: return "Cloudy"
        }
    }

    static func symbol(for code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}
