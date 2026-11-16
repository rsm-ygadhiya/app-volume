import CoreAudio
import Foundation
import os

/// Owns one process tap + one private aggregate device for a single app, and
/// re-renders that app's audio to the real output device scaled by the gain.
///
/// A controller that exists is rendering: `init` builds and starts the whole
/// chain or throws, and `deinit` tears it down. It is created the moment an app
/// is turned away from 100% and released when it returns to 100%, so untouched
/// apps play natively and are never routed through us.
final class AppVolumeController {

    /// Why the chain could not be built (surfaced in the UI).
    struct StartError: Error {
        let message: String
    }

    private let pid: pid_t

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?

    /// Heap-allocated so the realtime audio callback reads a stable address
    /// without touching Swift ARC / the owning object.
    private let gainPtr: UnsafeMutablePointer<Float>

    /// Peak |input sample| observed by the IO callback (for silent-capture
    /// detection). Written on the realtime thread, read on the main thread.
    private let peakPtr: UnsafeMutablePointer<Float>

    private static let log = Logger(subsystem: "AppVolumeMixer", category: "controller")

    init(pid: pid_t, processObject: AudioObjectID, initialGain: Float) throws {
        self.pid = pid
        self.gainPtr = .allocate(capacity: 1)
        self.gainPtr.initialize(to: initialGain)
        self.peakPtr = .allocate(capacity: 1)
        self.peakPtr.initialize(to: 0)

        // Every stored property is set, so a throw from here on runs `deinit`,
        // which is the single teardown path for a partly built chain.
        do {
            try start(processObject: processObject)
        } catch let error as StartError {
            Self.log.error("pid \(pid): \(error.message)")
            throw error
        }
        Self.log.info("Started volume control for pid \(pid)")
    }

    /// The caller is responsible for keeping this within its allowed range.
    func setGain(_ value: Float) {
        gainPtr.pointee = value
    }

    /// Read and reset the peak input level seen since the last call.
    func consumePeak() -> Float {
        let v = peakPtr.pointee
        peakPtr.pointee = 0
        return v
    }

    private func start(processObject: AudioObjectID) throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: [processObject])
        desc.name = "AppVolume tap \(pid)"
        desc.isPrivate = true
        // The tap silences the app's own output and hands the samples to us.
        desc.muteBehavior = .mutedWhenTapped

        var newTap: AudioObjectID = 0
        var status = AudioHardwareCreateProcessTap(desc, &newTap)
        guard status == noErr, newTap != 0 else {
            throw StartError(message: "Could not create audio tap (status \(status)). Grant audio-recording permission in System Settings › Privacy & Security.")
        }
        tapID = newTap

        guard let tapUID = CA.string(tapID, kAudioTapPropertyUID) else {
            throw StartError(message: "Could not read tap UID.")
        }

        let outputDevice = CA.defaultOutputDevice
        guard outputDevice != 0, let outputUID = CA.deviceUID(outputDevice) else {
            throw StartError(message: "No default output device.")
        }

        let aggUID = "com.appvolume.agg.\(pid).\(tapUID)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppVolume \(pid)",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID
                ]
            ]
        ]

        var newAgg: AudioObjectID = 0
        status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAgg)
        guard status == noErr, newAgg != 0 else {
            throw StartError(message: "Could not create aggregate device (status \(status)).")
        }
        aggregateID = newAgg

        let gainPtr = self.gainPtr
        let peakPtr = self.peakPtr
        let block: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            let gain = gainPtr.pointee
            let inBuffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)

            var localPeak: Float = 0
            let pairCount = min(inBuffers.count, outBuffers.count)
            for i in 0..<outBuffers.count {
                let out = outBuffers[i]
                guard let outData = out.mData else { continue }
                if i < pairCount, let inData = inBuffers[i].mData {
                    let samples = min(Int(out.mDataByteSize),
                                      Int(inBuffers[i].mDataByteSize)) / MemoryLayout<Float>.size
                    let dst = outData.assumingMemoryBound(to: Float.self)
                    let src = inData.assumingMemoryBound(to: Float.self)
                    var s = 0
                    while s < samples {
                        let v = src[s]
                        if v > localPeak { localPeak = v } else if -v > localPeak { localPeak = -v }
                        dst[s] = v * gain
                        s += 1
                    }
                    let copied = samples * MemoryLayout<Float>.size
                    if copied < Int(out.mDataByteSize) {
                        memset(outData + copied, 0, Int(out.mDataByteSize) - copied)
                    }
                } else {
                    memset(outData, 0, Int(out.mDataByteSize))
                }
            }
            if localPeak > peakPtr.pointee { peakPtr.pointee = localPeak }
        }

        var newProc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, nil, block)
        guard status == noErr, let proc = newProc else {
            throw StartError(message: "Could not create IO proc (status \(status)).")
        }
        ioProcID = proc

        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else {
            throw StartError(message: "Could not start audio device (status \(status)).")
        }
    }

    deinit {
        if let proc = ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
        }
        gainPtr.deinitialize(count: 1)
        gainPtr.deallocate()
        peakPtr.deinitialize(count: 1)
        peakPtr.deallocate()
    }
}
