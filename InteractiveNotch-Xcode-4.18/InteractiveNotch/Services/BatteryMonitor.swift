import Foundation
import IOKit.ps

@MainActor
protocol BatteryMonitoring: AnyObject {
    var snapshot: BatterySnapshot { get }
    var onSnapshotChanged: ((BatterySnapshot) -> Void)? { get set }

    func start()
    func stop()
}

@MainActor
final class BatteryMonitor: BatteryMonitoring {
    private(set) var snapshot = BatterySnapshot()
    var onSnapshotChanged: ((BatterySnapshot) -> Void)?

    private var runLoopSource: CFRunLoopSource?

    func start() {
        refresh()
        guard runLoopSource == nil else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.refresh()
            }
        }, context) else { return }

        let source = unmanagedSource.takeRetainedValue()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        guard let source = runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = nil
    }

    private func refresh() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            snapshot = BatterySnapshot()
            publish()
            return
        }

        let estimate = IOPSGetTimeRemainingEstimate()
        let timeRemaining = estimate > 0 && estimate.isFinite ? estimate : nil

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.doubleValue > 0 else { continue }

            let isCharging = (description[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false
            snapshot = BatterySnapshot(
                isAvailable: true,
                percentage: Int((current.doubleValue / maximum.doubleValue * 100).rounded()),
                isCharging: isCharging,
                isOnExternalPower: isCharging || (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                timeRemaining: timeRemaining
            )
            publish()
            return
        }

        snapshot = BatterySnapshot()
        publish()
    }

    private func publish() {
        onSnapshotChanged?(snapshot)
    }
}
