import SwiftUI
import CoreAudio
import AVFoundation

/// Top-level view model. Tracks which apps are playing audio and owns one
/// `AppVolumeController` per app the user has turned away from 100%.
@MainActor
final class Mixer: ObservableObject {

    /// Everything the mixer knows about one app, keyed by pid in `states`.
    private struct AppState {
        /// 0.0...`maxVolume`; `unity` means untouched / native passthrough.
        var volume: Float = Mixer.unity
        /// Present only while the app is routed through us.
        var controller: AppVolumeController?
        var error: String?
    }

    @Published private(set) var apps: [AudioProcessInfo] = []
    @Published private var states: [pid_t: AppState] = [:]
    /// Microphone/audio-capture permission — process taps are gated by it.
    @Published private var authStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    private var refreshTimer: Timer?

    nonisolated static let unity: Float = 1.0
    nonisolated static let maxVolume: Float = 1.5

    var isAuthorized: Bool { authStatus == .authorized }

    func volume(for pid: pid_t) -> Float { states[pid]?.volume ?? Self.unity }
    func error(for pid: pid_t) -> String? { states[pid]?.error }

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

    /// Re-scan the audio process list. A controlled app that is no longer
    /// outputting audio loses its controller and its state.
    func refresh() {
        let current = AudioProcessEnumerator.currentAudioApps()
        apps = current

        let livePIDs = Set(current.map(\.pid))
        for (pid, state) in states where state.controller != nil && !livePIDs.contains(pid) {
            states[pid] = nil
        }
        for app in current where states[app.pid] == nil {
            states[app.pid] = AppState()
        }
    }

    /// Apply a new volume to an app, creating or releasing its controller.
    func setVolume(_ value: Float, for app: AudioProcessInfo) {
        let clamped = min(max(value, 0), Self.maxVolume)
        var state = states[app.pid] ?? AppState()
        state.volume = clamped
        defer { states[app.pid] = state }

        // Within 1% of unity -> native passthrough, no tap needed.
        if abs(clamped - Self.unity) < 0.01 {
            state.controller = nil
            state.error = nil
            return
        }

        if let controller = state.controller {
            controller.setGain(clamped)
            return
        }

        do {
            state.controller = try AppVolumeController(pid: app.pid,
                                                       processObject: app.id,
                                                       initialGain: clamped)
            state.error = nil
            scheduleSilentCaptureCheck(for: app.pid)
        } catch let error as AppVolumeController.StartError {
            state.error = error.message
        } catch {
            state.error = "Failed to start"
        }
    }

    /// After a controller starts, verify it's actually receiving audio. If the
    /// tap is silent (almost always missing permission), surface a clear hint.
    private func scheduleSilentCaptureCheck(for pid: pid_t) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let controller = states[pid]?.controller else { return }
            if controller.consumePeak() == 0 {
                if !isAuthorized {
                    states[pid]?.error = "No audio captured — grant Microphone permission to AppVolume, then quit & reopen."
                } else {
                    states[pid]?.error = "No audio from this app (it may be paused)."
                }
            } else {
                states[pid]?.error = nil
            }
        }
    }

    func resetAll() {
        for pid in states.keys {
            states[pid] = AppState()
        }
    }

    func shutdown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        for pid in states.keys {
            states[pid]?.controller = nil
        }
    }
}
