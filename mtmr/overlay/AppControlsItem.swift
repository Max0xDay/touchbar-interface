import Cocoa

/// App Controls: the right-hand zone of the bar. One panel is shown at a time (System, YouTube Music, VS Code,
/// Stats, ...). The user picks it with the switcher button; the choice is persistent and does not follow the
/// frontmost app. Contract for adding a panel: docs/app-controls.md.
protocol AppControlsPanel: NSView {
    static var id: String { get }
    static var name: String { get }
    static func icon() -> NSImage
    init(frame frameRect: NSRect)
    /// Seconds between refresh() calls while the panel is on screen.
    var refreshInterval: TimeInterval { get }
    func refresh()
}

enum AppControlsRegistry {
    static let panels: [AppControlsPanel.Type] = [
        AppControlsSystemPanel.self,
        AppControlsMusicPanel.self,
        AppControlsCodePanel.self,
        AppControlsStatsPanel.self,
    ]
    static let fallbackId = AppControlsSystemPanel.id

    static func panel(_ id: String) -> AppControlsPanel.Type? {
        return panels.first { $0.id == id }
    }
}

struct AppControlsOptions: Decodable, Equatable {
    let panels: [String]

    init(panels: [String] = AppControlsRegistry.panels.map { $0.id }) {
        self.panels = panels
    }

    private enum CodingKeys: String, CodingKey { case panels }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let panels = try container.decodeIfPresent([String].self, forKey: .panels) ?? AppControlsRegistry.panels.map { $0.id }
        for id in panels where AppControlsRegistry.panel(id) == nil {
            throw DecodingError.dataCorruptedError(forKey: .panels, in: container, debugDescription: "unknown app controls panel: \(id)")
        }
        guard !panels.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .panels, in: container, debugDescription: "panels must not be empty")
        }
        self.init(panels: panels)
    }
}

/// The selected panel. Persists across restarts and layout reloads; changed by the switcher or the socket.
final class AppControlsSelection {
    static let shared = AppControlsSelection()
    static let changed = Notification.Name("MTMRAppControlsSelectionChanged")
    private static let defaultsKey = "AppControlsPanel"

    private(set) var id: String

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? AppControlsRegistry.fallbackId
        id = AppControlsRegistry.panel(stored) == nil ? AppControlsRegistry.fallbackId : stored
    }

    func select(_ id: String) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard AppControlsRegistry.panel(id) != nil else { throw LiveButtonError(message: "unknown app panel: \(id)") }
        guard id != self.id else { return }
        self.id = id
        UserDefaults.standard.set(id, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// `{"cmd":"app","id":"stats"}` selects a panel; `{"cmd":"apps"}` lists them. Registered once the layout has the zone.
    static func registerSocketCommands() {
        NotificationSocketServer.shared.register("app") { fields in
            guard let id = fields["id"] as? String else { throw LiveButtonError(message: "app requires id") }
            try shared.select(id)
            return [:]
        }
        NotificationSocketServer.shared.register("apps") { _ in
            return ["apps": shared.list()]
        }
    }

    func list() -> [[String: Any]] {
        return AppControlsRegistry.panels.map { ["id": $0.id, "name": $0.name, "selected": $0.id == id] }
    }
}

final class AppControlsTouchBarItem: NSCustomTouchBarItem {
    init(identifier: NSTouchBarItem.Identifier, options: AppControlsOptions) {
        super.init(identifier: identifier)
        AppControlsSelection.registerSocketCommands()
        view = AppControlsView(options: options)
    }

    required init?(coder: NSCoder) {
        return nil
    }
}

final class AppControlsView: NSView {
    private static let switcherWidth: CGFloat = 36
    private static let pickerButtonWidth: CGFloat = 44
    private static let pickerTimeout: TimeInterval = 6

    private let options: AppControlsOptions
    private let switcher: NSButton
    private let content = NSView()
    private let picker = NSScrollView()
    private var panel: AppControlsPanel?
    private var refreshTimer: Timer?
    private var pickerTimer: Timer?
    private var picking = false
    private var selectionObserver: NSObjectProtocol?

