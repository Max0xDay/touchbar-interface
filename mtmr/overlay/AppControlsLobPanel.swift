import Cocoa

/// lob: one pill per lob session, animated by state: working = blue spinning arc, delegate = purple slow orbit
/// (a pi-delegate run is in progress), finished = pulsing green (awaiting your reply), idle = still grey dot. Always a 2-row grid with 4-session cells: 3 sessions leave the top-left empty, 1–2 stack in the left column, 5+ add columns and scroll sideways.
/// Display only: taps do nothing (replies go through Claude remote control).
final class AppControlsLobPanel: NSView, AppControlsPanel {
    static let id = "lob"
    static let name = "lob"
    static func icon() -> NSImage { return lobIcon(size: TouchBarIcon.appBox) }
    let refreshInterval: TimeInterval = 1

    private static let gap: CGFloat = 4
    private let scroll = NSScrollView()
    private let container = NSView()
    private let empty = AppControlsStyle.label(size: 12, color: AppControlsStyle.secondaryText)
    private var pills: [Int32: LobSessionPill] = [:]
    private var order: [Int32] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.documentView = container
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
        layoutPills()
    }

    private func layoutPills() {
        let count = order.count
        guard count > 0 else { return }
        // Always the 2 x 2 grid cell size. 3 sessions leave the top-left cell empty; 1–2 stack in the left column.
        let columns = max(2, Int(ceil(Double(count) / 2)))
        let single = count == 1
        let height = single ? bounds.height : floor((bounds.height - Self.gap / 2) / 2)
        let width = max(88, floor((bounds.width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)))
        let skip = count <= 2 ? 0 : columns * 2 - count
        for (index, pid) in order.enumerated() {
            let slot = index + skip
            let row = count <= 2 ? index : slot / columns
            let column = count <= 2 ? 0 : slot % columns
            // Row 0 is the top row (AppKit's y grows upwards).
            let y = single ? 0 : (row == 0 ? bounds.height - height : 0)
            pills[pid]?.frame = NSRect(x: CGFloat(column) * (width + Self.gap), y: y, width: width, height: height)
            pills[pid]?.compact = !single
        }
        container.frame = NSRect(x: 0, y: 0, width: CGFloat(columns) * width + CGFloat(columns - 1) * Self.gap, height: bounds.height)
    }

    func refresh() {
        let sessions = LobMonitor.shared.sessions
        empty.isHidden = !sessions.isEmpty
        let pids = sessions.map { $0.pid }
        if pids != order {
            for (pid, pill) in pills where !pids.contains(pid) {
                pill.removeFromSuperview()
                pills.removeValue(forKey: pid)
            }
            for pid in pids where pills[pid] == nil {
                let pill = LobSessionPill()
                pills[pid] = pill
                container.addSubview(pill)
            }
            order = pids
            layoutPills()
        }
        for session in sessions { pills[session.pid]?.show(session) }
    }
}

/// Finds lob sessions from the running Claude processes ("claude … Active project: <name>. …", as lob.sh starts
/// them), so sessions on an older tmux server whose socket was replaced still appear (Verified 2026-10-06: two of
/// six were unreachable through tmux).
/// Working: for sessions tmux can reach, Claude's spinner line above the prompt (glyph, verb, ellipsis, e.g.
/// "✢ Tinkering… (thought for 2s)"; done reads "✻ Baked for 3s · done 3:30 PM"). The status line's "esc to
/// interrupt" is not used: narrow panes truncate it. For unreachable sessions: CPU use of at least 8 % averaged
/// over 6 s (working measured ~12 %, idle 0.3–3.7 % with brief spikes to ~8 %); a spell under 15 s never counts as finished.
/// Delegate: a process running pi-delegate.py anywhere below the session's Claude process (it overrides working).
final class LobMonitor {
    enum State: Equatable {
        case working(since: Date)
        case delegating(since: Date)
        case finished(at: Date)
        case idle
    }

    struct Session: Equatable {
        let pid: Int32
        let name: String
        let state: State
    }

    private struct Process {
        let pid: Int32
        let project: String
        let cpuSeconds: Double
        let delegating: Bool
    }

    private struct Reading {
        let pid: Int32
        let name: String
        let working: Bool
        let delegating: Bool
        /// Working was guessed from CPU use (session unreachable through tmux).
        let fromCPU: Bool
    }

