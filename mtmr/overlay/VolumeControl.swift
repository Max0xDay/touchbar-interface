import Cocoa

final class VolumeTouchBarItem: NSCustomTouchBarItem {
    override init(identifier: NSTouchBarItem.Identifier) {
        super.init(identifier: identifier)
        view = VolumeButton(frame: NSRect(x: 0, y: 0, width: 75, height: 30))
    }

    required init?(coder: NSCoder) { return nil }
}

final class VolumeButton: NSButton {
    let controller = OutputVolumeController()
    weak var slider: VolumeSliderView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        bezelStyle = .rounded
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        target = self
        action = #selector(openSlider)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        controller.changed = { [weak self] in self?.refreshAppearance() }
        refreshAppearance()
    }

    required init?(coder: NSCoder) { return nil }

    override var intrinsicContentSize: NSSize { return NSSize(width: 75, height: 30) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            controller.stop()
        } else {
            controller.start()
        }
    }

    @objc private func openSlider() {
        guard let host = superview as? NotificationLayoutView else {
            NSLog("MTMR volume: slider requires a notification layout host")
            return
        }
        host.openVolumeSlider(for: self)
    }

    private func refreshAppearance() {
        image = TouchBarIcon.symbol(controller.state.symbol, tint: NSColor(white: 0.62, alpha: 1))
        slider?.needsDisplay = true
    }
}

/// One opaque hit surface, above the normal left buttons. Touch handling mirrors the Fan custom slider.
final class VolumeSliderView: NSView {
    private enum Region { case speaker, track, close }
    private static let idleSeconds: TimeInterval = 6
    private let controller: OutputVolumeController
    private let close: () -> Void
    private var idleTimer: Timer?
    private var activeRegion: Region?

    init(controller: OutputVolumeController, close: @escaping () -> Void) {
        self.controller = controller
        self.close = close
        super.init(frame: .zero)
        allowedTouchTypes = .direct
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { return nil }
    deinit { idleTimer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            idleTimer?.invalidate()
        } else {
            resetIdleTimer()
        }
    }

    func resetIdleTimer() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.idleSeconds, repeats: false) { [weak self] _ in self?.close() }
        idleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    private var track: NSRect {
        return NSRect(x: 44, y: bounds.midY - 4, width: max(0, bounds.width - 86), height: 8)
    }

    override func draw(_: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        NSColor(white: 0.18, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        drawSymbol(controller.state.symbol, center: NSPoint(x: 18, y: bounds.midY), enabled: controller.state.canSetMute)
        drawSymbol("xmark", center: NSPoint(x: bounds.maxX - 15, y: bounds.midY), enabled: true, box: 12)
        drawSlider()
    }

    private func drawSymbol(_ name: String, center: NSPoint, enabled: Bool, box: CGFloat = TouchBarIcon.symbolBox) {
        let colour = NSColor(white: enabled ? 0.8 : 0.36, alpha: 1)
        guard let image = TouchBarIcon.symbol(name, box: box, tint: colour) else { return }
        image.draw(in: NSRect(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2, width: image.size.width, height: image.size.height))
    }

    private func drawSlider() {
        let enabled = controller.state.canSetVolume
        NSColor(white: enabled ? 0.35 : 0.24, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
        let knobPosition = VolumeControlGeometry.knobPosition(volume: controller.state.volume ?? 0, track: track)
        NSColor(white: enabled ? 0.75 : 0.3, alpha: 1).setFill()
        let fill = NSRect(x: track.minX, y: track.minY, width: knobPosition - track.minX, height: track.height)
        NSBezierPath(roundedRect: fill, xRadius: 4, yRadius: 4).fill()
        NSColor(white: enabled ? 1 : 0.4, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: knobPosition - 7, y: bounds.midY - 7, width: 14, height: 14)).fill()
    }

    private func region(at point: NSPoint) -> Region {
        if point.x < 36 { return .speaker }
        if point.x >= bounds.maxX - 30 { return .close }
        return .track
    }

    private func begin(at point: NSPoint) {
        idleTimer?.invalidate()
        activeRegion = region(at: point)
        move(to: point)
    }

    private func move(to point: NSPoint) {
        idleTimer?.invalidate()
        guard activeRegion == .track else { return }
        controller.setVolume(VolumeControlGeometry.volume(position: point.x, track: track))
    }

    private func end(at point: NSPoint) {
        let startedRegion = activeRegion
        activeRegion = nil
        resetIdleTimer()
        guard bounds.contains(point), startedRegion == region(at: point) else { return }
        switch startedRegion {
        case .speaker: controller.toggleMute()
        case .close: close()
        default: break
        }
    }

    // #COMPLETION_DRIVE: Direct Touch Bar touches follow the same began/moved/ended delivery as the Fan slider.
    // #SUGGEST_VERIFY: On hardware, check live dragging, mute/close taps and holding longer than the idle timeout.
    override func touchesBegan(with event: NSEvent) {
        guard let point = touchLocation(event, phase: .began) else { return }
        begin(at: point)
    }

    override func touchesMoved(with event: NSEvent) {
        guard let point = touchLocation(event, phase: .moved) else { return }
        move(to: point)
    }

    override func touchesEnded(with event: NSEvent) {
        guard let point = touchLocation(event, phase: .ended) else {
            cancelTouch()
            return
        }
        if activeRegion == .track { move(to: point) }
        end(at: point)
    }

    override func touchesCancelled(with event: NSEvent) { cancelTouch() }

    private func touchLocation(_ event: NSEvent, phase: NSTouch.Phase) -> NSPoint? {
        return event.touches(matching: phase, in: self).first(where: { $0.type == .direct })?.location(in: self)
    }

    private func cancelTouch() {
        activeRegion = nil
        resetIdleTimer()
    }

    override func mouseDown(with event: NSEvent) { begin(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { move(to: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if activeRegion == .track { move(to: point) }
        end(at: point)
    }
}
