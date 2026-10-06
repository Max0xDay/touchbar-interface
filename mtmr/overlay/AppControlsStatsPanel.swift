import Cocoa
import IOKit

/// Stats: CPU %, RAM %, CPU temperature, each with a meter. Read directly from the system (the Stats app has
/// no API); tapping the panel opens Stats.
final class AppControlsStatsPanel: NSView, AppControlsPanel {
    static let id = "stats"
    static let name = "Stats"
    static let bundleId = "eu.exelban.Stats"
    static func icon() -> NSImage { return AppControlsApps.icon(bundleId) ?? AppControlsStyle.symbolImage("gauge", box: TouchBarIcon.appBox)! }
    let refreshInterval: TimeInterval = 2

    private final class Cell {
        let caption = AppControlsStyle.label(size: 10, weight: .semibold, color: AppControlsStyle.secondaryText)
        let value = AppControlsStyle.label(size: 14, weight: .semibold, monospacedDigits: true)
        let meter = AppControlsMeterView()

        init(_ name: String) {
            caption.stringValue = name
            value.alignment = .right
            value.stringValue = "–"
        }
    }

    private let cells = [Cell("CPU"), Cell("RAM"), Cell("TEMP")]
    private let openButton = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Temperature: 40 °C reads as empty, 100 °C as full; orange from 80 °C, red from 92 °C.
        cells[2].meter.warnAt = 2.0 / 3
        cells[2].meter.badAt = 0.87
        for cell in cells {
            addSubview(cell.caption)
            addSubview(cell.value)
            addSubview(cell.meter)
        }
        openButton.isBordered = false
        openButton.target = self
        openButton.action = #selector(openApp)
        addSubview(openButton)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        let spacing: CGFloat = 10
        let width = (bounds.width - spacing * CGFloat(cells.count - 1)) / CGFloat(cells.count)
        for (index, cell) in cells.enumerated() {
            let x = CGFloat(index) * (width + spacing)
            cell.caption.frame = NSRect(x: x, y: 11, width: width / 2, height: 15)
            cell.value.frame = NSRect(x: x + width / 3, y: 10, width: width * 2 / 3, height: 18)
            cell.meter.frame = NSRect(x: x, y: 4, width: width, height: 4)
        }
        openButton.frame = bounds
    }

    func refresh() {
        if let cpu = SystemMetrics.shared.cpuUsage() { show(cells[0], fraction: cpu, text: "\(Int((cpu * 100).rounded()))%") }
        if let ram = SystemMetrics.shared.memoryUsage() { show(cells[1], fraction: ram, text: "\(Int((ram * 100).rounded()))%") }
        if let temp = SystemMetrics.shared.cpuTemperature() {
            show(cells[2], fraction: (temp - 40) / 60, text: "\(Int(temp.rounded()))°")
        }
    }

    private func show(_ cell: Cell, fraction: Double, text: String) {
        cell.value.stringValue = text
        cell.meter.fraction = fraction
    }

    @objc private func openApp() { AppControlsApps.open(Self.bundleId) }
}

/// CPU load (delta between calls), memory pressure-style usage and Apple Silicon CPU temperature.
final class SystemMetrics {
    static let shared = SystemMetrics()

    private var previousTicks: (busy: UInt64, total: UInt64)?
    private let thermal = ThermalSensors()

    func cpuUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { previousTicks = (busy, total) }
        guard let previous = previousTicks, total > previous.total else { return nil }
        return Double(busy - previous.busy) / Double(total - previous.total)
    }

    /// App memory + wired + compressed over physical memory (the "Memory Used" figure in Activity Monitor).
    func memoryUsage() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let appPages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let used = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return Double(used) / Double(ProcessInfo.processInfo.physicalMemory)
    }

    func cpuTemperature() -> Double? {
        return thermal.cpuTemperature()
    }
}

// IOHIDEventSystem private API (exported by IOKit, no header). Verified readable without sudo on this M1, 2026-10-06.
@_silgen_name("IOHIDEventSystemClientCreate") private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching") private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty") private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent") private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue") private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

private final class ThermalSensors {
    private static let temperatureEvent: Int64 = 15
    // The service objects point into the client without retaining it: the client must live as long as they do.
    // (Crash 2026-10-06: a local client was freed after init, then CopyEvent crashed in IOHIDEventSystemClient.)
    private let client: AnyObject?
    private let cpuSensors: [AnyObject]

    init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue()
        guard let client = client else {
            cpuSensors = []
            NSLog("MTMR stats: IOHIDEventSystemClient unavailable")
            return
        }
        // Usage page 0xff00 / usage 5: Apple vendor temperature sensors.
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        // Performance (pACC) and efficiency (eACC) core cluster sensors, as the Stats app uses on M1.
        cpuSensors = services.filter { service in
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
            return name.hasPrefix("pACC MTR Temp") || name.hasPrefix("eACC MTR Temp")
        }
        if cpuSensors.isEmpty { NSLog("MTMR stats: no CPU temperature sensors found") }
    }

    func cpuTemperature() -> Double? {
        let readings = cpuSensors.compactMap { sensor -> Double? in
            guard let event = IOHIDServiceClientCopyEvent(sensor, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            let value = IOHIDEventGetFloatValue(event, Int32(Self.temperatureEvent << 16))
            return (1...150).contains(value) ? value : nil
        }
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0, +) / Double(readings.count)
    }
}
