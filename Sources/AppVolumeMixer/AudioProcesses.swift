import CoreAudio
import AppKit
import Darwin

/// A process known to the audio system, resolved to a human-friendly app.
struct AudioProcessInfo: Identifiable {
    let id: AudioObjectID   // Core Audio process-object id (what taps expect)
    let pid: pid_t
    let name: String
}

enum AudioProcessEnumerator {

    // MARK: - Name resolution (walk helper -> owning app)

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
            if parent == nil || parent == p || parent == 1 { break }
            current = parent
            hops += 1
        }
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

        let processObjects = CA.array(CA.systemObject, kAudioHardwarePropertyProcessObjectList,
                                      of: AudioObjectID.self)
        for obj in processObjects {
            let processPID = CA.scalar(obj, kAudioProcessPropertyPID, default: pid_t(-1))
            guard processPID > 0,
                  CA.scalar(obj, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            else { continue }

            let key = owningApp(for: processPID)?.processIdentifier ?? processPID

            // Keep one entry per owning app; the tap still targets the specific
            // audio-producing process object (obj), which is what we store as id.
            if byOwner[key] == nil {
                let bundleID = CA.string(obj, kAudioProcessPropertyBundleID)
                byOwner[key] = AudioProcessInfo(id: obj, pid: processPID,
                                                name: displayName(pid: processPID, bundleID: bundleID))
            }
        }

        return byOwner.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func icon(for pid: pid_t) -> NSImage? {
        owningApp(for: pid)?.icon
    }
}
