import SwiftUI
import SoundFlowCore

struct CustomizeDeviceSheet: View {
    let device: AudioDeviceItem
    let engine: MixerEngine

    @Environment(\.dismiss) private var dismiss

    @State private var name: String

    init(device: AudioDeviceItem, engine: MixerEngine) {
        self.device = device
        self.engine = engine
        _name = State(initialValue: device.customName ?? "")
    }

    private var previewName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? device.name : trimmed
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: device.isOutput ? "speaker.wave.2.fill" : "mic.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(previewName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                TextField(device.name, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))

                Text("Leave empty to use the original device name.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Reset") {
                engine.renameDevice(device, to: "")
                dismiss()
            }
            .help("Restore the original name")

            Spacer(minLength: 0)

            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Done") {
                engine.renameDevice(device, to: name)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
