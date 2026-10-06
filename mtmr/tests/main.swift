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
    precondition(store.text == "oldest")
    store.pause()
    advance(seconds: 0.12)
    precondition(store.text == "oldest", "Pause must suspend expiry")
    store.move(by: 1)
    precondition(store.text == "newer", "Up selects next queued entry")
    store.move(by: -1)
    precondition(store.text == "oldest", "Down selects previous queued entry")
    store.move(by: -1)
    precondition(store.text == "oldest", "Navigation must clamp at queue ends")
    store.resume()
    advance(seconds: 0.1)
    precondition(store.text == "newer", "Expiry must remove current and select next")
    advance(seconds: 0.1)
    precondition(store.text.isEmpty, "Queue must become idle after expiry")
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
