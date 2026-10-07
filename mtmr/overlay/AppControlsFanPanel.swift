import Cocoa

/// Fan: mode button · curve graph (the slider in Custom) · temperature and RPM.
/// ThermalForge's root daemon writes the SMC; the curves are ours (FanController). Tap the mode button to open a
/// row with all modes (current one in the accent colour); tap one to select it. The row closes after 6 s.
/// In Custom, drag across the graph to set the fan speed.
final class AppControlsFanPanel: NSView, AppControlsPanel {
    static let id = "fan"
    static let name = "Fan"
    static func icon() -> NSImage { return fanIcon(size: TouchBarIcon.appBox) }
    let refreshInterval: TimeInterval = 1
    private static let pickerTimeout: TimeInterval = 6

    private lazy var modeButton = AppControlsStyle.button(title: "", size: 12, target: self, action: #selector(openPicker))
    private let graph = FanGraphView()
    private let readout = FanReadoutView()
    private var picker: [NSButton] = []
    private var pickerTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(modeButton)
        addSubview(graph)
        addSubview(readout)
        for mode in FanController.Mode.allCases {
            let button = AppControlsStyle.button(title: mode.title, size: 12, target: self, action: #selector(pickerChose(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
            button.isHidden = true
            picker.append(button)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        pickerTimer?.invalidate()
    }

    override func layout() {
        super.layout()
        AppControlsStyle.row([(modeButton, 64), (graph, nil), (readout, 54)], in: bounds)
        // Mode row: equal widths across the whole panel.
        let width = floor((bounds.width - 4 * CGFloat(picker.count - 1)) / CGFloat(picker.count))
        for (index, button) in picker.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * (width + 4), y: 0, width: width, height: bounds.height)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closePicker() }
    }

    func refresh() {
        let state = FanController.shared.state
        modeButton.title = state.mode.title
        graph.state = state
        readout.state = state
        for button in picker {
            button.bezelColor = button.identifier?.rawValue == state.mode.rawValue ? AppControlsStyle.selected : nil
        }
    }

    @objc private func openPicker() {
        refresh()
        showPicker(true)
        pickerTimer?.invalidate()
        pickerTimer = Timer.scheduledTimer(withTimeInterval: Self.pickerTimeout, repeats: false) { [weak self] _ in
            self?.closePicker()
        }
    }

    @objc private func pickerChose(_ sender: NSButton) {
        if let raw = sender.identifier?.rawValue, let mode = FanController.Mode(rawValue: raw) {
            FanController.shared.setMode(mode)
        }
        closePicker()
        refresh()
    }

    private func closePicker() {
        pickerTimer?.invalidate()
        pickerTimer = nil
        showPicker(false)
    }

    private func showPicker(_ shown: Bool) {
        for button in picker { button.isHidden = !shown }
        for view in [modeButton, graph, readout] as [NSView] { view.isHidden = shown }
    }
}

/// Graphite tile (as the System icon) with a white fan. The tint is drawn in: the switcher redraws icons as
/// non-template images, which turned a template glyph black (invisible) on the bar.
func fanIcon(size: CGFloat) -> NSImage {
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let tile = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)
        let corner = tile.width * 0.24
        let gradient = NSGradient(starting: NSColor(white: 0.42, alpha: 1), ending: NSColor(white: 0.2, alpha: 1))
        gradient?.draw(in: NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner), angle: -90)
        let glyphBox = tile.width * 0.66
        if let glyph = TouchBarIcon.symbol("fan", box: glyphBox, tint: .white) {
            glyph.draw(in: NSRect(x: tile.midX - glyph.size.width / 2, y: tile.midY - glyphBox / 2, width: glyph.size.width, height: glyphBox))
        }
        return true
    }
}

/// The last two minutes, newest on the right: the temperature line, the actual fan speed (shaded), the speed the
/// mode asks for (dashed), and the mode's thresholds as horizontal lines (fan on, full speed, 95 °C safety floor).
/// Temperature and fan speed share the height: 30–100 °C and 0–100 %. In Custom it is a slider instead.
final class FanGraphView: NSView {
    private static let coolest: Double = 30
    private static let hottest: Double = 100
    private static let floorTemperature: Double = 95

