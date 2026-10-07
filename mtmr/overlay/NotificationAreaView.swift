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
    /// The source app's icon (e.g. Teams, Outlook, lob), drawn left of the text; text and icon centre as one group.
    private let iconView = NSImageView()
    private static let iconSize: CGFloat = 18
    private static let iconGap: CGFloat = 6
    private var icon: NSImage?
    private var targetIcon: NSImage?
    private var shownIcon: NSImage?
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
        iconView.wantsLayer = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.layer?.opacity = 0
        addSubview(iconView)
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
        positionContent()
        updateText(animated: false)
        if NotificationDebug.enabled {
            NSLog("MTMR-notif: area=%@ label=%@", NSStringFromRect(frame), NSStringFromRect(label.frame))
        }
    }

    func show(text: String, icon: NSImage? = nil) {
        self.text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        self.icon = self.text.isEmpty ? nil : icon
        updateText(animated: true)
    }

    private var glyphWidth: CGFloat {
        return ("M" as NSString).size(withAttributes: [.font: font]).width
    }

    /// Without an icon the label spans the area (text centred, as before). With an icon, icon and text centre as
    /// one group; the label takes its measured text width so the text sits right beside the icon.
    private func positionContent() {
        let labelHeight = min(bounds.height, ceil(font.ascender - font.descender + font.leading) + 2)
        let available = max(0, bounds.width - 2 * inset)
        let labelY = bounds.midY - labelHeight / 2
        guard shownIcon != nil else {
            label.frame = NSRect(x: bounds.minX + min(inset, bounds.width / 2), y: labelY, width: available, height: labelHeight)
            return
        }
        let iconSpace = Self.iconSize + Self.iconGap
        let textWidth = min(max(0, available - iconSpace), ceil(label.intrinsicContentSize.width))
        let groupX = bounds.midX - (iconSpace + textWidth) / 2
        iconView.frame = NSRect(x: groupX, y: bounds.midY - Self.iconSize / 2, width: Self.iconSize, height: Self.iconSize)
        label.frame = NSRect(x: groupX + iconSpace, y: labelY, width: textWidth, height: labelHeight)
    }

    private func updateText(animated: Bool) {
        let iconSpace = icon == nil ? 0 : Double(Self.iconSize + Self.iconGap)
        let capacity = NotificationTextMetrics.capacity(width: max(0, Double(bounds.width) - iconSpace), inset: Double(inset), glyphWidth: Double(glyphWidth), maxChars: maxChars)
        let nextText = NotificationTextMetrics.truncated(text, capacity: capacity)
        let nextIcon = nextText.isEmpty ? nil : icon
        if animated {
            guard nextText != targetText || nextIcon !== targetIcon else { return }
        } else if pendingTransition == nil {
            guard nextText != label.stringValue || nextIcon !== shownIcon else { return }
        }
        targetText = nextText
        targetIcon = nextIcon
        let currentOpacity = label.layer?.presentation()?.opacity ?? label.layer?.opacity ?? 1
        transitionGeneration += 1
        let generation = transitionGeneration
        pendingTransition?.cancel()
        pendingTransition = nil
        for layer in contentLayers { layer.removeAllAnimations() }
        guard animated else {
            setLabel(nextText, icon: nextIcon)
            return
        }
        guard fadeSeconds > 0 else {
            setLabel(nextText, icon: nextIcon)
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if label.stringValue.isEmpty {
            reveal(nextText, icon: nextIcon, reduceMotion: reduceMotion)
            return
        }
        let duration = reduceMotion ? 0.15 : (nextText.isEmpty ? 0.25 : 0.12)
        animateOpacity(from: currentOpacity, to: 0, seconds: duration, timing: .easeIn)
        let transition = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.transitionGeneration == generation else { return }
            self.pendingTransition = nil
            self.reveal(nextText, icon: nextIcon, reduceMotion: reduceMotion)
        }
        pendingTransition = transition
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: transition)
    }

    private var contentLayers: [CALayer] {
        return [label.layer, iconView.layer].compactMap { $0 }
    }

    private func setLabel(_ nextText: String, icon nextIcon: NSImage?) {
        label.stringValue = nextText
        shownIcon = nextIcon
        iconView.image = nextIcon
        positionContent()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.layer?.opacity = nextText.isEmpty ? 0 : 1
        iconView.layer?.opacity = nextIcon == nil ? 0 : 1
        for layer in contentLayers { layer.transform = CATransform3DIdentity }
        CATransaction.commit()
    }

    private func reveal(_ nextText: String, icon nextIcon: NSImage?, reduceMotion: Bool) {
        setLabel(nextText, icon: nextIcon)
        guard !nextText.isEmpty else { return }
        let duration = reduceMotion ? 0.15 : fadeSeconds
        animateOpacity(from: 0, to: 1, seconds: duration, timing: .easeOut)
        guard !reduceMotion else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = -3
        slide.toValue = 0
        slide.duration = duration
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        for layer in contentLayers { layer.add(slide, forKey: "notificationSlide") }
        // #COMPLETION_DRIVE: A 3 pt layer translation and 15 pt monospaced text are visually subtle/readable on the physical bar.
        // #SUGGEST_VERIFY: Check visual settling, legibility and Reduce Motion on the real Touch Bar.
    }

    private func animateOpacity(from: Float, to: Float, seconds: Double, timing: CAMediaTimingFunctionName) {
        // The icon fades with the text; an absent icon stays at 0.
        let layers = shownIcon == nil ? [label.layer].compactMap { $0 } : contentLayers
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers { layer.opacity = to }
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = seconds
        fade.timingFunction = CAMediaTimingFunction(name: timing)
        for layer in layers { layer.add(fade, forKey: "notificationFade") }
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
