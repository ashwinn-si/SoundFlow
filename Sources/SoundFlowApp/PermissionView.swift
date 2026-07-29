import SwiftUI

/// Shown in place of the mixer when audio capture is not permitted.
///
/// This matters more than it looks: without the permission macOS does not fail,
/// it silently delivers empty audio. Every app would appear at its set volume
/// while nothing actually changed. Blocking the UI here makes the real state
/// obvious instead of leaving the user to wonder why the sliders do nothing.
struct PermissionView: View {
    let engine: MixerEngine

    var body: some View {
        ContentUnavailableView {
            Label("Permission Required", systemImage: "waveform.badge.exclamationmark")
        } description: {
            Text("""
            SoundFlow needs Screen & System Audio Recording to control each \
            application's volume. Audio is processed on this Mac and never \
            recorded or sent anywhere.
            """)
        } actions: {
            VStack(spacing: 8) {
                Button("Open System Settings") {
                    engine.openPermissionSettings()
                }
                .buttonStyle(.borderedProminent)

                Button("Check Again") {
                    engine.refreshPermission()
                }
                .buttonStyle(.borderless)

                Text("Enable SoundFlow in the list, then return here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
