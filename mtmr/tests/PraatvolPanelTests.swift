import Foundation

@main
struct PraatvolPanelTests {
    static func main() throws {
        try checkSnapshots()
        try checkAddendum()
        try checkSavedFlashRecency()
        try checkFraming()
        checkTimeAndConfirmation()
        if CommandLine.arguments.count > 1 {
            if CommandLine.arguments[1] == "--offline" {
                checkMissingSocket(path: CommandLine.arguments[2])
            } else {
                checkFakeSocket(path: CommandLine.arguments[1])
            }
        }
        print("praatvol protocol, display and socket checks passed")
    }

    private static func check(_ condition: @autoclosure () throws -> Bool) rethrows {
        let satisfied = try condition()
        precondition(satisfied)
    }

    private static func snapshot(step: String, kind: String? = nil, attention: Bool = false) throws -> Data {
        let fields: [String: Any] = [
            "v": 1, "step": step, "kind": kind.map { $0 as Any } ?? NSNull(),
            "startedAt": step == "recording" ? 1000.0 : NSNull(), "elapsedSeconds": 61.0,
            "microphone": ["name": "Desk Microphone", "hasSignal": true, "silenceSeconds": 0.0],
            "system": kind == "call" ? ["active": true, "hasSignal": false, "silenceSeconds": 12.0] : NSNull(),
            "uploadFraction": step == "uploading" ? 0.42 : NSNull(),
            "needsAttention": attention, "message": NSNull()
        ]
        return try JSONSerialization.data(withJSONObject: fields)
    }

    private static func checkSnapshots() throws {
        for step in ["idle", "saved", "failed", "starting", "preparing", "uploading", "transcribing"] {
            let bare = try snapshot(step: step)
            let wrapped = Data("{\"ok\":true,\"status\":".utf8) + bare + Data("}".utf8)
            let status = try PraatvolReply.decode(bare).snapshot!
            try check(PraatvolReply.decode(wrapped).snapshot == status)
            let display = PraatvolDisplay(snapshot: status)
            precondition(display.canStart == ["idle", "saved", "failed"].contains(step))
            precondition(display.canStop == (step == "starting"))
            precondition(display.failed == (step == "failed"))
            precondition(display.spinning == ["starting", "preparing", "uploading", "transcribing"].contains(step))
            if step == "uploading" { precondition(display.text == "Uploading 42%") }
            let attention = PraatvolDisplay(snapshot: try PraatvolReply.decode(snapshot(step: step, attention: true)).snapshot!)
            precondition(attention.text == "Needs attention on Mac")
            precondition(attention.attention)
            precondition(!attention.canStop)
        }
        for kind in ["room", "call"] {
            let status = try PraatvolReply.decode(snapshot(step: "recording", kind: kind)).snapshot!
            let display = PraatvolDisplay(snapshot: status)
            precondition(display.recording && display.canStop && !display.canStart)
            precondition(display.badge == kind.capitalized)
            precondition(display.microphoneName == "Desk Microphone")
            precondition(display.signals.first == .good)
            precondition(display.signals.count == (kind == "call" ? 2 : 1))
            if kind == "call" { precondition(display.signals.last == .warning) }
            precondition(status.elapsed(at: 1065, receivedAt: 1061) == 65)
            let attention = PraatvolDisplay(snapshot: try PraatvolReply.decode(snapshot(step: "recording", kind: kind, attention: true)).snapshot!)
            precondition(attention.attention && !attention.canStop)
        }
        precondition(PraatvolDisplay(snapshot: nil).text == "praatvol offline")
        precondition(!PraatvolDisplay(snapshot: nil).canStart)
        precondition(PraatvolDisplay.Signal.state(hasSignal: false, silenceSeconds: 10) == .silent)
        precondition(PraatvolDisplay.Signal.state(hasSignal: false, silenceSeconds: 10.1) == .warning)
        for code in ["busy", "notRecording", "denied"] {
            let reply = try PraatvolReply.decode(Data("{\"ok\":false,\"error\":\"\(code)\",\"message\":\"No\"}".utf8))
            precondition(reply.snapshot == nil && reply.error == code)
        }
        let unsupported = try snapshot(step: "idle")
        let unsupportedFields = try JSONSerialization.jsonObject(with: unsupported) as! [String: Any]
        let unsupportedVersion = try JSONSerialization.data(withJSONObject: unsupportedFields.merging(["v": 2]) { _, version in version })
        for invalid in [Data("{\"v\":2}".utf8), Data("null".utf8), Data("not json".utf8), unsupportedVersion] {
            do {
                _ = try PraatvolReply.decode(invalid)
                preconditionFailure("Invalid snapshots must fail")
            } catch { print("Invalid snapshot rejected: \(error)") }
        }
        try check(JSONDecoder().decode(PraatvolAppOptions.self, from: Data("{}".utf8)) == PraatvolAppOptions())
        try check(JSONDecoder().decode(PraatvolAppOptions.self, from: Data("{\"app\":\"dev\"}".utf8)) == PraatvolAppOptions(app: .dev))
    }

