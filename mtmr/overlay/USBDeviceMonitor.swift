import Cocoa
import IOKit
import CoreGraphics

final class USBDeviceMonitor {
    static let shared = USBDeviceMonitor()
    // Apple's 35 W charger also publishes USB2/USB3 transports ~0.6 s after the power edge (Verified in the
    // kernel log 2026-10-19), so only video/Thunderbolt transports count; real USB data devices arrive as IOUSBHostDevice.
    // #SUGGEST_VERIFY: Test repeated USB-C attaches and power-only chargers on this Mac and other models.
    static let accessoryTransportClasses = [
        "IOPortTransportStateDisplayPort", "IOPortTransportStateCIO"
    ]
    private var notificationPort: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var transportIterators: [io_iterator_t] = []
    private var lastConnection: TimeInterval = -.infinity
    private var watchingDisplays = false
    private var connectedDisplays = Set<CGDirectDisplayID>()
    private var lastDisplayConnections: [CGDirectDisplayID: TimeInterval] = [:]

    private init() {}

    func start() {
        startDisplays()
        guard notificationPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMasterPortDefault) else {
            NSLog("MTMR USB monitor could not create notification port")
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
            IOServiceMatching("IOUSBHostDevice"), { context, iterator in
                guard let context = context else { return }
                Unmanaged<USBDeviceMonitor>.fromOpaque(context).takeUnretainedValue().drain(iterator, notify: true)
            }, context, &iterator)
        guard status == KERN_SUCCESS,
              let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            NSLog("MTMR USB monitor registration failed: %d", status)
            if iterator != 0 { IOObjectRelease(iterator); iterator = 0 }
            IONotificationPortDestroy(port)
            return
        }
        notificationPort = port
        drain(iterator, notify: false)
        startTransports(port)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func startTransports(_ port: IONotificationPortRef) {
        let context = Unmanaged.passUnretained(self).toOpaque()
        for serviceClass in Self.accessoryTransportClasses {
            var transportIterator: io_iterator_t = 0
            let status = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
                IOServiceMatching(serviceClass), { context, iterator in
                    guard let context = context else { return }
                    Unmanaged<USBDeviceMonitor>.fromOpaque(context).takeUnretainedValue().drainTransport(iterator, notify: true)
                }, context, &transportIterator)
            guard status == KERN_SUCCESS else {
                NSLog("MTMR USB transport monitor registration failed for %@: %d", serviceClass, status)
                if transportIterator != 0 { IOObjectRelease(transportIterator) }
                continue
            }
            transportIterators.append(transportIterator)
            drainTransport(transportIterator, notify: false)
        }
    }

    private func drainTransport(_ iterator: io_iterator_t, notify: Bool) {
        var transport = IOIteratorNext(iterator)
        while transport != 0 {
            IOObjectRelease(transport)
            if notify { publishIfEligible(true) }
            transport = IOIteratorNext(iterator)
        }
    }

    private func startDisplays() {
        guard !watchingDisplays else { return }
        var displayCount: UInt32 = 0
        var status = CGGetOnlineDisplayList(0, nil, &displayCount)
        guard status == .success else {
            NSLog("MTMR display enumeration failed: %d", status.rawValue)
            return
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        status = CGGetOnlineDisplayList(displayCount, &displays, &displayCount)
        guard status == .success else {
            NSLog("MTMR display enumeration failed: %d", status.rawValue)
            return
        }
        connectedDisplays = Set(displays.prefix(Int(displayCount)))
        status = CGDisplayRegisterReconfigurationCallback({ display, flags, context in
            guard let context = context else { return }
            let monitor = Unmanaged<USBDeviceMonitor>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { monitor.displayChanged(display, flags: flags) }
        }, Unmanaged.passUnretained(self).toOpaque())
        watchingDisplays = status == .success
        if !watchingDisplays { NSLog("MTMR display callback registration failed: %d", status.rawValue) }
    }

    static func shouldAnimateDisplay(flags: CGDisplayChangeSummaryFlags, builtIn: Bool, alreadyConnected: Bool) -> Bool {
        guard !flags.contains(.beginConfigurationFlag) else { return false }
        guard flags.contains(.addFlag) else { return false }
        guard !builtIn else { return false }
        return !alreadyConnected
    }

    static func passesDebounce(now: TimeInterval, lastEvent: TimeInterval, interval: TimeInterval) -> Bool {
        return now - lastEvent >= interval
    }

    private func displayChanged(_ display: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        guard !flags.contains(.beginConfigurationFlag) else { return }
        let eligible = Self.shouldAnimateDisplay(flags: flags, builtIn: CGDisplayIsBuiltin(display) != 0,
                                                 alreadyConnected: connectedDisplays.contains(display))
        if flags.contains(.removeFlag) { connectedDisplays.remove(display) }
        guard flags.contains(.addFlag) else { return }
        connectedDisplays.insert(display)
        guard eligible else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let previousConnection = lastDisplayConnections[display] ?? -.infinity
        lastDisplayConnections[display] = now
        // #COMPLETION_DRIVE: Wake/reconnect noise uses the same display ID and arrives within five seconds.
        // #SUGGEST_VERIFY: Test display-only USB-C connect, mirroring changes and sleep/wake on the real Mac.
        guard Self.passesDebounce(now: now, lastEvent: previousConnection, interval: 5) else { return }
        publishIfEligible(true)
    }

    static func shouldAnimate(properties: [String: Any], ancestors: [[String: Any]] = []) -> Bool {
        guard !isInternal(properties) else { return false }
        guard !ancestors.contains(where: isInternal) else { return false }
        let deviceClass = (properties["bDeviceClass"] as? NSNumber)?.intValue
        guard deviceClass != 9 else { return false }
        // #COMPLETION_DRIVE: Billboard-only (class 17) devices describe USB-C alternate-mode/PD failures, not usable peripherals.
        // #SUGGEST_VERIFY: Test a PD-only adapter and a USB-C dock on this Mac.
        guard deviceClass != 17 else { return false }
        return true
    }

    private static func isInternal(_ properties: [String: Any]) -> Bool {
        if properties["Built-In"] as? Bool == true { return true }
        if properties["built-in"] as? Bool == true { return true }
        if let marker = properties["built-in"] as? Data, marker.contains(where: { $0 != 0 }) { return true }
        // #COMPLETION_DRIVE: Internal USB devices advertise non-removable ports; no IOUSBHostDevice existed in the M1 probe, so locationID alone cannot identify an internal port.
        // #SUGGEST_VERIFY: Verify Built-In/USB Device Internal/USB Device Removable on hardware that exposes internal USB devices; never blacklist the external controller's locationID 0.
        if properties["USB Device Internal"] as? Bool == true { return true }
        if let removable = properties["USB Device Removable"] as? String {
            return removable.lowercased() == "no"
        }
        return false
    }

    private func drain(_ iterator: io_iterator_t, notify: Bool) {
        var device = IOIteratorNext(iterator)
        while device != 0 {
            let eligible = Self.shouldAnimate(properties: properties(device), ancestors: ancestors(device))
            IOObjectRelease(device)
            if notify { publishIfEligible(eligible) }
            device = IOIteratorNext(iterator)
        }
    }

    private func publishIfEligible(_ eligible: Bool) {
        guard eligible else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard Self.passesDebounce(now: now, lastEvent: lastConnection, interval: 2) else { return }
        lastConnection = now
        // Charger plugged in (directly or through an adapter): the green burst wins. A charger edge that
        // arrives after the blue burst fades the blue out (NotificationLayoutView.playParticles).
        guard now - ChargingMonitor.shared.lastConnection > 3 else { return }
        NotificationCenter.default.post(name: Notification.Name("MTMRParticles"), object: nil, userInfo: ["preset": "usb"])
    }

    private func properties(_ entry: io_registry_entry_t) -> [String: Any] {
        var dictionary: Unmanaged<CFMutableDictionary>?
        let status = IORegistryEntryCreateCFProperties(entry, &dictionary, kCFAllocatorDefault, 0)
        guard status == KERN_SUCCESS else {
            NSLog("MTMR USB monitor could not read device properties: %d", status)
            return ["Built-In": true]
        }
        return dictionary?.takeRetainedValue() as? [String: Any] ?? ["Built-In": true]
    }

    private func ancestors(_ device: io_registry_entry_t) -> [[String: Any]] {
        var ancestors: [[String: Any]] = []
        var parent: io_registry_entry_t = 0
        var status = IORegistryEntryGetParentEntry(device, kIOServicePlane, &parent)
        while status == KERN_SUCCESS {
            // Stop at the USB controller: its platform ancestors are built in even for external ports.
            if IOObjectConformsTo(parent, "IOUSBHostController") != 0 {
                IOObjectRelease(parent)
                break
            }
            if IOObjectConformsTo(parent, "IOUSBHostDevice") != 0 {
                ancestors.append(properties(parent))
            }
            if IOObjectConformsTo(parent, "IOUSBHostPort") != 0 {
                ancestors.append(properties(parent))
            }
            var nextParent: io_registry_entry_t = 0
            status = IORegistryEntryGetParentEntry(parent, kIOServicePlane, &nextParent)
            IOObjectRelease(parent)
            parent = nextParent
        }
        return ancestors
    }
}
