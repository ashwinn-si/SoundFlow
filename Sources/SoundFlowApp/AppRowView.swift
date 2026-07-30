import SwiftUI

/// One application: icon, name, volume slider, percentage, mute.
///
/// The slider is live immediately — there is no "activate" step. Leaving an app
/// at 100% means it is never tapped at all, so the control is safe to touch.
struct AppRowView: View {
    @Bindable var app: AppMix
    let engine: MixerEngine
    /// The pencil and the star. Both are hidden in the menu bar popover: it is
    /// already filtered to stars, and editing belongs in the window.
    var showsRowActions = true
    /// Raised so the window can host one sheet rather than one per row.
    var onEdit: (AppMix) -> Void = { _ in }

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
                        PlayingIndicator()
                            .accessibilityLabel("Playing")
                    }

                    Spacer(minLength: 0)

                    Text(statusText)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)

                    if showsRowActions {
                        editButton
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
        .opacity(app.isDRMProtected ? 0.5 : (app.isActive ? 1 : 0.65))
        .help(rowHelp)
        .contextMenu {
            Button("Edit Name & Icon…") { onEdit(app) }
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

    /// The discoverable route to renaming, and the only route to the icon.
    /// Double-clicking the name still works and is left exactly as it was.
    private var editButton: some View {
        Button {
            onEdit(app)
        } label: {
            // `square.and.pencil` rather than `pencil`: at row size a bare
            // pencil is one thin diagonal stroke and reads as a slash. The
            // enclosing box is what makes it legible — weight and colour alone
            // do not rescue it.
            Image(systemName: "square.and.pencil")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .help("Edit name and icon")
        .accessibilityLabel("Edit name and icon")
    }

    // MARK: - Status

    private var statusText: String {
        if app.isDRMProtected { return "Protected" }
        if !app.isActive { return "Not running" }
        return "\(Int(app.volume * 100))%"
    }

    private var rowHelp: String {
        if app.isDRMProtected {
            return "macOS does not allow volume control for DRM-protected audio."
        }
        if !app.isActive {
            return "Starred, but not playing audio right now. "
                 + "This level applies the next time it does."
        }
        return ""
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

    /// The app's own icon, or the tile it was given in the editor. An app with
    /// no icon at all falls through to a generated tile rather than the grey
    /// `app.dashed` placeholder this used to draw.
    ///
    /// Double-click opens the editor, matching the double-click-to-rename on
    /// the name beside it. Gated on `showsRowActions` for the same reason the
    /// pencil is: the sheet is far wider than the 320pt popover.
    private var icon: some View {
        AppIconView(app: app, style: engine.iconStyle(for: app))
            .onTapGesture(count: 2) {
                guard showsRowActions else { return }
                onEdit(app)
            }
            .help(showsRowActions ? "Double-click to edit name and icon" : "")
    }

    private var muteSymbol: String {
        if app.isMuted { return "speaker.slash.fill" }
        if app.volume < 0.01 { return "speaker.fill" }
        if app.volume < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }
}

// MARK: - PlayingIndicator

/// Four bars pulsing on a loop, marking an app that is producing audio.
///
/// Deliberately **not** driven by the audio level, which is what the previous
/// version did and why it was replaced. Only a tapped app produces RMS, and
/// invariant 8 means an app left at 100% is never tapped — so its level was
/// permanently zero, every bar collapsed to its 2pt minimum, and the row showed
/// three dots that read as a truncated name. A real meter that is flat for
/// exactly the apps the user has not touched is worse than no meter: it looks
/// broken, and it is silent about the one thing it is there to say.
///
/// This says only "this app is playing", and says it the same way for every
/// app.
struct PlayingIndicator: View {

    @Environment(\.themeAccent) private var accent
    @State private var isAnimating = false

    /// Heights and rates are all coprime-ish so the group never falls into step
    /// and starts pulsing as one block.
    private let bars: [(height: CGFloat, duration: Double)] = [
        (9, 0.52), (14, 0.37), (11, 0.61), (13, 0.44)
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(bars.indices, id: \.self) { index in
                Capsule()
                    .fill(accent)
                    .frame(width: 2.5, height: bars[index].height)
                    // Centre-anchored, so it reads as a waveform pulse rather
                    // than a VU meter promising a level it is not showing.
                    .scaleEffect(y: isAnimating ? 1 : 0.3, anchor: .center)
                    .animation(
                        .easeInOut(duration: bars[index].duration)
                            .repeatForever(autoreverses: true),
                        value: isAnimating
                    )
            }
        }
        .frame(height: 14)
        .opacity(0.9)
        .onAppear { isAnimating = true }
    }
}
