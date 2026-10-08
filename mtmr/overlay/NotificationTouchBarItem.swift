import Cocoa

/// The notification queue. The newest entry shows on arrival; every entry counts down on its own, so a long
/// entry (e.g. a 10-minute Outlook reminder) never holds back newer ones. Swipes move through all live entries
/// (oldest → newest, wrapping). Touching the area pauses every countdown.
final class NotificationStore {
    static let shared = NotificationStore()
    static let changed = Notification.Name("MTMRNotificationChanged")

    private struct Entry {
        let text: String
        let icon: NSImage?
        /// Optional heading: the entry then shows as two lines (heading, then `text` smaller below).
        let title: String?
        /// systemUptime at which the entry expires (moved later by pauses).
        var deadline: Double
    }

    private var entries: [Entry] = []
    private var selectedIndex = 0
    private var timer: Timer?
    private var pausedAt: Double?
    var defaultSeconds: Double = 8
    var welcome: String?

    var text: String {
        return entries.isEmpty ? "" : entries[selectedIndex].text
    }

    var icon: NSImage? {
        return entries.isEmpty ? nil : entries[selectedIndex].icon
    }

    var title: String? {
        return entries.isEmpty ? nil : entries[selectedIndex].title
    }

    /// Number of live entries (the area shows a small dot when there is more than one).
    var count: Int {
        return entries.count
    }

    private var now: Double { return ProcessInfo.processInfo.systemUptime }

    func notify(text: String, seconds: Double?, icon: NSImage? = nil, title: String? = nil) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard entries.count < 256 else { return false }
        // While paused, the countdown starts from the pause moment so resume() shifts it like the others.
        let heading = title.flatMap { $0.isEmpty ? nil : $0 }
        entries.append(Entry(text: text, icon: icon, title: heading, deadline: (pausedAt ?? now) + (seconds ?? defaultSeconds)))
        selectedIndex = entries.count - 1
        scheduleExpiry()
        publish()
        return true
    }

    /// Posts the layout's welcome text unless it is already queued.
    func postWelcome() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let welcome = welcome, !welcome.isEmpty else { return }
        guard !entries.contains(where: { $0.text == welcome }) else { return }
        _ = notify(text: welcome, seconds: nil)
    }

    func clear() {
        dispatchPrecondition(condition: .onQueue(.main))
        timer?.invalidate()
        timer = nil
        entries.removeAll()
        selectedIndex = 0
        publish()
    }

    func pause() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard pausedAt == nil else { return }
        pausedAt = now
        timer?.invalidate()
        timer = nil
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
        guard let pausedAt = pausedAt else { return }
        let pausedFor = now - pausedAt
        self.pausedAt = nil
        for index in entries.indices { entries[index].deadline += pausedFor }
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        timer?.invalidate()
        timer = nil
        guard pausedAt == nil else { return }
        guard let next = entries.map({ $0.deadline }).min() else { return }
        let expiryTimer = Timer(timeInterval: max(0.001, next - now), repeats: false) { [weak self] _ in
            self?.expire()
        }
        timer = expiryTimer
        RunLoop.main.add(expiryTimer, forMode: .common)
    }

    private func expire() {
        guard !entries.isEmpty else { return }
        let current = now
        let selectedSurvives = entries[selectedIndex].deadline > current
        let selectedBefore = entries[..<selectedIndex].filter { $0.deadline > current }.count
        entries.removeAll { $0.deadline <= current }
        // Keep showing the same entry if it is still live; otherwise show the newest remaining one.
        selectedIndex = selectedSurvives ? selectedBefore : max(0, entries.count - 1)
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
        NotificationStore.shared.welcome = self.layoutOptions.welcome
        let notificationView = NotificationAreaView(maxChars: maxChars, fadeSeconds: self.layoutOptions.fadeSeconds)
        view = notificationView
        notificationView.show(text: NotificationStore.shared.text, icon: NotificationStore.shared.icon, title: NotificationStore.shared.title)
        notificationView.showMore(NotificationStore.shared.count > 1)
        observer = NotificationCenter.default.addObserver(forName: NotificationStore.changed, object: nil, queue: .main) { [weak notificationView] _ in
            notificationView?.show(text: NotificationStore.shared.text, icon: NotificationStore.shared.icon, title: NotificationStore.shared.title)
            notificationView?.showMore(NotificationStore.shared.count > 1)
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
