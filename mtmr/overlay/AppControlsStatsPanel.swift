import Cocoa
import IOKit

/// Stats (v4): four cells spread across the zone:
/// CPU (ring with the total + a heat grid, one square per core) · MEM (ring) · TEMP (thermometer + value) · NET (↓ / ↑).
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

    // MARK: Drawing (v4: rings and a heat grid)

    private static let ringSize: CGFloat = 28
    private static let gridCell: CGFloat = 7
    private static let gridGap: CGFloat = 2
    private static let netWidth: CGFloat = 50
    private static let tempWidth: CGFloat = 44

    /// Natural cell widths; the space left over is shared out evenly between the cells.
    override func draw(_: NSRect) {
        let cpuWidth = Self.ringSize + 5 + max(Self.captionWidth("CPU"), gridWidth)
        let memWidth = Self.ringSize + 5 + Self.captionWidth("MEM")
        let widths = [cpuWidth, memWidth, Self.tempWidth, Self.netWidth]
        let spare = max(0, bounds.width - widths.reduce(0, +))
        let gap = floor(spare / CGFloat(widths.count - 1))
        var x: CGFloat = 0
        var cells: [NSRect] = []
        for width in widths {
            cells.append(NSRect(x: x, y: 0, width: width, height: bounds.height))
            x += width + gap
        }
        drawCPU(in: cells[0])
        drawRing(at: cells[1].minX, fraction: snapshot.memory)
        drawCaption("MEM", at: NSPoint(x: cells[1].minX + Self.ringSize + 5, y: bounds.midY - 5))
        drawTemperature(in: cells[2])
        drawNetwork(in: cells[3])
    }

    private static func captionWidth(_ text: String) -> CGFloat {
        return ceil((text as NSString).size(withAttributes: [.font: captionFont]).width)
    }

    private static let captionFont = NSFont.systemFont(ofSize: 8, weight: .semibold)

    private func drawCaption(_ text: String, at point: NSPoint) {
        Self.draw(text, font: Self.captionFont, color: AppControlsStyle.secondaryText, in: NSRect(x: point.x, y: point.y, width: Self.captionWidth(text) + 2, height: 10))
    }

    /// A ring gauge with the percentage inside (no % sign: the ring says it). Colour turns orange / red when high.
    private func drawRing(at x: CGFloat, fraction: Double?) {
        let size = Self.ringSize
        let box = NSRect(x: x, y: bounds.midY - size / 2, width: size, height: size).insetBy(dx: 1.5, dy: 1.5)
        let centre = NSPoint(x: box.midX, y: box.midY)
        let track = NSBezierPath(ovalIn: box)
        track.lineWidth = 3
        AppControlsStyle.track.setStroke()
        track.stroke()
        if let fraction = fraction {
            let clamped = CGFloat(min(1, max(0, fraction)))
            if clamped > 0 {
                // Clockwise from 12 o'clock.
                let arc = NSBezierPath()
                arc.appendArc(withCenter: centre, radius: box.width / 2, startAngle: 90, endAngle: 90 - 360 * clamped, clockwise: true)
                arc.lineWidth = 3
                arc.lineCapStyle = .round
                Self.meterColour(Double(clamped), warnAt: 0.7, badAt: 0.9).setStroke()
                arc.stroke()
            }
        }
        let text = fraction.map { "\(Int(($0 * 100).rounded()))" } ?? "–"
        let font = NSFont.monospacedDigitSystemFont(ofSize: text.count > 2 ? 8.5 : 10, weight: .semibold)
        Self.drawCentred(text, font: font, color: AppControlsStyle.primaryText, at: centre)
    }

    private var gridWidth: CGFloat {
        let columns = CGFloat(gridColumns)
        return columns * Self.gridCell + max(0, columns - 1) * Self.gridGap
    }

    private var gridColumns: Int {
        let cores = max(snapshot.cores.count, 1)
        let efficiency = SystemMetrics.shared.efficiencyCores
        return max(efficiency, cores - efficiency, 1)
    }

    /// Total in the ring; beside it the caption and one square per core, efficiency row on top, performance row
    /// below, brighter the busier (orange / red when hot).
    private func drawCPU(in cell: NSRect) {
        drawRing(at: cell.minX, fraction: snapshot.cpu)
        let x = cell.minX + Self.ringSize + 5
        drawCaption("CPU", at: NSPoint(x: x, y: 19))
        let cores = snapshot.cores
        let efficiency = SystemMetrics.shared.efficiencyCores
        let rows: [ArraySlice<Double>] = efficiency > 0 && efficiency < cores.count
            ? [cores[..<efficiency], cores[efficiency...]]
            : [cores[...]]
        for (rowIndex, row) in rows.enumerated() {
            let y = rows.count == 1 ? 6 : 11 - CGFloat(rowIndex) * (Self.gridCell + Self.gridGap) - 1
            for (column, load) in row.enumerated() {
                let square = NSRect(x: x + CGFloat(column) * (Self.gridCell + Self.gridGap), y: y, width: Self.gridCell, height: Self.gridCell)
                Self.heatColour(load).setFill()
                NSBezierPath(roundedRect: square, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }

    /// Thermometer coloured by heat, value beside it. No meter (user request).
    private func drawTemperature(in cell: NSRect) {
        let temperature = snapshot.temperature
        let colour: NSColor = temperature.map { $0 >= 90 ? AppControlsStyle.bad : $0 >= 75 ? AppControlsStyle.warn : AppControlsStyle.neutralFill } ?? AppControlsStyle.secondaryText
        if let glyph = TouchBarIcon.symbol("thermometer", box: 16, tint: colour) {
            glyph.draw(in: NSRect(x: cell.minX, y: bounds.midY - 8, width: 16, height: 16))
        }
        let text = temperature.map { "\(Int($0.rounded()))°" } ?? "–"
        Self.draw(text, font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), color: AppControlsStyle.primaryText,
                  in: NSRect(x: cell.minX + 17, y: bounds.midY - 8, width: cell.width - 17, height: 16))
    }

    /// Down and up, one per line, each with a coloured arrow.
    private func drawNetwork(in cell: NSRect) {
        let lines: [(arrow: String, colour: NSColor, bytes: Double?, y: CGFloat)] = [
            ("↓", .systemBlue, snapshot.downloadBytesPerSecond, 15),
            ("↑", .systemGreen, snapshot.uploadBytesPerSecond, 2),
        ]
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        for line in lines {
            Self.draw(line.arrow, font: font, color: line.colour, in: NSRect(x: cell.minX, y: line.y, width: 10, height: 14))
            Self.draw(line.bytes.map { Self.rate($0) } ?? "–", font: font, color: AppControlsStyle.primaryText, in: NSRect(x: cell.minX + 10, y: line.y, width: cell.width - 10, height: 14))
        }
    }

    private static func heatColour(_ load: Double) -> NSColor {
        if load >= 0.9 { return AppControlsStyle.bad }
        if load >= 0.7 { return AppControlsStyle.warn }
        return NSColor(white: 1, alpha: 0.14 + 0.76 * CGFloat(min(1, max(0, load)) / 0.7))
    }

    private static func drawCentred(_ text: String, font: NSFont, color: NSColor, at centre: NSPoint) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2), withAttributes: attributes)
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
        var memory: Double?
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
        if let memory = memoryUsage() {
            snapshot.memory = Double(memory.used) / Double(memory.total)
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
