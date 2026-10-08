import DistillKit
import SwiftUI

// Clean up inbox (canvas: InboxCleanup; spec inbox-cleanup.md). Only when the user asks: the core
// decides what can go (ledger, unchanged, pages exist) and moves it to the Trash, checking each again.

/// What the app knows about clean-ups: previews by scope ("" = the whole vault, else a job id) and the last result.
@MainActor
final class InboxCleanupStore: ObservableObject {
    @Published var previews: [String: InboxCleanupPreview] = [:]
    @Published var results: [String: InboxCleanupResult] = [:]
    @Published var loading: Set<String> = []
    @Published var moving: Set<String> = []
    /// An older core without the clean-up routes.
    @Published var unavailable = false
    weak var engine: AppModel?
    fileprivate static var stores: [ObjectIdentifier: InboxCleanupStore] = [:]

    static func of(_ engine: AppModel) -> InboxCleanupStore {
        let key = ObjectIdentifier(engine)
        if let s = stores[key] { return s }
        let s = InboxCleanupStore()
        s.engine = engine
        stores[key] = s
        return s
    }

    /// Counted when a place opens, never kept: no stale "22 files" after they are gone.
    func load(jobID: String?) {
        let key = jobID ?? ""
        guard let client = engine?.client, !loading.contains(key) else { return }
        loading.insert(key)
        Task { [weak self] in
            do {
                let p = try await client.inboxCleanup(jobID: jobID)
                self?.previews[key] = p
                self?.unavailable = false
            } catch {
                if let e = error as? CoreClientError, e.isNotAvailable { self?.unavailable = true }
            }
            self?.loading.remove(key)
        }
    }

    func clean(paths: [String], jobID: String?, done: @escaping (InboxCleanupResult) -> Void = { _ in }) {
        let key = jobID ?? ""
        guard let client = engine?.client, !paths.isEmpty, !moving.contains(key) else { return }
        moving.insert(key)
        Task { [weak self] in
            do {
                let r = try await client.cleanUpInbox(paths: paths, jobID: jobID)
                self?.results[key] = r
                done(r)
            } catch {
                self?.engine?.report(error)
            }
            self?.moving.remove(key)
            self?.load(jobID: jobID)
            if jobID != nil { self?.load(jobID: nil) }
        }
    }
}

extension AppModel {
    var inboxCleanup: InboxCleanupStore { InboxCleanupStore.of(self) }

    /// v8: Done on an approved batch in Review (it stays in History).
    func finishReview(_ id: String) {
        guard let client else { lastError = "The Distill core is not connected."; return }
        Task {
            do { upsert(try await client.finishReview(id)) } catch { report(error) }
        }
    }
}

/// The confirm before anything moves: what goes to the Trash, what stays and why (canvas InboxCleanup B and the
/// vault-wide sheet). `selectable` adds checkboxes and select-all (Settings → Batching).
struct InboxCleanupSheet: View {
    let preview: InboxCleanupPreview
    var selectable = false
    var titles: [String: String] = [:]
    var moving = false
    let onMove: ([String]) -> Void
    let onCancel: () -> Void
    @State private var picked: Set<String>
    @State private var showAll = false
    @State private var showStays = false

    init(preview: InboxCleanupPreview, selectable: Bool = false, titles: [String: String] = [:], moving: Bool = false,
         onMove: @escaping ([String]) -> Void, onCancel: @escaping () -> Void) {
        self.preview = preview
        self.selectable = selectable
        self.titles = titles
        self.moving = moving
        self.onMove = onMove
        self.onCancel = onCancel
        _picked = State(initialValue: Set(preview.items.map(\.path)))
    }

