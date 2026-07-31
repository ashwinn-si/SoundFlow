import CoreAudio
import SwiftUI
import SoundFlowCore

/// Output and input device selection, with each device's own level.
///
/// Split out of the mixer header: picking a device is something you do
/// occasionally, so it does not deserve permanent space above the app list.
struct DevicesView: View {
    let engine: MixerEngine

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                card(
                    title: "Output",
                    symbol: "speaker.wave.2.fill",
                    devices: engine.outputDevices,
                    selection: outputSelection,
                    detail: engine.outputDevices.first { $0.id == engine.outputDeviceID }
                ) {
                    if engine.hasMasterVolumeControl {
                        LevelSlider(
                            symbol: "speaker.fill",
                            value: Binding(
                                get: { Double(engine.masterVolume) },
                                set: { engine.setMasterVolume(Float($0)) }
                            ),
                            isMuted: Binding(
                                get: { engine.isOutputMuted },
                                set: { engine.setOutputMuted($0) }
                            )
                        )
                    } else {
                        unavailable("This device has no software volume control.")
                    }
                }

                if engine.inputDevices.isEmpty {
                    ContentUnavailableView(
                        "No Input Devices",
                        systemImage: "mic.slash",
                        description: Text("Connect a microphone to control its level here.")
                    )
                    .padding(.top, 20)
                } else {
                    card(
                        title: "Input",
                        symbol: "mic.fill",
                        devices: engine.inputDevices,
                        selection: inputSelection,
                        detail: engine.inputDevices.first { $0.id == engine.inputDeviceID }
                    ) {
                        if engine.hasInputVolumeControl {
                            LevelSlider(
                                symbol: "mic.fill",
                                value: Binding(
                                    get: { Double(engine.inputVolume) },
                                    set: { engine.setInputVolume(Float($0)) }
                                ),
                                isMuted: Binding(
                                    get: { engine.isInputMuted },
                                    set: { engine.setInputMuted($0) }
                                )
                            )
                        } else {
                            unavailable("This microphone has no software gain control.")
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func card<Control: View>(
        title: String,
        symbol: String,
        devices: [AudioDeviceItem],
        selection: Binding<AudioObjectID>,
        detail: AudioDeviceItem?,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Picker(title, selection: selection) {
                ForEach(devices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            control()

            if let detail, detail.transportType != "Unknown" {
                Text(detail.transportType)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func unavailable(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    // MARK: - Selection

    /// Matched on device id, not name — see `MixerView.outputSelection`.
    private var outputSelection: Binding<AudioObjectID> {
        Binding(
            get: { engine.outputDeviceID },
            set: { newID in
                if let device = engine.outputDevices.first(where: { $0.id == newID }) {
                    engine.selectOutputDevice(device)
                }
            }
        )
    }

    private var inputSelection: Binding<AudioObjectID> {
        Binding(
            get: { engine.inputDeviceID },
            set: { newID in
                if let device = engine.inputDevices.first(where: { $0.id == newID }) {
                    engine.selectInputDevice(device)
                }
            }
        )
    }
}

// MARK: - LevelSlider

/// A labelled 0–100% slider. Shared by the device cards and the mixer's own
/// master row so they stay visually identical.
///
/// The leading glyph becomes a mute button when `isMuted` is supplied. That is
/// the device's own mute — the same one F10 toggles — so it has to be here
/// rather than implied by a level of zero: muting does not change the scalar,
/// and a slider sitting at 81% for a silent Mac is a lie.
struct LevelSlider: View {
    let symbol: String
    @Binding var value: Double
    var isMuted: Binding<Bool>?

    var body: some View {
        HStack(spacing: 8) {
            if let isMuted {
                Button {
                    isMuted.wrappedValue.toggle()
                } label: {
                    glyph(muted: isMuted.wrappedValue)
                }
                .buttonStyle(.borderless)
                .help(isMuted.wrappedValue ? "Unmute" : "Mute")
                .accessibilityLabel(isMuted.wrappedValue ? "Unmute" : "Mute")
            } else {
                glyph(muted: false)
            }

            Slider(value: $value, in: 0...1)
                .controlSize(.small)

            Text("\(Int(value * 100))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
                // Muted is the state the number cannot express on its own.
                .opacity(isMuted?.wrappedValue == true ? 0.4 : 1)
        }
    }

    /// Same threshold ladder as `AppRowView.muteSymbol`, so a device row and an
    /// app row never disagree about what a given level looks like. The caller's
    /// `symbol` is the unmuted shape for anything that is not a speaker.
    private func glyph(muted: Bool) -> some View {
        Image(systemName: muted ? mutedSymbol : symbol)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(width: 14)
    }

    private var mutedSymbol: String {
        symbol.hasPrefix("mic") ? "mic.slash.fill" : "speaker.slash.fill"
    }
}
