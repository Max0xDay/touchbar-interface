import Foundation
import CoreGraphics

/// Shared by drawing, touch tracking and the host; the slider never enters the layout solver.
enum VolumeControlGeometry {
    static func overlayFrame(button: CGRect, notificationLeft: CGFloat) -> CGRect {
        return CGRect(x: button.minX, y: button.minY, width: max(0, notificationLeft - 16 - button.minX), height: 30)
    }

    static func knobPosition(volume: Double, track: CGRect) -> CGFloat {
        return track.minX + track.width * CGFloat(clamped(volume))
    }

    static func volume(position: CGFloat, track: CGRect) -> Double {
        guard track.width > 0 else { return 0 }
        return clamped(Double((position - track.minX) / track.width))
    }

    static func clamped(_ volume: Double) -> Double {
        guard volume.isFinite else { return 0 }
        return min(1, max(0, volume))
    }
}