    private var pickedItems: [InboxCleanupItem] { preview.items.filter { picked.contains($0.path) } }
    private var pickedFiles: Int { pickedItems.reduce(0) { $0 + $1.fileCount } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selectable ? InboxCleanupWords.title : InboxCleanupWords.confirmTitle(preview.fileCount))
                .font(Theme.display(20))
            Text(selectable
                 ? InboxCleanupWords.confirmText + " Pick what is cleared; the rest stays in inbox/."
                 : InboxCleanupWords.confirmText)
                .font(Theme.body(12.5)).foregroundStyle(Color(hex: 0x48463F)).fixedSize(horizontal: false, vertical: true)
            if !preview.items.isEmpty { moveBox }
            if !preview.stays.isEmpty { stayBox }
            HStack(spacing: 10) {
                if selectable {
                    Text("\(pickedFiles) of \(preview.fileCount) picked").font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                SoftButton(title: "Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                PrimaryButton(title: moving ? "Clearing…" : InboxCleanupWords.moveButton(pickedFiles), enabled: pickedFiles > 0 && !moving) {
                    onMove(pickedItems.map(\.path))
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .frame(width: selectable ? 600 : 500)
    }

    private var moveBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            if selectable {
                Toggle(isOn: Binding(get: { picked.count == preview.items.count },
                                     set: { picked = $0 ? Set(preview.items.map(\.path)) : [] })) {
                    Text("All \(preview.fileCount) files").font(Theme.body(13, .bold))
                }
                .toggleStyle(.checkbox)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(groups, id: \.key) { g in
                            Toggle(isOn: Binding(get: { g.items.allSatisfy { picked.contains($0.path) } },
                                                 set: { on in for i in g.items { if on { picked.insert(i.path) } else { picked.remove(i.path) } } })) {
                                HStack(spacing: 6) {
                                    Text(g.title).font(Theme.body(13, .semibold)).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(filesWord(g.items.reduce(0) { $0 + $1.fileCount })).font(Theme.body(12)).foregroundStyle(Theme.muted)
                                }
                            }
                            .toggleStyle(.checkbox)
                            Text(g.items.prefix(3).map { $0.kind == "folder" ? "\($0.name)/" : $0.name }.joined(separator: " · ")
                                 + (g.items.count > 3 ? " · \(g.items.count - 3) more" : ""))
                                .font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).padding(.leading, 22)
                        }
                    }
                }
                .frame(maxHeight: 220)
            } else {
                Label { Text(InboxCleanupWords.willClear(preview.fileCount)).font(Theme.body(12, .bold)) } icon: {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(Theme.limeInk)
                let shown = showAll ? preview.items : Array(preview.items.prefix(3))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { i in
                        Text(i.kind == "folder" ? "\(i.name)/ · \(filesWord(i.fileCount))" : i.name)
                            .font(Theme.body(12.5)).lineLimit(1).truncationMode(.middle)
                    }
                    if preview.items.count > 3 && !showAll {
                        Button("and \(preview.items.count - 3) more") { showAll = true }
                            .buttonStyle(.plain).font(Theme.body(12.5, .semibold)).foregroundStyle(Theme.primary)
                    }
                    let manifests = preview.items.filter { $0.kind == "note" }.count
                    if manifests > 0 {
                        Text(manifests == 1 ? "with the note’s .distill.json" : "with the \(manifests) notes’ .distill.json files")
                            .font(Theme.body(12)).foregroundStyle(Theme.faint)
                    }
                }
                .padding(.leading, 21)
                .frame(maxHeight: showAll ? 220 : nil)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xFBFAF8)))
    }

    private var stayBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { Text("\(selectable ? "Stays" : "Will stay") in inbox/ · \(filesWord(preview.stayFileCount))").font(Theme.body(12, .bold)) } icon: {
                Image(systemName: "circle").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Theme.muted)
            if selectable && !showStays {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                    ForEach(preview.staysByReason, id: \.reason) { r in
                        GridRow {
                            Text(InboxCleanupWords.reason(r.reason).capitalizedFirst).font(Theme.body(12.5))
                            Text(filesWord(r.count)).font(Theme.body(12.5))
                                .foregroundStyle(InboxCleanupWords.isWarning(r.reason) ? Theme.peachInk : Theme.muted)
                        }
                    }
                }
                .padding(.leading, 21)
                Button("Show each file") { showStays = true }
                    .buttonStyle(.plain).font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary).padding(.leading, 21)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(preview.stays) { s in
                            HStack(spacing: 8) {
                                Text(s.kind == "folder" ? "\(s.name)/" : s.name).font(Theme.body(12.5)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(s.detail.map { s.kind == "folder" ? $0 : "\(s.reasonWords) (\($0))" } ?? s.reasonWords)
                                    .font(Theme.body(12.5)).foregroundStyle(s.isWarning ? Theme.peachInk : Theme.muted).lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxHeight: 140)
                .padding(.leading, 21)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xFBFAF8)))
    }

    private struct ItemGroup { let key: String; let title: String; let items: [InboxCleanupItem] }

    /// Grouped by the batch that added them, newest first; items with no known batch last.
    private var groups: [ItemGroup] {
        var order: [String] = []
        var by: [String: [InboxCleanupItem]] = [:]
        for i in preview.items {
            let k = i.jobId ?? ""
            if by[k] == nil { order.append(k) }
            by[k, default: []].append(i)
        }
        return order.map { k in
            let added = by[k]!.compactMap(\.addedAt).max()
            let title = (k.isEmpty ? "Other files" : titles[k] ?? "Batch") + (added.map { " · added \($0)" } ?? "")
            return ItemGroup(key: k, title: title, items: by[k]!)
        }
    }

    private func filesWord(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
}

/// After a clean-up: what moved, and what stayed (canvas InboxCleanup C).
struct InboxCleanupResultNotice: View {
    let result: InboxCleanupResult

