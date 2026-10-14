import AudioToolbox
import CoreAudio
import Foundation

@MainActor
protocol SystemVolumeControlling: AnyObject {
    var volume: Float { get }
    var isAvailable: Bool { get }
    var onVolumeChanged: ((Float, Bool) -> Void)? { get set }

    func start()
    func stop()
    func setVolume(_ value: Float)
    func toggleMute()
}

@MainActor
final class SystemVolumeController: SystemVolumeControlling {
    private(set) var volume: Float = 0
    private(set) var isAvailable = false
    var onVolumeChanged: ((Float, Bool) -> Void)?

    private var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var lastAudibleVolume: Float = 0.5
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var volumeListener: AudioObjectPropertyListenerBlock?

    func start() {
        installDefaultDeviceListener()
        reconnectOutputDevice()
    }

    func stop() {
        removeVolumeListener()
        removeDefaultDeviceListener()
    }

    func setVolume(_ value: Float) {
        guard isAvailable else { return }
        var newValue = VolumeMath.clamped(value)
        var address = volumePropertyAddress
        let status = AudioObjectSetPropertyData(
            outputDeviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &newValue
        )
        if status == noErr {
            // Moving a slider out of silence also clears the hardware mute bit.
            if newValue > 0 {
                var mute = UInt32(0)
                var muteAddress = mutePropertyAddress
                if AudioObjectHasProperty(outputDeviceID, &muteAddress) {
                    AudioObjectSetPropertyData(outputDeviceID, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute)
                }
            }
            readVolume()
        }
    }

    func toggleMute() {
        if volume > 0.01 {
            lastAudibleVolume = volume
            setVolume(0)
        } else {
            setVolume(max(lastAudibleVolume, 0.25))
        }
    }

    private var volumePropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private var mutePropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private func reconnectOutputDevice() {
        removeVolumeListener()
        outputDeviceID = Self.defaultOutputDevice()
        guard outputDeviceID != AudioObjectID(kAudioObjectUnknown) else {
            isAvailable = false
            publish()
            return
        }

        var address = volumePropertyAddress
        guard AudioObjectHasProperty(outputDeviceID, &address) else {
            isAvailable = false
            publish()
            return
        }

        isAvailable = true
        readVolume()
        installVolumeListener()
    }

    private func readVolume() {
        guard isAvailable else { return }
        var value = Float32.zero
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = volumePropertyAddress
        let status = AudioObjectGetPropertyData(outputDeviceID, &address, 0, nil, &size, &value)
        if status == noErr {
            volume = VolumeMath.clamped(value)
            if volume > 0.01 { lastAudibleVolume = volume }
            var muted = UInt32(0)
            var muteSize = UInt32(MemoryLayout<UInt32>.size)
            var muteAddress = mutePropertyAddress
            if AudioObjectHasProperty(outputDeviceID, &muteAddress),
               AudioObjectGetPropertyData(outputDeviceID, &muteAddress, 0, nil, &muteSize, &muted) == noErr,
               muted != 0 {
                volume = 0
            }
        } else {
            isAvailable = false
        }
        publish()
    }

    private func installDefaultDeviceListener() {
        guard defaultDeviceListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.reconnectOutputDevice() }
        }
        defaultDeviceListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
    }

    private func removeDefaultDeviceListener() {
        guard let listener = defaultDeviceListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
        defaultDeviceListener = nil
    }

    private func installVolumeListener() {
        guard volumeListener == nil, isAvailable else { return }
        var address = volumePropertyAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.readVolume() }
        }
        volumeListener = listener
        AudioObjectAddPropertyListenerBlock(outputDeviceID, &address, DispatchQueue.main, listener)
        var muteAddress = mutePropertyAddress
        if AudioObjectHasProperty(outputDeviceID, &muteAddress) {
            AudioObjectAddPropertyListenerBlock(outputDeviceID, &muteAddress, DispatchQueue.main, listener)
        }
    }

    private func removeVolumeListener() {
        guard let listener = volumeListener,
              outputDeviceID != AudioObjectID(kAudioObjectUnknown) else {
            volumeListener = nil
            return
        }
        var address = volumePropertyAddress
        AudioObjectRemovePropertyListenerBlock(outputDeviceID, &address, DispatchQueue.main, listener)
        var muteAddress = mutePropertyAddress
        if AudioObjectHasProperty(outputDeviceID, &muteAddress) {
            AudioObjectRemovePropertyListenerBlock(outputDeviceID, &muteAddress, DispatchQueue.main, listener)
        }
        volumeListener = nil
    }

    private func publish() {
        onVolumeChanged?(volume, isAvailable)
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : AudioObjectID(kAudioObjectUnknown)
    }
}
