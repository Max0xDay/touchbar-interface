import Cocoa

/// VS Code: a window toggle, Run (▶, F5 = Run > Start Debugging) and the Command Palette (⌘, ⇧⌘P).
/// The toggle shows the current window in that window's colour (project, open file, one dot per window);
/// a tap goes to the next window. Each window's colour comes from its project folder path, so it stays the
/// same across files and restarts.
final class AppControlsCodePanel: NSView, AppControlsPanel {
    static let id = "vscode"
    static let name = "VS Code"
    static let bundleId = "com.microsoft.VSCode"
    static func icon() -> NSImage { return AppControlsApps.icon(bundleId) ?? AppControlsStyle.symbolImage("chevron.left.forwardslash.chevron.right", box: TouchBarIcon.appBox)! }
    let refreshInterval: TimeInterval = 1

    private static let actionWidth: CGFloat = 40
    private static let keyF5: CGKeyCode = 96
    private static let keyP: CGKeyCode = 35

    private let toggle = CodeWindowToggle()
    private var run: NSButton!
    private var command: NSButton!
    private var windows: [CodeWindow] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toggle.onTap = { [weak self] in self?.toggleTapped() }
        run = AppControlsStyle.button(symbol: "play.fill", target: self, action: #selector(runTapped))
        command = AppControlsStyle.button(symbol: "command", target: self, action: #selector(commandTapped))
        addSubview(toggle)
        addSubview(run)
        addSubview(command)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        command.frame = NSRect(x: bounds.width - Self.actionWidth, y: 0, width: Self.actionWidth, height: bounds.height)
        run.frame = NSRect(x: command.frame.minX - AppControlsStyle.gap - Self.actionWidth, y: 0, width: Self.actionWidth, height: bounds.height)
        toggle.frame = NSRect(x: 0, y: 0, width: max(0, run.frame.minX - AppControlsStyle.gap), height: bounds.height)
    }

    func refresh() {
        guard let app = AppControlsApps.running(Self.bundleId) else {
            windows = []
            toggle.state = .placeholder(title: Self.name, detail: "Not running · tap to open")
            setActionsEnabled(false)
            return
        }
        windows = CodeWindow.all(of: app)
        if windows.isEmpty {
            toggle.state = .placeholder(title: Self.name, detail: "No windows · tap to open")
        } else {
            let current = windows.firstIndex { $0.focused } ?? 0
            toggle.state = .windows(windows, current: current)
        }
        setActionsEnabled(!windows.isEmpty)
    }

    private func setActionsEnabled(_ enabled: Bool) {
        run.isEnabled = enabled
        command.isEnabled = enabled
    }

    /// VS Code in front: next window. VS Code behind: bring the current window forward first.
    private func toggleTapped() {
        guard !windows.isEmpty else {
            AppControlsApps.open(Self.bundleId)
            return
        }
        let current = windows.firstIndex { $0.focused } ?? 0
        let codeInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleId
        let target = codeInFront ? (current + 1) % windows.count : current
        windows[target].raise()
        AppControlsApps.open(Self.bundleId)
        // Show the result at once; the next refresh confirms it from Accessibility.
        toggle.state = .windows(windows, current: target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    @objc private func runTapped() { pressInCode(Self.keyF5) }
    @objc private func commandTapped() { pressInCode(Self.keyP, flags: [.maskCommand, .maskShift]) }

    /// Brings VS Code forward, then presses the key once VS Code is frontmost (the delay lets the activation land).
    private func pressInCode(_ key: CGKeyCode, flags: CGEventFlags = []) {
        AppControlsApps.open(Self.bundleId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleId else { return }
            AppControlsStyle.pressKey(key, flags: flags)
        }
    }
}

/// One VS Code window, read through Accessibility (MTMR already holds the permission).
struct CodeWindow: Equatable {
    let project: String
    let file: String
    /// Project folder path when known (from the window's document), else the project name: the colour key.
    let folder: String
    let focused: Bool
    let element: AXUIElement

    var colour: NSColor { return CodeWindowPalette.colour(for: folder) }

    static func == (left: CodeWindow, right: CodeWindow) -> Bool {
        return left.project == right.project && left.file == right.file && left.folder == right.folder && left.focused == right.focused
    }

    func raise() {
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    static func all(of app: NSRunningApplication) -> [CodeWindow] {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        var focusedValue: CFTypeRef?
        AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedValue)
        let windows = elements.compactMap { element -> CodeWindow? in
            guard let title = string(element, kAXTitleAttribute), !title.isEmpty else { return nil }
            let document = string(element, kAXDocumentAttribute).flatMap { URL(string: $0) }
            let (project, file) = parse(title: title)
            let isFocused = focusedValue.map { CFEqual($0, element) } ?? false
            return CodeWindow(project: project, file: document?.lastPathComponent ?? file,
                              folder: folderPath(project: project, document: document) ?? project,
                              focused: isFocused, element: element)
        }
        // AX lists windows front to back, which changes on every focus; sort by folder so the order stays put.
        return windows.sorted { $0.folder.localizedStandardCompare($1.folder) == .orderedAscending }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// "file.swift — project" (VS Code's default title on macOS) → ("project", "file.swift").
    private static func parse(title: String) -> (project: String, file: String) {
        let parts = title.components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0 != "Visual Studio Code" }
        guard parts.count > 1 else { return (parts.first ?? title, "") }
        return (parts[parts.count - 1], parts[0])
    }

    /// The document path up to the folder named like the project: /…/projects/maxlaptopmtmr/touchbar-interface/bin/tbctl
    /// with project "maxlaptopmtmr" → /…/projects/maxlaptopmtmr.
    private static func folderPath(project: String, document: URL?) -> String? {
        guard let components = document?.pathComponents, let index = components.lastIndex(of: project) else { return nil }
        return NSString.path(withComponents: Array(components[...index]))
    }
}

/// Generic system colours (no red: red means a problem or muted on this bar), picked by a stable hash (FNV-1a; Swift's hashValue changes per launch).
enum CodeWindowPalette {
    static let colours: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemOrange, .systemTeal, .systemGreen, .systemIndigo, .systemYellow]

    static func colour(for key: String) -> NSColor {
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return colours[Int(hash % UInt32(colours.count))]
    }
}

/// The window toggle: drawn by hand so one tap target holds the colour, two text lines and the window dots.
final class CodeWindowToggle: NSView {
    enum State: Equatable {
        case placeholder(title: String, detail: String)
        case windows([CodeWindow], current: Int)
    }

    var state: State = .placeholder(title: "", detail: "") {
        didSet { if state != oldValue { needsDisplay = true } }
    }
    var onTap: (() -> Void)?
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Touch Bar touches are direct touches; MTMR's own buttons use the same recognizer setup.
        let press = NSPressGestureRecognizer(target: self, action: #selector(pressChanged(_:)))
        press.allowedTouchTypes = .direct
        press.minimumPressDuration = 0
        addGestureRecognizer(press)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    @objc private func pressChanged(_ recognizer: NSPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pressed = true
        case .ended:
            pressed = false
            if bounds.contains(recognizer.location(in: self)) { onTap?() }
        case .cancelled, .failed:
            pressed = false
        default:
            break
        }
    }

    override func draw(_: NSRect) {
        let radius: CGFloat = 6
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        switch state {
        case let .placeholder(title, detail):
            NSColor(white: pressed ? 0.36 : 0.25, alpha: 1).setFill()
            shape.fill()
            drawText(title: title, detail: detail, x: 10, right: bounds.width - 8)
        case let .windows(windows, current):
            let window = windows[min(current, windows.count - 1)]
            let base = window.colour.usingColorSpace(.sRGB) ?? window.colour
            (base.blended(withFraction: pressed ? 0.45 : 0.62, of: .black) ?? base).setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            base.setFill()
            NSRect(x: 0, y: 0, width: 4, height: bounds.height).fill()
            NSGraphicsContext.restoreGraphicsState()
            let dotsWidth = drawDots(windows, current: current)
            drawText(title: window.project, detail: window.file, x: 12, right: bounds.width - dotsWidth - 14)
        }
    }

    private func drawText(title: String, detail: String, x: CGFloat, right: CGFloat) {
        let width = max(0, right - x)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: AppControlsStyle.primaryText, .paragraphStyle: style]
        let detailAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(white: 0.78, alpha: 1), .paragraphStyle: style]
        (title as NSString).draw(in: NSRect(x: x, y: 14, width: width, height: 15), withAttributes: titleAttributes)
        (detail as NSString).draw(in: NSRect(x: x, y: 2, width: width, height: 13), withAttributes: detailAttributes)
    }

    /// One dot per window at the right; the current window's dot is larger with a white ring. Returns the width used.
    private func drawDots(_ windows: [CodeWindow], current: Int) -> CGFloat {
        guard windows.count > 1 else { return 0 }
        let small: CGFloat = 6, large: CGFloat = 9, spacing: CGFloat = 5
        let width = CGFloat(windows.count - 1) * (small + spacing) + large
        var x = bounds.width - 9 - width
        for (index, window) in windows.enumerated() {
            let size = index == current ? large : small
            let dot = NSRect(x: x, y: bounds.midY - size / 2, width: size, height: size)
            window.colour.setFill()
            NSBezierPath(ovalIn: dot).fill()
            if index == current {
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            x += size + spacing
        }
        return width
    }
}
