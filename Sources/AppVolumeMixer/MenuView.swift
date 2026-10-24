import SwiftUI

@available(macOS 14.4, *)
struct MenuView: View {
    @ObservedObject var mixer: Mixer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("App Volume").font(.headline)
                Spacer()
                Button {
                    mixer.resetAll()
                } label: {
                    Text("Reset all").font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if !mixer.isAuthorized {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Audio permission needed", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("App Volume needs Microphone/Audio access to re-render other apps' sound. Without it, apps go silent instead of quieter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Grant permission") { mixer.requestPermission() }
                        Button("Open Settings") { mixer.openPrivacySettings() }
                    }
                    .font(.caption)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                Divider()
            }

            if mixer.apps.isEmpty {
                Text("No apps are playing audio right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(mixer.apps) { app in
                            AppRow(mixer: mixer, app: app)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 340)
            }

            Divider()

            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 320)
    }
}

@available(macOS 14.4, *)
private struct AppRow: View {
    @ObservedObject var mixer: Mixer
    let app: AudioProcessInfo

    private var volume: Binding<Double> {
        Binding(
            get: { Double(mixer.volumes[app.pid] ?? 1.0) },
            set: { mixer.setVolume(Float($0), for: app) }
        )
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                if let icon = mixer.icon(for: app.pid) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app.dashed")
                        .frame(width: 20, height: 20)
                }
                Text(app.name).lineLimit(1)
                Spacer()
                Text("\(Int((mixer.volumes[app.pid] ?? 1.0) * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                Slider(value: volume, in: 0...Double(Mixer.maxVolume))
                Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.secondary)
            }

            if let err = mixer.errors[app.pid] {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}
