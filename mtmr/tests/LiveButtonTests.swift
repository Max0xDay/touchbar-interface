import Cocoa

enum LiveButtonTests {
    static func run() throws {
        try checkFieldsAndRestore()
        try checkPngAndLayoutDefaults()
        try checkVisibility(keepSlot: false, fadeSeconds: 0)
        try checkVisibility(keepSlot: true, fadeSeconds: 0)
        try checkVisibility(keepSlot: false, fadeSeconds: 0.35)
        try checkDuplicateIds()
        print("Live button checks passed (standalone views, no Touch Bar)")
    }

    private static func checkFieldsAndRestore() throws {
        let definitions = try JSONDecoder().decode([BarItemDefinition].self, from: Data(LayoutViewTests.fixture.utf8))
        LiveButtonStore.shared.beginRebuild()
        let (items, _) = try LayoutViewTests.makeItems(definitions)
        guard let button = items[2] as? CustomButtonTouchBarItem else { preconditionFailure("Missing fixture button") }
        let originalView = button.view
        let store = LiveButtonStore.shared
        try store.update(["id": "fixture-mic", "icon": "mic.slash.fill", "tint": "#ff3b30", "background": "#112233"])
        precondition(button.view === originalView, "Live state must never replace the button view")
        precondition(button.title.isEmpty)
        precondition(button.image?.isTemplate == true)
        precondition((button.view as? NSButton)?.contentTintColor == LiveButtonStore.color("#ff3b30"))
        precondition(button.backgroundColor == LiveButtonStore.color("#112233"))
        let state = try JSONSerialization.data(withJSONObject: store.buttons(), options: .sortedKeys)
        for fields: [String: Any] in [["id": "missing", "tint": "#ffffff"], ["id": "fixture-mic", "tint": "#zzz", "visible": false], ["id": "fixture-mic", "icon": "not-a-real-symbol"], ["id": "fixture-mic", "visible": 1], ["id": "fixture-mic", "background": true], ["id": "fixture-mic", "icon": 7], ["id": "fixture-mic", "iconPath": "relative.png"]] {
            do {
                try store.update(fields)
                preconditionFailure("Invalid fields accepted")
            } catch {
                print("Rejected invalid live state: \(error)")
            }
            let rejectedState = try JSONSerialization.data(withJSONObject: store.buttons(), options: .sortedKeys)
            precondition(rejectedState == state, "Rejections must be atomic")
        }
        store.beginRebuild()
        let (restoredItems, _) = try LayoutViewTests.makeItems(definitions)
        precondition(restoredItems[2].view !== originalView)
        let restoredState = try JSONSerialization.data(withJSONObject: store.buttons(), options: .sortedKeys)
        precondition(restoredState == state)
        try store.update(["id": "fixture-mic", "icon": NSNull(), "tint": NSNull(), "background": NSNull(), "visible": NSNull()])
        let restoredButton = restoredItems[2] as! CustomButtonTouchBarItem
        precondition((restoredButton.view as? NSButton)?.contentTintColor == LiveButtonStore.color("#8e8e93"))
        precondition(restoredButton.backgroundColor == nil)
        precondition(store.buttons()[0]["icon"] as? String == "mic.fill")
        try store.update(["id": "fixture-mic", "visible": false, "tint": "#34c759"])
        store.beginRebuild()
        precondition(store.buttons().isEmpty)
        let (returnedItems, _) = try LayoutViewTests.makeItems(definitions)
        precondition(returnedItems.count == items.count)
        precondition(store.buttons()[0]["visible"] as? Bool == false, "State for absent ids must survive")
        precondition(store.buttons()[0]["tint"] as? String == "#34c759")
        try store.update(["id": "fixture-mic", "visible": NSNull(), "tint": NSNull()])
    }

