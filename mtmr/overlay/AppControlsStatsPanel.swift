import Cocoa
import IOKit

/// Stats: five cells across the zone, each a small caption, a value and (where it helps) a meter:
/// CPU (total + one bar per core, efficiency | performance) · GPU · MEM (% and GB) · TEMP · NET (down / up).
/// Read directly from the system (the Stats app has no API); tapping the panel opens Stats.
final class AppControlsStatsPanel: NSView, AppControlsPanel {
    static let id = "stats"
    static let name = "Stats"
    static let bundleId = "eu.exelban.Stats"
    static func icon() -> NSImage { return AppControlsApps.icon(bundleId) ?? AppControlsStyle.symbolImage("gauge", box: TouchBarIcon.appBox)! }
    let refreshInterval: TimeInterval = 2

    private var snapshot = SystemMetrics.Snapshot()
    private let openButton = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        openButton.frame = bounds
    }

    func refresh() {
        snapshot = SystemMetrics.shared.snapshot()
        needsDisplay = true
    }

    @objc private func openApp() { AppControlsApps.open(Self.bundleId) }

    // MARK: Drawing

    /// Relative cell widths: CPU, GPU, MEM, TEMP, NET.
    private static let weights: [CGFloat] = [0.29, 0.14, 0.21, 0.14, 0.22]
    private static let cellGap: CGFloat = 6

    override func draw(_: NSRect) {
        let available = bounds.width - Self.cellGap * CGFloat(Self.weights.count - 1)
        var x: CGFloat = 0
        var cells: [NSRect] = []
        for weight in Self.weights {
            let width = floor(available * weight)
            cells.append(NSRect(x: x, y: 0, width: width, height: bounds.height))
            x += width + Self.cellGap
        }
        drawCPU(in: cells[0])
        drawGauge(in: cells[1], caption: "GPU", value: snapshot.gpu.map { Self.percent($0) }, fraction: snapshot.gpu)
        let memoryCaption = snapshot.memoryUsedBytes.map { String(format: "MEM %.1fG", Double($0) / 1_073_741_824) } ?? "MEM"
        drawGauge(in: cells[2], caption: memoryCaption, value: snapshot.memory.map { Self.percent($0) }, fraction: snapshot.memory)
        // Temperature: 40 °C reads as empty, 100 °C as full; orange from 80 °C, red from 92 °C.
        drawGauge(in: cells[3], caption: "TEMP", value: snapshot.temperature.map { "\(Int($0.rounded()))°" },
                  fraction: snapshot.temperature.map { ($0 - 40) / 60 }, warnAt: 2.0 / 3, badAt: 0.87)
        drawNetwork(in: cells[4])
    }

    private func drawCaption(_ text: String, at point: NSPoint, width: CGFloat) {
        Self.draw(text, font: NSFont.systemFont(ofSize: 8, weight: .semibold), color: AppControlsStyle.secondaryText, in: NSRect(x: point.x, y: point.y, width: width, height: 10))
    }

    private func drawValue(_ text: String, at point: NSPoint, width: CGFloat, size: CGFloat = 13) {
        Self.draw(text, font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold), color: AppControlsStyle.primaryText, in: NSRect(x: point.x, y: point.y, width: width, height: size + 3))
    }

    /// Caption (top), value (middle), thin meter (bottom).
    private func drawGauge(in cell: NSRect, caption: String, value: String?, fraction: Double?, warnAt: Double = 0.7, badAt: Double = 0.9) {
        drawCaption(caption, at: NSPoint(x: cell.minX, y: 20), width: cell.width)
        drawValue(value ?? "–", at: NSPoint(x: cell.minX, y: 5), width: cell.width)
        drawMeter(NSRect(x: cell.minX, y: 1, width: cell.width, height: 3), fraction: fraction ?? 0, warnAt: warnAt, badAt: badAt)
    }

    /// Total on the left; one vertical bar per core on the right, efficiency cores then performance cores.
    private func drawCPU(in cell: NSRect) {
        let textWidth: CGFloat = 34
        drawCaption("CPU", at: NSPoint(x: cell.minX, y: 20), width: textWidth)
        drawValue(snapshot.cpu.map { Self.percent($0) } ?? "–", at: NSPoint(x: cell.minX, y: 5), width: textWidth + 6)
        let cores = snapshot.cores
        guard !cores.isEmpty else { return }
        let efficiency = SystemMetrics.shared.efficiencyCores
        let groupGap: CGFloat = efficiency > 0 && efficiency < cores.count ? 4 : 0
        let barsX = cell.minX + textWidth + 6
        let barsWidth = cell.maxX - barsX
        let spacing: CGFloat = 2
        let barWidth = max(2, (barsWidth - groupGap - spacing * CGFloat(cores.count - 1)) / CGFloat(cores.count))
        var x = barsX
        for (index, load) in cores.enumerated() {
            if index == efficiency && groupGap > 0 { x += groupGap }
            let track = NSRect(x: x, y: 2, width: barWidth, height: 24)
            AppControlsStyle.track.setFill()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            let height = max(1.5, track.height * CGFloat(min(1, max(0, load))))
            Self.meterColour(load, warnAt: 0.7, badAt: 0.9).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 2, width: barWidth, height: height), xRadius: 1.5, yRadius: 1.5).fill()
            x += barWidth + spacing
        }
    }

    private func drawNetwork(in cell: NSRect) {
        drawCaption("NET", at: NSPoint(x: cell.minX, y: 20), width: cell.width)
        let down = snapshot.downloadBytesPerSecond.map { "↓" + Self.rate($0) } ?? "↓ –"
        let up = snapshot.uploadBytesPerSecond.map { "↑" + Self.rate($0) } ?? "↑ –"
        drawValue(down, at: NSPoint(x: cell.minX, y: 9), width: cell.width, size: 10)
        drawValue(up, at: NSPoint(x: cell.minX, y: 0), width: cell.width, size: 10)
    }

    private func drawMeter(_ rect: NSRect, fraction: Double, warnAt: Double, badAt: Double) {
        let radius = rect.height / 2
        AppControlsStyle.track.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let clamped = min(1, max(0, fraction))
        guard clamped > 0 else { return }
        Self.meterColour(clamped, warnAt: warnAt, badAt: badAt).setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: max(rect.height, rect.width * CGFloat(clamped)), height: rect.height), xRadius: radius, yRadius: radius).fill()
    }

    private static func meterColour(_ fraction: Double, warnAt: Double, badAt: Double) -> NSColor {
        return fraction >= badAt ? AppControlsStyle.bad : fraction >= warnAt ? AppControlsStyle.warn : AppControlsStyle.neutralFill
    }

    private static func draw(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    private static func percent(_ fraction: Double) -> String {
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// Bytes per second as a short rate: 950B, 40K, 1.2M, 12M.
    private static func rate(_ bytes: Double) -> String {
        switch bytes {
        case ..<1000: return "\(Int(bytes))B"
        case ..<1_000_000: return "\(Int((bytes / 1000).rounded()))K"
        case ..<10_000_000: return String(format: "%.1fM", bytes / 1_000_000)
        default: return "\(Int((bytes / 1_000_000).rounded()))M"
        }
    }
}

/// Everything the Stats panel shows, sampled together. Rates and loads are deltas between two snapshots,
/// so the first snapshot after launch has no CPU, core or network values yet.
final class SystemMetrics {
    struct Snapshot {
        var cpu: Double?
        var cores: [Double] = []
        var gpu: Double?
        var memory: Double?
        var memoryUsedBytes: UInt64?
        var temperature: Double?
        var downloadBytesPerSecond: Double?
        var uploadBytesPerSecond: Double?
    }

    static let shared = SystemMetrics()

    /// Efficiency cores come first in the processor list on Apple Silicon (hw.perflevel1 = efficiency).
    let efficiencyCores: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.perflevel1.logicalcpu", &count, &size, nil, 0) == 0 ? Int(count) : 0
    }()

    private var previousCoreTicks: [(busy: UInt64, total: UInt64)] = []
    private var previousNetwork: (received: UInt64, sent: UInt64, at: Double)?
    private let thermal = ThermalSensors()

    func snapshot() -> Snapshot {
        var snapshot = Snapshot()
        snapshot.cores = coreUsage()
        if !snapshot.cores.isEmpty { snapshot.cpu = snapshot.cores.reduce(0, +) / Double(snapshot.cores.count) }
        snapshot.gpu = gpuUsage()
        if let memory = memoryUsage() {
            snapshot.memoryUsedBytes = memory.used
            snapshot.memory = Double(memory.used) / Double(ProcessInfo.processInfo.physicalMemory)
        }
        snapshot.temperature = thermal.cpuTemperature()
        if let rates = networkRates() {
            snapshot.downloadBytesPerSecond = rates.down
            snapshot.uploadBytesPerSecond = rates.up
        }
        return snapshot
    }

    /// Load of each core since the previous call (0...1).
    private func coreUsage() -> [Double] {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount) == KERN_SUCCESS, let info = info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        let states = Int(CPU_STATE_MAX)
        var ticks: [(busy: UInt64, total: UInt64)] = []
        for core in 0..<Int(processorCount) {
            let user = UInt64(UInt32(bitPattern: info[core * states + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[core * states + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[core * states + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[core * states + Int(CPU_STATE_IDLE)]))
            ticks.append((user + system + nice, user + system + nice + idle))
        }
        defer { previousCoreTicks = ticks }
        guard previousCoreTicks.count == ticks.count else { return [] }
        return zip(ticks, previousCoreTicks).map { now, before in
            guard now.total > before.total, now.busy >= before.busy else { return 0 }
            return Double(now.busy - before.busy) / Double(now.total - before.total)
        }
    }

    /// GPU "Device Utilization %" from the IOAccelerator's PerformanceStatistics (no privileges needed).
    private func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(0, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if result == nil,
               let statistics = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let utilisation = statistics["Device Utilization %"] as? NSNumber {
                result = utilisation.doubleValue / 100
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return result
    }

    /// App memory + wired + compressed (Activity Monitor's "Memory Used").
    private func memoryUsage() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let appPages = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        let used = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (used, ProcessInfo.processInfo.physicalMemory)
    }

    /// Bytes per second received / sent on all non-loopback interfaces since the previous call.
    private func networkRates() -> (down: Double, up: Double)? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0, let data = entry.ifa_data else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(counters.ifi_ibytes)
            sent += UInt64(counters.ifi_obytes)
        }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previousNetwork = (received, sent, now) }
        // 32-bit interface counters wrap; a counter that went backwards gives no rate for this sample.
        guard let before = previousNetwork, now > before.at, received >= before.received, sent >= before.sent else { return nil }
        let seconds = now - before.at
        return (Double(received - before.received) / seconds, Double(sent - before.sent) / seconds)
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
