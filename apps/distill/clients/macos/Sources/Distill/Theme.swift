import SwiftUI

/// Palette and type from the "clean and joyful" design canvas.
enum Theme {
    // Neutrals
    static let window = Color(hex: 0xFFFFFF)
    static let panel = Color(hex: 0xF6F5F2)
    static let border = Color(hex: 0xECEAE5)
    static let ink = Color(hex: 0x1D1C1A)
    static let muted = Color(hex: 0x6B6862)
    static let faint = Color(hex: 0x9B978F)
    static let flaskLine = Color(hex: 0x6B7785)

    // Primary action
    static let primary = Color(hex: 0x1F6FEB)
    static let primaryTint = Color(hex: 0xE3EEFF)

    // Joy accents (fill, ink)
    static let lime = Color(hex: 0xB9F06A)
    static let limeTint = Color(hex: 0xE9FBC9)
    static let limeInk = Color(hex: 0x3D6110)
    static let peach = Color(hex: 0xFFB894)
    static let peachTint = Color(hex: 0xFFE4D6)
    static let peachInk = Color(hex: 0xB03A0A)
    static let pinkTint = Color(hex: 0xFFE0EC)
    static let pinkInk = Color(hex: 0xA3245A)
    static let skyTint = Color(hex: 0xDDF2FF)
    static let skyInk = Color(hex: 0x0B5C86)
    static let working = Color(hex: 0xA9CCFF)

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }

    /// Rotating avatar colors for vaults.
    static let vaultChips: [(Color, Color)] = [(pinkTint, pinkInk), (skyTint, skyInk), (limeTint, limeInk), (peachTint, peachInk)]
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: Flask

/// The flask silhouette, drawn in a 40×44 design space.
struct FlaskShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 40, sy = rect.height / 44
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(15, 3))
        path.addLine(to: p(25, 3))
        path.addLine(to: p(25, 15))
        path.addLine(to: p(36, 34))
        path.addQuadCurve(to: p(31.7, 41.5), control: p(38.5, 41.5))
        path.addLine(to: p(8.3, 41.5))
        path.addQuadCurve(to: p(4, 34), control: p(1.5, 41.5))
        path.addLine(to: p(15, 15))
        path.closeSubpath()
        return path
    }
}

/// Flask filled to `level` (0...1) with `liquid`, plus a few bubbles when lively.
struct FlaskView: View {
    var level: Double
    var liquid: Color = Theme.lime
    var bubbles: Bool = false
    var lineWidth: CGFloat = 2.4

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                FlaskShape().fill(Color.white)
                // Liquid fills the body (y 15...41.5 of 44), never the neck.
                let bodyTop = h * 15 / 44, bodyBottom = h * 41.5 / 44
                let fill = max(0, min(1, level)) * (bodyBottom - bodyTop)
                Rectangle()
                    .fill(liquid)
                    .frame(width: w, height: fill)
                    .position(x: w / 2, y: bodyBottom - fill / 2)
                    .clipShape(FlaskShape())
                if bubbles {
                    Circle().fill(Theme.primary).frame(width: w * 0.09).position(x: w * 0.44, y: h * 0.42)
                    Circle().fill(Theme.peach).frame(width: w * 0.07).position(x: w * 0.56, y: h * 0.30)
                    Circle().fill(Theme.skyInk.opacity(0.6)).frame(width: w * 0.05).position(x: w * 0.48, y: h * 0.20)
                }
                FlaskShape().stroke(Theme.flaskLine, style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
                RoundedRectangle(cornerRadius: h * 0.05)
                    .fill(Theme.flaskLine)
                    .frame(width: w * 15 / 40, height: h * 4 / 44)
                    .position(x: w / 2, y: h * 3 / 44)
            }
        }
        .aspectRatio(40 / 44, contentMode: .fit)
    }
}

// MARK: Reusable pieces

struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .bold)) }
                Text(title).font(Theme.body(14, .semibold))
            }
            .padding(.horizontal, 20)
            .frame(height: 40)
            .foregroundStyle(.white)
            .background(Capsule().fill(Theme.primary))
            .shadow(color: Theme.primary.opacity(0.28), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }
}

struct SoftButton: View {
    let title: String
    var tint: Color = Theme.ink
    var fill: Color = Theme.panel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(14, .semibold))
                .padding(.horizontal, 18)
                .frame(height: 40)
                .foregroundStyle(tint)
                .background(Capsule().fill(fill))
        }
        .buttonStyle(.plain)
    }
}

struct Pill: View {
    let text: String
    var fill: Color
    var ink: Color

    var body: some View {
        Text(text)
            .font(Theme.body(12, .bold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(ink)
            .background(Capsule().fill(fill))
    }
}

/// Colored rounded tile with a short label (file type, initials).
struct Tile: View {
    let text: String
    var fill: Color
    var ink: Color
    var size: CGFloat = 40
    var display = false

    var body: some View {
        Text(text)
            .font(display ? Theme.display(size * 0.42) : Theme.body(10, .bold))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3).fill(fill))
    }
}

enum FileStyle {
    static func tile(for name: String) -> (String, Color, Color) {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff": return (ext.uppercased(), Theme.primaryTint, Theme.primary)
        case "pdf": return ("PDF", Theme.peachTint, Theme.peachInk)
        case "md", "txt", "markdown": return (ext.uppercased(), Theme.limeTint, Theme.limeInk)
        case "": return ("FILE", Theme.panel, Theme.muted)
        default: return (String(ext.prefix(4)).uppercased(), Theme.skyTint, Theme.skyInk)
        }
    }
}

extension View {
    /// White card with the hairline border used across the design.
    func card(_ radius: CGFloat = 18, selected: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: radius).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(selected ? Theme.primary : Theme.border, lineWidth: selected ? 2 : 1))
    }
}

// MARK: Snapshot support

private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True only in `--snapshot` renders: ImageRenderer can't draw ScrollView
    /// contents or AppKit-backed editors, so those swap for static stand-ins.
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// ScrollView in the app, plain stack in snapshots.
struct Scrolling<Content: View>: View {
    @Environment(\.snapshotMode) private var snapshot
    @ViewBuilder var content: Content

    var body: some View {
        if snapshot {
            VStack(spacing: 0) { content; Spacer(minLength: 0) }
        } else {
            ScrollView { content }
        }
    }
}
