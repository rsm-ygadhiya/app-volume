import CoreAudio
import Foundation

/// Typed readers for Core Audio object properties (global scope, main element).
enum CA {

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func scalar<T>(_ object: AudioObjectID,
                          _ selector: AudioObjectPropertySelector,
                          default def: T) -> T {
        var address = address(selector)
        var value = def
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : def
    }

    static func array<T>(_ object: AudioObjectID,
                         _ selector: AudioObjectPropertySelector,
                         of type: T.Type) -> [T] {
        var address = address(selector)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize),
                                                   alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, raw)
        guard status == noErr else { return [] }
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    static func string(_ object: AudioObjectID,
                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = value else { return nil }
        return cf as String
    }

    static var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    static var defaultOutputDevice: AudioObjectID {
        scalar(systemObject, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }
}
