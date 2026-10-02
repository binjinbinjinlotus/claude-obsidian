import SwiftUI

// Shared loading-state pieces (canvas: "Loading states", and the per-screen
// loading boards). Every wait uses the same parts: a spinner or bubbling
// flask, a status line naming the work and model, an elapsed timer after 3 s,
// shimmer where the result will land, and a way out (Stop, Skip, Cancel).
// Motion stops under Reduce Motion and in snapshot renders.

/// Circular spinner (an open arc that rotates).
struct Spinner: View {
    var color: Color = Theme.primary
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.snapshotMode) private var snapshot
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(color, style: StrokeStyle(lineWidth: max(2, size / 7), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                guard !reduceMotion, !snapshot else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
            }
            .accessibilityLabel("Working")
    }
}

/// Placeholder block with a moving sheen, where a result will land.
struct Shimmer: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.snapshotMode) private var snapshot
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(Color(hex: 0xEFEDE8))
            .overlay(
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, Color(hex: 0xF8F7F4), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: phase * geo.size.width)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius))
            )
            .frame(width: width, height: height)
            .onAppear {
                guard !reduceMotion, !snapshot else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.5 }
            }
            .accessibilityHidden(true)
    }
}

/// "0:14" since `start`; hidden for the first 3 seconds.
struct ElapsedText: View {
    let start: Date
    var font: Font = .system(size: 11)
    var color: Color = Theme.muted

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            if seconds >= 3 {
                Text(Self.format(seconds)).font(font).foregroundStyle(color).monospacedDigit()
            }
        }
    }

    static func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The standard status row: spinner, title (pulsing), detail line with the
/// elapsed timer, and an optional action button (Stop / Cancel / Skip).
struct WorkingRow: View {
    let title: String
    var detail: String? = nil
    var start: Date? = nil
    var tint: Color = Theme.primary
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Spinner(color: tint, size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ink)
                HStack(spacing: 4) {
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                    if let start {
                        if detail != nil { Text("·").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                        ElapsedText(start: start)
                    }
                }
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(Theme.panel))
            }
        }
    }
}

/// Several shimmer lines, like a paragraph that is being written.
struct ShimmerParagraph: View {
    var widths: [CGFloat] = [0.94, 0.88, 0.62]

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(widths.enumerated()), id: \.offset) { _, w in
                    Shimmer(width: geo.size.width * w, height: 12)
                }
            }
        }
        .frame(height: CGFloat(widths.count) * 20)
    }
}

/// Thin determinate bar for "9 of 23".
struct ProgressBar: View {
    let done: Int
    let total: Int
    var tint: Color = Theme.peachInk

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.panel)
                Capsule().fill(tint).frame(width: total > 0 ? geo.size.width * CGFloat(done) / CGFloat(total) : 0)
            }
        }
        .frame(height: 6)
        .accessibilityValue("\(done) of \(total)")
    }
}
