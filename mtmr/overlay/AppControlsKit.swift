import Cocoa

/// Shared look and helpers for App Controls panels. Generic colours only: neutral greys, the system accent
/// for "selected", and green/orange/red strictly for state.
enum AppControlsStyle {
    static let height: CGFloat = 30
    static let gap: CGFloat = 6
    static let primaryText = NSColor.white
    static let secondaryText = NSColor(white: 0.62, alpha: 1)
    static let track = NSColor(white: 1, alpha: 0.16)
    static let neutralFill = NSColor(white: 0.72, alpha: 1)
    static let selected = NSColor.controlAccentColor
    static let good = NSColor.systemGreen
    static let warn = NSColor.systemOrange
    static let bad = NSColor.systemRed

    static func label(size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = primaryText, monospacedDigits: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = monospacedDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        return label
    }

    static func button(symbol: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: symbolImage(symbol) ?? NSImage(), target: target, action: action)
        button.bezelStyle = .rounded
        button.imagePosition = .imageOnly
        return button
    }

    static func button(title: String, size: CGFloat = 12, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: size, weight: .medium)
        button.lineBreakMode = .byTruncatingTail
        return button
    }

    /// Every button glyph in App Controls uses the bar-wide icon box (TouchBarIcon), so equal buttons show equal icons.
    static func symbolImage(_ name: String, box: CGFloat = TouchBarIcon.symbolBox) -> NSImage? {
        return TouchBarIcon.symbol(name, box: box)
    }

    /// Posts one key press (down and up) to the frontmost app.
    static func pressKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Lays children out left to right in `bounds`, each with a fixed width; a nil width takes the remaining space.
    static func row(_ items: [(NSView, CGFloat?)], in bounds: NSRect, gap: CGFloat = AppControlsStyle.gap) {
        let fixed = items.compactMap { $0.1 }.reduce(0, +) + gap * CGFloat(max(0, items.count - 1))
        let flexible = max(0, bounds.width - fixed)
        var x = bounds.minX
        for (view, width) in items {
            let resolved = width ?? flexible
            view.frame = NSRect(x: x, y: bounds.minY, width: resolved, height: bounds.height)
            x += resolved + gap
        }
    }
}

enum AppControlsApps {
    static func url(_ bundleId: String) -> URL? {
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }

    static func icon(_ bundleId: String, size: CGFloat = TouchBarIcon.appBox) -> NSImage? {
        guard let url = url(bundleId) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 128, height: 128)
        return TouchBarIcon.fitted(image, box: size, template: false)
    }

    static func running(_ bundleId: String) -> NSRunningApplication? {
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
    }

    /// Brings an app to the front, launching it if it is not running.
    static func open(_ bundleId: String) {
        if let app = running(bundleId) {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
        guard let url = url(bundleId) else {
            NSLog("MTMR app controls: no application for %@", bundleId)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error = error { NSLog("MTMR app controls: launch failed for %@: %@", bundleId, String(describing: error)) }
        }
    }
}

/// Thin horizontal meter: neutral fill, orange/red only above the warning thresholds.
final class AppControlsMeterView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var warnAt: Double = 0.7
    var badAt: Double = 0.9

    override func draw(_: NSRect) {
        let radius = bounds.height / 2
        AppControlsStyle.track.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let clamped = min(1, max(0, fraction))
        guard clamped > 0 else { return }
        let fill = clamped >= badAt ? AppControlsStyle.bad : clamped >= warnAt ? AppControlsStyle.warn : AppControlsStyle.neutralFill
        fill.setFill()
        let width = max(bounds.height, bounds.width * CGFloat(clamped))
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: radius, yRadius: radius).fill()
    }
}

/// Round-cornered text badge used as a panel icon when there is no app icon (e.g. "SY").
func appControlsTextBadge(_ text: String, size: CGFloat = TouchBarIcon.appBox) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        NSColor(white: 1, alpha: 0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.48, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        string.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
        return true
    }
    return image
}
