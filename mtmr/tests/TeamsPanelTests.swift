import Foundation

@main
struct TeamsPanelTests {
    static func snapshot(_ json: String) throws -> TeamsSnapshot {
        return try JSONDecoder().decode(TeamsSnapshot.self, from: Data(json.utf8))
    }

    static func checkGeometry() {
        let panel = TeamsPanelGeometry(width: 340)
        precondition(panel.cameraX == 264 && panel.microphoneX == 180)
        precondition(panel.textWidth == 172)
        precondition(TeamsPanelGeometry(width: 100).textWidth == 0)
    }

    static func main() throws {
        let call = try snapshot("""
        {"inCall":true,"focused":true,"mic":"on","camera":"off","title":"Planning","joinedAt":100,"durationText":"12:03","future":1}
        """)
        precondition(call.online && call.inCall && call.focused)
        precondition(call.microphone == .on && call.camera == .off)
        let unknown = try snapshot("{\"inCall\":false,\"mic\":\"future\"}")
        let disconnected = try snapshot("{\"online\":false,\"inCall\":false}")
        precondition(unknown.microphone == .unknown)
        precondition(disconnected.online == false)
        for invalid in ["{}", "{\"inCall\":1}", "{\"inCall\":true,\"joinedAt\":\"bad\"}", "{\"inCall\":false,\"focused\":1}"] {
            do {
                _ = try snapshot(invalid)
                fatalError("Malformed state accepted: \(invalid)")
            } catch { print("Rejected malformed Teams state: \(error)") }
        }
        precondition(TeamsClock.format(59) == "0:59")
        precondition(TeamsClock.format(60) == "1:00")
        precondition(TeamsClock.format(599) == "9:59")
        precondition(TeamsClock.format(600) == "10:00")
        precondition(TeamsClock.format(3599) == "59:59")
        precondition(TeamsClock.format(3600) == "1:00:00")
        precondition(TeamsClock.format(3601) == "1:00:01")
        precondition(TeamsClock.format(-1) == "0:00")
        precondition(TeamsClock.duration("1:02:03") == 3723)
        precondition(TeamsClock.duration("12:60") == nil)
        precondition(TeamsClock.duration("bad") == nil)
        var clock = TeamsClock()
        clock.receive(call, at: 1000)
        precondition(clock.text(at: 1002) == "12:05")
        clock.receive(call, at: 1002)
        precondition(clock.text(at: 1003) == "12:06", "Repeated duration must not freeze local clock")
        let fallback = try snapshot("{\"inCall\":true,\"joinedAt\":100}")
        clock.receive(fallback, at: 110)
        precondition(clock.text(at: 115) == "0:15")
        checkGeometry()

        var selection = TeamsAutoSelection()
        precondition(selection.receive(call, current: "lob") == "teams")
        let blurred = try snapshot("{\"inCall\":true,\"focused\":false}")
        precondition(selection.receive(blurred, current: "teams") == nil)
        let ended = try snapshot("{\"inCall\":false}")
        precondition(selection.receive(ended, current: "teams") == "lob")
        precondition(selection.receive(call, current: "stats") == "teams")
        selection.manuallySelected()
        precondition(selection.receive(call, current: "fan") == nil)
        precondition(selection.receive(ended, current: "fan") == nil)
        precondition(selection.receive(call, current: "system") == "teams")
        let offline = try snapshot("{\"online\":false,\"inCall\":false}")
        precondition(selection.receive(offline, current: "teams") == nil, "Offline is not a confirmed call end")
        precondition(selection.receive(ended, current: "teams") == "system")
        print("Teams decode, clock and auto-selection checks passed")
    }
}
