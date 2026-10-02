import AppKit
import SwiftUI

/// Forces the enclosing NSScrollView (a SwiftUI ScrollView on macOS) to use
/// thin overlay scrollers, even with "Show scroll bars: Always": no scroll-bar
/// strip ever takes space. Re-applied when the system preference changes,
/// because AppKit resets the style then.
struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.apply() }

    final class Probe: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            if observer == nil {
                observer = NotificationCenter.default.addObserver(
                    forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                    // AppKit applies the new preference after posting; ours goes on top.
                    DispatchQueue.main.async { self?.apply() }
                }
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func apply() {
            guard let scroll = enclosingScrollView ?? Self.scrollView(above: self) else { return }
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            scroll.hasHorizontalScroller = false
            scroll.drawsBackground = false
        }

        private static func scrollView(above view: NSView) -> NSScrollView? {
            var v = view.superview
            while let current = v {
                if let s = current as? NSScrollView { return s }
                v = current.superview
            }
            return nil
        }
    }
}

/// The soft fade at a cut edge of a scrolled area.
struct ScrollFade: View {
    var color: Color = .white
    var height: CGFloat = 22
    var top = false

    var body: some View {
        LinearGradient(colors: [color.opacity(0), color], startPoint: top ? .bottom : .top, endPoint: top ? .top : .bottom)
            .frame(height: height)
            .allowsHitTesting(false)
    }
}

/// Snapshot stand-in for the overlay scroller while scrolling (ImageRenderer can't draw NSScroller).
struct SnapshotScrollerThumb: View {
    var fraction: CGFloat = 0.45

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Color.black.opacity(0.28))
                .frame(width: 5, height: max(24, geo.size.height * fraction))
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 3)
        }
        .allowsHitTesting(false)
    }
}

/// Measures a view's height without affecting its layout.
struct HeightReader: ViewModifier {
    @Binding var height: CGFloat

    func body(content: Content) -> some View {
        content.background(GeometryReader { geo in
            Color.clear
                .onAppear { height = geo.size.height }
                .onChange(of: geo.size.height) { _, h in height = h }
        })
    }
}

extension View {
    func readHeight(_ height: Binding<CGFloat>) -> some View { modifier(HeightReader(height: height)) }
}

enum ComposeSizing {
    /// Four lines of 15 pt text with 5 pt line spacing, plus the editor's insets.
    static let minEditorHeight: CGFloat = 4 * 23 + 8
}

/// The Write a note card body: title, note box, then the source panel, images
/// and errors at the bottom. Spare height goes to the note box. Below the
/// minimum (note box at 4 lines) the whole card scrolls with an overlay bar
/// and a fade; the screen's header and footer stay outside and never move.
struct ComposeCardLayout<Title: View, Editor: View, Bottom: View>: View {
    let snapshot: Bool
    let minEditor: CGFloat
    @ViewBuilder var title: Title
    @ViewBuilder var editor: Editor
    @ViewBuilder var bottom: Bottom

    @State private var titleHeight: CGFloat = 30
    @State private var bottomHeight: CGFloat = 0
    private let spacing: CGFloat = 16
    private let padH: CGFloat = 26
    private let padV: CGFloat = 22

    /// Height of the card's content with the note box at its minimum. Built
    /// only from fixed-size parts, so it never depends on the window height.
    private var minContent: CGFloat { padV * 2 + titleHeight + spacing + minEditor + spacing + bottomHeight }

    var body: some View {
        if snapshot { snapshotBody } else { liveBody }
    }

    private var liveBody: some View {
        GeometryReader { geo in
            let overflow = geo.size.height + 0.5 < minContent
            ScrollView(.vertical) {
                content(measure: true).frame(height: max(geo.size.height, minContent))
                    .background(OverlayScrollers())
            }
            .scrollBounceBehavior(.basedOnSize)
            .overlay(alignment: .bottom) { if overflow { ScrollFade(height: 26) } }
        }
    }

    /// ImageRenderer can't draw a ScrollView: lay out once, and when the card is
    /// too short show the cut edge as the live window would while scrolling.
    private var snapshotBody: some View {
        ViewThatFits(in: .vertical) {
            content(measure: false)
            content(measure: false)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
                .overlay(alignment: .bottom) { ScrollFade(height: 26) }
                .overlay { SnapshotScrollerThumb(fraction: 0.6) }
        }
    }

    private func content(measure: Bool) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            title.fixedSize(horizontal: false, vertical: true)
                .readHeightIf(measure, $titleHeight)
            editor
                .frame(minHeight: minEditor, maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(-1)
            bottom.fixedSize(horizontal: false, vertical: true)
                .readHeightIf(measure, $bottomHeight)
        }
        .padding(.horizontal, padH).padding(.vertical, padV)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

extension View {
    @ViewBuilder func readHeightIf(_ on: Bool, _ height: Binding<CGFloat>) -> some View {
        if on { readHeight(height) } else { self }
    }
}
