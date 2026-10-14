import Foundation
import Darwin

struct PraatvolAppOptions: Decodable, Equatable {
    enum App: String, Decodable { case dev, release }
    let app: App

    init(app: App = .release) { self.app = app }

    private enum CodingKeys: String, CodingKey { case app }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = try container.decodeIfPresent(App.self, forKey: .app) ?? .release
    }

    var socketPath: String {
        let directory = app == .dev ? "praatvol-dev" : "praatvol"
        return NSHomeDirectory() + "/Library/Application Support/\(directory)/control.sock"
    }
}

struct PraatvolSnapshot: Decodable, Equatable {
    enum Step: Decodable, Equatable {
        case idle, starting, recording, preparing, uploading, transcribing, review, saved, failed
        case unknown(String)

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            switch value {
            case "idle": self = .idle
            case "starting": self = .starting
            case "recording": self = .recording
            case "preparing": self = .preparing
            case "uploading": self = .uploading
            case "transcribing": self = .transcribing
            case "review": self = .review
            case "saved": self = .saved
            case "failed": self = .failed
            default: self = .unknown(value)
            }
        }

        var rawValue: String {
            switch self {
            case .idle: return "idle"
            case .starting: return "starting"
            case .recording: return "recording"
            case .preparing: return "preparing"
            case .uploading: return "uploading"
            case .transcribing: return "transcribing"
            case .review: return "review"
            case .saved: return "saved"
            case .failed: return "failed"
            case .unknown(let value): return value
            }
        }
    }
    enum Kind: String, Decodable { case room, call }
    struct Microphone: Decodable, Equatable {
        let name: String
        let hasSignal: Bool
        let silenceSeconds: Double
    }
    struct SystemAudio: Decodable, Equatable {
        let active: Bool
        let hasSignal: Bool
        let silenceSeconds: Double
    }

    let v: Int
    let step: Step
    let kind: Kind?
    let startedAt: Double?
    let elapsedSeconds: Double
    let microphone: Microphone?
    let system: SystemAudio?
    let uploadFraction: Double?
    let needsAttention: Bool
    let message: String?
    var stepStartedAt: Double? = nil
    var estimatedSeconds: Double? = nil
    var preparingFraction: Double? = nil
    var durationSeconds: Double? = nil
    var uploadBytes: Int? = nil
    var warnings: [String]? = nil

    func elapsed(at now: Double, receivedAt: Double) -> Double {
        guard step == .recording else { return 0 }
        let interpolated = elapsedSeconds + max(0, now - receivedAt)
        return max(0, max(interpolated, startedAt.map { now - $0 } ?? 0))
    }
}

struct PraatvolReply: Decodable {
    let ok: Bool
    let status: PraatvolSnapshot?
    let error: String?

    var snapshot: PraatvolSnapshot? { return status }

    static func decode(_ line: Data) throws -> PraatvolReply {
        let fields = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        let reply: PraatvolReply
        if fields?["ok"] != nil {
            reply = try JSONDecoder().decode(Self.self, from: line)
        } else {
            reply = Self(ok: true, status: try JSONDecoder().decode(PraatvolSnapshot.self, from: line), error: nil)
        }
        if reply.ok {
            guard let snapshot = reply.status, snapshot.v == 1 else { throw PraatvolProtocolError.invalidSnapshot }
        }
        return reply
    }

    var errorText: String {
        switch error {
        case "busy": return "Busy"
        case "notRecording": return "Not recording"
        case "notReviewing": return "Already answered"
        case "denied": return "Denied"
        default: return "Command failed"
        }
    }
}

enum PraatvolProtocolError: Error { case lineTooLong, invalidSnapshot, closed }

struct PraatvolLineFramer {
    private var pending = Data()

    mutating func append(_ bytes: Data) throws -> [Data] {
        var lines: [Data] = []
        for byte in bytes {
            if byte == 10 {
                lines.append(pending)
                pending.removeAll(keepingCapacity: true)
            } else {
                guard pending.count < 4096 else { throw PraatvolProtocolError.lineTooLong }
                pending.append(byte)
            }
        }
        return lines
    }
}

