import SwiftUI

/// The three surfaces of the main window.
enum MixerTab: String, CaseIterable, Identifiable {
    case mixer
    case devices
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mixer:    "Mixer"
        case .devices:  "Devices"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .mixer:    "slider.vertical.3"
        case .devices:  "hifispeaker.and.homepod"
        case .settings: "gearshape"
        }
    }
}

/// Top navigation for the main window.
///
/// Deliberately not a `Picker(.segmented)`: the pills carry symbols, sit on the
/// window's own material rather than a control background, and let the accent
/// do the work of showing selection. A matched-geometry highlight slides
/// between them so switching reads as movement rather than a repaint.
struct NavBar: View {
    @Binding var selection: MixerTab

    @Environment(\.themeAccent) private var accent
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MixerTab.allCases) { tab in
                item(for: tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func item(for tab: MixerTab) -> some View {
        let isSelected = selection == tab

        return Button {
            // Spring rather than easeInOut: the highlight is travelling a
            // distance, and a little overshoot makes it feel physical.
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                selection = tab
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(tab.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accent.opacity(0.14))
                        .matchedGeometryEffect(id: "navHighlight", in: highlight)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
