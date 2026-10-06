import Cocoa

extension CustomButtonTouchBarItem {
    func bindLiveState(_ definition: LiveButtonDefinition) {
        if liveLayoutDefaults == nil { liveLayoutDefaults = (image, backgroundColor, title) }
        guard let defaults = liveLayoutDefaults else { return }
        LiveButtonStore.shared.bind(definition: definition, view: view, image: defaults.image, background: defaults.background) { [weak self] image, tint, background, visible in
            guard let self = self else { return }
            self.liveVisible = visible
            self.image = image
            if self.backgroundColor != background { self.backgroundColor = background }
            if let button = self.view as? NSButton {
                button.contentTintColor = tint
                button.isEnabled = visible
                self.title = image === defaults.image ? defaults.title : ""
            }
        }
    }
}

extension GroupBarItem {
    func bindLiveState(_ definition: LiveButtonDefinition) {
        guard let button = view as? NSButton else {
            if let id = definition.id { NSLog("MTMR live group button has no NSButton view: %@", id) }
            return
        }
        // #COMPLETION_DRIVE: AppKit exposes the popover's collapsed representation as its NSButton view.
        // #SUGGEST_VERIFY: Check live icon/tint/visibility for an id-bearing group on hardware.
        if liveLayoutDefaults == nil { liveLayoutDefaults = (button.image, button.bezelColor, button.title) }
        guard let defaults = liveLayoutDefaults else { return }
        LiveButtonStore.shared.bind(definition: definition, view: button, image: defaults.image, background: defaults.background) { [weak self, weak button] image, tint, background, visible in
            self?.liveVisible = visible
            button?.image = image
            button?.contentTintColor = tint
            button?.bezelColor = background
            button?.isEnabled = visible
            button?.title = image === defaults.image ? defaults.title : ""
        }
    }
}