    static let shared = LobMonitor()
    /// A finished session without a reply turns idle after this long.
    private static let finishedFor: TimeInterval = 30 * 60
    private static let busyCPU = 0.08
    /// CPU use is averaged over this window: idle Claude spikes past 8 % for a moment (seen 2026-10-07), real work holds it.
    private static let cpuWindow: Double = 6
    /// A CPU-guessed working spell shorter than this was a spike: it goes back to idle, not to finished.
    private static let minimumCPUWork: TimeInterval = 15
    private static let projectPattern = try! NSRegularExpression(pattern: "Active project: ([^.]+)\\.")
    private static let spinnerPattern = try! NSRegularExpression(pattern: "^\\S\\s+\\p{Lu}\\p{Ll}+…")

    private(set) var sessions: [Session] = []
    private var timer: Timer?
    private var polling = false
    /// Recent CPU samples per Claude process, oldest first, covering about `cpuWindow` seconds.
    private var cpuHistory: [Int32: [(seconds: Double, at: Double)]] = [:]
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
        guard !polling else { return }
        polling = true
        let tmux = self.tmux
        queue.async { [weak self] in
            guard let self = self else { return }
            let readings = self.read(tmux: tmux)
            DispatchQueue.main.async {
                self.polling = false
                self.update(readings)
            }
        }
    }

    /// One reading per lob Claude process. Runs on the monitor queue.
    private func read(tmux: String?) -> [Reading] {
        let processes = Self.claudeProcesses()
        var panes: [Int32: (session: String, pane: String)] = [:]
        if let tmux = tmux, let list = Self.run(tmux, ["list-panes", "-a", "-F", "#{pane_pid}\t#{session_name}\t#{pane_id}"]) {
            for line in list.split(separator: "\n") {
                let fields = line.split(separator: "\t").map(String.init)
                if fields.count == 3, let pid = Int32(fields[0]) { panes[pid] = (fields[1], fields[2]) }
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        var readings: [Reading] = []
        for process in processes {
            var history = (cpuHistory[process.pid] ?? []) + [(process.cpuSeconds, now)]
            history.removeAll { now - $0.at > Self.cpuWindow + 1 }
            cpuHistory[process.pid] = history
            if let tmux = tmux, let pane = panes[process.pid] {
                let screen = Self.run(tmux, ["capture-pane", "-p", "-t", pane.pane]) ?? ""
                readings.append(Reading(pid: process.pid, name: Self.displayName(session: pane.session), working: Self.isWorking(screen), delegating: process.delegating, fromCPU: false))
            } else {
                // Busy only when the average over the whole window is high; a full window is needed first.
                var busy = false
                if let oldest = history.first, now - oldest.at >= Self.cpuWindow - 1 {
                    busy = (process.cpuSeconds - oldest.seconds) / (now - oldest.at) >= Self.busyCPU
                }
                readings.append(Reading(pid: process.pid, name: process.project, working: busy, delegating: process.delegating, fromCPU: true))
            }
        }
        let alive = Set(processes.map { $0.pid })
        cpuHistory = cpuHistory.filter { alive.contains($0.key) }
        return readings.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func claudeProcesses() -> [Process] {
        guard let list = run("/bin/ps", ["-axo", "pid=,ppid=,time=,command="]) else { return [] }
        var rows: [(pid: Int32, parent: Int32, time: String, command: String)] = []
        for line in list.split(separator: "\n") {
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { continue }
            rows.append((pid, parent, String(fields[2]), String(fields[3])))
        }
        var children: [Int32: [Int32]] = [:]
        for row in rows { children[row.parent, default: []].append(row.pid) }
        let delegates = Set(rows.filter { $0.command.contains("pi-delegate.py --tier") }.map { $0.pid })
        return rows.compactMap { row in
            // lob.sh runs "claude --dangerously-skip-permissions <init prompt>"; tmux client lines start with "tmux".
            guard row.command.hasPrefix("claude "), let match = projectPattern.firstMatch(in: row.command, range: NSRange(row.command.startIndex..., in: row.command)),
                  let range = Range(match.range(at: 1), in: row.command) else { return nil }
            return Process(pid: row.pid, project: String(row.command[range]), cpuSeconds: cpuSeconds(row.time),
                           delegating: hasDescendant(of: row.pid, in: delegates, children: children))
        }
    }

    /// Whether any process below `pid` (shell, python, ...) is in `targets`.
    private static func hasDescendant(of pid: Int32, in targets: Set<Int32>, children: [Int32: [Int32]]) -> Bool {
        var pending = children[pid] ?? []
        var visited = Set<Int32>()
        while let next = pending.popLast() {
            guard visited.insert(next).inserted else { continue }
            if targets.contains(next) { return true }
            pending += children[next] ?? []
        }
        return false
    }

    /// ps "time": "M:SS.ss" or "H:MM:SS.ss" → seconds.
    private static func cpuSeconds(_ text: String) -> Double {
        return text.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
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
        let process = Foundation.Process()
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

    private func update(_ readings: [Reading]) {
        let now = Date()
        let previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.pid, $0.state) })
        sessions = readings.map { reading in
            let state: State
            let before = previous[reading.pid]
            if reading.delegating {
                if case let .delegating(since)? = before { state = .delegating(since: since) } else { state = .delegating(since: now) }
            } else if reading.working {
                if case let .working(since)? = before { state = .working(since: since) } else { state = .working(since: now) }
            } else {
                switch before {
                case let .working(since)? where reading.fromCPU && now.timeIntervalSince(since) < Self.minimumCPUWork: state = .idle
                case .working?, .delegating?: state = .finished(at: now)
                case let .finished(at)?: state = now.timeIntervalSince(at) > Self.finishedFor ? .idle : .finished(at: at)
                default: state = .idle
                }
            }
            return Session(pid: reading.pid, name: reading.name, state: state)
        }
    }

    /// "maxlaptopmtmr-01" → "maxlaptopmtmr"; "maxlaptopmtmr-02" → "maxlaptopmtmr 2".
    private static func displayName(session: String) -> String {
        guard let dash = session.lastIndex(of: "-"), let number = Int(session[session.index(after: dash)...]) else { return session }
        let base = String(session[..<dash])
        return number == 1 ? base : "\(base) \(number)"
    }
}

