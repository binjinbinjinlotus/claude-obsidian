import SwiftUI
import DistillKit

/// Review's batch list (review-queue.md, section 4): one row per batch, oldest first, with its name, date,
/// sources and one state pill. ↑/↓ move the selection. It replaces the horizontal tabs.
struct ReviewBatchList: View {
    @EnvironmentObject var engine: AppModel
    let jobs: [Job]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Batches").font(Theme.body(13, .bold))
                Text("\(jobs.count)").font(Theme.body(12)).foregroundStyle(Theme.muted)
                Spacer()
            }
            .padding(.horizontal, 6)
            Scrolling {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(jobs) { job in
                        Button { pick(job.id) } label: {
                            ReviewBatchRow(job: job, state: ReviewBatches.rowState(job, in: engine.jobs), selected: job.id == selected)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 24).padding(.horizontal, 12)
        .background(Theme.window)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            guard let i = jobs.firstIndex(where: { $0.id == selected }) else { return }
            switch direction {
            case .up where i > 0: pick(jobs[i - 1].id)
            case .down where i + 1 < jobs.count: pick(jobs[i + 1].id)
            default: break
            }
        }
    }
}

struct ReviewBatchRow: View {
    let job: Job
    let state: ReviewRowState
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(job.displayTitle).font(Theme.body(13, .semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text("\(ReviewBatches.batchDate(job)) · \(ReviewBatches.tabSubtitle(job))").font(Theme.body(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 4)
                pill
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.white : Color.clear)
            .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 4, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.border : Color.clear))
        .contentShape(Rectangle())
    }

    private var pill: some View {
        let (fill, ink): (Color, Color) = {
            switch state {
            case .ready, .needsYou, .couldntFix, .notAdded: return (Theme.peachTint, Theme.peachInk)
            case .updating, .applying, .recovering, .working: return (Theme.primaryTint, Theme.primary)
            case .added: return (Theme.limeTint, Theme.limeInk)
            case .queued: return (Theme.panel, Theme.softInk)
            }
        }()
        let busy = [.updating, .applying, .recovering, .working].contains(state)
        return HStack(spacing: 4) {
            if busy { Spinner(color: ink, size: 9) }
            Text(state.label).font(Theme.body(11, state == .needsYou ? .bold : .semibold)).lineLimit(1)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 8).frame(height: 20)
        .background(Capsule().fill(fill))
        .fixedSize()
    }
}
