import Cocoa

/// lob: one chip per lob session (tmux session "<project>-NN"), animated by state:
/// working = spinning arc, finished = pulsing green (awaiting your reply), idle = still grey dot.
/// Display only: taps do nothing (replies go through Claude remote control).
final class AppControlsLobPanel: NSView, AppControlsPanel {
    static let id = "lob"
    static let name = "lob"
    static func icon() -> NSImage { return lobIcon(size: TouchBarIcon.appBox) }
    let refreshInterval: TimeInterval = 1

    private let scroll = NSScrollView()
    private let stack = NSView()
    private let empty = AppControlsStyle.label(size: 12, color: AppControlsStyle.secondaryText)
    private var chips: [String: LobSessionChip] = [:]
    private var order: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        empty.stringValue = "No lob sessions"
        addSubview(scroll)
        addSubview(empty)
        LobMonitor.shared.start()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        empty.frame = NSRect(x: 4, y: 7, width: bounds.width - 8, height: 16)
        layoutChips()
    }

    /// Chips share the width equally (at least 68 pt each); more sessions than fit scroll sideways.
    private func layoutChips() {
        let count = CGFloat(order.count)
        guard count > 0 else { return }
        let width = max(68, floor((bounds.width - AppControlsStyle.gap * (count - 1)) / count))
        for name in order { chips[name]?.frame.size = NSSize(width: width, height: bounds.height) }
        stack.frame = NSRect(x: 0, y: 0, width: width * count + AppControlsStyle.gap * (count - 1), height: bounds.height)
        for (index, name) in order.enumerated() {
            chips[name]?.frame.origin = NSPoint(x: CGFloat(index) * (width + AppControlsStyle.gap), y: 0)
        }
    }

    func refresh() {
        let sessions = LobMonitor.shared.sessions
        empty.isHidden = !sessions.isEmpty
        let names = sessions.map { $0.name }
        if names != order {
            for (name, chip) in chips where !names.contains(name) {
                chip.removeFromSuperview()
                chips.removeValue(forKey: name)
            }
            for name in names where chips[name] == nil {
                let chip = LobSessionChip()
                chips[name] = chip
                stack.addSubview(chip)
            }
            order = names
            layoutChips()
        }
        for session in sessions { chips[session.name]?.show(session) }
    }
}

/// Watches lob's tmux sessions. Working = Claude's spinner line above the prompt: glyph, verb and an ellipsis,
/// e.g. "✢ Tinkering… (thought for 2s)"; when done it reads "✻ Baked for 3s · done 3:30 PM" (no ellipsis).
/// Verified 2026-10-06. The status line's "esc to interrupt" is not used: narrow panes truncate it.
/// Runs from the moment the App Controls zone loads, so finishes are caught even while another panel shows.
final class LobMonitor {
    enum State: Equatable {
        case working(since: Date)
        case finished(at: Date)
        case idle
    }

    struct Session: Equatable {
        let name: String
        let project: String
        let state: State
    }

    static let shared = LobMonitor()
    /// A finished session without a reply turns idle after this long.
    private static let finishedFor: TimeInterval = 30 * 60
    private static let sessionPattern = try! NSRegularExpression(pattern: "^(.+)-([0-9]{2})$")
    private static let spinnerPattern = try! NSRegularExpression(pattern: "^\\S\\s+\\p{Lu}\\p{Ll}+…")

