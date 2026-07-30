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
                    detail: engine.outputDevices.first { $0.id == outputSelection.wrappedValue }
                ) {
                    if engine.hasMasterVolumeControl {
                        LevelSlider(
                            symbol: "speaker.fill",
                            value: Binding(
                                get: { Double(engine.masterVolume) },
                                set: { engine.masterVolume = Float($0) }
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
                                    set: { engine.inputVolume = Float($0) }
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

    private var outputSelection: Binding<AudioObjectID> {
        Binding(
            get: { engine.outputDevices.first { $0.name == engine.outputDeviceName }?.id ?? 0 },
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
struct LevelSlider: View {
    let symbol: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Slider(value: $value, in: 0...1)
                .controlSize(.small)

            Text("\(Int(value * 100))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
