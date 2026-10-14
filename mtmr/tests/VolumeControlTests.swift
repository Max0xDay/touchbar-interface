import Foundation
import CoreGraphics

@main
struct VolumeControlTests {
    static func main() {
        checkVolumeMapping()
        checkOverlayFrames()
        checkVolumeState()
        print("Volume control geometry and state checks passed")
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

    private static func checkVolumeMapping() {
        let track = CGRect(x: 40, y: 11, width: 200, height: 8)
        for (volume, expectedPosition) in [(0.0, 40.0), (0.25, 90), (0.5, 140), (1, 240)] {
            let position = VolumeControlGeometry.knobPosition(volume: volume, track: track)
            precondition(position == expectedPosition, "Knob must use the full track range")
            precondition(VolumeControlGeometry.volume(position: position, track: track) == volume)
        }
        precondition(VolumeControlGeometry.volume(position: -100, track: track) == 0)
        precondition(VolumeControlGeometry.volume(position: 400, track: track) == 1)
        precondition(VolumeControlGeometry.knobPosition(volume: -1, track: track) == track.minX)
        precondition(VolumeControlGeometry.knobPosition(volume: 2, track: track) == track.maxX)
        precondition(VolumeControlGeometry.volume(position: 50, track: .zero) == 0)
        precondition(VolumeControlGeometry.knobPosition(volume: .nan, track: track) == track.minX)
    }

    private static func checkOverlayFrames() {
        let normal = VolumeControlGeometry.overlayFrame(button: CGRect(x: 47, y: 0, width: 75, height: 30), notificationLeft: 356)
        precondition(normal == CGRect(x: 47, y: 0, width: 293, height: 30))
        precondition(normal.contains(CGPoint(x: 287, y: 15)), "Overlay must cover the Teams camera")
        precondition(normal.maxX == 340, "Keep exactly 16 pt clear of notifications")
        for notificationLeft in [304.0, 356, 420] {
            let frame = VolumeControlGeometry.overlayFrame(button: CGRect(x: 47, y: 0, width: 45, height: 30), notificationLeft: notificationLeft)
            precondition(frame.minX == 47, "Start at the volume button even after shrinking")
            precondition(frame.maxX == notificationLeft - 16)
            precondition(frame.height == 30)
        }
        let impossible = VolumeControlGeometry.overlayFrame(button: CGRect(x: 47, y: 0, width: 45, height: 30), notificationLeft: 50)
        precondition(impossible.width == 0, "Never extend into notifications at impossible widths")
        let shifted = VolumeControlGeometry.overlayFrame(button: CGRect(x: 60, y: 5, width: 75, height: 30), notificationLeft: 400)
        precondition(shifted == CGRect(x: 60, y: 5, width: 324, height: 30))
    }
}
