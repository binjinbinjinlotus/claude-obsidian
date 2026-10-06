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
    /// Let recovery try again (a core with recovery); nil shows Tell Claude to read the files.
    var onRecover: (() -> Void)? = nil
    /// Continue in a new session, after the owner confirms (recovery suggested it).
    var onNewSession: (() -> Void)? = nil
    var onTerminal: () -> Void
    var onReject: () -> Void
    var onAllow: ([String]) -> Void
    /// Snapshots open the disclosure.
    var showCommand = false
    @State private var open: Bool?
    @State private var confirming = false

    /// What "Tell Claude to read the files" sends (the owner's reply, so recovery starts over).
    static let readInstead = "Don't run shell commands or python. Use Read, Grep or Glob to look at the files you need (to compare two files, read both), then continue and finish with the structured status."

    private var recovering: Bool { RecoveryText.isActive(job) }
    private var isOpen: Bool { open ?? showCommand }

    private var recoveringText: String {
        if let agent = job.recovery?.attempts.last(where: { $0.result == "running" }), agent.by == "agent" {
            return "Claude was blocked from running a command, and Distill’s answers didn’t help. \(ModelChoice.shortName(agent.model ?? "The Recovery model")) is looking at what to do next."
        }
        return "Claude was blocked from running a command. Distill told it to read the files instead and is waiting for its answer."
    }

    var body: some View {
        if recovering {
            ReviewNotice(tone: .blue, title: "Recovering", text: recoveringText, busy: true)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label(BlockedText.heading(job), systemImage: "exclamationmark.bubble").font(Theme.body(13, .bold))
                Text(BlockedText.summary(job)).font(Theme.body(12.5)).foregroundStyle(Theme.softInk).fixedSize(horizontal: false, vertical: true)
                if let tried = job.recovery.flatMap(RecoveryText.tried) { Text(tried).font(Theme.body(11.5)).foregroundStyle(Theme.muted) }
                FlowLayout(spacing: 8) {
                    if let onRecover, job.recovery != nil {
                        SoftButton(title: "Let recovery try again", tint: Theme.peachInk, fill: .white, size: .small, systemImage: "arrow.clockwise", action: onRecover)
                            .fixedSize()
                    } else {
                        SoftButton(title: "Tell Claude to read the files", tint: Theme.peachInk, fill: .white, size: .small, systemImage: "arrow.clockwise", action: onTryAgain)
                            .fixedSize()
                    }
                    NewSessionButton(job: job, confirming: $confirming, enabled: onNewSession != nil)
                    SoftButton(title: "Open in Terminal", fill: .white, size: .small, systemImage: "terminal", action: onTerminal).fixedSize()
                    SoftButton(title: "Reject batch", tint: Theme.muted, fill: .clear, size: .small, action: onReject).fixedSize()
                }
                if confirming, let onNewSession { NewSessionConfirm(job: job, onContinue: { confirming = false; onNewSession() }, onCancel: { confirming = false }) }
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

/// review-queue.md, Self-recovery: a batch stuck for another reason (its plan went stale again, the vault core
/// couldn't check it, or the run stopped with an error). Blue while Distill works on it (nothing needs the owner),
/// the peach Couldn't fix card once recovery gave up. The words are the core's sentence, never a command.
struct RecoveryCard: View {
    let job: Job
    let recovery: RecoveryState
    var onRecover: () -> Void
    var onTerminal: () -> Void
    /// Nil for a batch that can't be rejected from here.
    var onReject: (() -> Void)?
    /// Continue in a new session, after the owner confirms (recovery suggested it).
    var onNewSession: (() -> Void)? = nil
    /// Rebuild against the latest pages (the owner's click; a reply to the batch's session).
    var onRebuild: (() -> Void)? = nil
    /// Recovery's split proposal: rebuild these sources first (Approve with them picked).
    var onSplit: (([String]) -> Void)? = nil
    /// Recovery's discard proposal: discard the rebuilt part (its sources stay).
    var onDiscard: (() -> Void)? = nil
    /// Snapshots open the confirmation.
    var confirmingNewSession = false
    @State private var confirming: Bool?

    var body: some View {
        if !RecoveryText.isActive(job) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Distill couldn’t fix this", systemImage: "exclamationmark.bubble").font(Theme.body(13, .bold))
                Text(RecoveryText.summary(recovery)).font(Theme.body(12.5)).foregroundStyle(Theme.softInk).fixedSize(horizontal: false, vertical: true)
                if !recovery.attempts.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("WHAT WAS TRIED").font(Theme.body(10.5, .heavy)).kerning(0.5).foregroundStyle(Theme.muted)
                        ForEach(Array(RecoveryText.attemptRows(recovery).enumerated()), id: \.offset) { i, row in
                            Text("\(i + 1). \(row)").font(Theme.body(12)).foregroundStyle(Theme.softInk)
                        }
                    }
                }
                FlowLayout(spacing: 8) {
                    if let onRebuild {
                        SoftButton(title: "Rebuild against the latest pages", tint: Theme.peachInk, fill: .white, size: .small,
                                   systemImage: "arrow.triangle.2.circlepath", action: onRebuild)
                            .fixedSize()
                            .help("Asks this batch’s session to rebuild the plan for your vault as it is now. The new plan comes back for your OK.")
                    }
                    if let group = RecoveryText.splitGroup(job), let onSplit {
                        SoftButton(title: group.count == 1 ? "Rebuild 1 source first" : "Rebuild \(group.count) sources first", tint: Theme.peachInk, fill: .white,
                                   size: .small, systemImage: "square.split.2x1") { onSplit(group) }
                            .fixedSize()
                            .help("Recovery’s suggestion: these sources are rebuilt first and come back for your OK; the rest wait in this batch.")
                    }
                    if RecoveryText.offersDiscard(job), let onDiscard {
                        SoftButton(title: "Discard the rebuilt part", tint: Theme.peachInk, fill: .white, size: .small, systemImage: "xmark.circle", action: onDiscard)
                            .fixedSize()
                            .help("Recovery’s suggestion: nothing is applied, and its sources stay in this batch.")
                    }
                    SoftButton(title: "Let recovery try again", tint: Theme.peachInk, fill: .white, size: .small, systemImage: "arrow.clockwise", action: onRecover)
                        .fixedSize()
                    NewSessionButton(job: job, confirming: Binding(get: { isConfirming }, set: { confirming = $0 }), enabled: onNewSession != nil)
                    SoftButton(title: "Open in Terminal", fill: .white, size: .small, systemImage: "terminal", action: onTerminal).fixedSize()
                    if let onReject {
                        SoftButton(title: "Reject batch", tint: Theme.muted, fill: .clear, size: .small, action: onReject).fixedSize()
                    }
                }
                if isConfirming, let onNewSession {
                    NewSessionConfirm(job: job, onContinue: { confirming = false; onNewSession() }, onCancel: { confirming = false })
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xFFF4EE)))
        } else {
            ReviewNotice(tone: .blue, title: RecoveryText.heading(recovery),
                         text: RecoveryText.detail(recovery) + (RecoveryText.tried(recovery).map { " " + $0 } ?? ""),
                         busy: recovery.state == .running, systemImage: "clock")
        }
    }
}

