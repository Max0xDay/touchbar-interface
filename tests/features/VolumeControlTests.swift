import Cocoa

// Presentation and private brightness calls must never run in this hardware-free harness.
final class TouchBarController: NSObject {
    static let shared = TouchBarController()
    var touchBar: NSTouchBar! = NSTouchBar()
}

extension NSTouchBarItem.Identifier {
    static let controlStripItem = NSTouchBarItem.Identifier("test.controlStrip")
}

func presentSystemModal(_ touchBar: NSTouchBar!, placement: Int64, systemTrayItemIdentifier: NSTouchBarItem.Identifier!) {
    preconditionFailure("Tests must not present a hardware Touch Bar")
}

@main
struct VolumeControlTests {
    static func main() {
        checkClamping()
        checkVolumeState()
        checkPressTiming()
        checkSliderInteraction()
        checkSliderWrites()
        checkSystemSliderPage()
        checkScheduledFinalWrite()
        print("Universal control system sliders, clamping, press timing and volume state checks passed")
    }

    private static func checkSystemSliderPage() {
        _ = NSApplication.shared
        let page = UniversalControlPage()
        let bar = NSTouchBar()
        precondition(page.mediaItem.view.intrinsicContentSize == NSSize(width: 30, height: 30))
        for item in [page.brightnessItem, page.volumeItem] {
            precondition(type(of: item) == NSSliderTouchBarItem.self)
            precondition(type(of: item.slider) == NSSlider.self, "Use the system slider, not a custom control")
            precondition(item.label == nil)
            precondition(item.slider.minValue == 0)
            precondition(item.slider.maxValue == 1)
            precondition(item.slider.isContinuous)
            precondition(item.minimumValueAccessory != nil)
            precondition(item.maximumValueAccessory != nil)
            precondition(item.valueAccessoryWidth == .default)
            precondition(item.target === page)
            precondition(item.action != nil)
            precondition(page.touchBar(bar, makeItemForIdentifier: item.identifier) === item)
        }
        precondition(page.touchBar(bar, makeItemForIdentifier: page.mediaItem.identifier) === page.mediaItem)
        precondition(page.touchBar(bar, makeItemForIdentifier: .init("unknown")) == nil)
        let brightnessWidth = page.brightnessItem.view.constraints.first(where: { $0.firstAttribute == .width })
        let volumeWidth = page.volumeItem.view.constraints.first(where: { $0.firstAttribute == .width })
        precondition(brightnessWidth?.constant == 200)
        precondition(brightnessWidth?.priority == .required)
        precondition(volumeWidth?.constant == brightnessWidth?.constant)
        precondition(volumeWidth?.priority == .required)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1004, height: 30))
        var leading = host.leadingAnchor
        for item in [page.brightnessItem, page.volumeItem] {
            let container = item.view
            precondition(item.slider.isDescendant(of: container), "Constrain the actual slider/accessory container")
            host.addSubview(container)
            container.leadingAnchor.constraint(equalTo: leading).isActive = true
            container.topAnchor.constraint(equalTo: host.topAnchor).isActive = true
            container.heightAnchor.constraint(equalToConstant: 30).isActive = true
            leading = container.trailingAnchor
        }
        host.layoutSubtreeIfNeeded()
        for item in [page.brightnessItem, page.volumeItem] {
            precondition(abs(item.view.frame.width - 200) < 0.01)
            precondition(item.slider.frame.width <= 200)
        }
    }

    private static func checkSliderInteraction() {
        var brightness = UniversalSliderState()
        var volume = UniversalSliderState()
        precondition(!brightness.ignoresRefresh(at: 0))
        brightness.setTouching(true)
        precondition(brightness.ignoresRefresh(at: 10), "A stationary finger still owns the slider")
        precondition(!volume.ignoresRefresh(at: 10), "The other slider must remain independent")
        brightness.queue(0.7, at: 10)
        brightness.setTouching(false)
        precondition(brightness.ignoresRefresh(at: 10.599))
        precondition(!brightness.ignoresRefresh(at: 10.601))
        volume.queue(0.2, at: 11)
        precondition(!brightness.ignoresRefresh(at: 11))
        precondition(volume.ignoresRefresh(at: 11.3))
        volume.queue(0.8, at: 11.5)
        precondition(volume.ignoresRefresh(at: 12.099), "Each action extends the quiet period")
        precondition(!volume.ignoresRefresh(at: 12.101))
    }

    private static func checkSliderWrites() {
        var slider = UniversalSliderState()
        precondition(slider.nextWriteDelay(at: 0) == nil)
        slider.queue(0.1, at: 0)
        precondition(slider.takeWrite(at: 0) == 0.1, "The first change must be immediate")
        slider.setTouching(true)
        for index in 1...15 {
            let time = Double(index) / 1000
            slider.queue(Double(index) / 20, at: time)
            precondition(slider.takeWrite(at: time) == nil, "Never write faster than 60 Hz")
        }
        slider.setTouching(false)
        precondition(slider.takeWrite(at: 0.016) == nil, "Release must preserve the rate limit")
        precondition(slider.nextWriteDelay(at: 0.016)! > 0)
        precondition(slider.takeWrite(at: 1.0 / 60) == 0.75, "Apply the final queued value after release")
        precondition(slider.nextWriteDelay(at: 1) == nil, "Do not repeat a completed write")
        slider.queue(2, at: 1)
        precondition(slider.takeWrite(at: 1) == 1)
        slider.queue(-1, at: 2)
        precondition(slider.takeWrite(at: 2) == 0)
    }

    private static func checkScheduledFinalWrite() {
        let item = NSSliderTouchBarItem(identifier: .init("test.coalescing"))
        item.slider.minValue = 0
        item.slider.maxValue = 1
        var writes: [(time: TimeInterval, value: Double)] = []
        var finished = false
        var interaction: UniversalSliderInteraction? = UniversalSliderInteraction(item: item) {
            writes.append((ProcessInfo.processInfo.systemUptime, $0))
        }
        item.slider.doubleValue = 0.1
        interaction?.change()
        precondition(writes.map(\.value) == [0.1])
        for value in [0.3, 0.5, 0.9] {
            item.slider.doubleValue = value
            interaction?.change()
        }
        interaction?.finish { finished = true }
        interaction = nil
        let deadline = Date(timeIntervalSinceNow: 1)
        while !finished {
            precondition(Date() < deadline, "The final write must outlive its page and finish promptly")
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        precondition(writes.last?.value == 0.9)
        for index in 1..<writes.count {
            precondition(writes[index].time - writes[index - 1].time >= UniversalSliderState.writeInterval - 0.0001)
        }
    }

    private static func checkVolumeState() {
        let unavailable = OutputVolumeController.State()
        precondition(unavailable.volume == nil)
        precondition(!unavailable.canSetVolume)
        precondition(!unavailable.canSetMute)
        precondition(unavailable.symbol == "speaker.wave.2.fill", "Unknown volume is not zero")
        precondition(OutputVolumeController.State(volume: 0).symbol == "speaker.slash.fill")
        precondition(OutputVolumeController.State(volume: 0.6, muted: true).symbol == "speaker.slash.fill")
        precondition(OutputVolumeController.State(volume: 0.6).symbol == "speaker.wave.2.fill")
    }

    private static func checkClamping() {
        for level in [0.0, 0.25, 0.5, 1] {
            precondition(VolumeControlGeometry.clamped(level) == level)
        }
        precondition(VolumeControlGeometry.clamped(-1) == 0)
        precondition(VolumeControlGeometry.clamped(2) == 1)
        precondition(VolumeControlGeometry.clamped(.nan) == 0)
        precondition(VolumeControlGeometry.clamped(.infinity) == 0)
        precondition(VolumeControlGeometry.clamped(-.infinity) == 0)
    }

    private static func checkPressTiming() {
        var press = UniversalControlPress()
        precondition(press.end(at: 0) == nil)
        press.begin(at: 10)
        precondition(!press.hold(at: 10.499))
        precondition(press.end(at: 10.499) == .open)
        press.begin(at: 20)
        precondition(press.hold(at: 20.5))
        precondition(!press.hold(at: 21), "A held press must exit only once")
        precondition(press.end(at: 21) == nil, "Release after exiting must not open the page")
        press.begin(at: 30)
        precondition(press.end(at: 30.5) == .exit, "Threshold applies even if the timer is delayed")
        press.begin(at: 40)
        press.cancel()
        precondition(!press.hold(at: 41))
        precondition(press.end(at: 41) == nil)
    }
}
