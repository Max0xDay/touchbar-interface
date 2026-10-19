import Cocoa

/// praatvol: room/call capture controls and pushed status. Recording Stop needs a second tap within 3 s.
final class AppControlsPraatvolPanel: NSView, AppControlsPanel {
    static let id = "praatvol"
    static let name = "praatvol"
    static func icon() -> NSImage { return praatvolIcon(size: TouchBarIcon.appBox) }
    let refreshInterval: TimeInterval = 1

    private let readout = PraatvolReadoutView()
    private lazy var room = AppControlsStyle.button(symbol: "mic.fill", target: self, action: #selector(recordRoom))
    private lazy var call = AppControlsStyle.button(symbol: "phone.fill", target: self, action: #selector(recordCall))
    private lazy var stop = AppControlsStyle.button(symbol: "stop.fill", target: self, action: #selector(stopTapped))
    private lazy var transcribe = AppControlsStyle.button(symbol: "checkmark", target: self, action: #selector(transcribeTapped))
    private lazy var skip = AppControlsStyle.button(symbol: "xmark", target: self, action: #selector(skipTapped))
    private var options = PraatvolAppOptions()
    private var client: PraatvolClient?
    private var snapshot: PraatvolSnapshot?
    private var receivedAt: Double = 0
    private var savedReceipt = PraatvolSavedReceipt()
    private var confirmation = PraatvolStopConfirmation()
    private var confirmationTimer: Timer?
    private var commandMessage: String?
    private var messageExpiresAt: Double = 0
    private var stopWidth: CGFloat = praatvolStopButtonWidth(confirmationTextWidth: nil)
    private static let stopConfirmationAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: AppControlsStyle.bad
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [readout, room, call, stop, transcribe, skip] as [NSView] { addSubview(view) }
        room.toolTip = "Record room"
        call.toolTip = "Record call"
        stop.toolTip = "Stop / cancel"
        transcribe.toolTip = "Transcribe"
        skip.toolTip = "Keep audio only"
        room.image = praatvolButtonImage(symbol: "mic.fill", title: "Room")
        call.image = praatvolButtonImage(symbol: "phone.fill", title: "Call")
        stop.image = TouchBarIcon.symbol("stop.fill", tint: AppControlsStyle.bad)
        transcribe.image = TouchBarIcon.symbol("checkmark", tint: AppControlsStyle.good)
        skip.image = TouchBarIcon.symbol("xmark", tint: AppControlsStyle.secondaryText)
        refresh()
    }

    required init?(coder: NSCoder) { return nil }

    deinit {
        client?.stop()
        confirmationTimer?.invalidate()
    }

    func configure(_ options: PraatvolAppOptions) {
        guard options != self.options else { return }
        client?.stop()
        client = nil
        snapshot = nil
        savedReceipt = PraatvolSavedReceipt()
        self.options = options
        if window != nil { connect() }
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            client?.stop()
            client = nil
            snapshot = nil
            savedReceipt = PraatvolSavedReceipt()
            clearConfirmation()
            commandMessage = nil
            refresh()
        } else {
            connect()
        }
    }

    private func connect() {
        guard client == nil else { return }
        let connection = PraatvolClient(socketPath: options.socketPath)
        connection.onSnapshot = { [weak self, weak connection] snapshot in
            guard let self = self, self.client === connection else { return }
            self.snapshot = snapshot
            self.receivedAt = Date().timeIntervalSince1970
            self.savedReceipt.receive(snapshot, at: self.receivedAt)
            if snapshot?.step != .recording { self.clearConfirmation() }
            self.refresh()
        }
        connection.onCommandError = { [weak self, weak connection] message in
            guard let self = self, self.client === connection else { return }
            self.commandMessage = message
            self.messageExpiresAt = ProcessInfo.processInfo.systemUptime + 2
            self.refresh()
        }
        client = connection
        connection.start()
    }

    private var display: PraatvolDisplay {
        return PraatvolDisplay(snapshot: snapshot, savedAt: savedReceipt.savedAt)
    }

    private var activeMessage: String? {
        return ProcessInfo.processInfo.systemUptime < messageExpiresAt ? commandMessage : nil
    }

    private var showsIdleButtons: Bool { return display.canStart && activeMessage == nil }

    override func layout() {
        super.layout()
        if showsIdleButtons {
            let width = max(0, (bounds.width - 8) / 2)
            AppControlsStyle.row([(room, width), (call, width)], in: bounds, gap: 8)
        } else if display.showsStop {
            AppControlsStyle.row([(readout, nil), (stop, stopWidth)], in: bounds, gap: 8)
        } else if display.review {
            AppControlsStyle.row([(readout, nil), (transcribe, 56), (skip, 56)], in: bounds, gap: 8)
        } else {
            readout.frame = bounds
        }
    }

    func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        let display = self.display
        let message = activeMessage
        room.isHidden = !showsIdleButtons
        call.isHidden = !showsIdleButtons
        stop.isHidden = !display.showsStop
        transcribe.isHidden = !display.review
        skip.isHidden = !display.review
        transcribe.isEnabled = !display.attention
        skip.isEnabled = !display.attention
        readout.isHidden = showsIdleButtons
        room.isEnabled = !display.attention
        call.isEnabled = !display.attention
        if display.canStart { room.image = praatvolButtonImage(symbol: "mic.fill", title: "Room", failed: display.failed) }
        stop.isEnabled = display.canStop
        if !display.canStop { clearConfirmation() }
        let confirming = confirmation.isPending(at: now)
        stop.imagePosition = confirming ? .noImage : .imageOnly
        let stopTitle = confirming ? "Stop?" : ""
        stop.attributedTitle = NSAttributedString(string: stopTitle, attributes: Self.stopConfirmationAttributes)
        let stopTextWidth = confirming ? (stopTitle as NSString).size(withAttributes: Self.stopConfirmationAttributes).width : nil
        stopWidth = praatvolStopButtonWidth(confirmationTextWidth: stopTextWidth)
        let elapsed = snapshot?.elapsed(at: Date().timeIntervalSince1970, receivedAt: receivedAt) ?? 0
        readout.show(display, elapsed: elapsed, message: message)
        needsLayout = true
    }

    @objc private func recordRoom() {
        guard display.canStart, !display.attention else { return }
        client?.send(.recordRoom)
    }

    @objc private func recordCall() {
        guard display.canStart, !display.attention else { return }
        client?.send(.recordCall)
    }

    @objc private func transcribeTapped() {
        guard display.review, !display.attention else { return }
        client?.send(.transcribe)
    }

    @objc private func skipTapped() {
        guard display.review, !display.attention else { return }
        client?.send(.keep)
    }

    @objc private func stopTapped() {
        guard display.canStop else { return }
        if snapshot?.step == .starting {
            client?.send(.stop)
            return
        }
        if confirmation.tap(at: ProcessInfo.processInfo.systemUptime) {
            clearConfirmation()
            client?.send(.stop)
        } else {
            confirmationTimer?.invalidate()
            let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
                self?.clearConfirmation()
                self?.refresh()
            }
            confirmationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        refresh()
    }

    private func clearConfirmation() {
        confirmation.reset()
        confirmationTimer?.invalidate()
        confirmationTimer = nil
    }
}

/// A single image centres the icon and label as a pair, without NSButton's separate title/image offsets.
private func praatvolButtonImage(symbol: String, title: String, failed: Bool = false) -> NSImage {
    let glyph = TouchBarIcon.symbol(symbol, tint: AppControlsStyle.primaryText)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: AppControlsStyle.primaryText
    ]
    let textSize = (title as NSString).size(withAttributes: attributes)
    let glyphWidth = glyph?.size.width ?? 0
    let width = glyphWidth + 8 + textSize.width + (failed ? 13 : 0)
    // #COMPLETION_DRIVE: Measured icon/label centring should look balanced on the hardware Touch Bar.
    // #SUGGEST_VERIFY: Check idle buttons, recording pill/baselines and review controls on the real bar.
    return NSImage(size: NSSize(width: width, height: 18), flipped: false) { rect in
        if let glyph = glyph {
            glyph.draw(at: NSPoint(x: 0, y: rect.midY - glyph.size.height / 2), from: .zero, operation: .sourceOver, fraction: 1)
        }
        (title as NSString).draw(at: NSPoint(x: glyphWidth + 8, y: rect.midY - textSize.height / 2), withAttributes: attributes)
        if failed {
            AppControlsStyle.bad.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.midY - 2.5, width: 5, height: 5)).fill()
        }
        return true
    }
}

