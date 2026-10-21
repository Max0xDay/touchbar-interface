import Cocoa

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