    private static func checkPngAndLayoutDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-button-png-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { NSLog("Live button test cleanup failed: %@", String(describing: error)); exit(1) }
        }
        let imagePath = directory.appendingPathComponent("mic.png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAASklEQVR4nGP4//8/Ay0xTQ0fVBbgAhRbQCwgywJSAUkWkAuIsoBSMLAWUAuMWjCSLRj6+YAuRQVdCju6FNfEWERQL7EWkI2HvgUAuOu4qqtNpA8AAAAASUVORK5CYII=")!
        try png.write(to: imagePath)
        let definition = try JSONDecoder().decode(LiveButtonDefinition.self, from: Data(##"{"id":"png-button","icon":"mic.fill","tint":"#8e8e93"}"##.utf8))
        let button = CustomButtonTouchBarItem(identifier: .init("png-test"), title: "")
        button.backgroundColor = LiveButtonStore.color("#445566")
        button.bindLiveState(definition)
        let store = LiveButtonStore.shared
        try store.update(["id": "png-button", "iconPath": imagePath.path, "background": "#112233"])
        precondition(button.image?.size == NSSize(width: 17, height: 17))
        precondition(button.image?.isTemplate == true)
        let values = store.buttons().first { $0["id"] as? String == "png-button" }!
        precondition(values["icon"] is NSNull)
        precondition(values["iconPath"] as? String == imagePath.path)
        try store.update(["id": "png-button", "iconPath": NSNull(), "background": NSNull()])
        precondition(button.backgroundColor == LiveButtonStore.color("#445566"))
        let reset = store.buttons().first { $0["id"] as? String == "png-button" }!
        precondition(reset["icon"] as? String == "mic.fill")
        precondition(reset["background"] as? String == "#445566")
        let textDefinition = try JSONDecoder().decode(LiveButtonDefinition.self, from: Data(#"{"id":"text-button"}"#.utf8))
        let textButton = CustomButtonTouchBarItem(identifier: .init("text-test"), title: "Caption")
        textButton.bindLiveState(textDefinition)
        try store.update(["id": "text-button", "icon": "mic.fill"])
        precondition(textButton.title.isEmpty, "Live symbols must be icon-only")
        try store.update(["id": "text-button", "icon": NSNull()])
        precondition(textButton.title == "Caption", "Reset must restore the original text-only layout default")
        precondition(textButton.image == nil)
    }

    private static func checkVisibility(keepSlot: Bool, fadeSeconds: Double) throws {
        var objects = try JSONSerialization.jsonObject(with: Data(LayoutViewTests.fixture.utf8)) as! [[String: Any]]
        objects[2]["keepSlotWhenHidden"] = keepSlot
        objects[5]["fadeSeconds"] = fadeSeconds
        let definitions = try JSONDecoder().decode([BarItemDefinition].self, from: JSONSerialization.data(withJSONObject: objects))
        LiveButtonStore.shared.beginRebuild()
        let (items, indexed) = try LayoutViewTests.makeItems(definitions)
        let notification = items[5] as! NotificationTouchBarItem
        let container = NotificationLayoutView(items: items, definitions: indexed, notification: notification)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1085, height: 30))
        host.addSubview(container)
        host.layoutSubtreeIfNeeded()
        let originalFrames = items.compactMap { $0.view?.frame }
        var taps = 0
        let button = items[2] as! CustomButtonTouchBarItem
        button.actions = [ItemAction(trigger: .singleTap, { taps += 1 })]
        try LiveButtonStore.shared.update(["id": "fixture-mic", "visible": false])
        button.callActions(for: .singleTap)
        precondition(taps == 0, "Invisible buttons cannot run tap actions")
        precondition(button.view.alphaValue == 0)
        if fadeSeconds > 0 {
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                precondition(button.view.layer?.animation(forKey: "liveButtonLayout")?.duration == 0.2)
                precondition(notification.view.layer?.animation(forKey: "liveButtonLayout")?.duration == 0.2)
            }
        }
        if keepSlot {
            precondition(items.compactMap { $0.view?.frame } == originalFrames)
        } else {
            let left = [NotificationLayoutButton(width: 30, fixed: true), NotificationLayoutButton(width: 1, fixed: true), NotificationLayoutButton(width: 75), NotificationLayoutButton(width: 75)]
            let solution = NotificationLayoutSolver.solve(barWidth: 1085, left: left, right: [NotificationLayoutButton(width: 100), NotificationLayoutButton(width: 100)])
            for (index, frame) in zip([0, 1, 3, 4], solution.left) { checkFrame(items[index].view!, frame!) }
            checkFrame(notification.view, solution.notification)
            for (item, frame) in zip(items.suffix(2), solution.right) { checkFrame(item.view!, frame!) }
            precondition(items[3].view?.frame.minX == 47)
            precondition(notification.view.frame.width == 637)
        }
        precondition(notification.view.frame.midX == 542.5)
        precondition(items.suffix(2).compactMap { $0.view?.frame } == Array(originalFrames.suffix(2)))
        for visible in [true, false, true, false, true] {
            try LiveButtonStore.shared.update(["id": "fixture-mic", "visible": visible])
            precondition(notification.view.frame.midX == 542.5)
        }
        precondition(items.compactMap { $0.view?.frame } == originalFrames, "Rapid changes must synchronously leave final solver frames")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        precondition(items.compactMap { $0.view?.frame } == originalFrames, "No stale animation completion may change frames")
        precondition(button.view.alphaValue == 1)
        button.callActions(for: .singleTap)
        precondition(taps == 1)
        if fadeSeconds == 0 { precondition(button.view.layer?.animationKeys()?.isEmpty ?? true) }
    }

    private static func checkFrame(_ view: NSView, _ frame: NotificationLayoutFrame) {
        precondition(view.frame == NSRect(x: frame.x, y: 0, width: frame.width, height: 30))
    }

    private static func checkDuplicateIds() throws {
        for json in [#"[{"type":"staticButton","id":"repeat"},{"type":"staticButton","id":"repeat"}]"#, #"[{"type":"staticButton","id":"repeat"},{"type":"group","items":[{"type":"staticButton","id":"repeat"}]}]"#] {
            let definitions = try JSONDecoder().decode([BarItemDefinition].self, from: Data(json.utf8))
            do {
                try validateLiveButtonIds(definitions)
                preconditionFailure("Duplicate ids accepted")
            } catch {
                precondition(error.localizedDescription == "duplicate button id: repeat")
            }
            precondition(Data(json.utf8).barItemDefinitions() == nil, "Parser must reject rather than crash")
        }
        for id in ["", "BAD", "spaces here", String(repeating: "a", count: 33)] {
            do {
                _ = try JSONDecoder().decode(LiveButtonDefinition.self, from: JSONSerialization.data(withJSONObject: ["id": id]))
                preconditionFailure("Invalid id accepted")
            } catch { print("Rejected invalid id: \(error)") }
        }
    }
}
