import Cocoa

/// Shared pushed state stays alive while other panels show, so meeting focus can select Teams.
final class TeamsPanelController {
    static let shared = TeamsPanelController()
    static let changed = Notification.Name("MTMRTeamsStateChanged")
    private(set) var snapshot: TeamsSnapshot?
    private(set) var clock = TeamsClock()
    var autoSelection = TeamsAutoSelection()
    private var options = TeamsPanelOptions()
    private var optimistic: [String: (TeamsSnapshot.DeviceState, Double)] = [:]
    private var revision = 0
    private let commandQueue = DispatchQueue(label: "MTMRTeamsCommands")

    func configure(_ options: TeamsPanelOptions) {
        self.options = options
        NotificationSocketServer.shared.register("teams") { fields in
            let bytes = try JSONSerialization.data(withJSONObject: fields)
            let snapshot = try JSONDecoder().decode(TeamsSnapshot.self, from: bytes)
            self.receive(snapshot)
            return [:]
        }
    }

    private func receive(_ snapshot: TeamsSnapshot) {
        self.snapshot = snapshot
        clock.receive(snapshot, at: Date().timeIntervalSince1970)
        optimistic.removeAll()
        revision += 1
        if let selected = autoSelection.receive(snapshot, current: AppControlsSelection.shared.id) {
            do { try AppControlsSelection.shared.select(selected, automatic: true) }
            catch { NSLog("MTMR Teams selection failed: %@", error.localizedDescription) }
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    var canToggle: Bool {
        guard snapshot?.active == true else { return false }
        return options.directory != nil
    }

    func state(_ device: String) -> TeamsSnapshot.DeviceState {
        if let (state, expiresAt) = optimistic[device], ProcessInfo.processInfo.systemUptime < expiresAt { return state }
        return device == "mic" ? snapshot?.microphone ?? .unknown : snapshot?.camera ?? .unknown
    }

    func toggle(_ device: String) {
        guard canToggle, let directory = options.directory else { return }
        if let (_, expiresAt) = optimistic[device], ProcessInfo.processInfo.systemUptime < expiresAt { return }
        let previous = state(device)
        let next: TeamsSnapshot.DeviceState = previous == .on ? (device == "mic" ? .muted : .off) : .on
        optimistic[device] = (previous == .unknown ? .unknown : next, ProcessInfo.processInfo.systemUptime + 5)
        NotificationCenter.default.post(name: Self.changed, object: self)
        let revision = self.revision
        commandQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: directory).appendingPathComponent(device == "mic" ? "teams-mic-tap" : "teams-camera-tap")
            // Output goes to MTMR's existing log stream; do not retain unread pipes.
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            var succeeded = false
            do {
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 6, execute: timeout)
                process.waitUntilExit()
                timeout.cancel()
                succeeded = process.terminationStatus == 0
                if !succeeded {
                    NSLog("MTMR Teams tap failed: exit %d", process.terminationStatus)
                }
            } catch { NSLog("MTMR Teams tap failed: %@", error.localizedDescription) }
            // Never retry a toggle: a lost response could otherwise toggle the device twice.
            let commandFailed = !succeeded
            DispatchQueue.main.async {
                if commandFailed, self.revision == revision { self.optimistic[device] = nil }
                NotificationCenter.default.post(name: Self.changed, object: self)
            }
        }
    }
}

final class AppControlsTeamsPanel: NSView, AppControlsPanel {
    static let id = "teams"
    static let name = "Teams"
    static func icon() -> NSImage {
        if let icon = AppControlsApps.icon("com.microsoft.teams2") { return icon }
        return NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            NSColor(white: 0.28, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            if let glyph = TouchBarIcon.symbol("person.2.fill", box: 18, tint: .white) {
                glyph.draw(at: NSPoint(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2),
                           from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
    }
    let refreshInterval: TimeInterval = 1
    private let title = AppControlsStyle.label(size: 12, weight: .semibold)
    private let duration = AppControlsStyle.label(size: 11, weight: .medium, color: AppControlsStyle.bad, monospacedDigits: true)
    private let status = AppControlsStyle.label(size: 13, color: AppControlsStyle.secondaryText)
    private lazy var microphone = AppControlsStyle.button(symbol: "mic.fill", target: self, action: #selector(microphoneTapped))
    private lazy var camera = AppControlsStyle.button(symbol: "video.fill", target: self, action: #selector(cameraTapped))
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [title, duration, status, microphone, camera] as [NSView] { addSubview(view) }
        status.alignment = .center
        microphone.toolTip = "Toggle Teams microphone"
        camera.toolTip = "Toggle Teams camera"
        observer = NotificationCenter.default.addObserver(forName: TeamsPanelController.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) { return nil }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }

    override func layout() {
        super.layout()
        let geometry = TeamsPanelGeometry(width: bounds.width)
        let buttonWidth = TeamsPanelGeometry.buttonWidth
        title.frame = NSRect(x: 0, y: 15, width: geometry.textWidth, height: 15)
        duration.frame = NSRect(x: 0, y: 1, width: geometry.textWidth, height: 14)
        microphone.frame = NSRect(x: geometry.microphoneX, y: 0, width: buttonWidth, height: 30)
        camera.frame = NSRect(x: geometry.cameraX, y: 0, width: buttonWidth, height: 30)
        let statusHeight = ceil(status.intrinsicContentSize.height)
        status.frame = NSRect(x: 0, y: floor((bounds.height - statusHeight) / 2), width: floor(bounds.width), height: statusHeight)
    }

    func refresh() {
        let controller = TeamsPanelController.shared
        let active = controller.snapshot?.active == true
        status.isHidden = active
        for view in [title, duration, microphone, camera] as [NSView] { view.isHidden = !active }
        status.stringValue = controller.snapshot?.online == true ? "No meeting" : "Teams offline"
        let meetingTitle = controller.snapshot?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let genericTitles = ["", "microsoft teams", "chat", "calendar", "activity", "teams"]
        title.stringValue = genericTitles.contains(meetingTitle.lowercased()) ? "Meeting" : meetingTitle
        duration.stringValue = controller.clock.text(at: Date().timeIntervalSince1970)
        updateButton(microphone, device: "mic", live: "mic.fill", stopped: "mic.slash.fill")
        updateButton(camera, device: "camera", live: "video.fill", stopped: "video.slash.fill")
        microphone.isEnabled = controller.canToggle
        camera.isEnabled = controller.canToggle
        needsLayout = true
    }

    private func updateButton(_ button: NSButton, device: String, live: String, stopped: String) {
        let state = TeamsPanelController.shared.state(device)
        let color = state == .unknown ? AppControlsStyle.secondaryText : state == .on ? AppControlsStyle.good : AppControlsStyle.bad
        button.image = TouchBarIcon.symbol(state == .on ? live : stopped, tint: color)
    }

    @objc private func microphoneTapped() { TeamsPanelController.shared.toggle("mic") }
    @objc private func cameraTapped() { TeamsPanelController.shared.toggle("camera") }
}
