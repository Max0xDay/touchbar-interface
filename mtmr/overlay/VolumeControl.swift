import Cocoa

final class VolumeTouchBarItem: NSCustomTouchBarItem {
    override init(identifier: NSTouchBarItem.Identifier) {
        super.init(identifier: identifier)
        view = VolumeButton(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
    }

    required init?(coder: NSCoder) { return nil }
}

final class VolumeButton: NSButton {
    private var page: UniversalControlPage?
    var tapped: (() -> Void)?
    var detached: (() -> Void)?
    private var press = UniversalControlPress()
    private var holdTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        bezelStyle = .rounded
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        image = TouchBarIcon.symbol("slider.horizontal.3", tint: .white)
        allowedTouchTypes = .direct
        target = self
        action = #selector(openSlider)
        setAccessibilityLabel("Brightness and volume")
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) { return nil }
    deinit {
        holdTimer?.invalidate()
        page?.close(returnToMain: false)
    }
    override var intrinsicContentSize: NSSize { return NSSize(width: 30, height: 30) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelPress()
            detached?()
        }
    }

    @objc private func openSlider() {
        if let tapped = tapped {
            tapped()
            return
        }
        guard page == nil else { return }
        let controls = UniversalControlPage()
        controls.didClose = { [weak self] in self?.page = nil }
        page = controls
        controls.show()
    }

    private func exitTouchBar() {
        // Invoke the same private @objc entry point as upstream's exitTouchbar item, without patching upstream.
        TouchBarController.shared.perform(NSSelectorFromString("dismissTouchBar"))
    }

    private func beginPress() {
        cancelPress()
        press.begin(at: ProcessInfo.processInfo.systemUptime)
        highlight(true)
        let timer = Timer(timeInterval: UniversalControlPress.holdSeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard self.tapped == nil else { return }
            if self.press.hold(at: ProcessInfo.processInfo.systemUptime) { self.exitTouchBar() }
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        press.cancel()
        highlight(false)
    }

    private func endPress(at point: NSPoint) {
        guard bounds.contains(point) else {
            cancelPress()
            return
        }
        let action = press.end(at: ProcessInfo.processInfo.systemUptime)
        cancelPress()
        guard let action = action else { return }
        if tapped != nil {
            openSlider()
            return
        }
        switch action {
        case .open: openSlider()
        case .exit: exitTouchBar()
        }
    }

    // #COMPLETION_DRIVE: Direct touches reach the button.
    // #SUGGEST_VERIFY: Check short tap, 0.5 s hold, release after exit, and cancelled/dragged-out touches on hardware.
    override func touchesBegan(with event: NSEvent) {
        guard event.touches(matching: .began, in: self).contains(where: { $0.type == .direct }) else { return }
        beginPress()
    }

    override func touchesMoved(with event: NSEvent) {
        guard let point = touchLocation(event, phase: .moved) else { return }
        if !bounds.contains(point) { cancelPress() }
    }

    override func touchesEnded(with event: NSEvent) {
        guard let point = touchLocation(event, phase: .ended) else {
            cancelPress()
            return
        }
        endPress(at: point)
    }

    override func touchesCancelled(with event: NSEvent) { cancelPress() }

    private func touchLocation(_ event: NSEvent, phase: NSTouch.Phase) -> NSPoint? {
        return event.touches(matching: phase, in: self).first(where: { $0.type == .direct })?.location(in: self)
    }

    override func mouseDown(with event: NSEvent) { beginPress() }
    override func mouseDragged(with event: NSEvent) {
        if !bounds.contains(convert(event.locationInWindow, from: nil)) { cancelPress() }
    }
    override func mouseUp(with event: NSEvent) { endPress(at: convert(event.locationInWindow, from: nil)) }
}

/// Keeps native slider tracking intact; writes and external refreshes have independent ownership.
final class UniversalSliderInteraction {
    private let item: NSSliderTouchBarItem
    private let writeValue: (Double) -> Void
    private var state = UniversalSliderState()
    private var touches: [NSTouch] = []
    private var writeTimer: Timer?
    private var didFinish: (() -> Void)?

    init(item: NSSliderTouchBarItem, writeValue: @escaping (Double) -> Void) {
        self.item = item
        self.writeValue = writeValue
    }

