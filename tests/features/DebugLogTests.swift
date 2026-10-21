import Foundation

@main
struct DebugLogTests {
    static func main() {
        precondition(UserDefaults.standard.object(forKey: "DebugLogging") == nil)
        var evaluations = 0
        func message() -> String {
            evaluations += 1
            return String(format: "MTMR-notif: event state=%@ directTouches=%ld", "began", 2)
        }

        debugLog(message())
        precondition(evaluations == 0, "Unset logging must not evaluate the message")
        UserDefaults.standard.setVolatileDomain(["DebugLogging": true], forName: UserDefaults.argumentDomain)
        debugLog(message())
        precondition(evaluations == 1, "Enabling must take effect on the next call")
        UserDefaults.standard.setVolatileDomain(["DebugLogging": false], forName: UserDefaults.argumentDomain)
        debugLog(message())
        precondition(evaluations == 1, "Disabling must stop message evaluation immediately")
    }
}