func praatvolIcon(size: CGFloat) -> NSImage {
    // #COMPLETION_DRIVE: The white waveform on graphite should read like the existing Fan/System tiles.
    // #SUGGEST_VERIFY: Check the switcher tile and the compact recording readout on the real 30 pt Touch Bar.
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let tile = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)
        let gradient = NSGradient(starting: NSColor(white: 0.42, alpha: 1), ending: NSColor(white: 0.2, alpha: 1))
        gradient?.draw(in: NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.24, yRadius: tile.width * 0.24), angle: -90)
        if let glyph = TouchBarIcon.symbol("waveform", box: tile.width * 0.62, tint: .white) {
            glyph.draw(at: NSPoint(x: tile.midX - glyph.size.width / 2, y: tile.midY - glyph.size.height / 2), from: .zero, operation: .sourceOver, fraction: 1)
        }
        return true
    }
}

/// Two recording text rows keep elapsed time readable without shrinking the microphone name's font.
final class PraatvolReadoutView: NSView {
    private let indicator = CAShapeLayer()
    private var display = PraatvolDisplay(snapshot: nil)
    private var elapsed: Double = 0
    private var message: String?
    private var indicatorKind = ""
    private let recordingFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    private let detailFont = NSFont.systemFont(ofSize: 10)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(indicator)
        indicator.isHidden = true
        indicator.lineWidth = 1.5
        indicator.lineCap = .round
    }

    required init?(coder: NSCoder) { return nil }

    func show(_ display: PraatvolDisplay, elapsed: Double, message: String?) {
        self.display = display
        self.elapsed = elapsed
        self.message = message
        updateIndicator()
        needsLayout = true
        needsDisplay = true
    }

    private func textHeight(_ font: NSFont) -> CGFloat {
        return ("Ag" as NSString).size(withAttributes: [.font: font]).height
    }

    private var firstRowCenter: CGFloat { return bounds.midY + textHeight(detailFont) / 2 }
    private var secondRowCenter: CGFloat { return bounds.midY - textHeight(recordingFont) / 2 }
    private var progressRowCenter: CGFloat { return bounds.midY + 5.5 }

    override func layout() {
        super.layout()
        let center = display.recording ? firstRowCenter : display.showsProgress ? progressRowCenter : bounds.midY
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.frame = NSRect(x: 0, y: center - 4, width: 8, height: 8)
        indicator.path = CGPath(ellipseIn: indicator.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        CATransaction.commit()
    }

    private func updateIndicator() {
        let hidden = display.attention || message != nil
        let kind = hidden ? "" : display.recording ? "recording" : display.spinning ? "spinner" : ""
        guard kind != indicatorKind else { return }
        indicatorKind = kind
        indicator.removeAllAnimations()
        indicator.isHidden = kind.isEmpty
        indicator.fillColor = kind == "recording" ? AppControlsStyle.bad.cgColor : nil
        indicator.strokeColor = kind == "spinner" ? AppControlsStyle.secondaryText.cgColor : nil
        indicator.strokeEnd = kind == "spinner" ? 0.72 : 1
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        if kind == "spinner" {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 0.9
            spin.repeatCount = .infinity
            indicator.add(spin, forKey: "spin")
        } else if kind == "recording" {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            indicator.add(pulse, forKey: "pulse")
        }
    }

    override func draw(_: NSRect) {
        if display.attention {
            drawInline(display.text, symbol: "exclamationmark.triangle.fill", color: AppControlsStyle.warn)
        } else if let message = message {
            drawText(message, x: 0, center: bounds.midY, width: bounds.width, font: NSFont.systemFont(ofSize: 12), color: AppControlsStyle.warn)
        } else if display.recording {
            drawRecording()
        } else if display.review {
            drawReview()
        } else if display.savedFlash {
            drawInline("Saved", symbol: "checkmark", color: AppControlsStyle.good)
        } else if display.showsProgress {
            drawProgress()
        } else {
            let inset: CGFloat = display.spinning ? 16 : 0
            drawText(display.text, x: inset, center: bounds.midY, width: bounds.width - inset,
                     font: NSFont.systemFont(ofSize: 12), color: display.offline ? AppControlsStyle.secondaryText : AppControlsStyle.primaryText,
                     alignment: display.offline ? .center : .left)
        }
    }

    private func drawRecording() {
        let text = PraatvolDisplay.time(elapsed)
        let timeWidth = (text as NSString).size(withAttributes: [.font: recordingFont]).width
        drawText(text, x: 16, center: firstRowCenter, width: timeWidth, font: recordingFont, color: AppControlsStyle.primaryText)
        let badgeFont = NSFont.systemFont(ofSize: 9, weight: .medium)
        let badgeWidth = (display.badge as NSString).size(withAttributes: [.font: badgeFont]).width + 12
        let badge = NSRect(x: 16 + timeWidth + 8, y: firstRowCenter - 7, width: badgeWidth, height: 14)
        AppControlsStyle.track.setFill()
        NSBezierPath(roundedRect: badge, xRadius: 7, yRadius: 7).fill()
        drawText(display.badge, x: badge.minX, center: badge.midY, width: badge.width,
                 font: badgeFont, color: AppControlsStyle.secondaryText, alignment: .center)
        let signalsWidth = CGFloat(display.signals.count * 13 - 8)
        drawText(display.microphoneName, x: 0, center: secondRowCenter, width: bounds.width - signalsWidth - 8,
                 font: detailFont, color: AppControlsStyle.secondaryText)
        for (index, signal) in display.signals.enumerated() {
            drawDot(at: NSPoint(x: bounds.width - signalsWidth + CGFloat(index) * 13 + 2.5, y: secondRowCenter), signal: signal)
        }
    }

    private func drawReview() {
        drawText(display.text, x: 0, center: firstRowCenter, width: bounds.width,
                 font: recordingFont, color: AppControlsStyle.primaryText)
        let warning = display.reviewWarning != nil
        if warning { drawSymbol("exclamationmark.triangle.fill", x: 0, center: secondRowCenter, color: AppControlsStyle.warn, box: 10) }
        let inset: CGFloat = warning ? 18 : 0
        drawText(display.reviewDetail, x: inset, center: secondRowCenter, width: bounds.width - inset,
                 font: detailFont, color: warning ? AppControlsStyle.warn : AppControlsStyle.secondaryText)
    }

    private func drawProgress() {
        let font = NSFont.systemFont(ofSize: 12)
        drawText(display.text, x: 16, center: progressRowCenter, width: bounds.width - 16,
                 font: font, color: AppControlsStyle.primaryText)
        let center = bounds.midY - (textHeight(font) + 8) / 2
        let track = NSRect(x: 0, y: center - 1.5, width: bounds.width, height: 3)
        AppControlsStyle.track.setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        guard let fraction = display.progressFraction, fraction > 0 else { return }
        AppControlsStyle.selected.setFill()
        let fill = NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(fraction), height: 3)
        NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
    }

    private func drawInline(_ text: String, symbol: String, color: NSColor) {
        drawSymbol(symbol, x: 0, center: bounds.midY, color: color, box: 12)
        drawText(text, x: 20, center: bounds.midY, width: bounds.width - 20,
                 font: NSFont.systemFont(ofSize: 12), color: color)
    }

    private func drawSymbol(_ symbol: String, x: CGFloat, center: CGFloat, color: NSColor, box: CGFloat) {
        if let image = TouchBarIcon.symbol(symbol, box: box, tint: color) {
            image.draw(at: NSPoint(x: x, y: center - image.size.height / 2), from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    private func drawText(_ text: String, x: CGFloat, center: CGFloat, width: CGFloat, font: NSFont,
                          color: NSColor, alignment: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let height = textHeight(font)
        (text as NSString).draw(in: NSRect(x: x, y: center - height / 2, width: max(0, width), height: height), withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style
        ])
    }

    private func drawDot(at center: NSPoint, signal: PraatvolDisplay.Signal) {
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))
        let color = signal == .good ? AppControlsStyle.good : signal == .warning ? AppControlsStyle.warn : AppControlsStyle.secondaryText
        color.setStroke()
        color.setFill()
        if signal == .silent { circle.stroke() } else { circle.fill() }
    }
}
