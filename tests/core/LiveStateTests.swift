import Cocoa

@main
struct LiveStateTests {
    static func main() throws {
        guard let directory = ProcessInfo.processInfo.environment["MTMR_TEST_DIRECTORY"] else {
            preconditionFailure("Temporary directory is required")
        }
        precondition(NSHomeDirectory() == directory, "Watcher logs must stay in the temporary home")
        try checkButtonBinding()
        try checkGroupBinding()
        try checkWatcherLifecycle(directory: directory)
        try checkFailedWatcherRestart(directory: directory)
        print("Core binding and watcher checks passed")
    }

    private static func definition(_ fields: [String: Any]) throws -> LiveButtonDefinition {
        return try JSONDecoder().decode(LiveButtonDefinition.self,
                                       from: JSONSerialization.data(withJSONObject: fields))
    }

    private static func checkButtonBinding() throws {
        let store = LiveButtonStore.shared
        store.beginRebuild()
        let button = CustomButtonTouchBarItem(identifier: .init("core.button"), title: "Original")
        let configuration = try definition(["id": "core-button", "startHidden": true])
        button.bindLiveState(configuration)
        precondition(!button.liveVisible, "startHidden disables the bound button")
        try store.update(["id": "core-button", "icon": "mic.fill", "visible": true, "background": "#112233"])
        precondition(button.liveVisible, "Socket visibility reaches the item")
        precondition(button.title.isEmpty, "An overridden symbol replaces the caption")
        precondition(button.backgroundColor == LiveButtonStore.color("#112233"), "Background reaches the item")
        button.bindLiveState(configuration)
        try store.update(["id": "core-button", "icon": NSNull(), "background": NSNull()])
        precondition(button.title == "Original", "Rebinding preserves the original caption")
        precondition(button.image == nil, "Reset restores the original image")
        store.beginRebuild()
        precondition(store.buttons().isEmpty, "Rebuild removes bindings")
        button.bindLiveState(configuration)
        precondition(button.liveVisible, "Rebuild preserves socket overrides")
    }

    private static func checkGroupBinding() throws {
        let group = GroupBarItem(identifier: .init("core.group"), items: [])
        let button = NSButton(title: "Group", target: nil, action: nil)
        group.collapsedRepresentation = button
        group.bindLiveState(try definition(["id": "core-group"]))
        try LiveButtonStore.shared.update(["id": "core-group", "icon": "mic.fill", "visible": false])
        precondition(!group.liveVisible, "Group visibility reaches the item")
        precondition(!button.isEnabled, "Hidden groups cannot open")
        precondition(button.title.isEmpty, "Group icons replace captions")
        group.bindLiveState(try definition(["id": "core-group"]))
        try LiveButtonStore.shared.update(["id": "core-group", "icon": NSNull(), "visible": NSNull()])
        precondition(button.title == "Group", "Reset restores the first group caption")
        precondition(button.isEnabled, "Reset restores group visibility")
    }

    private static func waitUntil(_ condition: () throws -> Bool, seconds: Double, message: String) rethrows {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while try !condition() {
            precondition(Date() < deadline, message)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private static func starts(at path: String) throws -> [String] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        return try String(contentsOfFile: path).split(separator: "\n").map(String.init)
    }

    private static func checkWatcherLifecycle(directory: String) throws {
        let supervisor = WatcherSupervisor.shared
        defer { supervisor.stopAll() }
        let marker = directory + "/starts"
        let command = ["/bin/sh", "-c", "echo started >> '\(marker)'; exit 0"]
        supervisor.sync([[], command, command])
        try waitUntil({ try starts(at: marker).count == 1 }, seconds: 1, message: "Watcher must start")
        supervisor.sync([command])
        let firstStart = Date()
        try waitUntil({ try starts(at: marker).count == 2 }, seconds: 1.5, message: "Exited watcher must restart")
        precondition(Date().timeIntervalSince(firstStart) >= 0.9, "Restart must wait for the initial backoff")
        let secondStart = Date()
        try waitUntil({ try starts(at: marker).count == 3 }, seconds: 2.5, message: "Watcher must restart twice")
        precondition(Date().timeIntervalSince(secondStart) >= 1.9, "Repeated failures double the backoff")
        supervisor.sync([])
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let startCountAfterRemoval = try starts(at: marker).count
        precondition(startCountAfterRemoval == 3, "Removing a watcher stops restart scheduling")
        let runningMarker = directory + "/running"
        let running = ["/bin/sh", "-c", "echo $$ > '\(runningMarker)'; exec /bin/sleep 30"]
        supervisor.sync([running])
        waitUntil({ FileManager.default.fileExists(atPath: runningMarker) }, seconds: 1,
                      message: "Long-running fake must start")
        let processIdentifier = Int32(try String(contentsOfFile: runningMarker).trimmingCharacters(in: .whitespacesAndNewlines))!
        supervisor.stopAll()
        waitUntil({ kill(processIdentifier, 0) != 0 }, seconds: 1, message: "stopAll must terminate the child")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    private static func checkFailedWatcherRestart(directory: String) throws {
        let supervisor = WatcherSupervisor.shared
        defer { supervisor.stopAll() }
        let scriptPath = directory + "/late-watcher"
        let marker = directory + "/late-start"
        supervisor.sync([[scriptPath]])
        try "#!/bin/sh\necho started > '\(marker)'\n".write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptPath)
        waitUntil({ FileManager.default.fileExists(atPath: marker) }, seconds: 1.5,
                      message: "A failed launch must retry after the executable appears")
        let markerText = try String(contentsOfFile: marker)
        precondition(markerText == "started\n", "Restart executes the recovered script")
    }
}
