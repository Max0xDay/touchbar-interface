import Foundation
import CoreGraphics
import Darwin
import IOKit
import IOKit.graphics

/// Polled only while the universal control page is shown.
final class DisplayBrightnessController {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private(set) var brightness: Double?
    var changed: (() -> Void)?
    private var refreshTimer: Timer?
    private let framework: UnsafeMutableRawPointer?
    private let getBrightness: GetBrightness?
    private let setBrightnessValue: SetBrightness?
    private var loggedFailures = Set<String>()
    private var displayIdentifier = CGMainDisplayID()

    init() {
        framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        if let framework = framework,
           let getter = dlsym(framework, "DisplayServicesGetBrightness"),
           let setter = dlsym(framework, "DisplayServicesSetBrightness") {
            // Private DisplayServices signatures, verified on M1 / macOS 14.7.6; recheck after macOS upgrades.
            getBrightness = unsafeBitCast(getter, to: GetBrightness.self)
            setBrightnessValue = unsafeBitCast(setter, to: SetBrightness.self)
        } else {
            getBrightness = nil
            setBrightnessValue = nil
            logOnce("DisplayServices unavailable; trying IODisplay")
        }
    }

    func start() {
        stop()
        displayIdentifier = preferredDisplayIdentifier()
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    deinit {
        stop()
        if let framework = framework { dlclose(framework) }
    }

    func setBrightness(_ brightness: Double) {
        guard self.brightness != nil else { return }
        let level = Float(VolumeControlGeometry.clamped(brightness))
        if let setter = setBrightnessValue {
            guard succeeded(setter(displayIdentifier, level), operation: "set brightness") else { return }
        } else {
            guard let service = displayService() else { return }
            defer { IOObjectRelease(service) }
            let status = IODisplaySetFloatParameter(service, 1, kIODisplayBrightnessKey as CFString, level)
            guard succeeded(status, operation: "set brightness") else { return }
        }
        self.brightness = Double(level)
    }

    private func refresh() {
        var level: Float = 0
        if let getter = getBrightness {
            let status = getter(displayIdentifier, &level)
            brightness = succeeded(status, operation: "read brightness") ? validated(level) : nil
        } else {
            brightness = fallbackBrightness()
        }
        changed?()
    }

    private func preferredDisplayIdentifier() -> CGDirectDisplayID {
        let mainDisplay = CGMainDisplayID()
        if CGDisplayIsBuiltin(mainDisplay) != 0 { return mainDisplay }
        var count: UInt32 = 0
        guard succeeded(CGGetOnlineDisplayList(0, nil, &count).rawValue, operation: "count displays") else { return mainDisplay }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let status = CGGetOnlineDisplayList(count, &displays, &count)
        guard succeeded(status.rawValue, operation: "list displays") else { return mainDisplay }
        return displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? mainDisplay
    }

    private func validated(_ level: Float) -> Double? {
        guard level.isFinite else {
            logOnce("non-finite brightness")
            return nil
        }
        guard (0...1).contains(level) else {
            logOnce("brightness outside 0–1")
            return nil
        }
        return Double(level)
    }

    private func fallbackBrightness() -> Double? {
        guard let service = displayService() else { return nil }
        defer { IOObjectRelease(service) }
        var level: Float = 0
        let status = IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &level)
        guard succeeded(status, operation: "read brightness") else { return nil }
        return validated(level)
    }

    private func displayService() -> io_service_t? {
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IODisplayConnect"))
        guard service != 0 else {
            logOnce("no IODisplay service available")
            return nil
        }
        return service
    }

    private func succeeded(_ status: Int32, operation: String) -> Bool {
        guard status == 0 else {
            logOnce(operation, status: status)
            return false
        }
        return true
    }

    private func logOnce(_ operation: String, status: Int32? = nil) {
        guard loggedFailures.insert(operation).inserted else { return }
        NSLog("MTMR brightness: %@%@", operation, status.map { " failed (\($0))" } ?? "")
    }
}
