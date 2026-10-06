import SwiftUI
import DistillKit

/// A batch whose AI was blocked from running a command (review-queue.md). Distill answers the session itself
/// first; this card is the last resort, in plain words. The command and the Allow checkbox are only behind
/// Show command, closed by default.
struct BlockedCommandCard: View {
    let job: Job
    let approval: ApprovalRequest
    @Binding var allowed: Set<String>
    var onTryAgain: () -> Void
    var onTerminal: () -> Void
    var onReject: () -> Void
    var onAllow: ([String]) -> Void
    /// Snapshots open the disclosure.
    var showCommand = false
    @State private var open: Bool?

    /// What "Tell Claude to read the files" sends (the owner's reply, so recovery starts over).
    static let readInstead = "Don't run shell commands or python. Use Read, Grep or Glob to look at the files you need (to compare two files, read both), then continue and finish with the structured status."

    private var recovering: Bool { job.recovery?.state == .running }
    private var isOpen: Bool { open ?? showCommand }

    var body: some View {
        if recovering {
            ReviewNotice(tone: .blue, title: "Recovering", text: "Claude was blocked from running a command. Distill told it to read the files instead and is waiting for its answer.",
                         busy: true)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label(BlockedText.heading(job), systemImage: "exclamationmark.bubble").font(Theme.body(13, .bold))
                Text(BlockedText.summary(job)).font(Theme.body(12.5)).foregroundStyle(Theme.softInk).fixedSize(horizontal: false, vertical: true)
                if let tried = triedLine { Text(tried).font(Theme.body(11.5)).foregroundStyle(Theme.muted) }
                HStack(spacing: 8) {
                    SoftButton(title: "Tell Claude to read the files", tint: Theme.peachInk, fill: .white, size: .small, systemImage: "arrow.clockwise", action: onTryAgain)
                        .fixedSize()
                    SoftButton(title: "Open in Terminal", fill: .white, size: .small, systemImage: "terminal", action: onTerminal).fixedSize()
                    SoftButton(title: "Reject batch", tint: Theme.muted, fill: .clear, size: .small, action: onReject).fixedSize()
                }
                DisclosureGroup(isExpanded: Binding(get: { isOpen }, set: { open = $0 })) {
                    commands.padding(.top, 6)
                } label: {
                    Text("Show command").font(Theme.body(12, .semibold)).foregroundStyle(Theme.muted)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xFFF4EE)))
        }
    }

    private var triedLine: String? {
        guard let r = job.recovery, !r.attempts.isEmpty else { return nil }
        let n = r.attempts.count
        let cost = r.costUSD > 0 ? String(format: " · $%.2f", r.costUSD) : ""
        return "Tried \(n == 1 ? "once" : n == 2 ? "twice" : "\(n) times")\(cost)."
    }

    private var commands: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(approval.denials, id: \.self) { denial in
                if let rule = denial.suggestedRule {
                    Toggle(isOn: Binding(get: { allowed.contains(rule) },
                                         set: { on in if on { allowed.insert(rule) } else { allowed.remove(rule) } })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(denial.display).font(.system(size: 12, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                            if denial.bypassesApproval(jobDirectory: (job.vaultPath as NSString).appendingPathComponent(".vault-meta/worker/\(job.id)")) {
                                Text("Allowing this lets Claude change files without your review.")
                                    .font(Theme.body(12)).foregroundStyle(Theme.peachInk)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                } else {
                    Text(denial.display).font(.system(size: 12, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                }
            }
            if !allowed.isEmpty {
                SoftButton(title: "Allow & continue", tint: Theme.peachInk, fill: .white) { onAllow(Array(allowed)) }
            }
        }
    }
}
