import SwiftUI

/// One application: icon, name, volume slider, percentage, mute.
///
/// The slider is live immediately — there is no "activate" step. Leaving an app
/// at 100% means it is never tapped at all, so the control is safe to touch.
struct AppRowView: View {
    @Bindable var app: AppMix
    let engine: MixerEngine

    var body: some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    if app.isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Playing")
                    }

                    Spacer(minLength: 0)

                    Text(app.isDRMProtected ? "Protected" : "\(Int(app.volume * 100))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { Double(app.volume) },
                            set: { engine.setVolume(Float($0), for: app) }
                        ),
                        in: 0...1
                    )
                    .controlSize(.small)
                    .disabled(app.isDRMProtected)

                    Button {
                        engine.setMuted(!app.isMuted, for: app)
                    } label: {
                        Image(systemName: muteSymbol)
                            .font(.system(size: 11))
                            .frame(width: 16)
                    }
                    .buttonStyle(.borderless)
                    .disabled(app.isDRMProtected)
                    .help(app.isMuted ? "Unmute" : "Mute")
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(app.isDRMProtected ? 0.5 : 1)
        .help(app.isDRMProtected
              ? "macOS does not allow volume control for DRM-protected audio."
              : "")
    }

    private var icon: some View {
        Group {
            if let image = app.icon {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var muteSymbol: String {
        if app.isMuted { return "speaker.slash.fill" }
        if app.volume < 0.01 { return "speaker.fill" }
        if app.volume < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }
}
