import SwiftUI

/// Edits one application's name and icon together.
///
/// Both live here because they are the same job: making a row recognisable.
/// Splitting "rename" from "change icon" into two places would mean opening two
/// things to fix one unhelpful entry like `callservicesd`.
///
/// Reached from the row's pencil and its context menu. The double-click-to-
/// rename shortcut on the name is untouched — this is the discoverable route to
/// the same thing, plus the icon.
struct CustomizeAppSheet: View {
    let app: AppMix
    let engine: MixerEngine

    @Environment(\.dismiss) private var dismiss

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

    /// What the row will look like once Done is pressed.
    private var previewName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? app.name : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            nameField
            sourcePicker
            generatedOptions
            Divider()
            footer
        }
        .padding(14)
        // 400 rather than 320: at 320 the thirteen colour chips wrap to a second
        // row and push the buttons off the bottom of a minimum-height window.
        .frame(width: 400)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 13) {
            preview

            VStack(alignment: .leading, spacing: 2) {
                Text(previewName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text("Name and icon")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if !isGenerated, let image = app.icon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
        } else {
            GeneratedIconTile(
                hue: GeneratedIcon.hue(style, bundleID: app.bundleID),
                isSolid: style.isSolid,
                letters: GeneratedIcon.letters(style, displayName: previewName),
                size: 56
            )
        }
    }

    // MARK: - Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("Name")
            TextField(app.name, text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
            Text("Leave empty to use the name macOS reports.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Icon source

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel("Icon")
            Picker("Icon", selection: $style.source) {
                Text("App Icon").tag(AppIconSource.appIcon)
                Text("Generated").tag(AppIconSource.generated)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    /// Disabled rather than hidden when the real icon is in use: hiding them
    /// would make the sheet change height every time the segment is toggled.
    private var generatedOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Style")
                Picker("Style", selection: $style.isSolid) {
                    Text("Gradient").tag(false)
                    Text("Solid").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Colour")
                HStack(spacing: 6) {
                    automaticSwatch
                    ForEach(GeneratedIcon.hues, id: \.self) { hue in
                        swatch(hue)
                    }
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Letters")
                HStack(spacing: 10) {
                    TextField(GeneratedIcon.automaticLetters(for: previewName),
                              text: lettersBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5))
                        .frame(width: 70)
                    Text("Up to two characters.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(!isGenerated)
        .opacity(isGenerated ? 1 : 0.45)
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
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
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
                .frame(width: 22, height: 22)
                .overlay { selectionRing(isSelected) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Drawn outside the fill so selection never changes a swatch's apparent
    /// size — the same reason the old theme swatches did it this way.
    private func selectionRing(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(isSelected ? 0.85 : 0), lineWidth: 2)
            .padding(-3)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Reset") {
                // Clears the name and the icon together. "Reset" on a sheet that
                // edits both would be a lie if it only undid half.
                engine.rename(app, to: "")
                engine.setIconStyle(.default, for: app)
                dismiss()
            }

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
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.tertiary)
    }
}
