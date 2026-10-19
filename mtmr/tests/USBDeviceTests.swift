import Cocoa
import CoreGraphics

@main
struct USBDeviceTests {
    static func main() {
        let external: [String: Any] = ["bDeviceClass": 0, "locationID": 0x00100000]
        precondition(USBDeviceMonitor.shouldAnimate(properties: external))
        precondition(USBDeviceMonitor.shouldAnimate(properties: ["bDeviceClass": 3, "Built-In": false]))
        precondition(!USBDeviceMonitor.shouldAnimate(properties: ["bDeviceClass": 9]))
        precondition(!USBDeviceMonitor.shouldAnimate(properties: ["bDeviceClass": 17]))
        precondition(!USBDeviceMonitor.shouldAnimate(properties: ["Built-In": true]))
        precondition(!USBDeviceMonitor.shouldAnimate(properties: ["built-in": Data([1])]))
        precondition(!USBDeviceMonitor.shouldAnimate(properties: ["USB Device Internal": true]))
        precondition(!USBDeviceMonitor.shouldAnimate(properties: ["USB Device Removable": "No"]))
        precondition(!USBDeviceMonitor.shouldAnimate(properties: external, ancestors: [["Built-In": true]]))
        precondition(USBDeviceMonitor.shouldAnimate(properties: external, ancestors: [["bDeviceClass": 9]]))
        precondition(USBDeviceMonitor.shouldAnimate(properties: ["locationID": 0]))
        precondition(USBDeviceMonitor.shouldAnimateDisplay(flags: .addFlag, builtIn: false, alreadyConnected: false))
        precondition(!USBDeviceMonitor.shouldAnimateDisplay(flags: .addFlag, builtIn: true, alreadyConnected: false))
        precondition(!USBDeviceMonitor.shouldAnimateDisplay(flags: .addFlag, builtIn: false, alreadyConnected: true))
        precondition(!USBDeviceMonitor.shouldAnimateDisplay(flags: [.addFlag, .beginConfigurationFlag], builtIn: false, alreadyConnected: false))
        precondition(!USBDeviceMonitor.shouldAnimateDisplay(flags: .mirrorFlag, builtIn: false, alreadyConnected: false))
        precondition(!USBDeviceMonitor.shouldAnimateDisplay(flags: .removeFlag, builtIn: false, alreadyConnected: false))
        precondition(USBDeviceMonitor.passesDebounce(now: 10, lastEvent: 8, interval: 2))
        precondition(!USBDeviceMonitor.passesDebounce(now: 9.9, lastEvent: 8, interval: 2))
        precondition(!USBDeviceMonitor.passesDebounce(now: 12.9, lastEvent: 8, interval: 5))
        precondition(USBDeviceMonitor.passesDebounce(now: 13, lastEvent: 8, interval: 5))
        precondition(Set(USBDeviceMonitor.accessoryTransportClasses) == Set([
            "IOPortTransportStateDisplayPort", "IOPortTransportStateCIO"
        ]))
        precondition(!USBDeviceMonitor.accessoryTransportClasses.contains("IOPortTransportStateUSB2"))
        precondition(!USBDeviceMonitor.accessoryTransportClasses.contains("IOPortTransportStateCC"))
        print("USB device filter checks passed")
    }
}
