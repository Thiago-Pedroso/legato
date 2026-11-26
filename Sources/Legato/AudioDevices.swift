import CoreAudio
import Foundation

struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    /// Stable across reboots and reconnections, unlike `id`. This is what settings keep.
    let uid: String
    let name: String
}

/// The few Core Audio questions Legato asks: which microphones exist, and muting the speakers.
enum AudioDevices {
    static func inputs() -> [InputDevice] {
        all().compactMap { id in
            guard hasInput(id), let uid = uid(of: id), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    static func uid(of device: AudioDeviceID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    /// Any device, input or output, by the UID that `uid(of:)` gave for it.
    static func device(uid: String) -> AudioDeviceID? {
        all().first { self.uid(of: $0) == uid }
    }

    private static func all() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    static func input(uid: String) -> AudioDeviceID? {
        inputs().first { $0.uid == uid }?.id
    }

    static var defaultOutput: AudioDeviceID? { systemDevice(kAudioHardwarePropertyDefaultOutputDevice) }
    static var defaultInput: AudioDeviceID? { systemDevice(kAudioHardwarePropertyDefaultInputDevice) }

    private static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    /// Nil when the device has no mute control (some HDMI and Bluetooth outputs).
    static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var address = muteAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &address),
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value != 0
    }

    static func setMuted(_ device: AudioDeviceID, _ muted: Bool) {
        var address = muteAddress
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