    var state = FanController.State() { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowedTouchTypes = .direct
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private var plot: NSRect { return bounds.insetBy(dx: 2, dy: 2) }

    /// Sample index → x; the newest sample sits on the right edge.
    private func x(_ index: Int) -> CGFloat {
        let slots = CGFloat(max(1, FanController.historyLength - 1))
        let age = CGFloat(state.history.count - 1 - index)
        return plot.maxX - plot.width * age / slots
    }

    private func y(temperature: Double) -> CGFloat {
        let fraction = (temperature - Self.coolest) / (Self.hottest - Self.coolest)
        return plot.minY + plot.height * CGFloat(min(1, max(0, fraction)))
    }

    private func y(fan: Double) -> CGFloat {
        return plot.minY + plot.height * CGFloat(min(1, max(0, fan)))
    }

    override func draw(_: NSRect) {
        if let message = state.error {
            drawMessage(message)
            return
        }
        if state.mode == .custom {
            drawSlider()
            return
        }
        drawFanArea()
        drawThresholds()
        drawTarget()
        drawTemperature()
    }

    private func drawThresholds() {
        var lines: [(temperature: Double, colour: NSColor)] = [(Self.floorTemperature, AppControlsStyle.bad.withAlphaComponent(0.55))]
        if let curve = FanController.curves[state.mode] {
            lines.append((curve.start, AppControlsStyle.secondaryText))
            lines.append((curve.full, AppControlsStyle.secondaryText))
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .medium)
        for line in lines {
            let level = y(temperature: line.temperature)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: plot.minX + 12, y: level))
            path.line(to: NSPoint(x: plot.maxX, y: level))
            path.lineWidth = 0.5
            path.setLineDash([2, 2], count: 2, phase: 0)
            line.colour.setStroke()
            path.stroke()
            ("\(Int(line.temperature))" as NSString).draw(at: NSPoint(x: plot.minX, y: level - 4.5), withAttributes: [.font: font, .foregroundColor: line.colour])
        }
    }

    private func drawFanArea() {
        let history = state.history
        guard history.count > 1 else { return }
        let area = NSBezierPath()
        area.move(to: NSPoint(x: x(0), y: plot.minY))
        for (index, sample) in history.enumerated() { area.line(to: NSPoint(x: x(index), y: y(fan: sample.fan))) }
        area.line(to: NSPoint(x: x(history.count - 1), y: plot.minY))
        area.close()
        NSColor.systemBlue.withAlphaComponent(0.35).setFill()
        area.fill()
    }

    /// What the mode asks for; absent in Apple mode (Apple's target is not visible).
    private func drawTarget() {
        let path = NSBezierPath()
        var drawing = false
        for (index, sample) in state.history.enumerated() {
            guard let target = sample.target else {
                drawing = false
                continue
            }
            let point = NSPoint(x: x(index), y: y(fan: target))
            if drawing { path.line(to: point) } else { path.move(to: point) }
            drawing = true
        }
        path.lineWidth = 1
        path.setLineDash([3, 2], count: 2, phase: 0)
        NSColor.systemBlue.setStroke()
        path.stroke()
    }

    private func drawTemperature() {
        let history = state.history
        guard let last = history.last else { return }
        let line = NSBezierPath()
        for (index, sample) in history.enumerated() {
            let point = NSPoint(x: x(index), y: y(temperature: sample.temperature))
            if index == 0 { line.move(to: point) } else { line.line(to: point) }
        }
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        let colour = FanController.heatColour(last.temperature)
        colour.setStroke()
        line.stroke()
        colour.setFill()
        let end = NSPoint(x: x(history.count - 1), y: y(temperature: last.temperature))
        NSBezierPath(ovalIn: NSRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)).fill()
    }

    /// Custom: a track filled to the chosen speed, a knob, and the % inside the track's empty part.
    private func drawSlider() {
        let track = NSRect(x: plot.minX, y: bounds.midY - 4, width: plot.width, height: 8)
        AppControlsStyle.track.setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        let knobX = track.minX + track.width * CGFloat(state.customPercent)
        AppControlsStyle.neutralFill.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: max(8, knobX - track.minX), height: track.height), xRadius: 4, yRadius: 4).fill()
        AppControlsStyle.primaryText.setFill()
        NSBezierPath(ovalIn: NSRect(x: knobX - 8, y: bounds.midY - 8, width: 16, height: 16)).fill()
        let text = "\(Int((state.customPercent * 100).rounded()))%"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold), .foregroundColor: AppControlsStyle.secondaryText]
        let size = (text as NSString).size(withAttributes: attributes)
        // On the side of the knob with more room.
        let textX = knobX < track.midX ? track.maxX - size.width - 2 : track.minX + 2
        (text as NSString).draw(at: NSPoint(x: textX, y: track.maxY + 1), withAttributes: attributes)
    }

    private func drawMessage(_ message: String) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: AppControlsStyle.warn, .paragraphStyle: style]
        (message as NSString).draw(in: NSRect(x: 0, y: bounds.midY - 7, width: bounds.width, height: 14), withAttributes: attributes)
    }

    // MARK: Custom slider touches

    override func touchesBegan(with event: NSEvent) { slide(event, phase: .began) }
    override func touchesMoved(with event: NSEvent) { slide(event, phase: .moved) }
    override func touchesEnded(with event: NSEvent) { slide(event, phase: .ended) }
    override func touchesCancelled(with event: NSEvent) { slide(event, phase: .cancelled) }

    private func slide(_ event: NSEvent, phase: NSTouch.Phase) {
        guard state.mode == .custom, state.error == nil else { return }
        guard let touch = event.touches(matching: phase, in: self).first(where: { $0.type == .direct }) else { return }
        let fraction = Double((touch.location(in: self).x - plot.minX) / max(1, plot.width))
        let finished = phase == .ended || phase == .cancelled
        FanController.shared.setCustomPercent(fraction, commit: finished)
        state = FanController.shared.state
    }
}