    private static func display(step: String, fields: [String: Any] = [:], now: Double = 1060,
                                savedAt: Double? = nil) throws -> PraatvolDisplay {
        let original = try JSONSerialization.jsonObject(with: snapshot(step: step)) as! [String: Any]
        let extended = original.merging(fields) { _, value in value }
        let status = try PraatvolReply.decode(JSONSerialization.data(withJSONObject: extended)).snapshot!
        return PraatvolDisplay(snapshot: status, now: now, savedAt: savedAt)
    }

    private static func checkAddendum() throws {
        let review = try display(step: "review", fields: ["durationSeconds": 723.0, "uploadBytes": 4_100_000])
        precondition(review.review && !review.canStart && !review.canStop && !review.spinning)
        precondition(review.text == "Transcribe?" && review.reviewDetail == "12:03 · 4.1 MB")
        try check(display(step: "review").reviewDetail == "")
        try check(display(step: "review", fields: ["durationSeconds": 3601]).reviewDetail == "1:00:01")
        try check(display(step: "review", fields: ["uploadBytes": 1_250_000]).reviewDetail == "1.2 MB")
        let warning = try display(step: "review", fields: ["warnings": ["Long recording", "Second warning"]])
        precondition(warning.reviewWarning == "Long recording" && warning.reviewDetail == "Long recording")
        try check(display(step: "review", fields: ["warnings": []]).reviewWarning == nil)
        for field in ["stepStartedAt", "estimatedSeconds", "preparingFraction", "durationSeconds", "uploadBytes", "warnings"] {
            let legacy = try display(step: "transcribing", fields: [field: NSNull()])
            precondition(legacy.progressFraction == nil && legacy.text == "Transcribing")
        }
        let preparing = try display(step: "preparing", fields: ["preparingFraction": 0.25])
        precondition(preparing.progressFraction == 0.25 && preparing.text == "Preparing" && preparing.showsProgress)
        let uploading = try display(step: "uploading")
        precondition(uploading.progressFraction == 0.42 && uploading.text == "Uploading 42%")
        let estimate: [String: Any] = ["stepStartedAt": 1000.0, "estimatedSeconds": 100.0]
        let transcribing = try display(step: "transcribing", fields: estimate)
        precondition(transcribing.progressFraction == 0.6 && transcribing.text == "Transcribing ~60%")
        try check(display(step: "transcribing", fields: estimate, now: 2000).progressFraction == 0.95)
        try check(display(step: "transcribing", fields: estimate, now: 2000).text == "Transcribing ~95%")
        try check(display(step: "transcribing", fields: estimate, now: 900).progressFraction == 0)
        try check(display(step: "transcribing", fields: ["stepStartedAt": 1000]).progressFraction == nil)
        try check(display(step: "transcribing", fields: ["estimatedSeconds": 100]).progressFraction == nil)
        try check(display(step: "transcribing", fields: ["stepStartedAt": 1000, "estimatedSeconds": 0]).progressFraction == nil)
        try check(display(step: "uploading", fields: ["uploadFraction": 1]).text == "Uploading 99%")
        try check(display(step: "preparing").progressFraction == nil)
        try check(display(step: "uploading", fields: ["uploadFraction": NSNull()]).progressFraction == nil)
        let unknown = try display(step: "checking")
        precondition(unknown.snapshot?.step == .unknown("checking") && unknown.spinning && unknown.text == "Checking")
        precondition(!unknown.canStart && !unknown.showsStop)
        let saved = try display(step: "saved", now: 1003.9, savedAt: 1000)
        precondition(saved.savedFlash && saved.text == "Saved" && !saved.canStart)
        try check(display(step: "saved", now: 1004, savedAt: 1000).canStart)
        try check(display(step: "saved").canStart)
        let answered = try PraatvolReply.decode(Data("{\"ok\":false,\"error\":\"notReviewing\"}".utf8))
        precondition(answered.errorText == "Already answered")
        var receipt = PraatvolSavedReceipt()
        receipt.receive(saved.snapshot, at: 1000)
        precondition(receipt.savedAt == nil, "A first snapshot of saved must not flash")
        receipt.receive(try display(step: "transcribing").snapshot, at: 1001)
        receipt.receive(saved.snapshot, at: 1002)
        precondition(receipt.savedAt == 1002, "A live transition into saved must flash")
        receipt.receive(saved.snapshot, at: 1003)
        precondition(receipt.savedAt == 1002, "Repeated saved pushes must not extend the flash")
        receipt.receive(review.snapshot, at: 1004)
        precondition(receipt.savedAt == nil)
        receipt.receive(saved.snapshot, at: 1005)
        precondition(receipt.savedAt == 1005)
        receipt.receive(nil, at: 1006)
        precondition(receipt.savedAt == nil)
    }

