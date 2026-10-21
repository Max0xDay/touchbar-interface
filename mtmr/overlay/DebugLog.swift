import Foundation

/// Enable: defaults write com.maxday.touchbar-interface.mtmr-dev DebugLogging -bool true
/// Read on each call without a restart; external changes may wait for UserDefaults cache refresh.
func debugLog(_ message: @autoclosure () -> String) {
    guard UserDefaults.standard.bool(forKey: "DebugLogging") else { return }
    NSLog("%@", message())
}