    private(set) var sessions: [Session] = []
    private var timer: Timer?
    private var polling = false
    private let queue = DispatchQueue(label: "MTMRLobMonitor")
    private lazy var tmux: String? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard timer == nil else { return }
        let poll = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        timer = poll
        RunLoop.main.add(poll, forMode: .common)
        self.poll()
    }

    private func poll() {
        guard !polling, let tmux = tmux else { return }
        polling = true
        queue.async { [weak self] in
            let working = Self.readSessions(tmux: tmux)
            DispatchQueue.main.async {
                self?.polling = false
                self?.update(working)
            }
        }
    }

    /// Session name → is Claude working, for every tmux session named like lob's "<project>-NN".
    private static func readSessions(tmux: String) -> [(String, Bool)] {
        guard let list = run(tmux, ["list-panes", "-a", "-F", "#{session_name}\t#{pane_id}"]) else { return [] }
        var firstPane: [String: String] = [:]
        var names: [String] = []
        for line in list.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            guard fields.count == 2, firstPane[fields[0]] == nil else { continue }
            let range = NSRange(fields[0].startIndex..., in: fields[0])
            guard sessionPattern.firstMatch(in: fields[0], range: range) != nil else { continue }
            firstPane[fields[0]] = fields[1]
            names.append(fields[0])
        }
        return names.sorted().map { name in
            let screen = run(tmux, ["capture-pane", "-p", "-t", firstPane[name]!]) ?? ""
            return (name, isWorking(screen))
        }
    }

    /// Looks only at the lines just above the input prompt ("❯"), where Claude draws its spinner.
    static func isWorking(_ screen: String) -> Bool {
        let lines = screen.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let prompt = lines.lastIndex(where: { $0.hasPrefix("❯") }) else { return false }
        return lines[max(0, prompt - 12)..<prompt].contains { line in
            spinnerPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func update(_ readings: [(String, Bool)]) {
        let now = Date()
        let previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.name, $0.state) })
        sessions = readings.map { name, working in
            let state: State
            switch (previous[name], working) {
            case (.working(let since)?, true): state = .working(since: since)
            case (_, true): state = .working(since: now)
            case (.working?, false): state = .finished(at: now)
            case (.finished(let at)?, false): state = now.timeIntervalSince(at) > Self.finishedFor ? .idle : .finished(at: at)
            default: state = .idle
            }
            return Session(name: name, project: Self.project(name), state: state)
        }
    }

    /// "maxlaptopmtmr-01" → "maxlaptopmtmr"; "maxlaptopmtmr-02" → "maxlaptopmtmr 2".
    private static func project(_ session: String) -> String {
        guard let dash = session.lastIndex(of: "-") else { return session }
        let base = String(session[..<dash])
        let number = Int(session[session.index(after: dash)...]) ?? 1
        return number == 1 ? base : "\(base) \(number)"
    }
}

