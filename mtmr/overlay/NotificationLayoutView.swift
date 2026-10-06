import Cocoa

final class NotificationLayoutView: NSView {
    private struct Button {
        let view: NSView
        let layout: NotificationLayoutButton
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
        let solution = NotificationLayoutSolver.solve(barWidth: width, left: left.map { $0.layout }, right: right.map { $0.layout }, options: options)
        for (button, frame) in zip(left, solution.left) { apply(frame, to: button.view) }
        for (button, frame) in zip(right, solution.right) { apply(frame, to: button.view) }
        apply(solution.notification, to: notificationView)
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

    private func apply(_ frame: NotificationLayoutFrame?, to child: NSView) {
        child.isHidden = frame == nil
        let frame = frame ?? NotificationLayoutFrame(x: 0, width: 0)
        child.frame = NSRect(x: bounds.minX + CGFloat(frame.x), y: bounds.midY - 15, width: CGFloat(frame.width), height: CGFloat(frame.height))
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
            if case let .minWidth(value)? = definition.additionalParameters[.minWidth] { minWidth = Double(value) }
            return Button(view: view, layout: NotificationLayoutButton(width: width, minWidth: minWidth, fixed: fixedWidth(item, definition: definition)))
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
