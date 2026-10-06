import Cocoa

// Standalone view harness: no NSApplication, NSTouchBar, controller singleton, live config or socket.
@main
struct LayoutViewTests {
    static func main() {
        do {
            SupportedTypesHolder.sharedInstance.register(typename: "exitTouchbar", item: .staticButton(title: "exit"), actions: [], legacyAction: .none, legacyLongAction: .none)
            let layoutBytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let definitions = try JSONDecoder().decode([BarItemDefinition].self, from: layoutBytes)
            try checkNotificationLayout(definitions)
            try checkStackPath(definitions.filter { !$0.type.isNotification })
            try checkDecodedOptions()
            print("Layout view checks passed (no Touch Bar created)")
        } catch {
            NSLog("Layout view tests failed: %@", String(describing: error))
            exit(1)
        }
    }

    private static func makeItems(_ definitions: [BarItemDefinition]) throws -> ([NSTouchBarItem], [NSTouchBarItem.Identifier: BarItemDefinition]) {
        var items: [NSTouchBarItem] = []
        var indexedDefinitions: [NSTouchBarItem.Identifier: BarItemDefinition] = [:]
        for definition in definitions {
            let identifier = NSTouchBarItem.Identifier(UUID().uuidString)
            let item: NSCustomTouchBarItem
            switch definition.type {
            case let .staticButton(title):
                let button = CustomButtonTouchBarItem(identifier: identifier, title: title)
                if case let .title(value)? = definition.additionalParameters[.title] { button.title = value }
                if case let .bordered(value)? = definition.additionalParameters[.bordered] { button.isBordered = value }
                if case let .image(source)? = definition.additionalParameters[.image] { button.image = source.image }
                item = button
            case let .notification(maxChars, defaultSeconds, layoutOptions):
                item = NotificationTouchBarItem(identifier: identifier, maxChars: maxChars, defaultSeconds: defaultSeconds, layoutOptions: layoutOptions)
            default:
                throw NSError(domain: "LayoutViewTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected item in test layout"])
            }
            if case let .width(value)? = definition.additionalParameters[.width] { item.setWidth(value: value) }
            items.append(item)
            indexedDefinitions[identifier] = definition
        }
        return (items, indexedDefinitions)
    }

    private static func checkNotificationLayout(_ definitions: [BarItemDefinition]) throws {
        let (items, indexedDefinitions) = try makeItems(definitions)
        let basic = BasicView(identifier: NSTouchBarItem.Identifier(UUID().uuidString), items: items, swipeItems: [], itemDefinitions: indexedDefinitions)
        guard let container = basic.view as? NotificationLayoutView else { preconditionFailure("Notification must bypass NSStackView") }
        guard let notification = items.first(where: { $0 is NotificationTouchBarItem }) as? NotificationTouchBarItem else { preconditionFailure("Missing notification fixture") }
        guard let notificationView = notification.view as? NotificationAreaView else { preconditionFailure("Missing notification view") }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1085, height: 30))
        host.addSubview(container)
        host.layoutSubtreeIfNeeded()
        precondition(container.frame == host.bounds, "Container must fill its host")
        precondition(items[0].view?.frame.width == 30)
        precondition(items[1].view?.frame.width == 1)
        precondition(items[2].view?.frame.minX == 47)
        precondition(notificationView.frame == NSRect(x: 304, y: 0, width: 477, height: 30))
        precondition(items.last?.view?.frame.maxX == 1085)
        let initialFrames = items.compactMap { $0.view?.frame }
        let longNotificationText = String(repeating: "wide notification ", count: 100)
        let testTexts = [("", ""), ("hi", "hi"), ("  hi\nthere  ", "hi there"), (longNotificationText, String(longNotificationText.prefix(39)) + "…")]
        for (text, expectedText) in testTexts {
            notificationView.show(text: text)
            container.layoutSubtreeIfNeeded()
            precondition(items.compactMap { $0.view?.frame } == initialFrames, "Text must not resize or move any zone")
            guard let label = notificationView.subviews.first as? NSTextField else { preconditionFailure("Missing text label") }
            precondition(label.alignment == .center)
            precondition(label.stringValue == expectedText)
        }
        for barWidth: CGFloat in [900, 780, 300, 1085] {
            host.setFrameSize(NSSize(width: barWidth, height: 30))
            host.layoutSubtreeIfNeeded()
            precondition(container.frame == host.bounds, "Width changes must update the edge pins")
            precondition(notificationView.frame.midX == barWidth / 2)
            precondition(items.last?.view?.frame.maxX == barWidth)
            let visibleViews = items.compactMap { $0.view }.filter { !$0.isHidden }.sorted { $0.frame.minX < $1.frame.minX }
            for (previous, following) in zip(visibleViews, visibleViews.dropFirst()) {
                precondition(previous.frame.maxX <= following.frame.minX, "Container frames must not overlap")
            }
        }
        precondition(notificationView.frame.width == 477, "Growing W must restore nominal widths")
    }

    private static func checkStackPath(_ definitions: [BarItemDefinition]) throws {
        let (items, indexedDefinitions) = try makeItems(definitions)
        let basic = BasicView(identifier: NSTouchBarItem.Identifier(UUID().uuidString), items: items, swipeItems: [], itemDefinitions: indexedDefinitions)
        guard let stack = basic.view as? NSStackView else { preconditionFailure("No-notification layouts must retain upstream NSStackView") }
        precondition(stack.spacing == 8)
        precondition(stack.orientation == .horizontal)
        precondition(stack.distribution == NSStackView().distribution)
        precondition(stack.arrangedSubviews == items.compactMap { $0.view })
        for view in stack.arrangedSubviews {
            for constraint in view.constraints where constraint.firstAttribute == .width {
                precondition(constraint.isActive, "The stack path must keep original width constraints")
            }
        }
    }

    private static func checkDecodedOptions() throws {
        let bytes = Data(#"[{"type":"exitTouchbar","width":30,"minWidth":0,"align":"left"},{"type":"staticButton","title":"","width":75,"minWidth":70,"align":"left"},{"type":"notification","padding":24,"minWidth":300,"maxWidth":400}]"#.utf8)
        let definitions = try JSONDecoder().decode([BarItemDefinition].self, from: bytes)
        precondition(definitions[0].isExitButton, "Decoding must preserve exit identity after alias expansion")
        if case let .minWidth(value)? = definitions[1].additionalParameters[.minWidth] {
            precondition(value == 70)
        } else {
            preconditionFailure("Per-button minWidth was not decoded")
        }
        let (items, indexedDefinitions) = try makeItems(definitions)
        let basic = BasicView(identifier: NSTouchBarItem.Identifier(UUID().uuidString), items: items, swipeItems: [], itemDefinitions: indexedDefinitions)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1085, height: 30))
        host.addSubview(basic.view)
        host.layoutSubtreeIfNeeded()
        precondition(items.last?.view?.frame.width == 399, "Decoded padding/min/max must reach the container")
        for invalidParameters in [#"{"minWidth":-1}"#, #"{"minWidth":"bad"}"#] {
            do {
                _ = try JSONDecoder().decode(GeneralParameters.self, from: Data(invalidParameters.utf8))
                preconditionFailure("Invalid item minWidth was accepted")
            } catch {
                print("Rejected invalid item minWidth: \(error)")
            }
        }
    }
}
