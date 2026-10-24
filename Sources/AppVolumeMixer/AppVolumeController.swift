import CoreAudio
import Foundation
import os

/// Owns one process tap + one private aggregate device for a single app, and
/// re-renders that app's audio to the real output device scaled by `gain`.
///
/// Lifecycle: created lazily the moment an app is turned away from 100%, and
/// torn down when it returns to 100% (so untouched apps play natively and are
/// never routed through us).
@available(macOS 14.4, *)
final class AppVolumeController {

    let pid: pid_t
    private let processObject: AudioObjectID

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?

    /// Realtime-read gain. Heap-allocated so the audio callback reads a stable
    /// address without touching Swift ARC / the owning object.
    private let gainPtr: UnsafeMutablePointer<Float>

    /// Peak |input sample| observed by the IO callback (for silent-capture
    /// detection). Written on the realtime thread, read on the main thread.
    private let peakPtr: UnsafeMutablePointer<Float>

    private static let log = Logger(subsystem: "AppVolumeMixer", category: "controller")

    /// Non-nil message if setup failed (surfaced in the UI).
    private(set) var lastError: String?

    init(pid: pid_t, processObject: AudioObjectID, initialGain: Float) {
        self.pid = pid
        self.processObject = processObject
        self.gainPtr = .allocate(capacity: 1)
        self.gainPtr.initialize(to: initialGain)
        self.peakPtr = .allocate(capacity: 1)
        self.peakPtr.initialize(to: 0)
    }

    var gain: Float {
        get { gainPtr.pointee }
        set { gainPtr.pointee = max(0, newValue) }
    }

    /// Read and reset the peak input level seen since the last call.
    func consumePeak() -> Float {
        let v = peakPtr.pointee
        peakPtr.pointee = 0
        return v
    }

    var isActive: Bool { aggregateID != 0 && ioProcID != nil }

    // MARK: - Start

    /// Build tap -> aggregate -> IOProc and start rendering. Returns false on failure.
    @discardableResult
    func start() -> Bool {
        guard !isActive else { return true }

        // 1. Create a private tap that mutes the app's own output and hands the
        //    samples to us instead.
        let desc = CATapDescription(stereoMixdownOfProcesses: [processObject])
        desc.name = "AppVolume tap \(pid)"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped

        var newTap: AudioObjectID = 0
        var status = AudioHardwareCreateProcessTap(desc, &newTap)
        guard status == noErr, newTap != 0 else {
            fail("Could not create audio tap (status \(status)). Grant audio-recording permission in System Settings › Privacy & Security.")
            return false
        }
        tapID = newTap

        guard let tapUID = CA.string(tapID, kAudioTapPropertyUID) else {
            fail("Could not read tap UID.")
            stop()
            return false
        }

        // 2. Resolve the real output device we will render into.
        let outputDevice = CA.defaultOutputDevice
        guard outputDevice != 0, let outputUID = CA.deviceUID(outputDevice) else {
            fail("No default output device.")
            stop()
            return false
        }

        // 3. Wrap tap + output device into a private aggregate device.
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
            fail("Could not create aggregate device (status \(status)).")
            stop()
            return false
        }
        aggregateID = newAgg

        // 4. Install a realtime IO block: copy the tapped audio to the output
        //    buffers, scaled by the current gain.
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
                    // Zero any trailing bytes the input didn't cover.
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
            fail("Could not create IO proc (status \(status)).")
            stop()
            return false
        }
        ioProcID = proc

        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else {
            fail("Could not start audio device (status \(status)).")
            stop()
            return false
        }

        lastError = nil
        Self.log.info("Started volume control for pid \(self.pid)")
        return true
    }

    // MARK: - Stop / teardown

    func stop() {
        if let proc = ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil

        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    private func fail(_ message: String) {
        lastError = message
        Self.log.error("pid \(self.pid): \(message)")
    }

    deinit {
        stop()
        gainPtr.deinitialize(count: 1)
        gainPtr.deallocate()
        peakPtr.deinitialize(count: 1)
        peakPtr.deallocate()
    }
}
