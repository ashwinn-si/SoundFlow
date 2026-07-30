import AppKit
import SwiftUI

/// Where a row's icon comes from.
enum AppIconSource: String, Codable {
    /// Whatever macOS hands us for the bundle. The default: apps should look
    /// like themselves until the user says otherwise.
    case appIcon
    /// A tile minted by SoundFlow from the bundle id.
    case generated
}

/// How one application is drawn in the mixer.
///
/// Stored per bundle id in its own `UserDefaults` key — never as a field on
/// `AppPreference`, which would break decoding of every saved volume blob.
struct AppIconStyle: Codable, Equatable {
    var source: AppIconSource = .appIcon
    /// `nil` means "derive it from the bundle id".
    var hue: Double?
    var isSolid: Bool = false
    /// `nil` means "derive them from the display name". At most two characters.
    var letters: String?

    static let `default` = AppIconStyle()

    var isAutomaticHue: Bool { hue == nil }

    // MARK: - Decoding

    /// Written out by hand rather than synthesised.
    ///
    /// Synthesised `Codable` treats a missing key as a failure even when the
    /// property has a default, and the loader swallows that with `try?` — so
    /// adding one field later would silently reset everyone's icons. The same
    /// trap is already documented for `AppPreference`; this store is built to
    /// survive it from the start.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decodeIfPresent(AppIconSource.self, forKey: .source) ?? .appIcon
        hue = try container.decodeIfPresent(Double.self, forKey: .hue)
        isSolid = try container.decodeIfPresent(Bool.self, forKey: .isSolid) ?? false
        letters = try container.decodeIfPresent(String.self, forKey: .letters)
    }

    init(source: AppIconSource = .appIcon,
         hue: Double? = nil,
         isSolid: Bool = false,
         letters: String? = nil) {
        self.source = source
        self.hue = hue
        self.isSolid = isSolid
        self.letters = letters
    }
}

// MARK: - Generated identity

enum GeneratedIcon {

    /// The palette an automatic hue is drawn from, and the palette the editor
    /// offers.
    ///
    /// Quantized rather than `hash % 360` on purpose. A raw hue lets two apps
    /// land a few degrees apart — Spotify at 27° and Chrome at 21° were
    /// indistinguishable — and a near-miss reads as a rendering bug where an
    /// exact repeat reads as coincidence. Keeping the automatic hues inside the
    /// pickable set also means every colour the app chooses is one the user
    /// could have chosen.
    static let hues: [Double] = [8, 32, 48, 92, 140, 168, 196, 216, 252, 286, 318, 342]

    /// FNV-1a over the bundle id.
    ///
    /// Keyed to the bundle id and nothing else, so an app keeps its colour
    /// across launches and across the re-sorts that `sortApps` performs when it
    /// starts playing or gets starred.
    static func automaticHue(forBundleID bundleID: String) -> Double {
        var hash: UInt32 = 0x811c_9dc5
        for byte in bundleID.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hues[Int(hash % UInt32(hues.count))]
    }

    /// Up to two characters, taken from what the row actually shows — so
    /// renaming "callservicesd" to something meaningful fixes its tile too.
    static func automaticLetters(for name: String) -> String {
        let alphanumerics = name.unicodeScalars.filter(CharacterSet.alphanumerics.contains)
        guard let first = alphanumerics.first else { return "?" }
        return String(first).uppercased()
    }

    static func hue(_ style: AppIconStyle, bundleID: String) -> Double {
        style.hue ?? automaticHue(forBundleID: bundleID)
    }

    static func letters(_ style: AppIconStyle, displayName: String) -> String {
        let custom = style.letters?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? automaticLetters(for: displayName) : String(custom.prefix(2))
    }

    /// The tile fill. `Color(hue:saturation:brightness:)` takes a 0...1 hue.
    static func fill(hue: Double, isSolid: Bool) -> AnyShapeStyle {
        if isSolid {
            return AnyShapeStyle(Color(hue: hue / 360, saturation: 0.66, brightness: 0.80))
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color(hue: hue / 360, saturation: 0.68, brightness: 0.88),
                    Color(hue: ((hue + 26).truncatingRemainder(dividingBy: 360)) / 360,
                          saturation: 0.80, brightness: 0.66)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

// MARK: - Views

/// A generated tile: coloured fill, one or two letters.
///
/// Split out from `AppIconView` so the editor can preview a style that has not
/// been committed to the app yet.
struct GeneratedIconTile: View {
    let hue: Double
    let isSolid: Bool
    let letters: String
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(GeneratedIcon.fill(hue: hue, isSolid: isSolid))
            .overlay {
                Text(letters)
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.28), radius: 1, y: 0.5)
            }
            .overlay {
                // A hairline top highlight, so the tile reads as a physical
                // object next to real app icons rather than a flat swatch.
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
    }
}

/// One application's icon, honouring its stored style.
struct AppIconView: View {
    let app: AppMix
    let style: AppIconStyle
    var size: CGFloat = 28

    var body: some View {
        // An app asking for its real icon that macOS gave us nothing for falls
        // through to a generated tile. Strictly better than the grey dashed
        // placeholder this used to draw, and it costs nothing.
        if style.source == .appIcon, let image = app.icon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            GeneratedIconTile(
                hue: GeneratedIcon.hue(style, bundleID: app.bundleID),
                isSolid: style.isSolid,
                letters: GeneratedIcon.letters(style, displayName: app.displayName),
                size: size
            )
        }
    }
}