struct PraatvolDisplay {
    enum Signal: Equatable {
        case good, silent, warning
        static func state(hasSignal: Bool, silenceSeconds: Double) -> Signal {
            if hasSignal { return .good }
            return silenceSeconds > 10 ? .warning : .silent
        }
    }

    let snapshot: PraatvolSnapshot?
    var now: Double = Date().timeIntervalSince1970
    var savedAt: Double? = nil
    var savedFlash: Bool {
        guard snapshot?.step == .saved, let savedAt = savedAt else { return false }
        return now < savedAt + 4
    }
    var review: Bool { return snapshot?.step == .review }
    var offline: Bool { return snapshot == nil }
    var recording: Bool { return snapshot?.step == .recording }
    var attention: Bool { return snapshot?.needsAttention == true }
    var failed: Bool { return snapshot?.step == .failed }
    var canStart: Bool {
        guard let step = snapshot?.step else { return false }
        if attention { return false }
        if savedFlash { return false }
        return [.idle, .saved, .failed].contains(step)
    }
    var showsStop: Bool { return [.starting, .recording].contains(snapshot?.step) }
    var canStop: Bool { return showsStop && !attention }
    var spinning: Bool {
        guard let step = snapshot?.step else { return false }
        if case .unknown = step { return true }
        return [.starting, .preparing, .uploading, .transcribing].contains(step)
    }
    var showsProgress: Bool { return [.preparing, .uploading, .transcribing].contains(snapshot?.step) }
    var progressFraction: Double? {
        guard let snapshot = snapshot else { return nil }
        let fraction: Double?
        switch snapshot.step {
        case .preparing: fraction = snapshot.preparingFraction
        case .uploading: fraction = snapshot.uploadFraction
        case .transcribing:
            guard let startedAt = snapshot.stepStartedAt, startedAt.isFinite,
                  let estimate = snapshot.estimatedSeconds, estimate.isFinite, estimate > 0 else { return nil }
            fraction = (now - startedAt) / estimate
        default: return nil
        }
        guard let value = fraction, value.isFinite else { return nil }
        return min(snapshot.step == .transcribing ? 0.95 : 0.99, max(0, value))
    }
    var reviewWarning: String? { return snapshot?.warnings?.first }
    var reviewDetail: String {
        if let warning = reviewWarning { return warning }
        var parts: [String] = []
        if let duration = snapshot?.durationSeconds { parts.append(Self.time(duration)) }
        if let bytes = snapshot?.uploadBytes {
            // #COMPLETION_DRIVE: MB means decimal megabytes, rather than binary MiB.
            // #SUGGEST_VERIFY: Confirm praatvol uses the same size unit in its review UI.
            parts.append(String(format: "%.1f MB", Double(max(0, bytes)) / 1_000_000))
        }
        return parts.joined(separator: " · ")
    }
    var badge: String { return snapshot?.kind?.rawValue.capitalized ?? "" }
    var microphoneName: String { return snapshot?.microphone?.name ?? "" }
    var signals: [Signal] {
        guard recording else { return [] }
        let microphone = snapshot?.microphone
        var signals = [Signal.state(hasSignal: microphone?.hasSignal ?? false, silenceSeconds: microphone?.silenceSeconds ?? 0)]
        if snapshot?.kind == .call {
            let system = snapshot?.system
            signals.append(Signal.state(hasSignal: system?.hasSignal ?? false, silenceSeconds: system?.silenceSeconds ?? 0))
        }
        return signals
    }
    var text: String {
        if attention { return "Needs attention on Mac" }
        guard let snapshot = snapshot else { return "praatvol offline" }
        if savedFlash { return "Saved" }
        switch snapshot.step {
        case .starting: return "Starting"
        case .preparing: return "Preparing"
        case .uploading:
            guard let fraction = progressFraction else { return "Uploading" }
            return "Uploading \(Int((fraction * 100).rounded()))%"
        case .transcribing:
            guard let fraction = progressFraction else { return "Transcribing" }
            return "Transcribing ~\(Int((fraction * 100).rounded()))%"
        case .review: return "Transcribe?"
        case .unknown(let step): return step.capitalized
        default: return ""
        }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        guard seconds < Double(Int.max) else { return "--:--" }
        let total = Int(max(0, seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct PraatvolSavedReceipt {
    private var step: PraatvolSnapshot.Step?
    private(set) var savedAt: Double?

    mutating func receive(_ snapshot: PraatvolSnapshot?, at now: Double) {
        if snapshot?.step != step { savedAt = snapshot?.step == .saved ? now : nil }
        step = snapshot?.step
    }
}

struct PraatvolStopConfirmation {
    private var expiresAt: Double?
    func isPending(at now: Double) -> Bool { return expiresAt.map { now < $0 } ?? false }
    mutating func tap(at now: Double) -> Bool {
        if isPending(at: now) {
            reset()
            return true
        }
        expiresAt = now + 3
        return false
    }
    mutating func reset() { expiresAt = nil }
}

/// One subscription while visible. Commands use separate, short-lived sockets and are never retried:
/// a lost reply must not accidentally start a second recording or stop a later one.
final class PraatvolClient {
    enum Command: String { case recordRoom = "record-room", recordCall = "record-call", stop, transcribe, keep }
    var onSnapshot: ((PraatvolSnapshot?) -> Void)?
    var onCommandError: ((String) -> Void)?

    private let socketPath: String
    private let queue = DispatchQueue(label: "MTMRPraatvolSubscribe")
    private let commandQueue = DispatchQueue(label: "MTMRPraatvolCommands")
    private var source: DispatchSourceRead?
    private var retry: DispatchWorkItem?
    private var firstSnapshotTimeout: DispatchWorkItem?
    private var framer = PraatvolLineFramer()
    private var running = false
    private var subscriptionEpoch = 0
    private var connected: Bool?
    // Main-thread epoch rejects callbacks from a previous visibility lifetime.
    private var epoch = 0
    private var enabled = false

    init(socketPath: String) { self.socketPath = socketPath }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !enabled else { return }
        enabled = true
        epoch += 1
        let epoch = self.epoch
        queue.async {
            self.running = true
            self.subscriptionEpoch = epoch
            self.connectSubscription(epoch: epoch)
        }
    }

    func stop() {
        enabled = false
        epoch += 1
        queue.async {
            self.running = false
            self.retry?.cancel()
            self.retry = nil
            self.firstSnapshotTimeout?.cancel()
            self.source?.cancel()
            self.source = nil
        }
    }

    func send(_ command: Command) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard enabled else { return }
        let epoch = self.epoch
        commandQueue.async {
            do {
                let descriptor = try self.openSocket()
                defer { Darwin.close(descriptor) }
                try self.write(command.rawValue, descriptor: descriptor)
                let reply = try self.readReply(descriptor: descriptor)
                if !reply.ok { self.commandError(reply.errorText, epoch: epoch) }
            } catch {
                self.commandError("Command unavailable", epoch: epoch)
            }
        }
    }

    private func commandError(_ message: String, epoch: Int) {
        NSLog("MTMR praatvol command: %@", message)
        deliver(epoch: epoch) { self.onCommandError?(message) }
    }

    private func deliver(epoch: Int, action: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.enabled, self.epoch == epoch else { return }
            action()
        }
    }

    private func connectSubscription(epoch: Int) {
        guard isCurrentSubscription(epoch) else { return }
        do {
            let descriptor = try openSocket()
            do { try write("subscribe", descriptor: descriptor) } catch {
                Darwin.close(descriptor)
                throw error
            }
            framer = PraatvolLineFramer()
            let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source = reader
            reader.setEventHandler { [weak self] in self?.receive(descriptor: descriptor, epoch: epoch) }
            reader.setCancelHandler { Darwin.close(descriptor) }
            reader.resume()
            let timeout = DispatchWorkItem { [weak self] in self?.disconnected(epoch: epoch) }
            firstSnapshotTimeout = timeout
            queue.asyncAfter(deadline: .now() + 3, execute: timeout)
        } catch {
            disconnected(epoch: epoch)
        }
    }

    private func receive(descriptor: Int32, epoch: Int) {
        guard isCurrentSubscription(epoch) else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
        if count < 0 {
            if errno == EAGAIN { return }
            if errno == EINTR { return }
        }
        guard count > 0 else { disconnected(epoch: epoch); return }
        do {
            for line in try framer.append(Data(bytes.prefix(count))) {
                let reply = try PraatvolReply.decode(line)
                guard reply.ok, let snapshot = reply.snapshot else { throw PraatvolProtocolError.invalidSnapshot }
                firstSnapshotTimeout?.cancel()
                firstSnapshotTimeout = nil
                logConnection(true)
                deliver(epoch: epoch) { self.onSnapshot?(snapshot) }
            }
        } catch {
            disconnected(epoch: epoch)
        }
    }

    private func isCurrentSubscription(_ epoch: Int) -> Bool {
        return running && subscriptionEpoch == epoch
    }

    private func disconnected(epoch: Int) {
        guard isCurrentSubscription(epoch) else { return }
        firstSnapshotTimeout?.cancel()
        firstSnapshotTimeout = nil
        source?.cancel()
        source = nil
        logConnection(false)
        deliver(epoch: epoch) { self.onSnapshot?(nil) }
        guard running else { return }
        retry?.cancel()
        let retry = DispatchWorkItem { [weak self] in self?.connectSubscription(epoch: epoch) }
        self.retry = retry
        queue.asyncAfter(deadline: .now() + 2, execute: retry)
    }

    private func logConnection(_ next: Bool) {
        guard connected != next else { return }
        connected = next
        NSLog("MTMR praatvol %@", next ? "connected" : "offline")
    }

    private func openSocket() throws -> Int32 {
        var address = sockaddr_un()
        let bytes = Array(socketPath.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError() }
        do {
            try configure(descriptor)
            let connection = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connection != 0 {
                guard errno == EINPROGRESS else { throw socketError() }
                try wait(descriptor, events: Int16(POLLOUT), deadline: ProcessInfo.processInfo.systemUptime + 2)
                var failure: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 else { throw socketError() }
                guard failure == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure)) }
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func configure(_ descriptor: Int32) throws {
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw socketError() }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw socketError() }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw socketError() }
    }

    private func wait(_ descriptor: Int32, events: Int16, deadline: Double) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw POSIXError(.ETIMEDOUT) }
            var polling = pollfd(fd: descriptor, events: events, revents: 0)
            let count = Darwin.poll(&polling, 1, Int32(ceil(remaining * 1000)))
            if count > 0 { return }
            if count == 0 { throw POSIXError(.ETIMEDOUT) }
            if errno != EINTR { throw socketError() }
        }
    }

    private func write(_ command: String, descriptor: Int32) throws {
        let bytes = Data("{\"cmd\":\"\(command)\"}\n".utf8)
        var offset = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while offset < bytes.count {
            try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if count > 0 { offset += count; continue }
            if errno == EINTR { continue }
            if errno == EAGAIN { continue }
            throw socketError()
        }
    }

    private func readReply(descriptor: Int32) throws -> PraatvolReply {
        var framing = PraatvolLineFramer()
        var bytes = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while true {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { continue }
                throw socketError()
            }
            guard count > 0 else { throw PraatvolProtocolError.closed }
            if let line = try framing.append(Data(bytes.prefix(count))).first { return try PraatvolReply.decode(line) }
        }
    }

    private func socketError() -> NSError { return NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
