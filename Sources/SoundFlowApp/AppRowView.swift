import SwiftUI

/// One application: icon, name, volume slider, percentage, mute.
///
/// The slider is live immediately — there is no "activate" step. Leaving an app
/// at 100% means it is never tapped at all, so the control is safe to touch.
struct AppRowView: View {
    @Bindable var app: AppMix
    let engine: MixerEngine
    /// Hidden in the menu bar popover, which is already filtered to stars.
    var showsFavoriteToggle = true

    @State private var isEditingName = false
    @State private var draftName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isEditingName {
                        nameField
                    } else {
                        nameLabel
                    }

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

                    if showsFavoriteToggle {
                        favoriteButton
                    }
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
        .contextMenu {
            Button("Rename…") { beginRename() }
            if app.customName != nil {
                Button("Use Original Name (\(app.name))") { engine.rename(app, to: "") }
            }
            Divider()
            Button(app.isFavorite ? "Remove from Menu Bar" : "Show in Menu Bar") {
                engine.toggleFavorite(app)
            }
        }
    }

    // MARK: - Name

    /// Double-click to rename, matching Finder. The system name stays in the
    /// tooltip so a renamed row can still be traced back to its process.
    private var nameLabel: some View {
        Text(app.displayName)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .onTapGesture(count: 2) { beginRename() }
            .help(app.customName == nil ? "" : "Originally “\(app.name)”")
    }

    private var nameField: some View {
        TextField("Name", text: $draftName)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .focused($nameFieldFocused)
            .onSubmit { commitRename() }
            // Esc leaves the name untouched.
            .onExitCommand { isEditingName = false }
            // Clicking elsewhere commits, so an edit is never silently lost.
            .onChange(of: nameFieldFocused) { _, focused in
                if !focused && isEditingName { commitRename() }
            }
            .onAppear { nameFieldFocused = true }
    }

    private func beginRename() {
        draftName = app.displayName
        isEditingName = true
    }

    private func commitRename() {
        isEditingName = false
        engine.rename(app, to: draftName)
    }

    /// Starring only decides what the menu bar lists; it never changes volume,
    /// so it stays enabled even for DRM-protected apps.
    private var favoriteButton: some View {
        Button {
            engine.toggleFavorite(app)
        } label: {
            Image(systemName: app.isFavorite ? "star.fill" : "star")
                .font(.system(size: 11))
                .foregroundStyle(app.isFavorite
                                 ? AnyShapeStyle(.tint)
                                 : AnyShapeStyle(.tertiary))
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .help(app.isFavorite ? "Remove from menu bar" : "Show in menu bar")
        .accessibilityLabel(app.isFavorite ? "Starred" : "Not starred")
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
