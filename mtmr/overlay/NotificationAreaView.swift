import Cocoa

enum NotificationDebug {
    static var enabled = true

    static func hierarchy(_ view: NSView) {
        guard enabled else { return }
        var chain: [String] = []
        var current: NSView? = view
        while let host = current {
            chain.append(String(describing: type(of: host)))
            current = host.superview
        }
        NSLog("MTMR-notif: touch host=%@ window=%@ chain=%@", String(describing: type(of: view)), String(describing: view.window), chain.joined(separator: " -> "))
    }
}

final class NotificationAreaView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let maxChars: Int
    private let fadeSeconds: Double
    private let inset = CGFloat(NotificationTextMetrics.innerInset)
    private let font = NSFont.monospacedSystemFont(ofSize: CGFloat(NotificationTextMetrics.fontSize), weight: .regular)
    private var text = ""
    private var targetText = ""
    private var movedDuringSwipe = false
    private var pendingTransition: DispatchWorkItem?
    private var transitionGeneration = 0
    private var activeTouch: NSTouch?
    private var initialLocation = NSPoint.zero
    private var latestLocation = NSPoint.zero
    private var loggedWindowHierarchy = false

    init(maxChars: Int, fadeSeconds: Double = 0.35) {
        self.maxChars = maxChars
        self.fadeSeconds = fadeSeconds
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        allowedTouchTypes = .direct
        wantsRestingTouches = true
        label.wantsLayer = true
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.cell?.wraps = false
        label.cell?.isScrollable = false
        label.autoresizingMask = []
        addSubview(label)
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
        NotificationDebug.hierarchy(self)
        // #COMPLETION_DRIVE: Direct touches on this full-area hit target avoid label targeting and pan recognition thresholds on a 30 pt bar.
        // #SUGGEST_VERIFY: Read MTMR-notif logs on hardware; verify up/down navigation and expiry pause through end/cancel.
    }

    required init?(coder: NSCoder) { return nil }

    override var intrinsicContentSize: NSSize { return NSSize(width: 24, height: 30) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil { NotificationDebug.hierarchy(self) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            finishSwipe()
            return
        }
        if !loggedWindowHierarchy {
            loggedWindowHierarchy = true
            NotificationDebug.hierarchy(self)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let labelHeight = min(bounds.height, ceil(font.ascender - font.descender + font.leading) + 2)
        label.frame = NSRect(x: bounds.minX + min(inset, bounds.width / 2), y: bounds.midY - labelHeight / 2,
                             width: max(0, bounds.width - 2 * inset), height: labelHeight)
        updateText(animated: false)
        if NotificationDebug.enabled {
            NSLog("MTMR-notif: area=%@ label=%@", NSStringFromRect(frame), NSStringFromRect(label.frame))
        }
    }

    func show(text: String) {
        self.text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        updateText(animated: true)
    }

    private func updateText(animated: Bool) {
        let glyphWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        let capacity = NotificationTextMetrics.capacity(width: Double(bounds.width), inset: Double(inset), glyphWidth: Double(glyphWidth), maxChars: maxChars)
        let nextText = NotificationTextMetrics.truncated(text, capacity: capacity)
        if animated {
            guard nextText != targetText else { return }
        } else if pendingTransition == nil {
            guard nextText != label.stringValue else { return }
        }
        targetText = nextText
        let currentOpacity = label.layer?.presentation()?.opacity ?? label.layer?.opacity ?? 1
        transitionGeneration += 1
        let generation = transitionGeneration
        pendingTransition?.cancel()
        pendingTransition = nil
        label.layer?.removeAllAnimations()
        guard animated else {
            setLabel(nextText)
            return
        }
        guard fadeSeconds > 0 else {
            setLabel(nextText)
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if label.stringValue.isEmpty {
            reveal(nextText, reduceMotion: reduceMotion)
            return
        }
        let duration = reduceMotion ? 0.15 : (nextText.isEmpty ? 0.25 : 0.12)
        animateOpacity(from: currentOpacity, to: 0, seconds: duration, timing: .easeIn)
        let transition = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.transitionGeneration == generation else { return }
            self.pendingTransition = nil
            self.reveal(nextText, reduceMotion: reduceMotion)
        }
        pendingTransition = transition
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: transition)
    }

    private func setLabel(_ nextText: String) {
        label.stringValue = nextText
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.layer?.opacity = nextText.isEmpty ? 0 : 1
        label.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func reveal(_ nextText: String, reduceMotion: Bool) {
        setLabel(nextText)
        guard !nextText.isEmpty else { return }
        let duration = reduceMotion ? 0.15 : fadeSeconds
        animateOpacity(from: 0, to: 1, seconds: duration, timing: .easeOut)
        guard !reduceMotion else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = -3
        slide.toValue = 0
        slide.duration = duration
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        label.layer?.add(slide, forKey: "notificationSlide")
        // #COMPLETION_DRIVE: A 3 pt layer translation and 15 pt monospaced text are visually subtle/readable on the physical bar.
        // #SUGGEST_VERIFY: Check visual settling, legibility and Reduce Motion on the real Touch Bar.
    }

    private func animateOpacity(from: Float, to: Float, seconds: Double, timing: CAMediaTimingFunctionName) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.layer?.opacity = to
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = seconds
        fade.timingFunction = CAMediaTimingFunction(name: timing)
        label.layer?.add(fade, forKey: "notificationFade")
    }

    override func touchesBegan(with event: NSEvent) { receiveTouches(event, phase: .began, state: "began") }
    override func touchesMoved(with event: NSEvent) { receiveTouches(event, phase: .moved, state: "moved") }
    override func touchesEnded(with event: NSEvent) { receiveTouches(event, phase: .ended, state: "ended") }
    override func touchesCancelled(with event: NSEvent) { receiveTouches(event, phase: .cancelled, state: "cancelled") }

    private func receiveTouches(_ event: NSEvent, phase: NSTouch.Phase, state: String) {
        let touches = event.touches(matching: phase, in: self).filter { $0.type == .direct }
        if NotificationDebug.enabled {
            NSLog("MTMR-notif: event state=%@ directTouches=%ld", state, touches.count)
        }
        for touch in touches {
            let location = touch.location(in: self)
            if NotificationDebug.enabled {
                NSLog("MTMR-notif: touch state=%@ location=%@ translation=%@", state, NSStringFromPoint(location), NSStringFromPoint(NSPoint(x: location.x - initialLocation.x, y: location.y - initialLocation.y)))
            }
            if phase == .began {
                guard activeTouch == nil else {
                    finishSwipe()
                    return
                }
                activeTouch = touch
                movedDuringSwipe = false
                initialLocation = location
                latestLocation = location
                NotificationStore.shared.pause()
            } else if let activeTouch = activeTouch {
                guard activeTouch.identity.isEqual(touch.identity) else { continue }
                latestLocation = location
                if phase != .cancelled {
                    navigateSwipe()
                }
                if phase == .ended {
                    finishSwipe()
                } else if phase == .cancelled {
                    finishSwipe()
                }
            }
        }
        if phase == .cancelled { finishSwipe() }
    }

    private func navigateSwipe() {
        guard !movedDuringSwipe else { return }
        let offset = NotificationSwipe.offset(horizontal: Double(latestLocation.x - initialLocation.x), vertical: Double(latestLocation.y - initialLocation.y))
        guard offset != 0 else { return }
        movedDuringSwipe = true
        NotificationStore.shared.move(by: offset)
    }

    private func finishSwipe() {
        guard activeTouch != nil else { return }
        activeTouch = nil
        NotificationStore.shared.resume()
    }

    deinit {
        pendingTransition?.cancel()
        if activeTouch != nil { NotificationStore.shared.resume() }
    }
}
