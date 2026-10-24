import SwiftUI
import CoreAudio
import AVFoundation

/// Top-level view model. Tracks which apps are playing audio and owns one
/// `AppVolumeController` per app the user has turned away from 100%.
@available(macOS 14.4, *)
@MainActor
final class Mixer: ObservableObject {

    @Published private(set) var apps: [AudioProcessInfo] = []
    /// Volume per pid, 0.0...1.5 (100% = untouched / native passthrough).
    @Published var volumes: [pid_t: Float] = [:]
    @Published var errors: [pid_t: String] = [:]
    /// Microphone/audio-capture permission — process taps are gated by it.
    @Published var authStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    private var controllers: [pid_t: AppVolumeController] = [:]
    private var refreshTimer: Timer?

    static let maxVolume: Float = 1.5   // allow up to 150% boost

    var isAuthorized: Bool { authStatus == .authorized }

    /// Ask for audio-capture permission. Triggers the system prompt the first
    /// time and registers the app in Privacy & Security afterwards.
    func requestPermission() {
        authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard authStatus == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in
                self.authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func begin() {
        requestPermission()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Re-scan the audio process list; keep controllers for apps still alive.
    func refresh() {
        let current = AudioProcessEnumerator.currentAudioApps()
        apps = current

        let livePIDs = Set(current.map(\.pid))
        for pid in controllers.keys where !livePIDs.contains(pid) {
            controllers[pid]?.stop()
            controllers[pid] = nil
            volumes[pid] = nil
            errors[pid] = nil
        }
        // Default any newly-seen app to 100%.
        for app in current where volumes[app.pid] == nil {
            volumes[app.pid] = 1.0
        }
    }

    func icon(for pid: pid_t) -> NSImage? {
        AudioProcessEnumerator.icon(for: pid)
    }

    /// Apply a new volume to an app, creating or tearing down its controller.
    func setVolume(_ value: Float, for app: AudioProcessInfo) {
        let clamped = min(max(value, 0), Self.maxVolume)
        volumes[app.pid] = clamped

        // Within 1% of unity -> native passthrough, no tap needed.
        if abs(clamped - 1.0) < 0.01 {
            controllers[app.pid]?.stop()
            controllers[app.pid] = nil
            errors[app.pid] = nil
            return
        }

        if let controller = controllers[app.pid] {
            controller.gain = clamped
        } else {
            let controller = AppVolumeController(pid: app.pid,
                                                 processObject: app.id,
                                                 initialGain: clamped)
            if controller.start() {
                controllers[app.pid] = controller
                errors[app.pid] = nil
                scheduleSilentCaptureCheck(for: app.pid)
            } else {
                errors[app.pid] = controller.lastError ?? "Failed to start"
            }
        }
    }

    /// After a controller starts, verify it's actually receiving audio. If the
    /// tap is silent (almost always missing permission), surface a clear hint.
    private func scheduleSilentCaptureCheck(for pid: pid_t) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let controller = controllers[pid], controller.isActive else { return }
            if controller.consumePeak() == 0 {
                if !isAuthorized {
                    errors[pid] = "No audio captured — grant Microphone permission to AppVolume, then quit & reopen."
                } else {
                    errors[pid] = "No audio from this app (it may be paused)."
                }
            } else {
                errors[pid] = nil
            }
        }
    }

    func resetAll() {
        for (_, controller) in controllers { controller.stop() }
        controllers.removeAll()
        for key in volumes.keys { volumes[key] = 1.0 }
        errors.removeAll()
    }

    func shutdown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        for (_, controller) in controllers { controller.stop() }
        controllers.removeAll()
    }
}
