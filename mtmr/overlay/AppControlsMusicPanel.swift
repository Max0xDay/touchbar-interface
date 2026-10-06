import Cocoa

/// macOS Now Playing through the private MediaRemote framework (works without entitlements on macOS 14).
/// Pear Desktop (the YouTube Music app) publishes title, artist, artwork and play state there like any player.
final class NowPlaying {
    struct State: Equatable {
        var title = ""
        var artist = ""
        var artworkKey = ""
        var playing = false
        var duration: Double = 0
        var elapsed: Double = 0
        var elapsedAt = Date()
        var rate: Double = 0

        /// 0...1 position in the track, extrapolated from the last reported elapsed time.
        var progress: Double {
            guard duration > 0 else { return 0 }
            let position = elapsed + (playing ? Date().timeIntervalSince(elapsedAt) * max(rate, 1) : 0)
            return min(1, max(0, position / duration))
        }
        var bundleId: String?
    }

    enum Command: UInt32 {
        case togglePlayPause = 2
        case next = 4
        case previous = 5

        // Media key fallback (NX_KEYTYPE_*), used only when MediaRemote is unavailable.
        var mediaKey: Int32 {
            switch self {
            case .togglePlayPause: return 16
            case .next: return 17
            case .previous: return 18
            }
        }
    }

    static let shared = NowPlaying()

    private typealias GetInfo = @convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void
    private typealias GetPlaying = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias GetClient = @convention(c) (DispatchQueue, @escaping (AnyObject?) -> Void) -> Void
    private typealias ClientBundleId = @convention(c) (AnyObject) -> Unmanaged<CFString>?
    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    private let getInfo: GetInfo?
    private let getPlaying: GetPlaying?
    private let getClient: GetClient?
    private let clientBundleId: ClientBundleId?
    private let sendCommand: SendCommand?
    private(set) var state = State()
    private(set) var artwork: NSImage?

    private init() {
        let url = NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        let bundle = CFBundleCreate(kCFAllocatorDefault, url)
        func load<T>(_ name: String, as _: T.Type) -> T? {
            guard let bundle = bundle, let pointer = CFBundleGetFunctionPointerForName(bundle, name as CFString) else {
                NSLog("MTMR now playing: %@ unavailable", name)
                return nil
            }
            return unsafeBitCast(pointer, to: T.self)
        }
        getInfo = load("MRMediaRemoteGetNowPlayingInfo", as: GetInfo.self)
        getPlaying = load("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: GetPlaying.self)
        getClient = load("MRMediaRemoteGetNowPlayingClient", as: GetClient.self)
        clientBundleId = load("MRNowPlayingClientGetBundleIdentifier", as: ClientBundleId.self)
        sendCommand = load("MRMediaRemoteSendCommand", as: SendCommand.self)
    }

    /// Reads the current state; `done` runs on the main queue.
    func refresh(_ done: @escaping (State) -> Void) {
        guard let getInfo = getInfo else {
            done(state)
            return
        }
        getInfo(DispatchQueue.main) { [weak self] info in
            guard let self = self else { return }
            var next = State()
            let info = info ?? [:]
            next.title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            next.artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            next.rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            next.playing = next.rate > 0
            next.duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
            next.elapsed = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
            next.elapsedAt = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date()
            if let data = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
                next.artworkKey = info["kMRMediaRemoteNowPlayingInfoArtworkIdentifier"] as? String ?? "\(data.count)-\(next.title)"
                if next.artworkKey != self.state.artworkKey { self.artwork = NSImage(data: data) }
            } else {
                self.artwork = nil
            }
            self.finish(next, done)
        }
    }

    private func finish(_ partial: State, _ done: @escaping (State) -> Void) {
        var next = partial
        let group = DispatchGroup()
        if let getPlaying = getPlaying {
            group.enter()
            getPlaying(DispatchQueue.main) { playing in
                next.playing = playing
                group.leave()
            }
        }
        if let getClient = getClient, let clientBundleId = clientBundleId {
            group.enter()
            getClient(DispatchQueue.main) { client in
                if let client = client { next.bundleId = clientBundleId(client)?.takeUnretainedValue() as String? }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.state = next
            done(next)
        }
    }

    func send(_ command: Command) {
        if let sendCommand = sendCommand, sendCommand(command.rawValue, nil) { return }
        HIDPostAuxKey(command.mediaKey)
    }
}

/// YouTube Music (Pear Desktop): cover, title, artist, previous / play-pause / next.
final class AppControlsMusicPanel: NSView, AppControlsPanel {
    static let id = "ytmusic"
    static let name = "YouTube Music"
    static let bundleId = "com.github.th-ch.youtube-music"
    static func icon() -> NSImage { return AppControlsApps.icon(bundleId) ?? AppControlsStyle.symbolImage("music.note", box: TouchBarIcon.appBox)! }
    let refreshInterval: TimeInterval = 1

