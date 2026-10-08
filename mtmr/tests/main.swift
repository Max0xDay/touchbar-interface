import Cocoa

// Standalone harness: never creates NSApplication or a Touch Bar, and uses only a temporary socket.
guard let testDirectory = ProcessInfo.processInfo.environment["MTMR_TEST_DIRECTORY"] else {
    fatalError("MTMR_TEST_DIRECTORY is required")
}
let appSupportDirectory = testDirectory

func advance(seconds: Double) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
}

func checkNotificationStore() {
    let store = NotificationStore.shared
    store.defaultSeconds = 0.08
    precondition(store.notify(text: "oldest", seconds: nil))
    precondition(store.notify(text: "newer", seconds: 0.08))
    precondition(store.text == "newer", "The newest entry shows on arrival")
    store.pause()
    advance(seconds: 0.12)
    precondition(store.text == "newer", "Pause must suspend expiry")
    store.move(by: 1)
    precondition(store.text == "oldest", "Navigation must wrap from the last entry to the first")
    store.move(by: -1)
    precondition(store.text == "newer", "Navigation must wrap from the first entry to the last")
    store.move(by: -1)
    precondition(store.text == "oldest", "Down selects previous queued entry")
    store.move(by: 1)
    precondition(store.text == "newer", "Up selects next queued entry")
    store.resume()
    advance(seconds: 0.12)
    precondition(store.text.isEmpty, "Every entry counts down on its own; both expire")
    // A long entry (a 10-minute Outlook reminder) must not hold back newer ones, and must outlive them.
    precondition(store.notify(text: "sticky", seconds: 0.4))
    precondition(store.notify(text: "short", seconds: 0.08))
    precondition(store.text == "short", "A newer entry shows over a long one")
    advance(seconds: 0.15)
    precondition(store.text == "sticky", "After the newer entry expires, the long one shows again")
    let icon = NSImage(size: NSSize(width: 4, height: 4))
    precondition(store.notify(text: "with icon", seconds: 0.08, icon: icon))
    precondition(store.icon === icon, "An entry keeps its icon")
    store.clear()
    precondition(store.icon == nil)
    precondition(store.notify(text: "partly elapsed", seconds: 0.2))
    advance(seconds: 0.12)
    store.pause()
    advance(seconds: 0.12)
    store.resume()
    advance(seconds: 0.11)
    precondition(store.text.isEmpty, "Resume must preserve remaining time, not restart duration")
    precondition(store.notify(text: "clear me", seconds: 1))
    store.clear()
    precondition(store.text.isEmpty)
    for index in 0..<256 {
        precondition(store.notify(text: "entry \(index)", seconds: 5))
    }
    precondition(!store.notify(text: "overflow", seconds: 5))
    store.clear()
    store.defaultSeconds = 5
    print("Notification store checks passed")
}

checkNotificationStore()
let liveButtonView = NSButton(frame: NSRect(x: 0, y: 0, width: 75, height: 30))
let liveDefinition = try JSONDecoder().decode(LiveButtonDefinition.self, from: Data(##"{"id":"fixture-mic","icon":"mic.fill","tint":"#8e8e93"}"##.utf8))
LiveButtonStore.shared.bind(definition: liveDefinition, view: liveButtonView, image: nil, background: nil) { image, tint, background, visible in
    liveButtonView.image = image
    liveButtonView.contentTintColor = tint
    liveButtonView.bezelColor = background
    liveButtonView.isEnabled = visible
}
NotificationSocketServer.shared.start()
let stopPath = testDirectory + "/stop"
let deadline = Date(timeIntervalSinceNow: 20)
while !FileManager.default.fileExists(atPath: stopPath) {
    if Date() >= deadline {
        NotificationSocketServer.shared.stop()
        fatalError("Test harness timed out waiting for stop file")
    }
    advance(seconds: 0.01)
}
NotificationSocketServer.shared.stop()
precondition(!FileManager.default.fileExists(atPath: testDirectory + "/mtmr.sock"), "Quit must remove the socket")
print("Socket cleanup check passed")
