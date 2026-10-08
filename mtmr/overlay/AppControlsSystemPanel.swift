import Cocoa
import IOKit.ps

/// "SY": the default panel. Three columns across the full width: time with seconds | weekday and date |
/// bullet list (week, battery).
final class AppControlsSystemPanel: NSView, AppControlsPanel {
    static let id = "system"
    static let name = "System"
    static func icon() -> NSImage { return systemIcon(size: TouchBarIcon.appBox) }
    // Twice a second so the seconds never visibly skip.
    let refreshInterval: TimeInterval = 0.5

    private let time = AppControlsStyle.label(size: 20, weight: .medium, monospacedDigits: true)
    private let weekday = AppControlsStyle.label(size: 12, weight: .semibold)
    private let date = AppControlsStyle.label(size: 10, color: AppControlsStyle.secondaryText)
    private let week = AppControlsStyle.label(size: 10, color: AppControlsStyle.secondaryText, monospacedDigits: true)
    private let battery = AppControlsStyle.label(size: 10, color: AppControlsStyle.secondaryText, monospacedDigits: true)
    private let timeFormatter = DateFormatter()
    private let weekdayFormatter = DateFormatter()
    private let dateFormatter = DateFormatter()
    private var lastBatteryRead = Date.distantPast

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        timeFormatter.setLocalizedDateFormatFromTemplate("jmmss")
        weekdayFormatter.setLocalizedDateFormatFromTemplate("EEEE")
        dateFormatter.setLocalizedDateFormatFromTemplate("dMMMMy")
        for label in [time, weekday, date, week, battery] { addSubview(label) }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        // Time sized for its widest value so the columns never shift as the digits change.
        let timeWidth = ceil(("88:88:88" as NSString).size(withAttributes: [.font: time.font!]).width) + 4
        time.frame = NSRect(x: 0, y: 2, width: timeWidth, height: 26)
        let spacing: CGFloat = 12
        let columnWidth = max(0, (bounds.width - timeWidth - 2 * spacing) / 2)
        let dateX = timeWidth + spacing
        weekday.frame = NSRect(x: dateX, y: 15, width: columnWidth, height: 15)
        date.frame = NSRect(x: dateX, y: 2, width: columnWidth, height: 13)
        let listX = dateX + columnWidth + spacing
        week.frame = NSRect(x: listX, y: 15, width: columnWidth, height: 13)
        battery.frame = NSRect(x: listX, y: 2, width: columnWidth, height: 13)
    }

    func refresh() {
        let now = Date()
        time.stringValue = timeFormatter.string(from: now)
        weekday.stringValue = weekdayFormatter.string(from: now)
        date.stringValue = dateFormatter.string(from: now)
        week.stringValue = "• Week \(Calendar(identifier: .iso8601).component(.weekOfYear, from: now))"
        // The battery changes slowly; read it every 10 s, not on every tick.
        if now.timeIntervalSince(lastBatteryRead) >= 10 {
            lastBatteryRead = now
            battery.stringValue = Self.battery().map { "• " + $0 } ?? ""
        }
    }

    private static func battery() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard let current = description[kIOPSCurrentCapacityKey] as? Int, let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let percent = Int((Double(current) / Double(maximum) * 100).rounded())
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            return "Battery \(percent)%" + (charging ? " ⚡︎" : "")
        }
        return nil
    }
}

/// The System panel icon, drawn in code so it scales cleanly: a graphite app-style tile with a white clock face
/// at 10:10 and a small accent date tab. Generic colours only.
func systemIcon(size: CGFloat) -> NSImage {
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let tile = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)
        let corner = tile.width * 0.24
        let gradient = NSGradient(starting: NSColor(white: 0.42, alpha: 1), ending: NSColor(white: 0.2, alpha: 1))
        gradient?.draw(in: NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner), angle: -90)

        let centre = NSPoint(x: tile.midX, y: tile.midY - tile.height * 0.02)
        let radius = tile.width * 0.33
        let face = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        NSColor.white.setFill()
        face.fill()

        // Ticks at 12, 3, 6 and 9.
        NSColor(white: 0.25, alpha: 1).setStroke()
        for quarter in 0..<4 {
            let angle = CGFloat(quarter) * .pi / 2
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: centre.x + cos(angle) * radius * 0.72, y: centre.y + sin(angle) * radius * 0.72))
            tick.line(to: NSPoint(x: centre.x + cos(angle) * radius * 0.88, y: centre.y + sin(angle) * radius * 0.88))
            tick.lineWidth = max(0.75, size * 0.03)
            tick.stroke()
        }

        // Hands at 10:10: hour hand towards 10 (150°), minute hand towards 2 (30°).
        func hand(_ degrees: CGFloat, _ length: CGFloat, _ width: CGFloat) {
            let angle = degrees * .pi / 180
            let path = NSBezierPath()
            path.move(to: centre)
            path.line(to: NSPoint(x: centre.x + cos(angle) * radius * length, y: centre.y + sin(angle) * radius * length))
            path.lineWidth = width
            path.lineCapStyle = .round
            path.stroke()
        }
        NSColor(white: 0.15, alpha: 1).setStroke()
        hand(150, 0.5, max(1, size * 0.07))
        hand(30, 0.72, max(0.8, size * 0.05))
        NSColor.controlAccentColor.setFill()
        let pin = radius * 0.16
        NSBezierPath(ovalIn: NSRect(x: centre.x - pin, y: centre.y - pin, width: pin * 2, height: pin * 2)).fill()

        // Date tab: an accent bar along the top of the tile, like a calendar's binding.
        let tab = NSRect(x: tile.midX - tile.width * 0.2, y: tile.maxY - tile.height * 0.13, width: tile.width * 0.4, height: tile.height * 0.06)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: tab, xRadius: tab.height / 2, yRadius: tab.height / 2).fill()
        return true
    }
}
