import Cocoa

// Standalone views only: no application, Touch Bar, controller or live config/socket.
@main
struct NotificationAreaTests {
    static func main() {
        NotificationDebug.enabled = false
        checkFontAndFrames()
        checkSwipeDirection()
        checkTransitions()
        print("Notification area checks passed")
    }

    private static func label(in area: NotificationAreaView) -> NSTextField {
        guard let label = area.subviews.first as? NSTextField else { preconditionFailure("Missing label") }
        return label
    }

    private static func checkFontAndFrames() {
        let area = NotificationAreaView(maxChars: 40, fadeSeconds: 0)
        for width: CGFloat in [477, 395, 311, 120, 24, 10, 477] {
            area.frame = NSRect(x: 0, y: 0, width: width, height: 30)
            area.layoutSubtreeIfNeeded()
            area.show(text: String(repeating: "a", count: 60))
            let label = label(in: area)
            guard let font = label.font else { preconditionFailure("Missing font") }
            let measuredWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
            precondition(abs(measuredWidth - NotificationTextMetrics.glyphWidth) < 0.001)
            precondition(font.pointSize == 15)
            precondition(label.frame.midX == area.bounds.midX)
            precondition(label.frame.midY == area.bounds.midY)
            precondition(label.frame.width == max(0, width - 24))
            let capacity = NotificationTextMetrics.capacity(width: Double(width), inset: 12, glyphWidth: Double(measuredWidth), maxChars: 40)
            precondition(label.stringValue == NotificationTextMetrics.truncated(String(repeating: "a", count: 60), capacity: capacity))
            precondition(area.hitTest(NSPoint(x: width / 2, y: 15)) === area, "Label must not swallow direct touches")
        }
        let withIcon = NotificationAreaView(maxChars: 40, fadeSeconds: 0)
        withIcon.frame = NSRect(x: 0, y: 0, width: 292, height: 30)
        withIcon.layoutSubtreeIfNeeded()
        withIcon.show(text: "Standup in 10 minutes", icon: NSImage(size: NSSize(width: 18, height: 18)))
        guard let iconView = withIcon.subviews.compactMap({ $0 as? NSImageView }).first else { preconditionFailure("Missing icon view") }
        let iconLabel = label(in: withIcon)
        precondition(iconView.image != nil && iconView.frame.width == TouchBarIcon.switcherBox, "The entry's icon matches the switcher icon size")
        precondition(iconLabel.frame.minX - iconView.frame.maxX == 6, "The icon sits right beside the text")
        precondition(abs((iconLabel.frame.minX - 24 + iconLabel.frame.maxX) / 2 - withIcon.bounds.midX) < 0.5, "Text centres as if the icon took an 18 pt slot")
        precondition(iconLabel.frame.minX - iconView.frame.minX == 36, "The larger icon reaches further left")
        precondition(iconLabel.stringValue == "Standup in 10 minutes")
        withIcon.show(text: "no icon")
        precondition(iconView.image == nil && label(in: withIcon).frame.width == 292 - 24, "Without an icon the label spans the area again")
        precondition(area.allowedTouchTypes == .direct)
        precondition(area.wantsRestingTouches)
        let item = NotificationTouchBarItem(identifier: NSTouchBarItem.Identifier("capacity-test"), maxChars: 20, defaultSeconds: 5)
        precondition(item.layoutOptions.minWidth == 210, "Direct item construction must derive the minimum from its character budget")
    }

    private static func checkSwipeDirection() {
        precondition(NotificationSwipe.offset(horizontal: -20, vertical: 0) == 1)
        precondition(NotificationSwipe.offset(horizontal: 20, vertical: 1) == -1)
        precondition(NotificationSwipe.offset(horizontal: 19.9, vertical: 0) == 0)
        precondition(NotificationSwipe.offset(horizontal: 5, vertical: 10) == 0)
        precondition(NotificationSwipe.offset(horizontal: 25, vertical: 25) == 0)
    }

    private static func settle(_ seconds: Double) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private static func checkTransitions() {
        let area = NotificationAreaView(maxChars: 40, fadeSeconds: 0.35)
        area.frame = NSRect(x: 0, y: 0, width: 477, height: 30)
        area.layoutSubtreeIfNeeded()
        let initialFrame = label(in: area).frame
        area.show(text: "first")
        let label = label(in: area)
        precondition(label.stringValue == "first")
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        precondition(label.layer?.animation(forKey: "notificationFade")?.duration == (reduceMotion ? 0.15 : 0.35))
        precondition((label.layer?.animation(forKey: "notificationSlide") == nil) == reduceMotion)
        area.show(text: "second")
        area.show(text: "")
        area.show(text: "latest")
        settle(0.2)
        precondition(label.stringValue == "latest", "Cancelled completions must not replace the latest text")
        settle(0.4)
        precondition(label.layer?.opacity == 1)
        precondition(label.frame == initialFrame, "Animations must not change layout frames")
        area.show(text: "")
        settle(0.3)
        precondition(label.stringValue.isEmpty)
        precondition(label.layer?.opacity == 0)
        area.show(text: "restored")
        area.show(text: "replacement")
        area.frame.size.width = 311
        area.layoutSubtreeIfNeeded()
        settle(0.3)
        precondition(label.stringValue == "replacement")
        precondition(label.layer?.opacity == 1)
        precondition(label.frame.midX == area.bounds.midX)
        let instant = NotificationAreaView(maxChars: 40, fadeSeconds: 0)
        instant.frame = NSRect(x: 0, y: 0, width: 477, height: 30)
        instant.layoutSubtreeIfNeeded()
        instant.show(text: "one")
        instant.show(text: "two")
        precondition(self.label(in: instant).stringValue == "two")
        precondition(self.label(in: instant).layer?.animationKeys() == nil)
    }
}
