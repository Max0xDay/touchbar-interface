import Foundation

struct TeamsPanelOptions: Decodable, Equatable {
    let directory: String?
    init(directory: String? = nil) { self.directory = directory }

    private enum CodingKeys: String, CodingKey { case directory }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        directory = try fields.decodeIfPresent(String.self, forKey: .directory)
        if let directory = directory {
            guard directory.hasPrefix("/") else {
                throw DecodingError.dataCorruptedError(forKey: .directory, in: fields, debugDescription: "Teams directory must be absolute")
            }
            for script in ["teams-mic-tap", "teams-camera-tap"] {
                guard FileManager.default.isExecutableFile(atPath: directory + "/" + script) else {
                    throw DecodingError.dataCorruptedError(forKey: .directory, in: fields, debugDescription: "Teams tap is not executable: \(script)")
                }
            }
        }
    }
}

struct TeamsSnapshot: Decodable {
    enum DeviceState: String, Decodable {
        case on, muted, off, unknown
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = DeviceState(rawValue: value) ?? .unknown
        }
    }
    let online: Bool
    let inCall: Bool
    let focused: Bool
    let title: String
    let microphone: DeviceState
    let camera: DeviceState
    let joinedAt: Double?
    let durationText: String?

    private enum CodingKeys: String, CodingKey { case online, inCall, focused, title, mic, camera, joinedAt, durationText }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        online = try fields.decodeIfPresent(Bool.self, forKey: .online) ?? true
        inCall = try fields.decode(Bool.self, forKey: .inCall)
        focused = try fields.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        title = try fields.decodeIfPresent(String.self, forKey: .title) ?? ""
        let microphoneState = try fields.decodeIfPresent(DeviceState.self, forKey: .mic) ?? .unknown
        microphone = [.on, .muted].contains(microphoneState) ? microphoneState : .unknown
        let cameraState = try fields.decodeIfPresent(DeviceState.self, forKey: .camera) ?? .unknown
        camera = [.on, .off].contains(cameraState) ? cameraState : .unknown
        joinedAt = try fields.decodeIfPresent(Double.self, forKey: .joinedAt)
        durationText = try fields.decodeIfPresent(String.self, forKey: .durationText)
    }

    var active: Bool { return online && inCall }
    var focusRequestsSelection: Bool { return active && focused }
}

struct TeamsClock {
    private var origin: Double?
    private var joinedAt: Double?
    private var durationText: String?

    mutating func receive(_ snapshot: TeamsSnapshot, at now: Double) {
        guard snapshot.active else { origin = nil; joinedAt = nil; durationText = nil; return }
        if origin == nil || snapshot.joinedAt != joinedAt {
            origin = snapshot.joinedAt ?? now
        }
        if snapshot.durationText != durationText {
            if let duration = snapshot.durationText.flatMap(Self.duration) {
                origin = now - duration
            } else if let joinedAt = snapshot.joinedAt {
                origin = joinedAt
            }
        }
        joinedAt = snapshot.joinedAt
        durationText = snapshot.durationText
    }

    func text(at now: Double) -> String { return Self.format(max(0, now - (origin ?? now))) }

    static func duration(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        guard parts.allSatisfy({ $0.range(of: "^[0-9]+$", options: .regularExpression) != nil }) else { return nil }
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count else { return nil }
        guard let seconds = values.last, seconds < 60 else { return nil }
        if values.count == 3 { guard values[1] < 60 else { return nil } }
        let duration = values.reduce(0) { $0 * 60 + $1 }
        return duration.isFinite ? duration : nil
    }

    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        guard seconds < Double(Int.max) else { return "--:--" }
        let total = Int(max(0, seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Name on top, timer below, both left-aligned and truncating in the text column left of the two buttons.
struct TeamsPanelGeometry {
    static let buttonWidth: CGFloat = 76
    static let gap: CGFloat = 8
    let textWidth: CGFloat
    let microphoneX: CGFloat
    let cameraX: CGFloat

    init(width: CGFloat) {
        cameraX = floor(width) - Self.buttonWidth
        microphoneX = cameraX - Self.gap - Self.buttonWidth
        textWidth = max(0, microphoneX - Self.gap)
    }
}

/// Manual choices suppress further automatic selection for this call, including re-selecting Teams itself.
struct TeamsAutoSelection {
    private var previous: String?
    private var inCall = false
    private var attempted = false

    mutating func manuallySelected() {
        previous = nil
        if inCall { attempted = true }
    }

    mutating func receive(_ snapshot: TeamsSnapshot, current: String) -> String? {
        guard snapshot.online else { return nil }
        inCall = snapshot.inCall
        if !inCall {
            let restore = current == "teams" ? previous : nil
            previous = nil
            attempted = false
            return restore
        }
        guard snapshot.focusRequestsSelection else { return nil }
        guard !attempted else { return nil }
        attempted = true
        guard current != "teams" else { return nil }
        previous = current
        return "teams"
    }
}