/// One session pill: animated indicator and project name; in the one-row layout also the elapsed time.
final class LobSessionPill: NSView {
    var compact = false {
        didSet { if compact != oldValue { needsLayout = true } }
    }

    private let background = CALayer()
    private let indicator = CALayer()
    private let spinner = CAShapeLayer()
    private let dot = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let title = AppControlsStyle.label(size: 11, weight: .semibold)
    private let detail = AppControlsStyle.label(size: 9, color: AppControlsStyle.secondaryText, monospacedDigits: true)
    private var shownKind = ""

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 96, height: 30))
        wantsLayer = true
        layer?.addSublayer(background)
        layer?.addSublayer(indicator)
        for shape in [ring, dot, spinner] { indicator.addSublayer(shape) }
        spinner.fillColor = nil
        spinner.lineCap = .round
        spinner.strokeColor = NSColor.systemBlue.cgColor
        ring.fillColor = nil
        ring.lineWidth = 1.2
        ring.strokeColor = AppControlsStyle.good.cgColor
        // Middle truncation keeps both ends of a long project name if it ever overflows.
        title.lineBreakMode = .byTruncatingMiddle
        detail.alignment = .right
        addSubview(title)
        addSubview(detail)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        let size: CGFloat = compact ? 8 : 11
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        background.cornerRadius = bounds.height / 2
        indicator.frame = NSRect(x: compact ? 5 : 8, y: bounds.midY - size / 2, width: size, height: size)
        let box = indicator.bounds
        for shape in [spinner, dot, ring] { shape.frame = box }
        spinner.lineWidth = compact ? 1.5 : 2
        spinner.path = CGPath(ellipseIn: box.insetBy(dx: 1, dy: 1), transform: nil)
        ring.path = CGPath(ellipseIn: box.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        CATransaction.commit()
        if !shownKind.isEmpty { applyShapes(shownKind) }
        title.font = NSFont.systemFont(ofSize: compact ? 9 : 11, weight: .semibold)
        let textX = indicator.frame.maxX + (compact ? 4 : 6)
        let detailWidth: CGFloat = compact ? 0 : 40
        detail.isHidden = compact
        let titleHeight: CGFloat = compact ? 12 : 15
        title.frame = NSRect(x: textX, y: bounds.midY - titleHeight / 2, width: max(0, bounds.width - textX - detailWidth - 6), height: titleHeight)
        detail.frame = NSRect(x: bounds.width - detailWidth - 8, y: bounds.midY - 6, width: detailWidth, height: 12)
    }

    func show(_ session: LobMonitor.Session) {
        title.stringValue = session.name
        let kind: String
        switch session.state {
        case let .working(since):
            kind = "working"
            detail.stringValue = Self.elapsed(since)
        case let .delegating(since):
            kind = "delegate"
            detail.stringValue = "pi " + Self.elapsed(since)
        case let .finished(at):
            kind = "finished"
            detail.stringValue = "done " + Self.elapsed(at)
        case .idle:
            kind = "idle"
            detail.stringValue = ""
        }
        guard kind != shownKind else { return }
        shownKind = kind
        for shape in [spinner, dot, ring, background] { shape.removeAllAnimations() }
        applyShapes(kind)
        startAnimations(kind)
    }

    private func applyShapes(_ kind: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let box = indicator.bounds
        switch kind {
        case "working", "delegate":
            let colour = kind == "working" ? NSColor.systemBlue : NSColor.systemPurple
            spinner.isHidden = false
            ring.isHidden = true
            dot.isHidden = true
            spinner.strokeColor = colour.cgColor
            // Working: a long arc; delegate: a short one, so the two read differently even without colour.
            spinner.strokeEnd = kind == "working" ? 0.72 : 0.3
            background.backgroundColor = colour.withAlphaComponent(0.22).cgColor
        case "finished":
            spinner.isHidden = true
            ring.isHidden = false
            dot.isHidden = false
            dot.path = CGPath(ellipseIn: box.insetBy(dx: 1, dy: 1), transform: nil)
            dot.fillColor = AppControlsStyle.good.cgColor
            background.backgroundColor = AppControlsStyle.good.withAlphaComponent(0.24).cgColor
        default:
            spinner.isHidden = true
            ring.isHidden = true
            dot.isHidden = false
            dot.path = CGPath(ellipseIn: box.insetBy(dx: box.width * 0.25, dy: box.height * 0.25), transform: nil)
            dot.fillColor = NSColor(white: 0.55, alpha: 1).cgColor
            background.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        }
        CATransaction.commit()
    }

    private func startAnimations(_ kind: String) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        switch kind {
        case "working", "delegate":
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = kind == "working" ? 0.9 : 2
            spin.repeatCount = .infinity
            spinner.add(spin, forKey: "spin")
        case "finished":
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = 2
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
            breathe.toValue = AppControlsStyle.good.withAlphaComponent(0.34).cgColor
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
        return "\(seconds / 3600)h"
    }
}

