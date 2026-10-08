import AppKit
import SwiftUI
import DistillKit

/// SwiftUI layout of a quick window: a close bar on top (QUICK NOTE / QUICK
/// ASK and ×), an optional pinned header, the middle that scrolls once the
/// window reaches the screen's limit, and a pinned footer. It reports the
/// height it would like (`onDesiredHeight`), built only from the natural
/// heights of its parts so it never depends on the window's current height.
///
/// The middle has a top part (text, answer) and a bottom part (images,
/// errors). When the window is taller than the content, the spare height
/// sits between them, so the text area fills it; a click there focuses the
/// note's text.
struct QuickShell<Header: View, Top: View, Bottom: View, Footer: View>: View {
    let title: String
    var close: () -> Void
    var onDesiredHeight: (CGFloat) -> Void = { _ in }
    var onSpareTap: (() -> Void)? = nil
    /// Snapshots only: the window height to draw (nil = natural) and whether the middle is cut there.
    var snapshotHeight: CGFloat? = nil
    var snapshotWidth: CGFloat = QuickWindowGeometry.defaultWidth
    @ViewBuilder var header: Header
    @ViewBuilder var top: Top
    @ViewBuilder var bottom: Bottom
    @ViewBuilder var footer: Footer

    @Environment(\.snapshotMode) private var snapshot
    @State private var barHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var topHeight: CGFloat = 0
    @State private var bottomHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    static var padding: CGFloat { 16 }
    static var gap: CGFloat { 12 }

    private var middleNatural: CGFloat { topHeight + (bottomHeight > 0 ? Self.gap + bottomHeight : 0) }
    private var desired: CGFloat {
        barHeight + (headerHeight > 0 ? headerHeight + Self.gap : 0) + middleNatural + Self.gap + footerHeight + Self.padding
    }

    var body: some View {
        if snapshot { snapshotBody } else { liveBody }
    }

    // MARK: Live

    private var liveBody: some View {
        VStack(spacing: 0) {
            closeBar.readHeight($barHeight)
            header.readHeight($headerHeight)
                .padding(.bottom, headerHeight > 0 ? Self.gap : 0)
                .padding(.horizontal, Self.padding)
            GeometryReader { geo in
                ScrollView(.vertical) {
                    middle(height: max(geo.size.height, middleNatural))
                        .background(OverlayScrollers())
                }
                .scrollBounceBehavior(.basedOnSize)
                .overlay(alignment: .bottom) {
                    if middleNatural > geo.size.height + 0.5 { ScrollFade(height: 22) }
                }
            }
            footer.readHeight($footerHeight)
                .padding(.top, Self.gap)
                .padding(.horizontal, Self.padding).padding(.bottom, Self.padding)
        }
        .background(Color.white)
        .foregroundStyle(Theme.ink)
        .onChange(of: desired, initial: true) { _, h in onDesiredHeight(h.rounded(.up)) }
    }

    private func middle(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            top.fixedSize(horizontal: false, vertical: true).readHeight($topHeight)
            spare(max(0, height - middleNatural))
            bottom.fixedSize(horizontal: false, vertical: true).readHeight($bottomHeight)
                .padding(.top, bottomHeight > 0 ? Self.gap : 0)
        }
        .padding(.horizontal, Self.padding)
        .frame(height: height, alignment: .top)
    }

    /// The text area's share of extra height; clicking it puts the cursor in the text.
    private func spare(_ h: CGFloat) -> some View {
        Color.white.opacity(0.001).frame(height: h)
            .contentShape(Rectangle())
            .onTapGesture { onSpareTap?() }
            .allowsHitTesting(onSpareTap != nil)
    }

    // MARK: Snapshot (ImageRenderer can't draw ScrollView or AppKit views)

    private var snapshotBody: some View {
        let cut = snapshotHeight != nil
        return VStack(spacing: 0) {
            closeBar
            header.padding(.horizontal, Self.padding).padding(.bottom, Self.gap)
            VStack(alignment: .leading, spacing: Self.gap) {
                top.fixedSize(horizontal: false, vertical: true)
                if cut { Spacer(minLength: 0) }
                bottom.fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Self.padding)
            .frame(minHeight: cut ? 0 : nil, maxHeight: cut ? .infinity : nil, alignment: .top)
            .clipped()
            .layoutPriority(-1)
            .overlay { SnapshotOverflow() }
            footer.padding(.top, Self.gap).padding(.horizontal, Self.padding).padding(.bottom, Self.padding)
        }
        .frame(width: snapshotWidth)
        .frame(height: snapshotHeight)
        .background(Color.white)
        .foregroundStyle(Theme.ink)
        .overlay(alignment: .bottomTrailing) { SnapshotResizeCorner() }
        .clipShape(RoundedRectangle(cornerRadius: QuickWindowContainer.radius, style: .continuous))
    }

    // MARK: Close bar

    private var closeBar: some View {
        HStack(spacing: 8) {
            Text(title.uppercased()).font(Theme.body(10.5, .bold)).tracking(0.9).foregroundStyle(Theme.faint)
            Spacer(minLength: 0)
            IconButton(systemImage: "xmark", size: 22, fill: Theme.panel, iconSize: 8.5, weight: .heavy,
                       help: "Close (Esc)", label: "Close \(title)", action: close)
        }
        .padding(.horizontal, Self.padding).padding(.top, 12).padding(.bottom, 10)
    }
}

/// Snapshots mark a cut middle (`.snapshotOverflow(true)`) with the fade and an overlay scroller.
private struct SnapshotOverflowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var snapshotOverflow: Bool {
        get { self[SnapshotOverflowKey.self] }
        set { self[SnapshotOverflowKey.self] = newValue }
    }
}

private struct SnapshotOverflow: View {
    @Environment(\.snapshotOverflow) private var overflow
    var body: some View {
        if overflow {
            ZStack(alignment: .bottom) {
                SnapshotScrollerThumb(fraction: 0.4)
                ScrollFade(height: 22)
            }
        }
    }
}

private struct SnapshotResizeCorner: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 13, y: 4)); p.addLine(to: CGPoint(x: 4, y: 13))
            p.move(to: CGPoint(x: 13, y: 9)); p.addLine(to: CGPoint(x: 9, y: 13))
        }
        .stroke(Color(white: 0.62), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        .frame(width: 18, height: 18)
    }
}

/// "Aa" in the quick windows' footers: the shared toggle bound to the quick key (the editors read the same key).
struct QuickMarkdownBarToggle: View {
    @AppStorage("distill.markdownBar.quick") private var on = false

    var body: some View { MarkdownBarToggle(isOn: $on, height: 26) }
}