    var ignoresRefresh: Bool {
        return state.ignoresRefresh(at: ProcessInfo.processInfo.systemUptime)
    }

    func change() {
        state.queue(item.slider.doubleValue, at: ProcessInfo.processInfo.systemUptime)
        applyPending()
    }

    func updateTouches(_ event: NSEvent) {
        for touch in event.touches(matching: .began, in: nil) where touch.type == .direct {
            if item.view.bounds.contains(touch.location(in: item.view)) { touches.append(touch) }
        }
        let activeTouches = event.touches(matching: .touching, in: nil)
        touches.removeAll { previous in
            !activeTouches.contains(where: { $0.identity.isEqual(previous.identity) })
        }
        state.setTouching(!touches.isEmpty)
        if touches.isEmpty { applyPending() }
    }

    func finish(afterWriting completion: @escaping () -> Void) {
        touches = []
        state.setTouching(false)
        didFinish = completion
        applyPending()
    }

    private func applyPending() {
        writeTimer?.invalidate()
        writeTimer = nil
        let time = ProcessInfo.processInfo.systemUptime
        if let value = state.takeWrite(at: time) { writeValue(value) }
        guard let delay = state.nextWriteDelay(at: time) else {
            let completion = didFinish
            didFinish = nil
            completion?()
            return
        }
        // Retain until the one-shot fires so closing the page cannot drop its final pending write.
        let timer = Timer(timeInterval: delay, repeats: false) { _ in self.applyPending() }
        writeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// Uses the same modal-bar item replacement as GroupBarItem, preserving the main page for return.
final class UniversalControlPage: NSObject, NSTouchBarDelegate {
    let mediaItem = VolumeTouchBarItem(identifier: NSTouchBarItem.Identifier("MTMR.controls.media"))
    let brightnessItem = NSSliderTouchBarItem(identifier: NSTouchBarItem.Identifier("MTMR.controls.brightness"))
    let volumeItem = NSSliderTouchBarItem(identifier: NSTouchBarItem.Identifier("MTMR.controls.volume"))
    var didClose: (() -> Void)?
    private let brightnessController = DisplayBrightnessController()
    private let volumeController = OutputVolumeController()
    private lazy var brightnessInteraction = UniversalSliderInteraction(item: brightnessItem) { [brightnessController] in
        brightnessController.setBrightness($0)
    }
    private lazy var volumeInteraction = UniversalSliderInteraction(item: volumeItem) { [volumeController] in
        volumeController.setVolume($0)
    }
    private var modalBar: NSTouchBar?
    private weak var mainDelegate: NSTouchBarDelegate?
    private var mainIdentifiers: [NSTouchBarItem.Identifier] = []
    private var idleTimer: Timer?
    private var visibilityTimer: Timer?
    private var touchMonitor: Any?
    private var touching = false
    private var showing = false

    override init() {
        super.init()
        configureSlider(brightnessItem, low: "sun.min.fill", high: "sun.max.fill", action: #selector(changeBrightness))
        configureSlider(volumeItem, low: "speaker.fill", high: "speaker.wave.3.fill", action: #selector(changeVolume))
        mediaItem.view.widthAnchor.constraint(equalToConstant: 30).isActive = true
        if let button = mediaItem.view as? VolumeButton {
            button.tapped = { [weak self] in self?.close() }
            button.detached = { [weak self] in self?.close(returnToMain: false) }
        }
        brightnessController.changed = { [weak self] in self?.refreshBrightness() }
        volumeController.changed = { [weak self] in self?.refreshVolume() }
    }

    private func configureSlider(_ item: NSSliderTouchBarItem, low: String, high: String, action: Selector) {
        item.label = nil
        item.slider.minValue = 0
        item.slider.maxValue = 1
        item.slider.isContinuous = true
        item.valueAccessoryWidth = .default
        item.minimumValueAccessory = accessory(low)
        item.maximumValueAccessory = accessory(high)
        item.target = self
        item.action = action
        // item.view is AppKit's container for both accessories and the slider, not the slider itself.
        item.view.translatesAutoresizingMaskIntoConstraints = false
        item.view.widthAnchor.constraint(equalToConstant: 200).isActive = true
        item.slider.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
    }

    private func accessory(_ symbol: String) -> NSSliderAccessory? {
        guard let image = TouchBarIcon.symbol(symbol, tint: .white) else {
            NSLog("MTMR controls: missing slider accessory symbol %@", symbol)
            return nil
        }
        return NSSliderAccessory(image: image)
    }

    func show() {
        guard !showing else { return }
        guard let bar = TouchBarController.shared.touchBar else {
            NSLog("MTMR controls: no main Touch Bar available")
            didClose?()
            return
        }
        modalBar = bar
        mainDelegate = bar.delegate
        mainIdentifiers = bar.defaultItemIdentifiers
        brightnessController.start()
        volumeController.start()
        bar.delegate = self
        bar.defaultItemIdentifiers = []
        bar.defaultItemIdentifiers = [mediaItem.identifier, brightnessItem.identifier, volumeItem.identifier, .flexibleSpace]
        presentSystemModal(bar, placement: 1, systemTrayItemIdentifier: .controlStripItem)
        showing = true
        monitorTouches()
        resetIdleTimer()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkVisibility() }
        visibilityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func close(returnToMain: Bool = true) {
        guard showing else { return }
        showing = false
        stopMonitoring()
        if let bar = modalBar, bar.delegate === self {
            bar.defaultItemIdentifiers = []
            bar.delegate = mainDelegate
            bar.defaultItemIdentifiers = mainIdentifiers
            if returnToMain, TouchBarController.shared.touchBar === bar {
                presentSystemModal(bar, placement: 1, systemTrayItemIdentifier: .controlStripItem)
            }
        }
        modalBar = nil
        didClose?()
    }

    private func stopMonitoring() {
        idleTimer?.invalidate()
        visibilityTimer?.invalidate()
        brightnessInteraction.finish { [brightnessController] in brightnessController.stop() }
        volumeInteraction.finish { [volumeController] in volumeController.stop() }
        if let monitor = touchMonitor { NSEvent.removeMonitor(monitor) }
        touchMonitor = nil
    }

    // #COMPLETION_DRIVE: The modal host reports visibility and direct touches.
    // #SUGGEST_VERIFY: Dismiss/recreate the bar; hold a stationary slider touch for more than 6 s.
    private func checkVisibility() {
        guard TouchBarController.shared.touchBar === modalBar else {
            close(returnToMain: false)
            return
        }
        guard modalBar?.delegate === self else {
            close(returnToMain: false)
            return
        }
        if mediaItem.view.window?.isVisible != true { close(returnToMain: false) }
    }

    // #COMPLETION_DRIVE: Slider touches share the modal window touch stream.
    // #SUGGEST_VERIFY: Hold and drag each slider beyond its bounds on hardware.
    private func monitorTouches() {
        touchMonitor = NSEvent.addLocalMonitorForEvents(matching: .directTouch) { [weak self] event in
            guard let self = self, let window = self.mediaItem.view.window else { return event }
            guard event.window === window else { return event }
            self.brightnessInteraction.updateTouches(event)
            self.volumeInteraction.updateTouches(event)
            self.touching = event.touches(matching: .touching, in: nil).contains(where: { $0.type == .direct })
            self.resetIdleTimer()
            return event
        }
    }

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 6, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.touching { self.resetIdleTimer() } else { self.close() }
        }
        idleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshBrightness() {
        guard !brightnessInteraction.ignoresRefresh else { return }
        brightnessItem.slider.doubleValue = brightnessController.brightness ?? 0
        brightnessItem.slider.isEnabled = brightnessController.brightness != nil
    }

    private func refreshVolume() {
        guard !volumeInteraction.ignoresRefresh else { return }
        volumeItem.slider.doubleValue = volumeController.state.volume ?? 0
        volumeItem.slider.isEnabled = volumeController.state.canSetVolume
    }

    @objc private func changeBrightness() {
        resetIdleTimer()
        brightnessInteraction.change()
    }

    @objc private func changeVolume() {
        resetIdleTimer()
        volumeInteraction.change()
    }

    func touchBar(_: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        return [mediaItem, brightnessItem, volumeItem].first(where: { $0.identifier == identifier })
    }

    deinit { stopMonitoring() }
}
