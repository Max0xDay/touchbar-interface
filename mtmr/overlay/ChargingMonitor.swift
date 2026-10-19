import Cocoa
import IOKit.ps

final class ChargingMonitor {
    static let shared = ChargingMonitor()

    static let chargingChanged = Notification.Name("MTMRChargingChanged")
    private(set) var isCharging = false
    private var previewEnabled = false
    var shouldTrickle: Bool { previewEnabled || isCharging }
    private var previewObserver: NSObjectProtocol?
    private var runLoopSource: CFRunLoopSource?
    private var adapterConnected: Bool?
    private(set) var lastConnection: TimeInterval = -.infinity

    private init() {}

    func start() {
        guard runLoopSource == nil else { return }
        let state = readPowerState()
        adapterConnected = state?.connected
        isCharging = state?.charging ?? false
        previewObserver = NotificationCenter.default.addObserver(forName: Notification.Name("MTMRTricklePreview"), object: nil, queue: .main) { [weak self] notification in
            guard let self = self else { return }
            self.previewEnabled = notification.userInfo?["trickle"] as? Bool ?? false
            NotificationCenter.default.post(name: Self.chargingChanged, object: nil)
        }
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
        guard let state = readPowerState() else { return }
        let connected = state.connected
        let previouslyConnected = adapterConnected
        adapterConnected = connected
        let chargingChanged = isCharging != state.charging
        isCharging = state.charging
        defer {
            if chargingChanged { NotificationCenter.default.post(name: Self.chargingChanged, object: nil) }
        }
        guard previouslyConnected == false else { return }
        guard connected else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastConnection >= 3 else { return }
        lastConnection = now
        NotificationCenter.default.post(name: Notification.Name("MTMRParticles"), object: nil)
    }

    static func charging(connected: Bool, description: [String: Any]) -> Bool {
        guard connected else { return false }
        // Adapter connected and below full is enough: macOS charge holds (IsCharging false) still trickle.
        guard let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int else { return false }
        guard maximum > 0 else { return false }
        return current < maximum
    }

    private func readPowerState() -> (connected: Bool, charging: Bool)? {
        guard let information = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let providingSource = IOPSGetProvidingPowerSourceType(information)?.takeUnretainedValue() else {
            NSLog("MTMR charging monitor could not read power-source state")
            return nil
        }
        let connected = providingSource as String == kIOPSACPowerValue
        let sources = IOPSCopyPowerSourcesList(information)?.takeRetainedValue() as? [CFTypeRef] ?? []
        let charging = sources.contains { source in
            guard let description = IOPSGetPowerSourceDescription(information, source)?.takeUnretainedValue() as? [String: Any] else { return false }
            return Self.charging(connected: connected, description: description)
        }
        return (connected, charging)
    }
}
