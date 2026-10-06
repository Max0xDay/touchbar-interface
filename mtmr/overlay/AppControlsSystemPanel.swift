import Cocoa
import IOKit.ps

/// "SY": the default panel. Three columns across the full width: time with seconds | weekday and date |
/// bullet list (week, battery).
final class AppControlsSystemPanel: NSView, AppControlsPanel {
    static let id = "system"
    static let name = "System"
    static func icon() -> NSImage { return appControlsTextBadge("SY") }
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
