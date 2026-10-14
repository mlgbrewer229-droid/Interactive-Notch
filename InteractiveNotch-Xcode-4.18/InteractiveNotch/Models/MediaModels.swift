import AppKit
import Foundation

struct MediaSnapshot {
    var integrationAvailable = false
    var hasMedia = false
    var title = ""
    var artist = ""
    var album = ""
    var bundleIdentifier = ""
    var artwork: NSImage?
    var duration: TimeInterval = 0
    var elapsedTime: TimeInterval = 0
    var playbackRate: Double = 0
    var isPlaying = false
    var updatedAt = Date()

    var sourceBundleIdentifier: String? {
        guard hasMedia else { return nil }
        let source = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? nil : source
    }

    func estimatedElapsedTime(at date: Date) -> TimeInterval {
        guard hasMedia else { return 0 }
        let advanced = isPlaying ? date.timeIntervalSince(updatedAt) * max(playbackRate, 1) : 0
        return min(max(elapsedTime + advanced, 0), max(duration, 0))
    }
}

enum MediaSourceApplication {
    // Resolve only the reported player. An unknown source must not launch an
    // unrelated installed music app (including when Spotify is installed).
    static func url(for snapshot: MediaSnapshot, resolve: (String) -> URL?) -> URL? {
        guard let source = snapshot.sourceBundleIdentifier else { return nil }
        return resolve(source)
    }
}

struct BatterySnapshot: Equatable {
    var isAvailable = false
    var percentage = 0
    var isCharging = false
    var isOnExternalPower = false
    var timeRemaining: TimeInterval?

    var symbolName: String {
        if isCharging { return "battery.100percent.bolt" }
        switch percentage {
        case 76...: return "battery.100percent"
        case 51...: return "battery.75percent"
        case 26...: return "battery.50percent"
        case 1...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    var timeRemainingDescription: String {
        if isOnExternalPower || isCharging { return "On power" }
        guard let timeRemaining, timeRemaining.isFinite, timeRemaining > 0 else { return "Calculating" }
        let totalMinutes = Int((timeRemaining / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m left" }
        return "\(hours)h \(minutes)m left"
    }
}

enum VolumeMath {
    static func clamped(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