/// Temperature (coloured by heat) over the fan speed.
final class FanReadoutView: NSView {
    var state = FanController.State() { didSet { needsDisplay = true } }

    override func draw(_: NSRect) {
        let temperature = state.temperature.map { "\(Int($0.rounded()))°" } ?? "–"
        let colour = state.temperature.map { FanController.heatColour($0) } ?? AppControlsStyle.secondaryText
        draw(temperature, size: 13, colour: colour, y: 13, height: 16)
        let speed = state.rpm.map { $0 == 0 ? "off" : "\($0) rpm" } ?? "–"
        draw(speed, size: 9, colour: AppControlsStyle.secondaryText, y: 2, height: 12)
    }

    private func draw(_ text: String, size: CGFloat, colour: NSColor, y: CGFloat, height: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold), .foregroundColor: colour, .paragraphStyle: style]
        (text as NSString).draw(in: NSRect(x: 0, y: y, width: bounds.width, height: height), withAttributes: attributes)
    }
}

/// Runs the fan curve whether or not the Fan panel is on screen: every 2 s it reads ThermalForge's status, picks the
/// speed for the current mode, and sends `set` / `max` / `auto`, or a `heartbeat` to keep a hold alive. If MTMR
/// stops, the daemon's watchdog hands the fans back to Apple after 15 s. Started when the zone loads.
final class FanController {
    enum Mode: String, CaseIterable {
        case apple, quiet, cool, max, custom
        var title: String { return rawValue.capitalized }
    }

    /// Fan % over temperature. Off below `start` (with hysteresis once running), ease-in up to `top` at `full`.
    struct Curve {
        static let hysteresis: Double = 5
        let start: Double
        let full: Double
        let top: Double
        let exponent: Double

        func percent(at temperature: Double, running: Bool) -> Double? {
            guard temperature >= (running ? start - Self.hysteresis : start) else { return nil }
            let position = min(1, max(0, (temperature - start) / (full - start)))
            return top * pow(position, exponent)
        }
    }