    private static let controlWidth: CGFloat = 34
    private let cover = NSImageView()
    private let title = AppControlsStyle.label(size: 12, weight: .semibold)
    private let artist = AppControlsStyle.label(size: 10, color: AppControlsStyle.secondaryText)
    private let progress = AppControlsMeterView()
    private let openButton = NSButton(title: "", target: nil, action: nil)
    private var previous: NSButton!
    private var playPause: NSButton!
    private var next: NSButton!
    private var shownPlaying: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cover.imageScaling = .scaleProportionallyUpOrDown
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 4
        cover.layer?.masksToBounds = true
        cover.layer?.backgroundColor = AppControlsStyle.track.cgColor
        // Track position is not a warning: keep the meter neutral all the way.
        progress.warnAt = 2
        progress.badAt = 2
        openButton.isBordered = false
        openButton.target = self
        openButton.action = #selector(openApp)
        previous = AppControlsStyle.button(symbol: "backward.fill", target: self, action: #selector(previousTapped))
        playPause = AppControlsStyle.button(symbol: "play.fill", target: self, action: #selector(playPauseTapped))
        next = AppControlsStyle.button(symbol: "forward.fill", target: self, action: #selector(nextTapped))
        for view in [cover, title, artist, progress, openButton, previous!, playPause!, next!] as [NSView] { addSubview(view) }
        showPlaceholder("Nothing playing")
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        let controls = 3 * Self.controlWidth + 2 * 4
        let controlsX = bounds.width - controls
        for (index, button) in [previous!, playPause!, next!].enumerated() {
            button.frame = NSRect(x: controlsX + CGFloat(index) * (Self.controlWidth + 4), y: 0, width: Self.controlWidth, height: bounds.height)
        }
        cover.frame = NSRect(x: 0, y: 2, width: 26, height: 26)
        let textX = cover.frame.maxX + AppControlsStyle.gap
        let textWidth = max(0, controlsX - AppControlsStyle.gap - textX)
        title.frame = NSRect(x: textX, y: 15, width: textWidth, height: 16)
        artist.frame = NSRect(x: textX, y: 3, width: textWidth, height: 13)
        progress.frame = NSRect(x: textX + 2, y: 0, width: max(0, textWidth - 4), height: 2)
        openButton.frame = NSRect(x: 0, y: 0, width: textX + textWidth, height: bounds.height)
    }

    func refresh() {
        guard AppControlsApps.running(Self.bundleId) != nil else {
            showPlaceholder("Not running · tap to open")
            return
        }
        NowPlaying.shared.refresh { [weak self] state in
            self?.show(state)
        }
    }

    private func show(_ state: NowPlaying.State) {
        guard !state.title.isEmpty else {
            showPlaceholder("Nothing playing")
            return
        }
        title.stringValue = state.title
        artist.stringValue = state.artist
        cover.image = NowPlaying.shared.artwork ?? AppControlsStyle.symbolImage("music.note", box: 14)
        setControlsEnabled(true)
        setPlaying(state.playing)
        progress.isHidden = state.duration <= 0
        progress.fraction = state.progress
    }

    private func showPlaceholder(_ detail: String) {
        title.stringValue = Self.name
        artist.stringValue = detail
        cover.image = Self.icon()
        progress.isHidden = true
        setControlsEnabled(AppControlsApps.running(Self.bundleId) != nil)
        setPlaying(false)
    }

    private func setControlsEnabled(_ enabled: Bool) {
        for button in [previous!, playPause!, next!] { button.isEnabled = enabled }
    }

    private func setPlaying(_ playing: Bool) {
        guard playing != shownPlaying else { return }
        shownPlaying = playing
        playPause.image = AppControlsStyle.symbolImage(playing ? "pause.fill" : "play.fill")
    }

    private func perform(_ command: NowPlaying.Command) {
        NowPlaying.shared.send(command)
        if command == .togglePlayPause { setPlaying(!(shownPlaying ?? false)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.refresh() }
    }

    @objc private func previousTapped() { perform(.previous) }
    @objc private func playPauseTapped() { perform(.togglePlayPause) }
    @objc private func nextTapped() { perform(.next) }
    @objc private func openApp() { AppControlsApps.open(Self.bundleId) }
}
