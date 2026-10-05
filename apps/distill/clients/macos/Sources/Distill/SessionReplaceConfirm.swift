import DistillKit
import SwiftUI

/// The one confirmation Distill shows wherever it would continue in an AI session that no longer
/// exists (system-wide rule, 2026-10-05; canvas: SessionReplaceConfirm). Calm on purpose: blue,
/// not a warning. Continue sends the same call again with `newSession`; Cancel changes nothing.
struct SessionReplaceConfirm: View {
    /// batch | conversation | terminal
    var place: String
    /// notFound | missing | neverStarted | runnerGone
    var reason: String
    var runner: String = "Claude Code"
    /// What the new session starts with; empty = the place's default.
    var carries: String = ""
    /// The technical reason (quiet monospace line); empty hides it.
    var detail: String = ""
    var width: CGFloat? = nil
    var busy = false
    var onContinue: () -> Void = {}
    var onCancel: () -> Void = {}

    init(place: String, reason: String, runner: String = "Claude Code", carries: String = "", detail: String = "",
         width: CGFloat? = nil, busy: Bool = false, onContinue: @escaping () -> Void = {}, onCancel: @escaping () -> Void = {}) {
        self.place = place
        self.reason = reason
        self.runner = runner
        self.carries = carries
        self.detail = detail
        self.width = width
        self.busy = busy
        self.onContinue = onContinue
        self.onCancel = onCancel
    }

    /// From the core's report (an error body or a job's marker).
    init(_ s: SessionUnavailable, runner: String, place: String? = nil, carries: String = "", width: CGFloat? = nil, busy: Bool = false,
         onContinue: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.init(place: place ?? s.place, reason: s.reason, runner: runner, carries: carries, detail: s.detail, width: width,
                  busy: busy, onContinue: onContinue, onCancel: onCancel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
                    .frame(width: 18).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(SessionReplaceText.heading(place: place)).font(Theme.body(14, .bold)).foregroundStyle(Theme.ink)
                    Text(SessionReplaceText.body(place: place, reason: reason, runner: runner))
                        .font(Theme.body(12.5)).foregroundStyle(Color(hex: 0x48463F)).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(carries.isEmpty ? SessionReplaceText.carries(place: place) : carries)
                        .font(Theme.body(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                PrimaryButton(title: SessionReplaceText.continueTitle(place: place), size: .small, enabled: !busy, action: onContinue)
                SoftButton(title: "Cancel", tint: Theme.ink, fill: .white, size: .small, stroke: true, action: onCancel)
                Spacer(minLength: 0)
            }
            .padding(.leading, 28)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.faint)
                    .lineLimit(1).truncationMode(.middle).help(detail)
                    .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xF2F7FF)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: 0xD6E4FB)))
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SessionReplaceText.heading(place: place))
    }
}
