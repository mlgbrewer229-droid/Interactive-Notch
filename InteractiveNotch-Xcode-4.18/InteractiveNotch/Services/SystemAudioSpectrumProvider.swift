import Accelerate
import CoreAudio
import Foundation

enum AudioSpectrumStatus: Equatable {
    case stopped
    case starting
    case active
    case failed(OSStatus)

    var label: String {
        switch self {
        case .stopped: return "Spectrum stopped"
        case .starting: return "Waiting for system audio…"
        case .active: return "Live system-audio spectrum"
        case .failed(let code) where Self.isPermissionFailure(code):
            return "Allow System Audio Recording in Settings"
        case .failed(let code):
            return "Spectrum unavailable (\(Self.readableCode(code)))"
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var isPermissionFailure: Bool {
        if case .failed(let code) = self { return Self.isPermissionFailure(code) }
        return false
    }

    private static func readableCode(_ code: OSStatus) -> String {
        let value = UInt32(bitPattern: code)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        if bytes.allSatisfy({ (32...126).contains($0) }) {
            return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")'"
        }
        return String(code)
    }

    private static func isPermissionFailure(_ code: OSStatus) -> Bool {
        let permission = OSStatus(bitPattern: 0x7065_726d) // 'perm'
        let denied = OSStatus(bitPattern: 0x6465_6e79) // 'deny'
        return code == permission || code == denied || code == -54
    }
}

@MainActor
protocol AudioSpectrumProviding: AnyObject {
    var levels: [Double] { get }
    var status: AudioSpectrumStatus { get }
    var onLevelsChanged: (([Double]) -> Void)? { get set }
    var onStatusChanged: ((AudioSpectrumStatus) -> Void)? { get set }
    func start()
    func stop()
    func restart()
    func suspendForSleep()
    func resumeAfterWake()
}

@MainActor
final class SystemAudioSpectrumProvider: AudioSpectrumProviding {
    private let engine = CoreAudioTapEngine()
    private var generation = 0
    private var restartTask: DispatchWorkItem?
    private var desiredRunning = false
    private var resumeAfterSleep = false
    private var automaticRecoveryAttempts = 0

    private(set) var levels = Array(repeating: 0.08, count: SpectrumAnalyzer.bandCount)
    private(set) var status: AudioSpectrumStatus = .stopped
    var onLevelsChanged: (([Double]) -> Void)?
    var onStatusChanged: ((AudioSpectrumStatus) -> Void)?

    func start() {
        desiredRunning = true
        guard status == .stopped || isFailed else { return }
        restartTask?.cancel()
        restartTask = nil
        generation += 1
        let currentGeneration = generation
        setStatus(.starting)
        engine.start(
            onLevels: { [weak self] measured in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration else { return }
                    let smoothed = zip(self.levels, measured).map { previous, current in
                        current > previous
                            ? current * 0.7 + previous * 0.3
                            : current * 0.22 + previous * 0.78
                    }
                    self.levels = smoothed
                    self.onLevelsChanged?(smoothed)
                    self.automaticRecoveryAttempts = 0
                    if self.status != .active { self.setStatus(.active) }
                }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration else { return }
                    if result != noErr {
                        self.setStatus(.failed(result))
                        self.retryTransientFailure(result)
                    }
                }
            },
            onConfigurationChanged: { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration else { return }
                    self.scheduleAutomaticRestart()
                }
            }
        )
    }

    func stop() {
        desiredRunning = false
        resumeAfterSleep = false
        automaticRecoveryAttempts = 0
        stopCapture()
    }

    func restart() {
        desiredRunning = true
        automaticRecoveryAttempts = 0
        scheduleRestart(after: 0.35, onlyWhenActive: false)
    }

    func suspendForSleep() {
        resumeAfterSleep = desiredRunning && !status.isPermissionFailure
        desiredRunning = false
        if resumeAfterSleep {
            stopCapture()
        } else {
            restartTask?.cancel()
            restartTask = nil
            generation += 1
            engine.stop()
        }
    }

    func resumeAfterWake() {
        guard resumeAfterSleep else { return }
        resumeAfterSleep = false
        desiredRunning = true
        automaticRecoveryAttempts = 0
        scheduleRestart(after: 1.0, onlyWhenActive: false)
    }

    private func stopCapture() {
        restartTask?.cancel()
        restartTask = nil
        generation += 1
        engine.stop()
        levels = Array(repeating: 0.08, count: SpectrumAnalyzer.bandCount)
        onLevelsChanged?(levels)
        setStatus(.stopped)
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private func setStatus(_ newStatus: AudioSpectrumStatus) {
        status = newStatus
        onStatusChanged?(newStatus)
    }

    private func scheduleAutomaticRestart() {
        guard desiredRunning else { return }
        scheduleRestart(after: 0.8, onlyWhenActive: true)
    }

    private func retryTransientFailure(_ code: OSStatus) {
        guard desiredRunning,
              !AudioSpectrumStatus.failed(code).isPermissionFailure,
              automaticRecoveryAttempts < 3 else { return }
        let delays: [TimeInterval] = [1, 3, 8]
        let delay = delays[automaticRecoveryAttempts]
        automaticRecoveryAttempts += 1
        scheduleRestart(after: delay, onlyWhenActive: false)
    }

    private func scheduleRestart(after delay: TimeInterval, onlyWhenActive: Bool) {
        if onlyWhenActive, status != .active { return }
        restartTask?.cancel()
        restartTask = nil

        generation += 1
        engine.stop()
        levels = Array(repeating: 0.08, count: SpectrumAnalyzer.bandCount)
        onLevelsChanged?(levels)
        setStatus(.stopped)

        let task = DispatchWorkItem { [weak self] in
            guard let self, self.desiredRunning else { return }
            self.restartTask = nil
            self.start()
        }
        restartTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
}

private final class CoreAudioTapEngine: @unchecked Sendable {
    typealias Completion = @Sendable (OSStatus) -> Void
    typealias LevelHandler = @Sendable ([Double]) -> Void

    private let lifecycleQueue = DispatchQueue(label: "InteractiveNotch.CoreAudioTap.Lifecycle", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "InteractiveNotch.CoreAudioTap.IO", qos: .userInteractive)
    private let analysisQueue = DispatchQueue(label: "InteractiveNotch.SpectrumAnalysis", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format = AudioStreamBasicDescription()
    private let sampleCapacity = 4_096
    private let sampleStorage: UnsafeMutablePointer<Float>
    // These three properties are confined to ioQueue.
    private var sampleCount = 0
    private var analysisPending = false
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
    private var observedOutputDevice = AudioObjectID(kAudioObjectUnknown)

    init() {
        sampleStorage = .allocate(capacity: sampleCapacity)
        sampleStorage.initialize(repeating: 0, count: sampleCapacity)
    }

    deinit {
        sampleStorage.deinitialize(count: sampleCapacity)
        sampleStorage.deallocate()
    }

    func start(
        onLevels: @escaping LevelHandler,
        completion: @escaping Completion,
        onConfigurationChanged: @escaping @Sendable () -> Void
    ) {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            let result = self.startLocked(
                onLevels: onLevels,
                onConfigurationChanged: onConfigurationChanged
            )
            completion(result)
        }
    }

    func stop() {
        lifecycleQueue.async { [weak self] in self?.stopLocked() }
    }

    private func startLocked(
        onLevels: @escaping LevelHandler,
        onConfigurationChanged: @escaping @Sendable () -> Void
    ) -> OSStatus {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Interactive Notch Spectrum"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var result = AudioHardwareCreateProcessTap(description, &newTapID)
        guard result == noErr else { return result }
        tapID = newTapID

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapUID: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        result = withUnsafeMutablePointer(to: &tapUID) {
            AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &uidSize, $0)
        }
        guard result == noErr else { stopLocked(); return result }

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        result = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &format)
        guard result == noErr else { stopLocked(); return result }
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              format.mChannelsPerFrame > 0,
              format.mSampleRate > 0 else {
            stopLocked()
            return kAudioHardwareUnsupportedOperationError
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Interactive Notch Spectrum",
            kAudioAggregateDeviceUIDKey: "local.InteractiveNotch.Spectrum.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            // Never wait for a future audio event inside AudioDeviceStart.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        result = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard result == noErr else { stopLocked(); return result }
        aggregateID = newAggregateID

        var newIOProcID: AudioDeviceIOProcID?
        ioQueue.sync {
            sampleCount = 0
            analysisPending = false
        }

        result = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateID, ioQueue) {
            [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            guard !self.analysisPending, self.sampleCount < self.sampleCapacity else { return }
            let destination = self.sampleStorage.advanced(by: self.sampleCount)
            let copied = SpectrumAnalyzer.copyMonoSamples(
                from: inputData,
                format: self.format,
                into: destination,
                capacity: self.sampleCapacity - self.sampleCount
            )
            guard copied > 0 else { return }
            self.sampleCount += copied
            guard self.sampleCount == self.sampleCapacity else { return }

            self.analysisPending = true
            let sampleRate = self.format.mSampleRate
            self.analysisQueue.async { [weak self] in
                guard let self else { return }
                let samples = UnsafeBufferPointer(start: self.sampleStorage, count: self.sampleCapacity)
                let levels = SpectrumAnalyzer.levels(samples: samples, sampleRate: sampleRate)
                onLevels(levels)
                self.ioQueue.async { [weak self] in
                    self?.sampleCount = 0
                    self?.analysisPending = false
                }
            }
        }
        guard result == noErr else { stopLocked(); return result }
        guard let newIOProcID else {
            stopLocked()
            return kAudioHardwareUnspecifiedError
        }
        ioProcID = newIOProcID

        result = AudioDeviceStart(aggregateID, ioProcID)
        guard result == noErr else { stopLocked(); return result }

        installConfigurationListeners(onConfigurationChanged: onConfigurationChanged)
        return noErr
    }

    private func installConfigurationListeners(
        onConfigurationChanged: @escaping @Sendable () -> Void
    ) {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemBlock: AudioObjectPropertyListenerBlock = { _, _ in
            onConfigurationChanged()
        }
        if AudioObjectAddPropertyListenerBlock(
            systemObject,
            &defaultOutputAddress,
            lifecycleQueue,
            systemBlock
        ) == noErr {
            systemListener = systemBlock
        }

        var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var outputDevice = AudioObjectID(kAudioObjectUnknown)
        guard AudioObjectGetPropertyData(
            systemObject,
            &defaultOutputAddress,
            0,
            nil,
            &deviceSize,
            &outputDevice
        ) == noErr,
        outputDevice != kAudioObjectUnknown else { return }

        var sampleRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let outputBlock: AudioObjectPropertyListenerBlock = { _, _ in
            onConfigurationChanged()
        }
        if AudioObjectAddPropertyListenerBlock(
            outputDevice,
            &sampleRateAddress,
            lifecycleQueue,
            outputBlock
        ) == noErr {
            observedOutputDevice = outputDevice
            outputDeviceListener = outputBlock
        }
    }

    private func stopLocked() {
        removeConfigurationListeners()
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        analysisQueue.sync {}
        ioQueue.sync {
            sampleCount = 0
            analysisPending = false
        }
        format = AudioStreamBasicDescription()
    }

    private func removeConfigurationListeners() {
        if let systemListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                lifecycleQueue,
                systemListener
            )
            self.systemListener = nil
        }
        if observedOutputDevice != kAudioObjectUnknown, let outputDeviceListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                observedOutputDevice,
                &address,
                lifecycleQueue,
                outputDeviceListener
            )
        }
        outputDeviceListener = nil
        observedOutputDevice = AudioObjectID(kAudioObjectUnknown)
    }
}

