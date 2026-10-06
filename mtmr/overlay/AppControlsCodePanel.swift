import Cocoa

/// VS Code: one numbered chip per open window ("Win 1", "Win 2", ...; numbered by project name so the numbers
/// stay put); tap raises that window. Run (▶) presses F5 (Run > Start Debugging), ⌘ opens the Command Palette (⇧⌘P).
/// Both bring VS Code forward first.
final class AppControlsCodePanel: NSView, AppControlsPanel {
    static let id = "vscode"
    static let name = "VS Code"
    static let bundleId = "com.microsoft.VSCode"
    static func icon() -> NSImage { return AppControlsApps.icon(bundleId) ?? AppControlsStyle.symbolImage("chevron.left.forwardslash.chevron.right", box: TouchBarIcon.appBox)! }
    let refreshInterval: TimeInterval = 2

    private struct Window: Equatable {
        let name: String
        let focused: Bool
    }

    private static let actionWidth: CGFloat = 40
    private static let keyF5: CGKeyCode = 96
    private static let keyP: CGKeyCode = 35
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var run: NSButton!
    private var command: NSButton!
    private var shown: [Window]?
    private var elements: [AXUIElement] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = AppControlsStyle.gap
        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        run = AppControlsStyle.button(symbol: "play.fill", target: self, action: #selector(runTapped))
        command = AppControlsStyle.button(symbol: "command", target: self, action: #selector(commandTapped))
        addSubview(scroll)
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
        scroll.frame = NSRect(x: 0, y: 0, width: max(0, run.frame.minX - AppControlsStyle.gap), height: bounds.height)
        layoutStack()
    }

    private func layoutStack() {
        stack.frame = NSRect(x: 0, y: 0, width: stack.fittingSize.width, height: bounds.height)
    }

    func refresh() {
        guard let app = AppControlsApps.running(Self.bundleId) else {
            elements = []
            show([], placeholder: "VS Code not running · open")
            return
        }
        let (windows, elements) = Self.windows(of: app)
        self.elements = elements
        show(windows, placeholder: windows.isEmpty ? "No windows · open" : nil)
    }

    private func show(_ windows: [Window], placeholder: String?) {
        let key = placeholder.map { [Window(name: $0, focused: false)] } ?? windows
        guard key != shown else { return }
        shown = key
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let placeholder = placeholder {
            let open = AppControlsStyle.button(title: placeholder, target: self, action: #selector(openApp))
            stack.addArrangedSubview(open)
        }
        for (index, window) in windows.enumerated() {
            let chip = AppControlsStyle.button(title: "Win \(index + 1)", target: self, action: #selector(windowTapped(_:)))
            chip.tag = index
            if window.focused { chip.bezelColor = AppControlsStyle.selected }
            stack.addArrangedSubview(chip)
        }
        run.isEnabled = !windows.isEmpty
        command.isEnabled = !windows.isEmpty
        layoutStack()
    }

    /// Window titles through Accessibility ("file — project" → "project"). MTMR already holds the AX permission.
    private static func windows(of app: NSRunningApplication) -> ([Window], [AXUIElement]) {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return ([], []) }
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused)
        var found: [(Window, AXUIElement)] = []
        for element in elements {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            guard let text = title as? String, !text.isEmpty else { continue }
            let isFocused = focused.map { CFEqual($0, element) } ?? false
            found.append((Window(name: projectName(text), focused: isFocused), element))
        }
        // AX lists windows front to back, which changes on every focus; sort by project so "Win 2" stays the same window.
        found.sort { $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
        return (found.map { $0.0 }, found.map { $0.1 })
    }

    private static func projectName(_ title: String) -> String {
        // VS Code titles default to "file — folder" (sometimes with "[Extension Development Host]" etc.).
        let parts = title.components(separatedBy: " — ")
        return (parts.count > 1 ? parts[1] : parts[0]).trimmingCharacters(in: .whitespaces)
    }

    @objc private func windowTapped(_ sender: NSButton) {
        guard sender.tag < elements.count else { return }
        let element = elements[sender.tag]
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AppControlsApps.open(Self.bundleId)
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

    @objc private func openApp() { AppControlsApps.open(Self.bundleId) }
}