    struct Sample {
        var temperature: Double
        /// Actual fan speed, 0–1 of the fan's range.
        var fan: Double
        /// The speed the mode asks for, 0–1; nil in Apple mode.
        var target: Double?
    }

    struct State {
        var mode: Mode = .cool
        var customPercent: Double = 0.4
        var temperature: Double?
        var rpm: Int?
        var minRPM = 0
        var maxRPM = 0
        var error: String?
        /// Oldest first, one sample per tick (2 s), at most `historyLength`.
        var history: [Sample] = []

        /// Actual fan speed as a fraction of the fan's range (0 when off).
        var fanFraction: Double {
            guard let rpm = rpm, rpm > 0, maxRPM > minRPM else { return 0 }
            return min(1, max(0, Double(rpm - minRPM) / Double(maxRPM - minRPM)))
        }
    }

    private enum Command: Equatable {
        case auto, max, rpm(Int)

        var request: [String: Any] {
            switch self {
            case .auto: return ["verb": "auto"]
            case .max: return ["verb": "max"]
            case .rpm(let rpm): return ["verb": "set", "rpm": rpm]
            }
        }
    }

    private struct Reading {
        var temperature: Double?
        var rpm: Int?
        var minRPM = 0
        var maxRPM = 0
        var error: String?
        /// The speed the mode asks for, 0–1; nil in Apple mode.
        var target: Double?
        /// Custom mode passed `customLimit`; the controller already ran the Cool curve.
        var tooHot = false
    }

    static let shared = FanController()
    static let curves: [Mode: Curve] = [
        .quiet: Curve(start: 70, full: 90, top: 0.5, exponent: 2),
        .cool: Curve(start: 45, full: 75, top: 1, exponent: 2),
    ]
    /// Custom switches to Cool at this temperature (°C).
    static let customLimit: Double = 85
    private static let interval: TimeInterval = 2
    /// Two minutes of samples.
    static let historyLength = 60
    /// Slowest way down per tick, so the fan winds down instead of dropping (rpm).
    private static let rampDownPerTick = 300
    /// Smaller changes are not written; a heartbeat keeps the hold alive instead (rpm).
    private static let minimumChange = 100
    private static let modeKey = "FanMode"
    private static let percentKey = "FanCustomPercent"

    private(set) var state = State()
    private var timer: Timer?
    private var ticking = false
    private var tickAgain = false
    private let queue = DispatchQueue(label: "MTMRFanController")
    // Only touched on `queue`.
    private var smoothed: Double?
    private var sent: Command?
    private var running = false