    private static func checkSavedFlashRecency() throws {
        let recentSave = try display(step: "saved", fields: ["stepStartedAt": 1059.0], now: 1060)
        precondition(recentSave.savedFlash && !recentSave.canStart, "Saved one second ago must flash")
        let staleSave = try display(step: "saved", fields: ["stepStartedAt": 1055.0], now: 1060)
        precondition(!staleSave.savedFlash && staleSave.canStart, "Saved five seconds ago must not flash")
        let oldSaveOnNewPanel = try display(step: "saved", fields: ["stepStartedAt": 1000.0], now: 1060)
        precondition(!oldSaveOnNewPanel.savedFlash && oldSaveOnNewPanel.canStart,
                     "A new panel seeing an old saved state must show idle buttons")
        let slightlyFutureSave = try display(step: "saved", fields: ["stepStartedAt": 1061.5], now: 1060)
        precondition(slightlyFutureSave.savedFlash, "A save up to 2 s in the future counts as recent")
        let farFutureSave = try display(step: "saved", fields: ["stepStartedAt": 1063.0], now: 1060)
        precondition(!farFutureSave.savedFlash, "A save more than 2 s in the future is not recent")
        let legacyFirstSnapshot = try display(step: "saved", now: 1060, savedAt: nil)
        precondition(!legacyFirstSnapshot.savedFlash && legacyFirstSnapshot.canStart,
                     "Without stepStartedAt, a first snapshot of saved must not flash")
        var legacyReceipt = PraatvolSavedReceipt()
        legacyReceipt.receive(try display(step: "transcribing").snapshot, at: 1000)
        legacyReceipt.receive(try display(step: "saved").snapshot, at: 1001)
        let flashing = try display(step: "saved", now: 1004.9, savedAt: legacyReceipt.savedAt)
        precondition(flashing.savedFlash, "Legacy live transition must flash for 4 s")
        let expired = try display(step: "saved", now: 1005, savedAt: legacyReceipt.savedAt)
        precondition(!expired.savedFlash && expired.canStart, "Legacy flash must end after 4 s")
    }

    private static func checkFraming() throws {
        var framer = PraatvolLineFramer()
        let line = try snapshot(step: "idle")
        try check(framer.append(line.prefix(10)).isEmpty)
        let lines = try framer.append(Data(line.dropFirst(10)) + Data([10]) + line + Data([10]))
        precondition(lines == [line, line])
        try check(framer.append(Data(repeating: 32, count: 4096)).isEmpty)
        try check(framer.append(Data([10])).first?.count == 4096)
        do {
            _ = try framer.append(Data(repeating: 32, count: 4097))
            preconditionFailure("Oversize lines must fail")
        } catch { print("Oversize line rejected: \(error)") }
    }

