import CoreAudio
import Foundation

// MARK: - Low level Core Audio property helpers
//
// These wrap the verbose AudioObjectGetPropertyData / SetPropertyData calls
// into small typed helpers so the engine code below stays readable.

enum CA {

    /// Read a fixed-size scalar property (Int32, UInt32, AudioObjectID, ...).
    static func scalar<T>(_ object: AudioObjectID,
                          _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                          default def: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value = def
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : def
    }

    /// Read an array-valued property (e.g. the process object list).
    static func array<T>(_ object: AudioObjectID,
                         _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                         of type: T.Type) -> [T] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
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

    /// Read a CFString-valued property (bundle id, UID, ...).
    static func string(_ object: AudioObjectID,
                       _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = value else { return nil }
        return cf as String
    }

    static var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    /// The user's current default output device object id.
    static var defaultOutputDevice: AudioObjectID {
        scalar(systemObject, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
    }

    /// UID string for a device object.
    static func deviceUID(_ device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }
}
