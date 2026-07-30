import SwiftUI

/// Edits one application's name and icon together.
///
/// Both live here because they are the same job: making a row recognisable.
/// Splitting "rename" from "change icon" into two places would mean opening two
/// things to fix one unhelpful entry like `callservicesd`.
///
/// Reached from the row's pencil, a double-click on its icon, and its context
/// menu. The double-click-to-rename shortcut on the *name* is untouched — this
/// is the fuller route to the same thing.
struct CustomizeAppSheet: View {
    let app: AppMix
    let engine: MixerEngine

    @Environment(\.dismiss) private var dismiss
    @Environment(\.themeAccent) private var accent

    /// Uncommitted, so Cancel is a real cancel.
    @State private var name: String
    @State private var style: AppIconStyle

    init(app: AppMix, engine: MixerEngine) {
        self.app = app
        self.engine = engine
        _name = State(initialValue: app.customName ?? "")
        _style = State(initialValue: engine.iconStyle(for: app))
    }

    private var isGenerated: Bool { style.source == .generated }

    /// What the row will show once Done is pressed.
    private var previewName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? app.name : trimmed
    }

    private var previewHue: Double {
        GeneratedIcon.hue(style, bundleID: app.bundleID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            iconSection
            Divider()
            footer
        }
        // Wide enough that the thirteen colour chips sit on one line. At 400
        // they wrapped, which pushed the buttons off a minimum-height window.
        .frame(width: 440)
    }

    // MARK: - Header

    /// Preview and name side by side, over a bloom of the tile's own colour —
    /// so the thing being edited is the thing you look at first, and changing a
    /// swatch visibly changes the whole header rather than one small square.
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            preview
                .background {
                    if isGenerated {
                        Circle()
                            .fill(Color(hue: previewHue / 360, saturation: 0.7, brightness: 0.85))
                            .frame(width: 96, height: 96)
                            .blur(radius: 34)
                            .opacity(0.55)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: previewHue)
                .animation(.easeOut(duration: 0.18), value: style.source)

            VStack(alignment: .leading, spacing: 6) {
                Text(previewName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                TextField(app.name, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))

                Text("Leave empty to use the name macOS reports.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
    }

    @ViewBuilder
    private var preview: some View {
        if !isGenerated, let image = app.icon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
        } else {
            GeneratedIconTile(
                hue: previewHue,
                isSolid: style.isSolid,
                letters: GeneratedIcon.letters(style, displayName: previewName),
                size: 64
            )
        }
    }

    // MARK: - Icon

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Icon", selection: $style.source) {
                Text("App Icon").tag(AppIconSource.appIcon)
                Text("Generated").tag(AppIconSource.generated)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            // Label-left / control-right for all three, so they read as one
            // column instead of three stacked headings.
            VStack(alignment: .leading, spacing: 11) {
                field("Style") {
                    Picker("Style", selection: $style.isSolid) {
                        Text("Gradient").tag(false)
                        Text("Solid").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }

                field("Colour") {
                    HStack(spacing: 5) {
                        automaticSwatch
                        ForEach(GeneratedIcon.hues, id: \.self) { swatch($0) }
                    }
                }

                field("Letters") {
                    HStack(spacing: 9) {
                        TextField(GeneratedIcon.automaticLetters(for: previewName),
                                  text: lettersBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12.5))
                            .frame(width: 56)
                        Text("Up to two characters")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            // Disabled rather than hidden: hiding these would make the sheet
            // change height every time the segment is toggled.
            .disabled(!isGenerated)
            .opacity(isGenerated ? 1 : 0.4)
        }
        .padding(18)
    }

    private func field<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }

    /// Clamped as it is typed, so the preview can never show more than the tile
    /// will actually render.
    private var lettersBinding: Binding<String> {
        Binding(
            get: { style.letters ?? "" },
            set: { style.letters = String($0.prefix(2)).uppercased() }
        )
    }

    private var automaticSwatch: some View {
        let isSelected = style.isAutomaticHue

        return Button {
            style.hue = nil
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .frame(width: 21, height: 21)
                .overlay {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                }
                .overlay { selectionRing(isSelected) }
        }
        .buttonStyle(.plain)
        .help("Derived from the app's bundle identifier")
        .accessibilityLabel("Automatic colour")
    }

    private func swatch(_ hue: Double) -> some View {
        let isSelected = style.hue == hue

        return Button {
            style.hue = hue
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(GeneratedIcon.fill(hue: hue, isSolid: style.isSolid))
                .frame(width: 21, height: 21)
                .overlay { selectionRing(isSelected) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colour \(Int(hue))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Drawn outside the fill so selection never changes a swatch's apparent
    /// size — the same reason the theme swatches did it this way.
    private func selectionRing(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(isSelected ? 0.85 : 0), lineWidth: 2)
            .padding(-3)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Reset") {
                // Clears the name and the icon together. "Reset" on a sheet
                // that edits both would be a lie if it only undid half.
                engine.rename(app, to: "")
                engine.setIconStyle(.default, for: app)
                dismiss()
            }
            .help("Restore the original name and icon")

            Spacer(minLength: 0)

            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Done") {
                // rename() already treats blank or unchanged as "clear the
                // override" rather than storing a duplicate.
                engine.rename(app, to: name)
                engine.setIconStyle(style, for: app)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