    init(options: AppControlsOptions) {
        self.options = options
        switcher = NSButton(image: NSImage(), target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: AppControlsStyle.height))
        wantsLayer = true
        layer?.masksToBounds = true
        // Borderless: app icons carry their own shape, so the icon can use the full bar height.
        switcher.isBordered = false
        switcher.imagePosition = .imageOnly
        switcher.imageScaling = .scaleNone
        switcher.target = self
        switcher.action = #selector(switcherTapped)
        content.wantsLayer = true
        picker.drawsBackground = false
        picker.hasHorizontalScroller = false
        picker.wantsLayer = true
        picker.isHidden = true
        addSubview(content)
        addSubview(picker)
        addSubview(switcher)
        selectionObserver = NotificationCenter.default.addObserver(forName: AppControlsSelection.changed, object: nil, queue: .main) { [weak self] _ in
            self?.showSelectedPanel(animated: true)
        }
        showSelectedPanel(animated: false)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        if let observer = selectionObserver { NotificationCenter.default.removeObserver(observer) }
        refreshTimer?.invalidate()
        pickerTimer?.invalidate()
    }

    override func layout() {
        super.layout()
        switcher.frame = NSRect(x: 0, y: 0, width: Self.switcherWidth, height: bounds.height)
        let contentFrame = NSRect(x: Self.switcherWidth + AppControlsStyle.gap, y: 0, width: max(0, bounds.width - Self.switcherWidth - AppControlsStyle.gap), height: bounds.height)
        content.frame = contentFrame
        picker.frame = contentFrame
        panel?.frame = content.bounds
        layoutPicker()
    }

    // Timers run only while the view is on the bar; item instances that MTMR builds and throws away never start one.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            refreshTimer?.invalidate()
            refreshTimer = nil
            closePicker(animated: false)
        } else {
            startRefreshing()
        }
    }

    private func visiblePanelIds() -> [String] {
        let selected = AppControlsSelection.shared.id
        return options.panels.contains(selected) ? options.panels : [selected] + options.panels
    }

    private func showSelectedPanel(animated: Bool) {
        let id = AppControlsSelection.shared.id
        guard let panelType = AppControlsRegistry.panel(id) else { return }
        if let current = panel, type(of: current).id == id { return }
        let next = panelType.init(frame: content.bounds)
        next.autoresizingMask = [.width, .height]
        let previous = panel
        panel = next
        switcher.image = Self.switcherIcon(panelType)
        next.alphaValue = animated ? 0 : 1
        content.addSubview(next)
        next.refresh()
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                next.animator().alphaValue = 1
                previous?.animator().alphaValue = 0
            }, completionHandler: { previous?.removeFromSuperview() })
        } else {
            next.alphaValue = 1
            previous?.removeFromSuperview()
        }
        startRefreshing()
    }

    private func startRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard window != nil, let panel = panel else { return }
        let timer = Timer(timeInterval: max(0.25, panel.refreshInterval), repeats: true) { [weak self] _ in
            self?.panel?.refresh()
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Picker

    @objc private func switcherTapped() {
        if picking {
            closePicker(animated: true)
        } else {
            openPicker()
        }
    }

    private func openPicker() {
        picking = true
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = AppControlsStyle.gap
        let selected = AppControlsSelection.shared.id
        for id in visiblePanelIds() {
            guard let type = AppControlsRegistry.panel(id) else { continue }
            let button = NSButton(image: type.icon(), target: self, action: #selector(pickerChose(_:)))
            button.bezelStyle = .rounded
            button.imagePosition = .imageOnly
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.toolTip = type.name
            if id == selected { button.bezelColor = AppControlsStyle.selected }
            button.widthAnchor.constraint(equalToConstant: Self.pickerButtonWidth).isActive = true
            stack.addArrangedSubview(button)
        }
        picker.documentView = stack
        layoutPicker()
        switcher.image = AppControlsStyle.symbolImage("xmark", box: 14)
        crossFade(show: picker, hide: content)
        pickerTimer?.invalidate()
        pickerTimer = Timer.scheduledTimer(withTimeInterval: Self.pickerTimeout, repeats: false) { [weak self] _ in
            self?.closePicker(animated: true)
        }
    }

    private static func switcherIcon(_ type: AppControlsPanel.Type) -> NSImage {
        return TouchBarIcon.fitted(type.icon(), box: TouchBarIcon.switcherBox, template: false)
    }

    private func layoutPicker() {
        guard let stack = picker.documentView else { return }
        // Exactly the fitting width: a wider frame stretches the fixed-width buttons and conflicts with their constraints.
        stack.frame = NSRect(x: 0, y: 0, width: stack.fittingSize.width, height: picker.bounds.height)
    }

    private func closePicker(animated: Bool) {
        pickerTimer?.invalidate()
        pickerTimer = nil
        guard picking else { return }
        picking = false
        if let type = AppControlsRegistry.panel(AppControlsSelection.shared.id) { switcher.image = Self.switcherIcon(type) }
        if animated {
            crossFade(show: content, hide: picker)
        } else {
            picker.isHidden = true
            content.isHidden = false
            content.alphaValue = 1
        }
    }

    @objc private func pickerChose(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        do {
            try AppControlsSelection.shared.select(id)
        } catch {
            NSLog("MTMR app controls: %@", error.localizedDescription)
        }
        closePicker(animated: true)
    }

    private func crossFade(show: NSView, hide: NSView) {
        show.isHidden = false
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            show.alphaValue = 1
            hide.isHidden = true
            return
        }
        show.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            show.animator().alphaValue = 1
            hide.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A later fade may have reversed this one; only hide what is still meant to be hidden.
            guard let self = self else { return }
            let pickerShown = self.picking
            self.picker.isHidden = !pickerShown
            self.content.isHidden = pickerShown
        })
    }
}
