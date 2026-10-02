import SwiftUI
import DistillKit

// Loading states for Queue and Review (canvas: "Queue · batch running",
// "Review · applying", "Loading states" panels 5 and 6).

/// The running batch: what it is doing, which model, elapsed, steps from the
/// core's progress events (job state only on a core without them), Cancel.
struct BatchBanner: View {
    @EnvironmentObject var engine: AppModel
    let job: Job
    /// History's job detail has its own Cancel in the footer.
    var showsCancel = true
    /// Batches normally take minutes (the canvas shows 1:52 as normal), so
    /// "Still working" comes later than for Ask.
    static let slowAfter = 600

    var body: some View {
        let progress = engine.progress(forJob: job.id)
        let start = progress?.startedAt ?? job.createdAt
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Spinner(size: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(seconds >= Self.slowAfter ? "Still working" : title(progress))
                            .font(Theme.body(15, .bold))
                        Text(detail(progress, seconds: seconds)).font(Theme.body(13)).foregroundStyle(Theme.softInk)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if showsCancel {
                        Button { engine.cancel(job.id) } label: {
                            Text("Cancel").font(Theme.body(13, .semibold)).foregroundStyle(Theme.ink)
                                .padding(.horizontal, 14).frame(height: 32)
                                .background(Capsule().fill(Color.white))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let progress, !progress.steps.isEmpty {
                    StepRow(steps: Self.steps(progress.steps), index: progress.stepIndex ?? 0)
                        .padding(.leading, 30)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.primaryTint))
    }

    /// The batch's steps, ending with "Finding actions (after you apply)" while the
    /// core's list stops at review (Finding actions runs once the batch is applied).
    static func steps(_ core: [String]) -> [String] {
        core.contains { $0.localizedCaseInsensitiveContains("finding actions") } ? core : core + ["Finding actions (after you apply)"]
    }

    private func title(_ p: CoreProgress?) -> String {
        let n = job.files.count
        let vault = URL(fileURLWithPath: job.vaultPath).lastPathComponent
        if let p, !p.message.isEmpty { return "\(p.message) into \(vault)" }
        return "Reading \(n == 1 ? "1 source" : "\(n) sources") into \(vault)"
    }

    private func detail(_ p: CoreProgress?, seconds: Int) -> String {
        let runner = (p?.runnerID ?? job.selection.runnerID) == "claude-code" ? "Claude Code" : (p?.runnerID ?? job.selection.runnerID)
        let model = ModelChoice.shortName(p?.model ?? job.model)
        var parts = [runner, model]
        // A clock time, never a ticking counter (canvas: MainLoading).
        parts.append("started at \(ActionsClock.time(p?.startedAt ?? job.createdAt))")
        parts.append("nothing is written until you approve")
        return parts.joined(separator: " · ")
    }
}

/// "✓ Moved to inbox  ✓ Read sources  … Drafting page changes  Ready for review".
struct StepRow: View {
    let steps: [String]
    let index: Int

    var body: some View {
        // One line when it fits (Queue); a column in narrow panes (History).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { items }
            VStack(alignment: .leading, spacing: 4) { items }
        }
    }

    @ViewBuilder private var items: some View {
        ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
            HStack(spacing: 3) {
                if i < index {
                    Text("✓").font(Theme.body(12, .bold)).foregroundStyle(Theme.limeInk)
                } else if i == index {
                    Text("…").font(Theme.body(12, .bold)).foregroundStyle(Theme.primary)
                }
                Text(step).font(Theme.body(12)).foregroundStyle(i > index ? Theme.faint : Theme.softInk)
            }
            .lineLimit(1).fixedSize()
        }
    }
}

/// Review while the vault write runs: "Writing to Research · 0:03 · …".
struct ApplyingLine: View {
    let vault: String
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            Text(seconds >= 60
                 ? "Still writing to \(vault) · \(ElapsedText.format(seconds)) · the card unlocks when the vault write finishes"
                 : "Writing to \(vault) · \(ElapsedText.format(seconds)) · the card unlocks when the vault write finishes")
                .font(Theme.body(13, .semibold)).foregroundStyle(Theme.primary)
        }
    }
}

/// Disabled "Applying N changes…" in place of Approve.
struct ApplyingButton: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Spinner(color: .white, size: 14)
            Text(count == 1 ? "Applying 1 change…" : "Applying \(count) changes…").font(Theme.body(14, .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22).frame(height: 42)
        .background(Capsule().fill(Theme.primary.opacity(0.85)))
    }
}

/// Disabled "Processing…" button.
struct ProcessingButton: View {
    var body: some View {
        HStack(spacing: 8) {
            Spinner(color: Theme.muted, size: 14)
            Text("Processing…").font(Theme.body(14, .semibold))
        }
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 20).frame(height: 42)
        .background(Capsule().fill(Theme.panel))
        .accessibilityLabel("Processing")
    }
}

/// While the core has not answered yet: say so, and shimmer where content will land.
struct StartingPlaceholder: View {
    var rows = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Spinner(color: Theme.muted, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Starting Distill…").font(Theme.body(13, .bold))
                    Text("Waiting for the core to answer.").font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: 14) {
                    Shimmer(width: 40, height: 40, radius: 12)
                    VStack(alignment: .leading, spacing: 8) {
                        Shimmer(width: 220, height: 12)
                        Shimmer(width: 140, height: 10)
                    }
                }
            }
        }
    }
}
