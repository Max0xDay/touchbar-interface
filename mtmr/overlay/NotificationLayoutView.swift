import Cocoa

final class NotificationLayoutView: NSView {
    private struct Button {
        let view: NSView
        let layout: NotificationLayoutButton
        let item: NSTouchBarItem
        let keepSlotWhenHidden: Bool
        var visible: Bool {
            if let button = item as? CustomButtonTouchBarItem { return button.liveVisible }
            if let group = item as? GroupBarItem { return group.liveVisible }
            return true
        }
        var reservesSlot: Bool { return visible || keepSlotWhenHidden }
    }

    // #COMPLETION_DRIVE: Use 1085 pt only while actual host/view bounds are unavailable.
    // #SUGGEST_VERIFY: Confirm the live full-width bar reports 1085x30 pt on this MacBook Pro.
    private static let fallbackWidth: CGFloat = 1085
    private let left: [Button]
    private let right: [Button]
    private let notificationView: NSView
    private let options: NotificationLayoutOptions
    private var hostConstraints: [NSLayoutConstraint] = []
    private var solvedWidth: Double?
    private var visibilityObserver: NSObjectProtocol?

    init(items: [NSTouchBarItem], definitions: [NSTouchBarItem.Identifier: BarItemDefinition], notification: NotificationTouchBarItem) {
        left = Self.buttons(items, definitions: definitions, alignment: .left)
        right = Self.buttons(items, definitions: definitions, alignment: .right)
        notificationView = notification.view
        options = notification.layoutOptions
        super.init(frame: NSRect(x: 0, y: 0, width: Self.fallbackWidth, height: 30))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
        for button in left + right { install(button.view) }
        install(notificationView)
        visibilityObserver = NotificationCenter.default.addObserver(forName: LiveButtonStore.visibilityChanged, object: nil, queue: .main) { [weak self] notification in
            guard let self = self, let changedView = notification.object as? NSView else { return }
            guard (self.left + self.right).contains(where: { $0.view === changedView }) else { return }
            self.solve(animated: true)
        }
        needsLayout = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: Self.fallbackWidth, height: 30)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NSLayoutConstraint.deactivate(hostConstraints)
        hostConstraints = []
        if let host = superview {
            // #COMPLETION_DRIVE: The sole custom item's host spans the modal bar; pin to its actual edges, not a leftover stack gap.
            // #SUGGEST_VERIFY: Check host/container bounds and edge pins on the real Touch Bar, including a width change.
            hostConstraints = [
                leadingAnchor.constraint(equalTo: host.leadingAnchor),
                trailingAnchor.constraint(equalTo: host.trailingAnchor),
                centerYAnchor.constraint(equalTo: host.centerYAnchor)
            ]
            NSLayoutConstraint.activate(hostConstraints)
        }
        solvedWidth = nil
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = barWidth()
        guard solvedWidth != width else { return }
        solvedWidth = width
        solve(animated: false)
    }

    private func solve(animated: Bool) {
        let width = barWidth()
        let visibleLeft = left.filter { $0.reservesSlot }
        let visibleRight = right.filter { $0.reservesSlot }
        let solution = NotificationLayoutSolver.solve(barWidth: width, left: visibleLeft.map { $0.layout }, right: visibleRight.map { $0.layout }, options: options)
        let duration = animationDuration(animated: animated)
        for button in left + right where !button.reservesSlot {
            transition(button.view, frame: button.view.frame, alpha: 0, duration: duration)
        }
        for (button, frame) in zip(visibleLeft, solution.left) { apply(frame, to: button.view, visible: button.visible, duration: duration) }
        for (button, frame) in zip(visibleRight, solution.right) { apply(frame, to: button.view, visible: button.visible, duration: duration) }
        apply(solution.notification, to: notificationView, visible: true, duration: duration)
        notificationView.layoutSubtreeIfNeeded()
        if NotificationDebug.enabled {
            let labelFrame = notificationView.subviews.first?.frame ?? .zero
            NSLog("MTMR-notif: container=%@ notification=%@ label=%@", NSStringFromSize(bounds.size), NSStringFromRect(notificationView.frame), NSStringFromRect(labelFrame))
        }
        if solution.isBelowMinimum {
            NSLog("MTMR layout warning: W=%.2f, notification=%.0f below minimum=%.0f, hidden edge items=%@", width, solution.notification.width, options.minWidth, solution.hasHiddenItems ? "yes" : "no")
        }
    }

    private func barWidth() -> Double {
        if let host = superview {
            if Self.usableWidth(host.bounds.width) { return Double(host.bounds.width) }
        }
        if Self.usableWidth(bounds.width) { return Double(bounds.width) }
        return Double(Self.fallbackWidth)
    }

    private static func usableWidth(_ width: CGFloat) -> Bool {
        return width.isFinite && width > 0
    }

    private func install(_ child: NSView) {
        NSLayoutConstraint.deactivate(child.constraints.filter { Self.constantWidthConstraint($0, on: child) })
        child.translatesAutoresizingMaskIntoConstraints = true
        child.autoresizingMask = []
        addSubview(child)
    }

    private static func constantWidthConstraint(_ constraint: NSLayoutConstraint, on view: NSView) -> Bool {
        guard let constrainedView = constraint.firstItem as? NSView else { return false }
        return constrainedView === view && constraint.firstAttribute == .width && constraint.secondItem == nil
    }

    private func animationDuration(animated: Bool) -> Double {
        guard animated else { return 0 }
        guard options.fadeSeconds > 0 else { return 0 }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return 0 }
        return 0.2
    }

    private func apply(_ frame: NotificationLayoutFrame?, to child: NSView, visible: Bool, duration: Double) {
        let frameValue = frame ?? NotificationLayoutFrame(x: 0, width: 0)
        let rectangle = NSRect(x: bounds.minX + CGFloat(frameValue.x), y: bounds.midY - 15, width: CGFloat(frameValue.width), height: CGFloat(frameValue.height))
        transition(child, frame: rectangle, alpha: frame == nil ? 0 : (visible ? 1 : 0), duration: duration)
    }

    private func transition(_ child: NSView, frame: NSRect, alpha: CGFloat, duration: Double) {
        child.wantsLayer = true
        if alpha > 0 { child.isHidden = false }
        defer { hideWhenFaded(child, alpha: alpha, after: duration) }
        guard let layer = child.layer else {
            child.frame = frame
            child.alphaValue = alpha
            return
        }
        let presentation = layer.presentation() ?? layer
        let previousPosition = presentation.position
        let previousBounds = presentation.bounds
        let previousOpacity = presentation.opacity
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        child.frame = frame
        child.alphaValue = alpha
        CATransaction.commit()
        guard duration > 0 else { return }
        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(point: previousPosition)
        position.toValue = NSValue(point: layer.position)
        let bounds = CABasicAnimation(keyPath: "bounds")
        bounds.fromValue = NSValue(rect: previousBounds)
        bounds.toValue = NSValue(rect: layer.bounds)
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = previousOpacity
        opacity.toValue = Float(alpha)
        let animation = CAAnimationGroup()
        animation.animations = [position, bounds, opacity]
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        // #COMPLETION_DRIVE: Layer presentation geometry tracks AppKit frames correctly on the private Touch Bar host.
        // #SUGGEST_VERIFY: Observe rapid hide/show on hardware; model frames are set synchronously to the latest pure solution.
        layer.add(animation, forKey: "liveButtonLayout")
    }

    /// A transparent view still takes touches: an invisible, never-placed teams-mic sat on top of ✕ and swallowed
    /// its taps (2026-10-06). Hide fully transparent views once their fade-out has finished.
    private func hideWhenFaded(_ child: NSView, alpha: CGFloat, after duration: Double) {
        guard alpha == 0 else { return }
        guard duration > 0 else {
            child.isHidden = true
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak child] in
            if child?.alphaValue == 0 { child?.isHidden = true }
        }
    }

    deinit {
        if let observer = visibilityObserver { NotificationCenter.default.removeObserver(observer) }
    }

    private static func buttons(_ items: [NSTouchBarItem], definitions: [NSTouchBarItem.Identifier: BarItemDefinition], alignment: Align) -> [Button] {
        return items.compactMap { item in
            guard let definition = definitions[item.identifier] else {
                NSLog("MTMR layout omitted item with missing definition: %@", item.identifier.rawValue)
                return nil
            }
            guard definition.align == alignment else { return nil }
            guard let view = item.view else {
                NSLog("MTMR layout omitted item with no view: %@", item.identifier.rawValue)
                return nil
            }
            let width: Double
            if case let .width(value)? = definition.additionalParameters[.width] {
                width = Double(value)
            } else {
                width = Double(view.fittingSize.width)
            }
            var minWidth: Double?
            if alignment == .left {
                if case let .minWidth(value)? = definition.additionalParameters[.minWidth] { minWidth = Double(value) }
            }
            return Button(view: view, layout: NotificationLayoutButton(width: width, minWidth: minWidth, fixed: fixedWidth(item, definition: definition)), item: item, keepSlotWhenHidden: definition.liveButton?.keepSlotWhenHidden ?? false)
        }
    }

    private static func fixedWidth(_ item: NSTouchBarItem, definition: BarItemDefinition) -> Bool {
        return definition.isExitButton || spacer(item)
    }

    private static func spacer(_ item: NSTouchBarItem) -> Bool {
        guard let button = item as? CustomButtonTouchBarItem else { return false }
        return button.isBordered == false && button.title.isEmpty && button.image == nil && button.backgroundColor == nil && button.actions.isEmpty
    }
}
