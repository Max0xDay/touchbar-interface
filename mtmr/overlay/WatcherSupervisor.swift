import Foundation

/// Runs the `watcher` processes that layout buttons declare (e.g. teams-watch for teams-mic) for as long as
/// that layout is loaded: started on load, restarted with backoff if they exit, stopped when the layout no
/// longer lists them or MTMR quits. No LaunchAgent needed. Output goes to ~/Library/Logs/touchbar-interface/watchers.log.
final class WatcherSupervisor {
    static let shared = WatcherSupervisor()

    private final class Watcher {
        let command: [String]
        var process: Process?
        var startedAt = Date()
        var backoff: TimeInterval = 1
        var stopped = false

        init(command: [String]) {
            self.command = command
        }
    }

    private static let maximumBackoff: TimeInterval = 60
    private static let healthyRunSeconds: TimeInterval = 30
    private var watchers: [[String]: Watcher] = [:]
    private lazy var log: FileHandle? = openLog()

    func sync(_ commands: [[String]]) {
        dispatchPrecondition(condition: .onQueue(.main))
        let wanted = Set(commands.filter { !$0.isEmpty })
        for (command, watcher) in watchers where !wanted.contains(command) {
            stop(watcher)
            watchers.removeValue(forKey: command)
        }
        for command in wanted where watchers[command] == nil {
            let watcher = Watcher(command: command)
            watchers[command] = watcher
            start(watcher)
        }
    }

    func stopAll() {
        dispatchPrecondition(condition: .onQueue(.main))
        for watcher in watchers.values { stop(watcher) }
        watchers.removeAll()
    }

    private func start(_ watcher: Watcher) {
        guard !watcher.stopped else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: watcher.command[0])
        process.arguments = Array(watcher.command.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        if let log = log {
            process.standardOutput = log
            process.standardError = log
        }
        process.terminationHandler = { [weak self, weak watcher] finished in
            DispatchQueue.main.async {
                guard let self = self, let watcher = watcher else { return }
                self.exited(watcher, status: finished.terminationStatus)
            }
        }
        do {
            try process.run()
            watcher.process = process
            watcher.startedAt = Date()
            write("started \(watcher.command.joined(separator: " ")) (pid \(process.processIdentifier))")
        } catch {
            write("failed to start \(watcher.command[0]): \(error.localizedDescription)")
            scheduleRestart(watcher)
        }
    }

    private func exited(_ watcher: Watcher, status: Int32) {
        watcher.process = nil
        guard !watcher.stopped else { return }
        write("exited \(watcher.command[0]) with status \(status)")
        if Date().timeIntervalSince(watcher.startedAt) > Self.healthyRunSeconds { watcher.backoff = 1 }
        scheduleRestart(watcher)
    }

    private func scheduleRestart(_ watcher: Watcher) {
        let delay = watcher.backoff
        watcher.backoff = min(Self.maximumBackoff, watcher.backoff * 2)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak watcher] in
            guard let self = self, let watcher = watcher, !watcher.stopped, watcher.process == nil else { return }
            self.start(watcher)
        }
    }

    private func stop(_ watcher: Watcher) {
        watcher.stopped = true
        if let process = watcher.process, process.isRunning {
            process.terminate()
            write("stopped \(watcher.command[0])")
        }
        watcher.process = nil
    }

    private func openLog() -> FileHandle? {
        let directory = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/touchbar-interface")
        let path = (directory as NSString).appendingPathComponent("watchers.log")
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: nil)
            // Keep the log small: start over once it passes 1 MB.
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64, size > 1_000_000 {
                try FileManager.default.removeItem(atPath: path)
            }
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            handle.seekToEndOfFile()
            return handle
        } catch {
            NSLog("MTMR watchers: log unavailable: %@", String(describing: error))
            return nil
        }
    }

    private func write(_ message: String) {
        NSLog("MTMR watchers: %@", message)
        let line = "\(ISO8601DateFormatter().string(from: Date())) supervisor: \(message)\n"
        log?.write(line.data(using: .utf8) ?? Data())
    }
}