    private init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Self.modeKey), let mode = Mode(rawValue: stored) { state.mode = mode }
        if defaults.object(forKey: Self.percentKey) != nil { state.customPercent = min(1, max(0, defaults.double(forKey: Self.percentKey))) }
    }

    static func heatColour(_ temperature: Double) -> NSColor {
        return temperature >= 90 ? AppControlsStyle.bad : temperature >= 75 ? AppControlsStyle.warn : AppControlsStyle.primaryText
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        registerSocketCommand()
        guard timer == nil else { return }
        let poll = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.tick() }
        timer = poll
        RunLoop.main.add(poll, forMode: .common)
        tick()
    }

    func setMode(_ mode: Mode) {
        dispatchPrecondition(condition: .onQueue(.main))
        state.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        tick()
    }

    func cycleMode() {
        let modes = Mode.allCases
        let index = modes.firstIndex(of: state.mode) ?? 0
        setMode(modes[(index + 1) % modes.count])
    }

    /// `commit` (touch ended) saves the value and applies it now; while dragging only the UI follows.
    func setCustomPercent(_ percent: Double, commit: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        state.customPercent = min(1, max(0, percent))
        guard commit else { return }
        UserDefaults.standard.set(state.customPercent, forKey: Self.percentKey)
        tick()
    }

    /// `{"cmd":"fan"}` reports; `"mode"` and `"percent"` (0–100, Custom) change it.
    private func registerSocketCommand() {
        NotificationSocketServer.shared.register("fan") { [weak self] fields in
            guard let self = self else { return [:] }
            if let percent = fields["percent"] as? Double {
                guard (0...100).contains(percent) else { throw LiveButtonError(message: "percent must be 0–100") }
                self.setCustomPercent(percent / 100, commit: true)
            }
            if let name = fields["mode"] as? String {
                guard let mode = Mode(rawValue: name) else {
                    throw LiveButtonError(message: "unknown fan mode: \(name) (\(Mode.allCases.map { $0.rawValue }.joined(separator: ", ")))")
                }
                self.setMode(mode)
            }
            return ["fan": self.report()]
        }
    }

    private func report() -> [String: Any] {
        var fields: [String: Any] = ["mode": state.mode.rawValue, "customPercent": Int((state.customPercent * 100).rounded())]
        if let temperature = state.temperature { fields["temperature"] = (temperature * 10).rounded() / 10 }
        if let rpm = state.rpm { fields["rpm"] = rpm }
        if let error = state.error { fields["error"] = error }
        return fields
    }

    private func tick() {
        guard !ticking else {
            tickAgain = true
            return
        }
        ticking = true
        let mode = state.mode
        let percent = state.customPercent
        queue.async { [weak self] in
            guard let self = self else { return }
            let reading = self.control(mode: mode, customPercent: percent)
            DispatchQueue.main.async {
                self.ticking = false
                self.update(reading)
                if self.tickAgain {
                    self.tickAgain = false
                    self.tick()
                }
            }
        }
    }

    private func update(_ reading: Reading) {
        state.temperature = reading.temperature
        state.rpm = reading.rpm
        state.minRPM = reading.minRPM
        state.maxRPM = reading.maxRPM
        state.error = reading.error
        if let temperature = reading.temperature {
            state.history.append(Sample(temperature: temperature, fan: state.fanFraction, target: reading.target))
            if state.history.count > Self.historyLength { state.history.removeFirst(state.history.count - Self.historyLength) }
        }
        if reading.tooHot && state.mode == .custom {
            setMode(.cool)
            let temperature = reading.temperature.map { " at \(Int($0.rounded()))°" } ?? ""
            _ = NotificationStore.shared.notify(text: "Custom → Cool\(temperature)", seconds: 10, icon: AppControlsFanPanel.icon(), title: "Fan")
        }
    }

    // MARK: On `queue`

    private func control(mode: Mode, customPercent: Double) -> Reading {
        var reading = Reading()
        guard let status = ThermalForgeClient.status() else {
            sent = nil
            reading.error = "ThermalForge not running"
            return reading
        }
        reading.rpm = status.rpm
        reading.minRPM = status.minRPM
        reading.maxRPM = status.maxRPM
        guard let peak = status.peakTemperature else {
            // No temperature: hand the fans to Apple rather than guess.
            reading.error = send(.auto, fanMode: status.mode) ?? "No temperature"
            return reading
        }
        let temperature = smoothed.map { $0 + 0.35 * (peak - $0) } ?? peak
        smoothed = temperature
        reading.temperature = temperature
        var effective = mode
        if mode == .custom && temperature >= Self.customLimit {
            effective = .cool
            reading.tooHot = true
        }
        let desired: Command
        switch effective {
        case .apple:
            desired = .auto
        case .max:
            desired = .max
        case .custom:
            desired = .rpm(rpm(customPercent, status))
        case .quiet, .cool:
            if let percent = Self.curves[effective]?.percent(at: temperature, running: running) {
                running = true
                desired = .rpm(rpm(percent, status))
            } else {
                running = false
                desired = .auto
            }
        }
        if effective != .quiet && effective != .cool { running = false }
        reading.error = send(desired, fanMode: status.mode)
        switch desired {
        case .auto: reading.target = effective == .apple ? nil : 0
        case .max: reading.target = 1
        case .rpm(let rpm): reading.target = status.maxRPM > status.minRPM ? Double(rpm - status.minRPM) / Double(status.maxRPM - status.minRPM) : nil
        }
        return reading
    }

    private func rpm(_ percent: Double, _ status: ThermalForgeClient.Status) -> Int {
        return status.minRPM + Int((Double(status.maxRPM - status.minRPM) * min(1, max(0, percent))).rounded())
    }

    /// Writes only real changes; otherwise a heartbeat keeps a hold alive. Returns an error to show, if any.
    private func send(_ desired: Command, fanMode: String) -> String? {
        var command = desired
        if case .rpm(let target) = desired, case .rpm(let last)? = sent, target < last - Self.rampDownPerTick {
            command = .rpm(last - Self.rampDownPerTick)
        }
        let holding = command != .auto
        // The daemon dropped our hold (watchdog, restart, `thermalforge auto`): write it again.
        let lost = holding && fanMode == "auto"
        let write: Bool
        switch (command, sent) {
        case (.rpm(let next), .rpm(let last)?):
            write = lost || abs(next - last) >= Self.minimumChange
        default:
            write = lost || command != sent
        }
        let request: [String: Any]
        if write {
            request = command.request
        } else if holding {
            request = ["verb": "heartbeat"]
        } else {
            return nil
        }
        guard let response = ThermalForgeClient.request(request) else {
            if write { sent = nil }
            return "ThermalForge not running"
        }
        if response["ok"] as? Bool == true {
            if write { sent = command }
            return nil
        }
        if write { sent = nil }
        switch response["error"] as? String {
        case "heldByCLI": return "Held by thermalforge CLI"
        case "rateLimited": return nil
        default: return (response["message"] as? String) ?? "ThermalForge error"
        }
    }
}

