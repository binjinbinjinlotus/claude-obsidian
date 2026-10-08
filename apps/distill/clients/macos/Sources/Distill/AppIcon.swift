import AppKit
import SwiftUI

/// The app icon (canvas: "App icon"): white rounded tile with a soft sky-blue
/// curve at the bottom, the flask in slate outline with lime liquid and two
/// bubbles. `scripts/make-icon.sh` renders it into Resources/AppIcon.icns via
/// `Distill --snapshot OUT --app-icon`.
struct AppIconView: View {
    /// Canvas size; the tile follows the macOS icon grid (824 of 1024, centered).
    var size: CGFloat = 1024

    var body: some View {
        let tile = size * 824 / 1024
        ZStack {
            ZStack {
                Color.white
                // circle(62% at 50% 118%): r = 62% of the tile's reference size.
                Circle()
                    .fill(Color(hex: 0xE3EEFF))
                    .frame(width: tile * 0.62 * 2 * 1.0, height: tile * 0.62 * 2)
                    .position(x: tile / 2, y: tile * 1.18)
                IconFlask()
                    .frame(width: tile * 0.62, height: tile * 0.62)
            }
            .frame(width: tile, height: tile)
            .clipShape(RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: max(1, tile / 400)))
            .shadow(color: .black.opacity(0.18), radius: tile * 0.03, y: tile * 0.015)
        }
        .frame(width: size, height: size)
    }
}

/// The flask in the 40×44 design space of the canvas SVG.
private struct IconFlask: View {
    var body: some View {
        Canvas { ctx, sz in
            // Fit 40×44 into the square, centered.
            let scale = min(sz.width / 40, sz.height / 44)
            let dx = (sz.width - 40 * scale) / 2, dy = (sz.height - 44 * scale) / 2
            ctx.translateBy(x: dx, y: dy)
            ctx.scaleBy(x: scale, y: scale)
            let body = Self.flaskPath()
            ctx.fill(body, with: .color(.white))
            var liquid = ctx
            liquid.clip(to: body)
            liquid.fill(Path(CGRect(x: 0, y: 25, width: 40, height: 20)), with: .color(Color(hex: 0xB9F06A)))
            liquid.fill(Self.wave(), with: .color(Color(hex: 0xD9FFA3)))
            ctx.fill(Path(ellipseIn: CGRect(x: 18 - 1.8, y: 20 - 1.8, width: 3.6, height: 3.6)), with: .color(Color(hex: 0x1F6FEB)))
            ctx.fill(Path(ellipseIn: CGRect(x: 22.5 - 1.3, y: 15.5 - 1.3, width: 2.6, height: 2.6)), with: .color(Color(hex: 0xFFB894)))
            ctx.stroke(body, with: .color(Color(hex: 0x6B7785)), style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
            ctx.fill(Path(roundedRect: CGRect(x: 12.5, y: 1, width: 15, height: 4), cornerRadius: 2), with: .color(Color(hex: 0x6B7785)))
        }
    }

    /// M15 3h10v12l11 19a5 5 0 0 1-4.3 7.5H8.3A5 5 0 0 1 4 34l11-19z
    static func flaskPath() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 15, y: 3))
        p.addLine(to: CGPoint(x: 25, y: 3))
        p.addLine(to: CGPoint(x: 25, y: 15))
        p.addLine(to: CGPoint(x: 36, y: 34))
        p.addQuadCurve(to: CGPoint(x: 31.7, y: 41.5), control: CGPoint(x: 38.6, y: 38.5))
        p.addLine(to: CGPoint(x: 8.3, y: 41.5))
        p.addQuadCurve(to: CGPoint(x: 4, y: 34), control: CGPoint(x: 1.4, y: 38.5))
        p.addLine(to: CGPoint(x: 15, y: 15))
        p.closeSubpath()
        return p
    }

    /// M0 26c4-2 8 2 12 0s8-2 12 0 8 2 16 0v-3H0z (the lighter top of the liquid).
    static func wave() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 26))
        p.addCurve(to: CGPoint(x: 12, y: 26), control1: CGPoint(x: 4, y: 24), control2: CGPoint(x: 8, y: 28))
        p.addCurve(to: CGPoint(x: 24, y: 26), control1: CGPoint(x: 16, y: 24), control2: CGPoint(x: 20, y: 24))
        p.addCurve(to: CGPoint(x: 40, y: 26), control1: CGPoint(x: 28, y: 28), control2: CGPoint(x: 32, y: 28))
        p.addLine(to: CGPoint(x: 40, y: 23))
        p.addLine(to: CGPoint(x: 0, y: 23))
        p.closeSubpath()
        return p
    }
}

extension Snapshot {
    /// Writes the `.iconset` PNGs (`icon_16x16.png` … `icon_512x512@2x.png`) into `dir`.
    static func renderAppIconSet(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let renderer = ImageRenderer(content: AppIconView(size: CGFloat(px)).environment(\.colorScheme, .light))
                renderer.scale = 1
                guard let cg = renderer.cgImage else { continue }
                let rep = NSBitmapImageRep(cgImage: cg)
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
            }
        }
        print(dir.path)
    }
}
