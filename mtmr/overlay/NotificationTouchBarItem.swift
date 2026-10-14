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
        /// Separate visible countdown; nil while the entry is hidden but still live.
        var displayDeadline: Double?
    }

    private let displaySeconds: Double = 8
    private var entries: [Entry] = []
    private var selectedIndex = 0
    private var timer: Timer?
    private var pausedAt: Double?
    var defaultSeconds: Double = 8
    var welcome: String?

    private var visibleEntry: Entry? {
        guard !entries.isEmpty else { return nil }
        let entry = entries[selectedIndex]
        guard entry.displayDeadline != nil else { return nil }
        return entry
    }

    var text: String { return visibleEntry?.text ?? "" }
    var icon: NSImage? { return visibleEntry?.icon }
    var title: String? { return visibleEntry?.title }
    var isShowing: Bool { return visibleEntry != nil }

    /// Live entries remain to be recalled while the notification area is empty.
    var hasUnread: Bool {
        guard !isShowing else { return false }
        return !entries.isEmpty
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
        entries.append(Entry(text: text, icon: icon, title: heading, deadline: (pausedAt ?? now) + (seconds ?? defaultSeconds), displayDeadline: nil))
        showEntry(at: entries.count - 1)
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
        let nextIndex = ((selectedIndex + offset) % entries.count + entries.count) % entries.count
        showEntry(at: nextIndex)
    }

    func showNewestHidden() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard hasUnread else { return }
        showEntry(at: entries.count - 1)
    }

    private func showEntry(at index: Int) {
        entries[selectedIndex].displayDeadline = nil
        selectedIndex = index
        entries[index].displayDeadline = min(entries[index].deadline, (pausedAt ?? now) + displaySeconds)
        scheduleExpiry()
        publish()
    }

    func resume() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let pausedAt = pausedAt else { return }
        let pausedFor = now - pausedAt
        self.pausedAt = nil
        for index in entries.indices {
            entries[index].deadline += pausedFor
            if let displayDeadline = entries[index].displayDeadline {
                entries[index].displayDeadline = displayDeadline + pausedFor
            }
        }
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        timer?.invalidate()
        timer = nil
        guard pausedAt == nil else { return }
        guard var next = entries.map({ $0.deadline }).min() else { return }
        if let displayDeadline = entries[selectedIndex].displayDeadline {
            next = min(next, displayDeadline)
        }
        let expiryTimer = Timer(timeInterval: max(0.001, next - now), repeats: false) { [weak self] _ in
            self?.expire()
        }
        timer = expiryTimer
        RunLoop.main.add(expiryTimer, forMode: .common)
    }

    private func expire() {
        guard !entries.isEmpty else { return }
        let current = now
        if let displayDeadline = entries[selectedIndex].displayDeadline {
            if displayDeadline <= current { entries[selectedIndex].displayDeadline = nil }
        }
        let selectedSurvives = entries[selectedIndex].deadline > current
        let selectedBefore = entries[..<selectedIndex].filter { $0.deadline > current }.count
        entries.removeAll { $0.deadline <= current }
        // Keep showing the same entry if it is still live; otherwise show the newest remaining one.
        // #COMPLETION_DRIVE: Expiry leaves the area empty; another live entry appears only on tap, swipe or arrival.
        // #SUGGEST_VERIFY: Confirm this replaces automatic advancement when the shown entry's life ends.
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
        notificationView.showNotification()
        observer = NotificationCenter.default.addObserver(forName: NotificationStore.changed, object: nil, queue: .main) { [weak notificationView] _ in
            notificationView?.showNotification()
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
