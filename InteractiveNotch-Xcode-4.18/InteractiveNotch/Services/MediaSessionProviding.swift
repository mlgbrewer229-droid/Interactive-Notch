import AppKit
import Foundation

@MainActor
protocol MediaSessionProviding: AnyObject {
    var snapshot: MediaSnapshot { get }
    var onSnapshotChanged: ((MediaSnapshot) -> Void)? { get set }

    func start()
    func stop()
    func restart()
    func togglePlayPause()
    func previousTrack()
    func nextTrack()
    func seek(to elapsedTime: TimeInterval)
}

@MainActor
struct MediaRemotePayloadDecoder {
    static func snapshot(fromGetResponse data: Data, now: Date = Date()) -> MediaSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        if object is NSNull { return MediaSnapshot(integrationAvailable: true) }
        guard let payload = object as? [String: Any] else { return nil }
        return snapshot(from: payload, now: now)
    }

    static func snapshot(from payload: [String: Any], now: Date = Date()) -> MediaSnapshot {
        guard !payload.isEmpty else {
            return MediaSnapshot(integrationAvailable: true)
        }

        let isPlaying = payload["playing"] as? Bool ?? false
        let playbackRate = number(payload["playbackRate"])
        var snapshot = MediaSnapshot(
            integrationAvailable: true,
            hasMedia: true,
            title: payload["title"] as? String ?? "Unknown title",
            artist: payload["artist"] as? String ?? "Unknown artist",
            album: payload["album"] as? String ?? "",
            bundleIdentifier: payload["bundleIdentifier"] as? String ?? "",
            duration: number(payload["duration"]),
            elapsedTime: number(payload["elapsedTime"]),
            playbackRate: playbackRate == 0 && isPlaying ? 1 : playbackRate,
            isPlaying: isPlaying,
            updatedAt: date(payload["timestamp"]) ?? now
        )

        if let encodedArtwork = payload["artworkData"] as? String,
           let artworkData = Data(base64Encoded: encodedArtwork) {
            snapshot.artwork = NSImage(data: artworkData)
        }
        return snapshot
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// Reads system-wide now-playing data through the bundled MediaRemote Adapter.
///
/// macOS 15.4 and newer reject direct MediaRemote reads from third-party apps.
/// The adapter is loaded by Apple's `/usr/bin/perl` process, which retains the
/// system access required by MediaRemote. The app itself never claims a private
/// entitlement and communicates with the helper only through newline JSON.
@MainActor
final class MediaRemoteSessionProvider: MediaSessionProviding {
    private enum Command: Int {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    private struct AdapterResources {
        let scriptURL: URL
        let frameworkURL: URL

        static func locate(in bundle: Bundle = .main) -> AdapterResources? {
            if let scriptURL = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl"),
               let frameworksURL = bundle.privateFrameworksURL {
                let frameworkURL = frameworksURL.appendingPathComponent("MediaRemoteAdapter.framework")
                if FileManager.default.fileExists(atPath: frameworkURL.path) {
                    return AdapterResources(scriptURL: scriptURL, frameworkURL: frameworkURL)
                }
            }

            // Command-line launches of the app executable do not always give
            // Foundation an application Bundle.main. Resolve Contents from the
            // executable as a development and diagnostics fallback.
            let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let contentsURL = executableURL.deletingLastPathComponent().deletingLastPathComponent()
            let scriptURL = contentsURL
                .appendingPathComponent("Resources")
                .appendingPathComponent("mediaremote-adapter.pl")
            let frameworkURL = contentsURL
                .appendingPathComponent("Frameworks")
                .appendingPathComponent("MediaRemoteAdapter.framework")
            guard FileManager.default.fileExists(atPath: scriptURL.path),
                  FileManager.default.fileExists(atPath: frameworkURL.path) else { return nil }
            return AdapterResources(scriptURL: scriptURL, frameworkURL: frameworkURL)
        }
    }

    private(set) var snapshot = MediaSnapshot()
    var onSnapshotChanged: ((MediaSnapshot) -> Void)?

    private var resources: AdapterResources?
    private var streamProcess: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var commandProcesses: [UUID: Process] = [:]
    private var shouldRun = false
    private var recoveryTask: DispatchWorkItem?
    private var consecutiveFailures = 0
    private let refreshQueue = DispatchQueue(label: "InteractiveNotch.MediaRefresh", qos: .utility)
    private var refreshTimer: Timer?
    private var refreshProcess: Process?
    private var refreshGeneration = 0
    private var streamRevision = 0
    private var emptyRefreshes = 0

    func start() {
        guard streamProcess?.isRunning != true else { return }
        shouldRun = true
        recoveryTask?.cancel()
        recoveryTask = nil
        guard let resources = AdapterResources.locate() else {
            snapshot = MediaSnapshot(integrationAvailable: false)
            publish()
            return
        }
        self.resources = resources
        startRefreshTimer()
        refreshSnapshot()

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            resources.scriptURL.path,
            resources.frameworkURL.path,
            "stream",
            "--no-diff",
            "--debounce=100"
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor in self?.consume(data) }
        }
        // Drain diagnostics so a full stderr pipe cannot stall the adapter.
        // Expected private-framework messages are intentionally not mirrored
        // to the app console.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            Task { @MainActor in
                guard let self, let process, self.streamProcess === process else { return }
                self.finishStream()
            }
        }

        do {
            try process.run()
            streamProcess = process
            self.outputPipe = outputPipe
            self.errorPipe = errorPipe
            snapshot.integrationAvailable = true
            publish()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            snapshot = MediaSnapshot(integrationAvailable: false)
            publish()
            scheduleRecovery()
        }
    }

    func stop() {
        shouldRun = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshGeneration += 1
        if let refreshProcess, refreshProcess.isRunning { refreshProcess.terminate() }
        refreshProcess = nil
        emptyRefreshes = 0
        recoveryTask?.cancel()
        recoveryTask = nil
        consecutiveFailures = 0
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let streamProcess, streamProcess.isRunning {
            streamProcess.terminate()
        }
        streamProcess = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)

        for process in commandProcesses.values where process.isRunning {
            process.terminate()
        }
        commandProcesses.removeAll()
    }

    func restart() {
        stop()
        start()
    }

    func togglePlayPause() {
        runAdapterCommand("send", argument: String(Command.togglePlayPause.rawValue))
    }

    func previousTrack() {
        runAdapterCommand("send", argument: String(Command.previousTrack.rawValue))
    }

    func nextTrack() {
        runAdapterCommand("send", argument: String(Command.nextTrack.rawValue))
    }

    func seek(to elapsedTime: TimeInterval) {
        let value = min(max(elapsedTime, 0), max(snapshot.duration, 0))
        let microseconds = Int64((value * 1_000_000).rounded())
        runAdapterCommand("seek", argument: String(microseconds))
        snapshot.elapsedTime = value
        snapshot.updatedAt = Date()
        publish()
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newlineIndex]
            outputBuffer.removeSubrange(...newlineIndex)
            guard !line.isEmpty else { continue }
            applyAdapterLine(Data(line))
        }
    }

    private func applyAdapterLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "data",
              let payload = object["payload"] as? [String: Any] else {
            return
        }

        snapshot = MediaRemotePayloadDecoder.snapshot(from: payload)
        streamRevision += 1
        emptyRefreshes = 0
        consecutiveFailures = 0
        publish()
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSnapshot() }
        }
    }

    private func refreshSnapshot() {
        guard shouldRun, let resources, refreshProcess?.isRunning != true else { return }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [resources.scriptURL.path, resources.frameworkURL.path, "get"]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let generation = refreshGeneration
        let revision = streamRevision
        do {
            try process.run()
            refreshProcess = process
            refreshQueue.async { [weak self] in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                Task { @MainActor in
                    guard let self, self.shouldRun,
                          self.refreshGeneration == generation,
                          self.refreshProcess === process else { return }
                    self.refreshProcess = nil
                    guard self.streamRevision == revision,
                          let refreshed = MediaRemotePayloadDecoder.snapshot(fromGetResponse: data) else { return }
                    if !refreshed.hasMedia {
                        self.emptyRefreshes += 1
                        guard self.emptyRefreshes >= 2 else { return }
                    } else {
                        self.emptyRefreshes = 0
                    }

                    var reconciled = refreshed
                    if reconciled.hasMedia, reconciled.artwork == nil,
                       reconciled.title == self.snapshot.title,
                       reconciled.artist == self.snapshot.artist,
                       reconciled.album == self.snapshot.album {
                        reconciled.artwork = self.snapshot.artwork
                    }
                    self.snapshot = reconciled
                    self.publish()
                }
            }
        } catch {
            // The live stream can still function when an individual refresh fails.
        }
    }

    private func runAdapterCommand(_ command: String, argument: String) {
        guard let resources else { return }

        let identifier = UUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            resources.scriptURL.path,
            resources.frameworkURL.path,
            command,
            argument
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.commandProcesses[identifier] = nil }
        }

        do {
            try process.run()
            commandProcesses[identifier] = process
        } catch {
            // The stream remains useful even if a single command cannot run.
        }
    }

    private func finishStream() {
        streamProcess = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)
        guard shouldRun else { return }
        snapshot = MediaSnapshot(integrationAvailable: false)
        publish()
        scheduleRecovery()
    }

    private func scheduleRecovery() {
        guard shouldRun, recoveryTask == nil else { return }
        let delays: [TimeInterval] = [1, 2, 5, 15, 30]
        let delay = delays[min(consecutiveFailures, delays.count - 1)]
        consecutiveFailures += 1
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.shouldRun else { return }
            self.recoveryTask = nil
            self.start()
        }
        recoveryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func publish() {
        onSnapshotChanged?(snapshot)
    }

}