extension RecoveryCard {
    private var isConfirming: Bool { confirming ?? confirmingNewSession }
}

/// review-queue.md: Continue in a new session, offered when recovery suggests it. It only opens the confirmation;
/// a new session never starts without the owner's Continue there.
private struct NewSessionButton: View {
    let job: Job
    @Binding var confirming: Bool
    var enabled: Bool

    var body: some View {
        if enabled && RecoveryText.offersNewSession(job) {
            SoftButton(title: "Continue in a new session", fill: .white, size: .small, systemImage: "arrow.triangle.2.circlepath") { confirming = true }
                .fixedSize()
                .disabled(confirming)
        }
    }
}

/// The same confirmation as everywhere else a new session would start (SessionReplaceConfirm), with recovery's reason.
private struct NewSessionConfirm: View {
    let job: Job
    var onContinue: () -> Void
    var onCancel: () -> Void

    var body: some View {
        SessionReplaceConfirm(place: "batch", reason: "recovery", runner: SessionReplaceText.runnerName(job.runnerID),
                              carries: "It starts with this batch’s sources, labels and conversation, then picks up where it stopped. Nothing is applied without your OK.",
                              onContinue: onContinue, onCancel: onCancel)
    }
}

/// review-queue.md: a plan the owner approved was rebuilt after another batch changed the same pages; one more OK.
struct SinceApprovedCard: View {
    let since: SinceApproved?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Rebuilt after you approved it", systemImage: "arrow.triangle.2.circlepath").font(Theme.body(13, .bold))
            Text("Another batch changed the same pages first, so this batch’s session rebuilt the plan for your vault as it is now. Approve it once more; it keeps its place.")
                .font(Theme.body(12.5)).foregroundStyle(Theme.softInk).fixedSize(horizontal: false, vertical: true)
            if let since {
                VStack(alignment: .leading, spacing: 3) {
                    Text("WHAT CHANGED SINCE YOU APPROVED").font(Theme.body(10.5, .heavy)).kerning(0.5).foregroundStyle(Theme.muted)
                    ForEach(ReviewQueueText.sinceLines(since), id: \.self) { line in
                        Text("• " + line).font(Theme.body(12)).foregroundStyle(Theme.softInk)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.primaryTint))
    }
}