enum SpectrumAnalyzer {
    static let bandCount = 8
    private static let fftSize = 4_096
    private static let log2FFTSize = vDSP_Length(12)
    private static let bandEdges: [Double] = [20, 47, 112, 270, 630, 1_500, 3_500, 8_400, 20_000]
    private static let hannWindow: [Float] = {
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        return window
    }()
    private static let fftSetup: FFTSetup = {
        guard let setup = vDSP_create_fftsetup(log2FFTSize, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("Unable to create the audio-spectrum FFT setup")
        }
        return setup
    }()

    static func copyMonoSamples(
        from inputData: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription,
        into destination: UnsafeMutablePointer<Float>,
        capacity: Int
    ) -> Int {
        guard capacity > 0,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32,
              format.mSampleRate > 0 else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        var frameCount = capacity
        var totalChannels = 0
        for buffer in buffers {
            guard buffer.mData != nil, buffer.mDataByteSize > 0 else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let availableFrames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            frameCount = min(frameCount, availableFrames)
            totalChannels += channels
        }
        guard frameCount > 0, totalChannels > 0 else { return 0 }

        for frame in 0..<frameCount { destination[frame] = 0 }
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let pointer = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    destination[frame] += pointer[frame * channels + channel]
                }
            }
        }
        let divisor = Float(totalChannels)
        for frame in 0..<frameCount { destination[frame] /= divisor }
        return frameCount
    }

    static func levels(from inputData: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription) -> [Double]? {
        let capacity = fftSize
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        defer { storage.deallocate() }
        let count = copyMonoSamples(from: inputData, format: format, into: storage, capacity: capacity)
        guard count >= 128 else { return nil }
        return levels(
            samples: UnsafeBufferPointer(start: storage, count: count),
            sampleRate: format.mSampleRate
        )
    }

    static func levels(samples: [Float], sampleRate: Double) -> [Double] {
        samples.withUnsafeBufferPointer { buffer in
            levels(samples: buffer, sampleRate: sampleRate)
        }
    }

    static func levels(samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> [Double] {
        guard samples.count >= 128, sampleRate > 0 else { return Array(repeating: 0.04, count: bandCount) }
        var input = [Float](repeating: 0, count: fftSize)
        let copiedCount = min(samples.count, fftSize)
        for index in 0..<copiedCount {
            let value = samples[index]
            input[index] = value.isFinite ? value : 0
        }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(input, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imaginary = [Float](repeating: 0, count: fftSize / 2)
        var power = [Float](repeating: 0, count: fftSize / 2)
        windowed.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            let complex = base.assumingMemoryBound(to: DSPComplex.self)
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(
                        realp: realBuffer.baseAddress!,
                        imagp: imaginaryBuffer.baseAddress!
                    )
                    vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(fftSize / 2))
                    vDSP_fft_zrip(
                        fftSetup,
                        &split,
                        1,
                        log2FFTSize,
                        FFTDirection(kFFTDirection_Forward)
                    )
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(fftSize / 2))
                }
            }
        }

        let binWidth = sampleRate / Double(fftSize)
        let nyquist = sampleRate / 2
        return (0..<bandCount).map { band in
            let lower = min(bandEdges[band], nyquist)
            let upper = min(bandEdges[band + 1], nyquist)
            // Half-open bands give each FFT bin exactly one home.
            let firstBin = max(Int((lower / binWidth).rounded(.up)), 1)
            let lastBin = min(Int((upper / binWidth).rounded(.up)) - 1, power.count - 1)
            guard lastBin >= firstBin else { return 0.04 }

            var peakPower: Float = 0
            power.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                vDSP_maxv(
                    base.advanced(by: firstBin),
                    1,
                    &peakPower,
                    vDSP_Length(lastBin - firstBin + 1)
                )
            }
            let magnitude = sqrt(max(Double(peakPower), 1e-14)) / Double(fftSize)
            let decibels = 20 * log10(max(magnitude, 1e-7))
            return min(max((decibels + 65) / 55, 0.04), 1)
        }
    }
}