/// ThermalForge daemon socket: 4-byte big-endian length + JSON, one request per connection. Only the user who
/// installed the daemon may connect (no sudo). Protocol: ThermalForge/Sources/ThermalForgeCore/DaemonProtocol.swift.
enum ThermalForgeClient {
    static let socketPath = "/var/run/thermalforge.sock"
    private static let protocolVersion = 1
    private static let maxResponseBytes = 64 * 1024

    struct Status {
        var rpm: Int
        var minRPM: Int
        var maxRPM: Int
        var mode: String
        /// Hottest CPU (`TC`/`Tp`) or GPU (`TG`/`Tg`) sensor: the value the daemon's 95 °C floor watches.
        var peakTemperature: Double?
    }

    static func status() -> Status? {
        guard let response = request(["verb": "status"]), response["ok"] as? Bool == true,
              let text = response["statusJSON"] as? String, let data = text.data(using: .utf8),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fan = (status["fans"] as? [[String: Any]])?.first else { return nil }
        let temperatures = status["temperatures"] as? [String: Double] ?? [:]
        let peak = temperatures.filter { key, _ in ["TC", "Tp", "TG", "Tg"].contains { key.hasPrefix($0) } }.values.max()
        return Status(rpm: fan["actual_rpm"] as? Int ?? 0, minRPM: fan["min_rpm"] as? Int ?? 0, maxRPM: fan["max_rpm"] as? Int ?? 0,
                      mode: fan["mode"] as? String ?? "auto", peakTemperature: peak)
    }

    /// Sends one request and returns the reply, or nil when the daemon is not reachable. Blocks up to ~2 s.
    static func request(_ fields: [String: Any]) -> [String: Any]? {
        var body = fields
        body["v"] = protocolVersion
        body["oneshot"] = false
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path)
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        let length = UInt32(payload.count).bigEndian
        guard writeAll(fd, withUnsafeBytes(of: length) { Data($0) } + payload),
              let header = readAll(fd, 4) else { return nil }
        let size = header.reduce(0) { $0 << 8 | Int($1) }
        guard size > 0, size <= maxResponseBytes, let reply = readAll(fd, size) else { return nil }
        return try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        return data.withUnsafeBytes { buffer -> Bool in
            var sent = 0
            while sent < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private static func readAll(_ fd: Int32, _ count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let read = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: got), count - got) }
            guard read > 0 else { return nil }
            got += read
        }
        return Data(buffer)
    }
}