    var body: some View {
        ReviewNotice(tone: result.movedFiles > 0 ? .green : .calm, title: InboxCleanupWords.resultTitle(result),
                     text: InboxCleanupWords.resultText(result), systemImage: result.movedFiles > 0 ? "checkmark" : "info.circle")
    }
}

/// Settings → Batching: "Clear inbox", every file in inbox/ that can go (canvas InboxCleanup card 1, FullRead card-clear).
struct InboxCleanupSettingsRow: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: InboxCleanupStore
    @State private var open = false

    var body: some View {
        let p = store.previews[""]
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(InboxCleanupWords.title).font(Theme.body(13, .semibold))
                Text(line(p)).font(Theme.body(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let p, p.fileCount > 0 {
                SoftButton(title: "Review \(p.fileCount) file\(p.fileCount == 1 ? "" : "s")…", size: .small) { open = true }
                    .fixedSize()
                    .sheet(isPresented: $open) {
                        InboxCleanupSheet(preview: p, selectable: true, titles: titles, moving: store.moving.contains(""),
                                          onMove: { paths in store.clean(paths: paths, jobID: nil) { _ in open = false } },
                                          onCancel: { open = false })
                    }
            }
        }
        .onAppear { store.load(jobID: nil) }
    }

    private var titles: [String: String] { Dictionary(uniqueKeysWithValues: engine.jobs.map { ($0.id, $0.displayTitle) }) }

    private func line(_ p: InboxCleanupPreview?) -> String {
        if store.unavailable { return "Update the Distill core to clear inbox/ from here." }
        guard let p else { return "Counting the files in inbox/ that were read in full and archived…" }
        if let r = store.results[""], r.movedFiles > 0, p.fileCount == 0 { return InboxCleanupWords.resultTitle(r) + ". " + InboxCleanupWords.resultText(r) }
        if p.fileCount == 0 {
            return p.stayFileCount == 0 ? "Nothing to clear: inbox/ is empty."
                : "Nothing to clear: \(p.stayFileCount) file\(p.stayFileCount == 1 ? " in inbox/ isn’t" : "s in inbox/ aren’t") read in full and archived yet, or a batch still needs \(p.stayFileCount == 1 ? "it" : "them")."
        }
        return "\(p.fileCount) file\(p.fileCount == 1 ? " in inbox/ was" : "s in inbox/ were") read in full, and \(p.fileCount == 1 ? "its original is" : "their originals are") archived in your vault. Distill never clears them on its own; you pick what is cleared."
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// History and Review: "Clear inbox · 22 files" for one batch (only the files it used), with its confirm.
struct InboxCleanupButton: View {
    @ObservedObject var store: InboxCleanupStore
    let job: Job
    var compact = false
    @State private var open = false

    var body: some View {
        let p = store.previews[job.id]
        Group {
            if let title = InboxCleanupWords.button(p), let p {
                SoftButton(title: compact ? "Clear inbox · \(p.fileCount)" : title, systemImage: "trash") { open = true }
                    .fixedSize()
                    .help("Clear this batch’s files from inbox/: their originals are archived in your vault; the inbox copies go to the Trash")
                    .sheet(isPresented: $open) { sheet(p) }
            } else if let line = InboxCleanupWords.nothingLine(p), let p {
                HStack(spacing: 6) {
                    Text(line).font(Theme.body(12)).foregroundStyle(Theme.muted)
                    if !p.stays.isEmpty {
                        Button("Why") { open = true }.buttonStyle(.plain).font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary)
                    }
                }
                .fixedSize()
                .sheet(isPresented: $open) { sheet(p) }
            }
        }
        .onAppear { store.load(jobID: job.id) }
        .onChange(of: job.id) { store.load(jobID: job.id) }
        .onChange(of: job.state) { store.load(jobID: job.id) }
    }

    private func sheet(_ p: InboxCleanupPreview) -> some View {
        InboxCleanupSheet(preview: p, moving: store.moving.contains(job.id),
                          onMove: { paths in store.clean(paths: paths, jobID: job.id) { _ in open = false } },
                          onCancel: { open = false })
    }

    /// Only a batch that read files from inbox/ and was added (at least in part).
    static func applies(to job: Job) -> Bool {
        job.kind == "ingest" && (job.state == .completed || !(job.parts ?? []).isEmpty)
            && (job.files.contains { $0.hasPrefix("inbox/") } || !(job.folders ?? []).isEmpty)
    }
}

/// The last clean-up of this batch: what moved and what stayed.
struct InboxCleanupResultLine: View {
    @ObservedObject var store: InboxCleanupStore
    let jobID: String

    var body: some View {
        if let r = store.results[jobID] { InboxCleanupResultNotice(result: r) }
    }
}
