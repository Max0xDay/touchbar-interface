import Foundation
import CoreAudio
import AudioToolbox

/// Main-thread CoreAudio state, independent of the Touch Bar. Unsupported controls remain read-only.
final class OutputVolumeController {
    struct State {
        var volume: Double?
        var muted = false
        var canSetVolume = false
        var canSetMute = false

        var symbol: String {
            if muted { return "speaker.slash.fill" }
            if volume == 0 { return "speaker.slash.fill" }
            return "speaker.wave.2.fill"
        }
    }

    private struct Listener {
        let device: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private(set) var state = State()
    var changed: (() -> Void)?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var volumeAddresses: [AudioObjectPropertyAddress] = []
    private var muteAddresses: [AudioObjectPropertyAddress] = []
    private var listeners: [Listener] = []
    private var running = false
    private var loggedFailures = Set<String>()

    // #COMPLETION_DRIVE: The default output exposes virtual/main or preferred stereo-channel controls when supported.
    // #SUGGEST_VERIFY: Check keyboard/app updates and device switching with built-in audio, headphones and HDMI.
    func start() {
        guard !running else { return }
        running = true
        listen(device: AudioObjectID(kAudioObjectSystemObject), address: Self.defaultOutputAddress)
        refresh()
    }

    func stop() {
        running = false
        removeListeners()
        device = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { removeListeners() }

    func setVolume(_ volume: Double) {
        guard state.canSetVolume else { return }
        let level = Float32(VolumeControlGeometry.clamped(volume))
        for address in volumeAddresses { write(level, address: address) }
        if state.canSetMute {
            for address in muteAddresses { write(UInt32(level == 0 ? 1 : 0), address: address) }
        }
    }

    func toggleMute() {
        refresh()
        guard state.canSetMute else { return }
        for address in muteAddresses { write(UInt32(state.muted ? 0 : 1), address: address) }
        refresh()
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        return AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    }

    private func outputAddress(_ selector: AudioObjectPropertySelector, element: UInt32 = 0) -> AudioObjectPropertyAddress {
        return AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private func refresh() {
        let nextDevice = read(AudioObjectID(kAudioObjectUnknown), device: AudioObjectID(kAudioObjectSystemObject), address: Self.defaultOutputAddress)
        let resolvedDevice = nextDevice ?? AudioObjectID(kAudioObjectUnknown)
        if device != resolvedDevice { bind(resolvedDevice) }
        state = State()
        guard device != kAudioObjectUnknown else {
            changed?()
            return
        }
        let levels = volumeAddresses.compactMap { read(Float32(0), device: device, address: $0) }
        if levels.count == volumeAddresses.count, let maximum = levels.max(), maximum.isFinite {
            state.volume = VolumeControlGeometry.clamped(Double(maximum))
            state.canSetVolume = volumeAddresses.allSatisfy { isSettable($0) }
        }
        let mutes = muteAddresses.compactMap { read(UInt32(0), device: device, address: $0) }
        if !mutes.isEmpty, mutes.count == muteAddresses.count {
            state.muted = mutes.allSatisfy { $0 != 0 }
            state.canSetMute = muteAddresses.allSatisfy { isSettable($0) }
        }
        changed?()
    }

    private func bind(_ nextDevice: AudioObjectID) {
        removeListeners(deviceOnly: true)
        device = nextDevice
        volumeAddresses = []
        muteAddresses = []
        guard device != kAudioObjectUnknown else { return }
        let stereoChannels = preferredStereoChannels()
        let volumeCandidates = [outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume), outputAddress(kAudioDevicePropertyVolumeScalar)]
        volumeAddresses = controls(master: volumeCandidates, selector: kAudioDevicePropertyVolumeScalar, channels: stereoChannels)
        muteAddresses = controls(master: [outputAddress(kAudioDevicePropertyMute)], selector: kAudioDevicePropertyMute, channels: stereoChannels)
        for address in volumeCandidates + volumeAddresses + muteAddresses where hasProperty(address) {
            listen(device: device, address: address)
        }
    }

    private func controls(master: [AudioObjectPropertyAddress], selector: AudioObjectPropertySelector, channels: [UInt32]) -> [AudioObjectPropertyAddress] {
        let supported = master.filter { hasProperty($0) }
        if let writable = supported.first(where: { isSettable($0) }) { return [writable] }
        let channelAddresses = channels.map { outputAddress(selector, element: $0) }.filter { hasProperty($0) }
        if !channelAddresses.isEmpty, channelAddresses.allSatisfy({ isSettable($0) }) { return channelAddresses }
        return supported.first.map { [$0] } ?? channelAddresses
    }

    private func preferredStereoChannels() -> [UInt32] {
        var address = outputAddress(kAudioDevicePropertyPreferredChannelsForStereo)
        guard hasProperty(address) else { return [] }
        var channels = [UInt32](repeating: 0, count: 2)
        var size = UInt32(2 * MemoryLayout<UInt32>.size)
        let status = channels.withUnsafeMutableBytes { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!) }
        guard succeeded(status, operation: "read stereo channels") else { return [] }
        return Array(Set(channels.filter { $0 > 0 })).sorted()
    }

    private func hasProperty(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(device, &address)
    }

    private func isSettable(_ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(device, &address, &settable)
        return succeeded(status, operation: "check writable control") ? settable.boolValue : false
    }

    private func read<Value>(_ initial: Value, device: AudioObjectID, address: AudioObjectPropertyAddress) -> Value? {
        guard device != kAudioObjectUnknown else { return nil }
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard succeeded(status, operation: "read control") else { return nil }
        return value
    }

    private func write<Value>(_ value: Value, address: AudioObjectPropertyAddress) {
        var address = address
        var value = value
        let status = withUnsafePointer(to: &value) { AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Value>.size), $0) }
        _ = succeeded(status, operation: "write control")
    }

    private func listen(device: AudioObjectID, address: AudioObjectPropertyAddress) {
        guard !listeners.contains(where: { matches($0, device: device, address: address) }) else { return }
        var address = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self, self.running else { return }
            self.refresh()
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
        if succeeded(status, operation: "add listener") {
            listeners.append(Listener(device: device, address: address, block: block))
        }
    }

    private func matches(_ listener: Listener, device: AudioObjectID, address: AudioObjectPropertyAddress) -> Bool {
        guard listener.device == device else { return false }
        guard listener.address.mSelector == address.mSelector else { return false }
        guard listener.address.mScope == address.mScope else { return false }
        return listener.address.mElement == address.mElement
    }

    private func removeListeners(deviceOnly: Bool = false) {
        let removed = listeners.filter { deviceOnly ? $0.device != kAudioObjectSystemObject : true }
        listeners.removeAll { listener in deviceOnly ? listener.device != kAudioObjectSystemObject : true }
        for var listener in removed {
            let status = AudioObjectRemovePropertyListenerBlock(listener.device, &listener.address, .main, listener.block)
            _ = succeeded(status, operation: "remove listener")
        }
    }

    private func succeeded(_ status: OSStatus, operation: String) -> Bool {
        guard status == noErr else {
            if loggedFailures.insert(operation).inserted {
                NSLog("MTMR volume: %@ failed (%d)", operation, status)
            }
            return false
        }
        return true
    }
}
