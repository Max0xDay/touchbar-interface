import Cocoa

final class NotificationStore {
    static let shared = NotificationStore()
    static let changed = Notification.Name("MTMRNotificationChanged")

    private struct Entry {
        let text: String
        var remainingSeconds: Double
    }

    private var entries: [Entry] = []
    private var selectedIndex = 0
    private var timer: Timer?
    private var startedAt: Double?
    private var paused = false
    var defaultSeconds: Double = 8

    var text: String {
        return entries.isEmpty ? "" : entries[selectedIndex].text
    }

    func notify(text: String, seconds: Double?) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard entries.count < 256 else { return false }
        entries.append(Entry(text: text, remainingSeconds: seconds ?? defaultSeconds))
        if entries.count == 1 {
            selectedIndex = 0
            scheduleExpiry()
            publish()
        }
        return true
    }

    func clear() {
        dispatchPrecondition(condition: .onQueue(.main))
        timer?.invalidate()
        timer = nil
        startedAt = nil
        entries.removeAll()
        selectedIndex = 0
        publish()
    }

    func pause() {
        dispatchPrecondition(condition: .onQueue(.main))
        paused = true
        if let startedAt = startedAt, !entries.isEmpty {
            entries[selectedIndex].remainingSeconds = max(0, entries[selectedIndex].remainingSeconds - (ProcessInfo.processInfo.systemUptime - startedAt))
        }
        timer?.invalidate()
        timer = nil
        startedAt = nil
    }

    func move(by offset: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !entries.isEmpty else { return }
        // Endless swipe: wraps around the queue in both directions.
        selectedIndex = ((selectedIndex + offset) % entries.count + entries.count) % entries.count
        publish()
    }

    func resume() {
        dispatchPrecondition(condition: .onQueue(.main))
        paused = false
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        guard !paused else { return }
        guard !entries.isEmpty else { return }
        startedAt = ProcessInfo.processInfo.systemUptime
        let expiryTimer = Timer(timeInterval: max(0.001, entries[selectedIndex].remainingSeconds), repeats: false) { [weak self] _ in
            self?.expire()
        }
        timer = expiryTimer
        RunLoop.main.add(expiryTimer, forMode: .common)
    }

    private func expire() {
        guard !entries.isEmpty else { return }
        entries.remove(at: selectedIndex)
        selectedIndex = min(selectedIndex, max(0, entries.count - 1))
        scheduleExpiry()
        publish()
    }

    private func publish() {
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

final class NotificationTouchBarItem: NSCustomTouchBarItem {
    let layoutOptions: NotificationLayoutOptions
    private var observer: NSObjectProtocol?

    init(identifier: NSTouchBarItem.Identifier, maxChars: Int, defaultSeconds: Double, layoutOptions: NotificationLayoutOptions? = nil) {
        self.layoutOptions = layoutOptions ?? NotificationLayoutOptions(maxChars: maxChars)
        super.init(identifier: identifier)
        NotificationStore.shared.defaultSeconds = defaultSeconds
        let notificationView = NotificationAreaView(maxChars: maxChars, fadeSeconds: self.layoutOptions.fadeSeconds)
        view = notificationView
        notificationView.show(text: NotificationStore.shared.text)
        observer = NotificationCenter.default.addObserver(forName: NotificationStore.changed, object: nil, queue: .main) { [weak notificationView] _ in
            notificationView?.show(text: NotificationStore.shared.text)
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
