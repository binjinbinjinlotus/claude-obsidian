import CoreGraphics

/// Frame math for the quick note and quick ask windows (canvas: "Quick
/// windows: size, growth and scrolling"). AppKit screen coordinates: y grows
/// upward, so a window's top edge is `frame.maxY`.
///
/// Rules:
/// - Open centered horizontally on the chosen screen with the top edge 30 %
///   down the visible frame (like Spotlight), or where the user dragged it while
///   it stayed open. Closing forgets the spot, so the next open is centered again.
/// - Open at `defaultSize` (560 × 214, a third bigger than the old 420 × 160)
///   unless the user dragged another size, which is kept as the opening size.
/// - The top edge never moves while the window fits its content: it grows and
///   shrinks downward, and stops `bottomMargin` above the visible frame's bottom.
/// - A size the user drags is a floor: content never shrinks the window below it.
/// - Dragging it smaller than the content hides the difference (`hiddenOverflow`):
///   the middle scrolls by that much, and later growth or shrinking moves the
///   window by the same amount as the content, never below the floor. So the
///   next keystroke doesn't snap the window back to full height.
public enum QuickWindowGeometry {
    public static let minSize = CGSize(width: 360, height: 160)
    /// The opening size until the user drags one (canvas: "Default size (a third bigger)").
    public static let defaultSize = CGSize(width: 560, height: 214)
    public static let defaultWidth: CGFloat = defaultSize.width
    public static let bottomMargin: CGFloat = 8
    public static let sideMargin: CGFloat = 8
    /// The top edge sits this far down the visible frame.
    public static let topFraction: CGFloat = 0.30

    /// Tallest the window may be with its top edge at `top`.
    public static func maxHeight(top: CGFloat, visible: CGRect) -> CGFloat {
        max(minSize.height, top - (visible.minY + bottomMargin))
    }

    /// The height for `desired` content height: content minus what the user
    /// chose to hide, at least the floor and the minimum, at most the limit.
    public static func fittedHeight(desired: CGFloat, floor: CGFloat, hiddenOverflow: CGFloat = 0,
                                    top: CGFloat, visible: CGRect) -> CGFloat {
        let wanted = max(desired - max(0, hiddenOverflow), floor, minSize.height)
        return min(wanted, maxHeight(top: top, visible: visible))
    }

    /// Where the top-left corner goes when the window opens.
    public static func openTopLeft(width: CGFloat, visible: CGRect, remembered: CGPoint? = nil) -> CGPoint {
        if let p = remembered {
            return clampTopLeft(p, width: width, visible: visible)
        }
        let top = visible.maxY - (visible.height * topFraction).rounded()
        return clampTopLeft(CGPoint(x: (visible.midX - width / 2).rounded(), y: top), width: width, visible: visible)
    }

    /// The frame on open: centered (or remembered), sized for the content.
    public static func openFrame(desired: CGFloat, floor: CGSize, visible: CGRect, remembered: CGPoint? = nil) -> CGRect {
        let width = clampWidth(floor.width, visible: visible)
        let topLeft = openTopLeft(width: width, visible: visible, remembered: remembered)
        let height = fittedHeight(desired: desired, floor: floor.height, top: topLeft.y, visible: visible)
        return CGRect(x: topLeft.x, y: topLeft.y - height, width: width, height: height)
    }

    /// `current` refitted to the content with its top edge kept.
    public static func grownFrame(_ current: CGRect, desired: CGFloat, floor: CGFloat, hiddenOverflow: CGFloat,
                                  visible: CGRect) -> CGRect {
        let height = fittedHeight(desired: desired, floor: floor, hiddenOverflow: hiddenOverflow, top: current.maxY, visible: visible)
        return CGRect(x: current.minX, y: current.maxY - height, width: current.width, height: height)
    }

    /// A drag of the bottom-right resize corner by (dx, dy) in screen points
    /// (dy < 0 = pointer moved down). The top-left corner stays.
    public static func resized(_ start: CGRect, dx: CGFloat, dy: CGFloat, visible: CGRect) -> CGRect {
        let maxW = max(minSize.width, visible.maxX - sideMargin - start.minX)
        let width = min(max(start.width + dx, minSize.width), maxW)
        let height = min(max(start.height - dy, minSize.height), maxHeight(top: start.maxY, visible: visible))
        return CGRect(x: start.minX, y: start.maxY - height, width: width, height: height)
    }

    /// How much content the user hid by dragging the window to `height`.
    public static func hiddenOverflow(desired: CGFloat, height: CGFloat) -> CGFloat {
        max(0, desired - height)
    }

    /// After the content changes: once everything fits in the floor again, nothing stays hidden.
    public static func updatedHiddenOverflow(_ hidden: CGFloat, desired: CGFloat, floor: CGFloat) -> CGFloat {
        min(max(0, hidden), max(0, desired - floor))
    }

    static func clampWidth(_ width: CGFloat, visible: CGRect) -> CGFloat {
        min(max(width, minSize.width), max(minSize.width, visible.width - 2 * sideMargin))
    }

    /// Keeps the window on the visible frame, with room for at least the minimum height below the top.
    static func clampTopLeft(_ p: CGPoint, width: CGFloat, visible: CGRect) -> CGPoint {
        let x = min(max(p.x, visible.minX + sideMargin), visible.maxX - sideMargin - width)
        let y = min(max(p.y, visible.minY + bottomMargin + minSize.height), visible.maxY)
        return CGPoint(x: max(visible.minX, x), y: y)
    }
}
