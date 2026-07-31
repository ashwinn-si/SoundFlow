import AppKit
import SwiftUI

/// Who made it, and where to find them.
///
/// Link rows rather than a paragraph with a URL in it: an icon tile in the
/// brand's own colour is recognisable before the label is read, and a row that
/// looks tappable invites the tap.
struct DeveloperView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                AboutCard(title: "Links", symbol: "link") {
                    LinkRow(
                        title: "GitHub",
                        subtitle: "github.com/ashwinn-si",
                        symbol: "chevron.left.forwardslash.chevron.right",
                        tile: Color(.sRGB, red: 0.12, green: 0.14, blue: 0.16),
                        url: URL(string: "https://github.com/ashwinn-si")!
                    )

                    Divider()

                    LinkRow(
                        title: "LinkedIn",
                        subtitle: "linkedin.com/in/ashwinsi",
                        // SF Symbols ships no brand logos. Rather than fake one,
                        // each row is identified by its brand colour plus the
                        // wordmark — which for LinkedIn is literally "in".
                        wordmark: "in",
                        tile: Color(.sRGB, red: 0.04, green: 0.40, blue: 0.76),
                        url: URL(string: "https://www.linkedin.com/in/ashwinsi/")!
                    )
                }
            }
            .padding(14)
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            // Reuses the app's own generated-tile look, so the page belongs to
            // the same design as the mixer rows rather than importing a
            // portrait from nowhere.
            GeneratedIconTile(hue: 252, isSolid: false, letters: "AS", size: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text("Ashwin SI")
                    .font(.system(size: 17, weight: .semibold))
                Text("Developer")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }
}

/// The app's own version and what it runs on.
struct VersionView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                AboutCard(title: "Requirements", symbol: "checklist") {
                    SpecRow(symbol: "desktopcomputer", label: "macOS", value: "15 or later")
                    Divider()
                    SpecRow(symbol: "swift", label: "Swift", value: "6")
                    Divider()
                    SpecRow(symbol: "cpu", label: "Architecture", value: "Native arm64")
                }

                AboutCard(title: "What's New", symbol: "sparkles") {
                    VStack(alignment: .leading, spacing: 6) {
                        bullet("The output slider now follows the Mac's own volume, both ways.")
                        bullet("Mute the output or the mic from the speaker icon.")
                        bullet("The playing indicator flattens to a line for a muted app.")
                        bullet("Playback is picked up as it starts, not seconds later.")
                        bullet("A new app icon, drawn from the app's own accent and shapes.")
                    }
                }
            }
            .padding(14)
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text("SoundFlow")
                    .font(.system(size: 17, weight: .semibold))
                Text("Version \(Self.version) (\(Self.build))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(.tertiary)
                .frame(width: 3.5, height: 3.5)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Read from the bundle so it cannot drift from `Info.plist`.
    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}

// MARK: - Pieces

/// The same card shape `DevicesView` uses, so About does not look like a
/// different app.
private struct AboutCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// An external link, drawn as a tappable row.
private struct LinkRow: View {
    let title: String
    let subtitle: String
    var symbol: String?
    var wordmark: String?
    let tile: Color
    let url: URL

    @State private var isHovering = false

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tile)
                    .frame(width: 28, height: 28)
                    .overlay {
                        if let symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        } else if let wordmark {
                            Text(wordmark)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        // Not the default link style: it hardcodes the system blue and ignores
        // the theme tint, which left these rows off-theme.
        .buttonStyle(.plain)
        .background {
            if isHovering {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
                    .padding(.horizontal, -6)
            }
        }
        .onHover { isHovering = $0 }
    }
}

private struct SpecRow: View {
    let symbol: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12))
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
}