    private static func checkTimeAndConfirmation() {
        for (seconds, text) in [(0.0, "00:00"), (61, "01:01"), (3599, "59:59"), (3600, "1:00:00"), (7384, "2:03:04"), (-5, "00:00")] {
            precondition(PraatvolDisplay.time(seconds) == text)
        }
        precondition(PraatvolDisplay.time(.nan) == "--:--")
        precondition(PraatvolDisplay.time(.infinity) == "--:--")
        var confirmation = PraatvolStopConfirmation()
        precondition(!confirmation.tap(at: 10))
        precondition(confirmation.isPending(at: 12.9))
        precondition(confirmation.tap(at: 12.9))
        precondition(!confirmation.isPending(at: 13))
        precondition(!confirmation.tap(at: 20))
        precondition(!confirmation.tap(at: 23), "Expiry must re-arm, not stop")
        confirmation.reset()
        precondition(!confirmation.isPending(at: 23))
        precondition(praatvolStopButtonWidth(confirmationTextWidth: nil) == 44, "Icon-only Stop keeps 44 pt")
        precondition(praatvolStopButtonWidth(confirmationTextWidth: 5) == 44, "Short text never shrinks below 44 pt")
        precondition(praatvolStopButtonWidth(confirmationTextWidth: 40.1) == 75, "Padding is added, then rounded up")
        precondition(praatvolStopButtonWidth(confirmationTextWidth: 40) == 74, "Exact padding sum is not rounded further")
        precondition(PraatvolAppOptions().socketPath.hasSuffix("/praatvol/control.sock"))
        precondition(PraatvolAppOptions(app: .dev).socketPath.hasSuffix("/praatvol-dev/control.sock"))
        let recording = PraatvolSnapshot(v: 1, step: .recording, kind: .room, startedAt: nil, elapsedSeconds: 61,
                                        microphone: nil, system: nil, uploadFraction: nil, needsAttention: false, message: nil)
        precondition(recording.elapsed(at: 2004, receivedAt: 2000) == 65, "Interpolate even without startedAt")
    }

    private static func checkMissingSocket(path: String) {
        let client = PraatvolClient(socketPath: path)
        var callbacks = 0
        var commandErrors = 0
        client.onCommandError = { message in
            precondition(message == "Command unavailable")
            commandErrors += 1
        }
        client.onSnapshot = { snapshot in
            precondition(snapshot == nil)
            callbacks += 1
        }
        client.start()
        client.send(.recordRoom)
        RunLoop.current.run(until: Date().addingTimeInterval(2.7))
        precondition(callbacks == 2, "Missing sockets must retry after 2 s, not spin")
        precondition(commandErrors == 1, "Command connection failures must reach the brief UI message")
        client.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(2.2))
        precondition(callbacks == 2, "Stopping must cancel reconnects and callbacks")
    }

    private static func checkFakeSocket(path: String) {
        let client = PraatvolClient(socketPath: path)
        var stages = [String]()
        var finished = false
        var commandErrors = [String]()
        client.onSnapshot = { status in
            stages.append(status?.step.rawValue ?? "offline")
            if status?.step == .recording { client.send(.stop) }
            if status?.step == .review {
                client.send(.transcribe)
                client.send(.keep)
            }
        }
        client.onCommandError = { message in
            commandErrors.append(message)
            finished = commandErrors.count == 3
        }
        client.start()
        let deadline = Date().addingTimeInterval(9)
        while !finished {
            guard Date() < deadline else { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        client.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        precondition(finished, "Fake server command response not received")
        precondition(commandErrors == ["Busy", "Already answered", "Already answered"])
        precondition(stages.filter { $0 == "review" }.count == 1, "Commands must not change pushed status optimistically")
        precondition(stages.contains("idle") && stages.contains("recording") && stages.contains("offline"), "Subscribe must recover after EOF")
    }
}