/// The lob icon, drawn in code: a terminal prompt — orange ">_" — on a black tile (user's choice: orange and black).
func lobIcon(size: CGFloat) -> NSImage {
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let tile = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)
        let corner = tile.width * 0.24
        let shape = NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner)
        NSGradient(starting: NSColor(white: 0.12, alpha: 1), ending: NSColor(white: 0.02, alpha: 1))?.draw(in: shape, angle: -90)
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
        let orange = NSColor(srgbRed: 1, green: 0.58, blue: 0.1, alpha: 1)
        orange.setStroke()
        chevron.stroke()

        let cursor = NSRect(x: tile.minX + tile.width * 0.5, y: tile.midY - tile.height * 0.17 - stroke / 2, width: tile.width * 0.26, height: stroke)
        orange.setFill()
        NSBezierPath(roundedRect: cursor, xRadius: stroke / 2, yRadius: stroke / 2).fill()
        return true
    }
}

extension LobMonitor {
    /// The session that most recently stopped working: the likely sender of a Claude notification (Claude says
    /// only "Claude is waiting for your input", not which session).
    func latestFinished() -> Session? {
        return sessions.compactMap { session -> (Session, Date)? in
            if case let .finished(at) = session.state { return (session, at) }
            return nil
        }.max { $0.1 < $1.1 }?.0
    }

    /// Name of the folder a process runs in (its working directory), e.g. "maxlaptopmtmr".
    static func folder(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { buffer -> String in
            guard let base = buffer.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