/// One session: animated indicator, project name, state line.
final class LobSessionChip: NSView {
    private let background = CALayer()
    private let indicator = CALayer()
    private let spinner = CAShapeLayer()
    private let dot = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let title = AppControlsStyle.label(size: 10, weight: .semibold)
    private let detail = AppControlsStyle.label(size: 9, color: AppControlsStyle.secondaryText, monospacedDigits: true)
    private var shownKind = ""

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 96, height: 30))
        wantsLayer = true
        layer?.addSublayer(background)
        background.cornerRadius = 6
        layer?.addSublayer(indicator)
        for shape in [ring, dot, spinner] { indicator.addSublayer(shape) }
        spinner.fillColor = nil
        spinner.lineWidth = 2
        spinner.lineCap = .round
        spinner.strokeColor = NSColor.systemBlue.cgColor
        ring.fillColor = nil
        ring.lineWidth = 1.5
        ring.strokeColor = AppControlsStyle.good.cgColor
        // Middle truncation keeps both ends of long project names ("andoi…find").
        title.lineBreakMode = .byTruncatingMiddle
        addSubview(title)
        addSubview(detail)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        let size: CGFloat = 12
        indicator.frame = NSRect(x: 6, y: bounds.midY - size / 2, width: size, height: size)
        let box = indicator.bounds
        for shape in [spinner, dot, ring] {
            shape.frame = box
        }
        spinner.path = CGPath(ellipseIn: box.insetBy(dx: 1, dy: 1), transform: nil)
        spinner.strokeEnd = 0.72
        ring.path = CGPath(ellipseIn: box.insetBy(dx: 1, dy: 1), transform: nil)
        CATransaction.commit()
        // Dot shapes depend on the indicator size, which is only known now.
        if !shownKind.isEmpty { applyShapes(shownKind) }
        let textX = indicator.frame.maxX + 5
        title.frame = NSRect(x: textX, y: 14, width: max(0, bounds.width - textX - 4), height: 15)
        detail.frame = NSRect(x: textX, y: 2, width: max(0, bounds.width - textX - 4), height: 12)
    }

    func show(_ session: LobMonitor.Session) {
        title.stringValue = session.project
        let kind: String
        switch session.state {
        case let .working(since):
            kind = "working"
            detail.stringValue = Self.elapsed(since)
        case let .finished(at):
            kind = "finished"
            detail.stringValue = "done " + Self.elapsed(at)
        case .idle:
            kind = "idle"
            detail.stringValue = "idle"
        }
        guard kind != shownKind else { return }
        shownKind = kind
        animate(kind)
    }

    private func animate(_ kind: String) {
        for shape in [spinner, dot, ring, background] { shape.removeAllAnimations() }
        applyShapes(kind)
        startAnimations(kind)
    }

    private func applyShapes(_ kind: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let small = indicator.bounds.insetBy(dx: 4, dy: 4)
        let full = indicator.bounds.insetBy(dx: 2, dy: 2)
        switch kind {
        case "working":
            spinner.isHidden = false
            ring.isHidden = true
            dot.isHidden = true
            background.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.18).cgColor
        case "finished":
            spinner.isHidden = true
            ring.isHidden = false
            dot.isHidden = false
            dot.path = CGPath(ellipseIn: full, transform: nil)
            dot.fillColor = AppControlsStyle.good.cgColor
            background.backgroundColor = AppControlsStyle.good.withAlphaComponent(0.22).cgColor
        default:
            spinner.isHidden = true
            ring.isHidden = true
            dot.isHidden = false
            dot.path = CGPath(ellipseIn: small, transform: nil)
            dot.fillColor = NSColor(white: 0.55, alpha: 1).cgColor
            background.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        }
        CATransaction.commit()
    }

    private func startAnimations(_ kind: String) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        switch kind {
        case "working":
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 0.9
            spin.repeatCount = .infinity
            spinner.add(spin, forKey: "spin")
        case "finished":
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = 1.9
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9
            fade.toValue = 0
            let pulse = CAAnimationGroup()
            pulse.animations = [grow, fade]
            pulse.duration = 1.4
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(pulse, forKey: "pulse")
            let breathe = CABasicAnimation(keyPath: "backgroundColor")
            breathe.fromValue = AppControlsStyle.good.withAlphaComponent(0.12).cgColor
            breathe.toValue = AppControlsStyle.good.withAlphaComponent(0.32).cgColor
            breathe.duration = 1.4
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            background.add(breathe, forKey: "breathe")
        default:
            break
        }
    }

    private static func elapsed(_ since: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
    }
}

/// The lob icon, drawn in code: a terminal prompt — white ">" and a blue "_" cursor — on a charcoal tile.
/// Generic colours only.
func lobIcon(size: CGFloat) -> NSImage {
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let tile = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)
        let corner = tile.width * 0.24
        let shape = NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner)
        NSGradient(starting: NSColor(white: 0.24, alpha: 1), ending: NSColor(white: 0.08, alpha: 1))?.draw(in: shape, angle: -90)
        // A faint edge keeps the dark tile visible on the black bar.
        NSColor(white: 1, alpha: 0.18).setStroke()
        shape.lineWidth = max(0.5, size * 0.02)
        shape.stroke()

        let stroke = max(1.2, size * 0.085)
        let left = tile.minX + tile.width * 0.24
        let tip = tile.minX + tile.width * 0.44
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: left, y: tile.midY + tile.height * 0.17))
        chevron.line(to: NSPoint(x: tip, y: tile.midY))
        chevron.line(to: NSPoint(x: left, y: tile.midY - tile.height * 0.17))
        chevron.lineWidth = stroke
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        NSColor.white.setStroke()
        chevron.stroke()

        let cursor = NSRect(x: tile.minX + tile.width * 0.5, y: tile.midY - tile.height * 0.17 - stroke / 2, width: tile.width * 0.26, height: stroke)
        NSColor(srgbRed: 0.35, green: 0.6, blue: 1, alpha: 1).setFill()
        NSBezierPath(roundedRect: cursor, xRadius: stroke / 2, yRadius: stroke / 2).fill()
        return true
    }
}
