import CoreAudio
import AppKit
import Darwin

/// A process known to the audio system, resolved to a human-friendly app.
struct AudioProcessInfo: Identifiable, Equatable {
    let id: AudioObjectID   // Core Audio process-object id (what taps expect)
    let pid: pid_t
    let bundleID: String?
    var name: String
    var isPlaying: Bool

    static func == (lhs: AudioProcessInfo, rhs: AudioProcessInfo) -> Bool {
        lhs.id == rhs.id && lhs.isPlaying == rhs.isPlaying && lhs.name == rhs.name
    }
}

@available(macOS 14.4, *)
enum AudioProcessEnumerator {

    /// All process objects currently registered with the HAL.
    static func allProcessObjects() -> [AudioObjectID] {
        CA.array(CA.systemObject, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
    }

    static func pid(of processObject: AudioObjectID) -> pid_t {
        CA.scalar(processObject, kAudioProcessPropertyPID, default: pid_t(-1))
    }

    static func bundleID(of processObject: AudioObjectID) -> String? {
        CA.string(processObject, kAudioProcessPropertyBundleID)
    }

    /// True while the process is actively producing output audio.
    static func isRunningOutput(_ processObject: AudioObjectID) -> Bool {
        CA.scalar(processObject, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
    }

    // MARK: - Name resolution (walk helper -> owning app)

    /// Parent pid of a process, via sysctl.
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let r = mib.withUnsafeMutableBufferPointer { buf in
            sysctl(buf.baseAddress, 4, &info, &size, nil, 0)
        }
        guard r == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// Audio often comes from a helper child process (e.g. "Google Chrome
    /// Helper (Renderer)"). Walk up the parent chain to the first *regular*
    /// GUI app so we can show its real name + icon.
    private static func owningApp(for pid: pid_t) -> NSRunningApplication? {
        var current: pid_t? = pid
        var hops = 0
        while let p = current, hops < 10 {
            if let app = NSRunningApplication(processIdentifier: p),
               app.activationPolicy == .regular {
                return app
            }
            let parent = parentPID(of: p)
            if parent == nil || parent == p || parent == 0 || parent == 1 { break }
            current = parent
            hops += 1
        }
        // Fall back to whatever app object matches the original pid, if any.
        return NSRunningApplication(processIdentifier: pid)
    }

    private static func displayName(pid: pid_t, bundleID: String?) -> String {
        if let app = owningApp(for: pid), let n = app.localizedName {
            return n
        }
        if let bundleID {
            // Clean "com.google.Chrome.helper.Renderer" -> "Chrome"
            let base = bundleID
                .replacingOccurrences(of: ".helper", with: "")
                .components(separatedBy: ".")
            // Prefer a segment that isn't a generic reverse-DNS token.
            if let meaningful = base.reversed().first(where: {
                !["com", "org", "io", "app", "renderer", "gpu", "plugin"].contains($0.lowercased())
            }) {
                return meaningful.capitalized
            }
            return bundleID
        }
        return "PID \(pid)"
    }

    /// Build the list the UI shows: apps currently outputting audio, resolved
    /// to friendly names. Multiple helper processes of one app are merged.
    static func currentAudioApps() -> [AudioProcessInfo] {
        var byOwner: [pid_t: AudioProcessInfo] = [:]   // keyed by owning-app pid

        for obj in allProcessObjects() {
            let processPID = pid(of: obj)
            guard processPID > 0, isRunningOutput(obj) else { continue }

            let bundle = bundleID(of: obj)
            let owner = owningApp(for: processPID)
            let key = owner?.processIdentifier ?? processPID
            let name = displayName(pid: processPID, bundleID: bundle)

            // Keep one entry per owning app; the tap still targets the specific
            // audio-producing process object (obj), which is what we store as id.
            if byOwner[key] == nil {
                byOwner[key] = AudioProcessInfo(id: obj, pid: processPID,
                                                bundleID: bundle, name: name, isPlaying: true)
            }
        }

        return byOwner.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func icon(for pid: pid_t) -> NSImage? {
        owningApp(for: pid)?.icon
    }
}
