import Cocoa
import IOKit.ps

final class ChargingMonitor {
    static let shared = ChargingMonitor()

    private var runLoopSource: CFRunLoopSource?
    private var adapterConnected: Bool?
    private var lastConnection: TimeInterval = -.infinity

    private init() {}

    func start() {
        guard runLoopSource == nil else { return }
        adapterConnected = readAdapterConnected()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            Unmanaged<ChargingMonitor>.fromOpaque(context).takeUnretainedValue().powerSourceChanged()
        }, context)?.takeRetainedValue() else {
            NSLog("MTMR charging monitor could not create power-source notification source")
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func powerSourceChanged() {
        guard let connected = readAdapterConnected() else { return }
        let previouslyConnected = adapterConnected
        adapterConnected = connected
        guard previouslyConnected == false else { return }
        guard connected else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastConnection >= 3 else { return }
        lastConnection = now
        NotificationCenter.default.post(name: Notification.Name("MTMRParticles"), object: nil)
    }

    private func readAdapterConnected() -> Bool? {
        guard let information = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let providingSource = IOPSGetProvidingPowerSourceType(information)?.takeUnretainedValue() else {
            NSLog("MTMR charging monitor could not read power-source state")
            return nil
        }
        return providingSource as String == kIOPSACPowerValue
    }
}
