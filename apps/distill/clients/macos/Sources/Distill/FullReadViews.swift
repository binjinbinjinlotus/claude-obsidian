import AppKit
import DistillKit
import SwiftUI

// Full reads (canvas: FullRead; spec full-read.md, "Visible parts"): the batch size and detail level in
// Settings → Batching, what a batch read in Review (information, no buttons), the hard stop ("Not added ·
// couldn’t be read") and Queue's "Held in inbox/". The core counts and decides; these show its answers.

/// Sources held in inbox/ because they couldn't be read in full (`GET /v1/held`), and Try again.
@MainActor
final class HeldStore: ObservableObject {
    @Published var held: [HeldSource] = []
    /// Files whose Try again is on its way.
    @Published var retrying: Set<String> = []
    weak var engine: AppModel?
    fileprivate static var stores: [ObjectIdentifier: HeldStore] = [:]
    private var loading = false

    static func of(_ engine: AppModel) -> HeldStore {
        let key = ObjectIdentifier(engine)
        if let s = stores[key] { return s }
        let s = HeldStore()
        s.engine = engine
        stores[key] = s
        return s
    }

    func load() {
        guard let engine, let client = engine.client, !loading else { return }
        loading = true
        let vault = engine.activeVault?.path
        Task { [weak self] in
            if let list = try? await client.held(vaultPath: vault) { self?.held = list }
            self?.loading = false
        }
    }

    /// Try again: the core checks the file's bytes, then reads it in a batch of its own.
    func retry(_ file: String, vaultPath: String?) {
        guard let engine, let client = engine.client, !retrying.contains(file) else { return }
        retrying.insert(file)
        Task { [weak self] in
            do {
                let r = try await client.retryHeld(file: file, vaultPath: vaultPath)
                for job in r.started { self?.engine?.upsert(job) }
            } catch {
                self?.engine?.report(error)
            }
            self?.retrying.remove(file)
            self?.load()
        }
    }
}

extension AppModel {
    var heldSources: HeldStore { HeldStore.of(self) }
    /// Held files count in the sidebar until they are read in full or removed.
    var heldCount: Int { status?.heldCount ?? 0 }
}

// MARK: - Settings → Batching

/// "Batch size" and "How much of each source goes into its page" (canvas FullRead card-settings).
struct FullReadSettings: View {
    @EnvironmentObject var engine: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let size = BatchSize(tokens: engine.settings.batchSourceTokens)
            SettingsRow(title: "Batch size", note: FullReadWords.batchSizeNote(engine.status?.batchBudget), bold: true) {
                DropdownButton(title: size.label, height: 30) {
                    ForEach(BatchSize.options, id: \.label) { option in
                        Button(option.menuLabel) { engine.settings.batchSourceTokens = option.tokens }
                    }
                }
                .fixedSize()
                .accessibilityLabel("Batch size")
            }
            .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text("How much of each source goes into its page").font(Theme.body(13, .semibold))
                Text(FullReadWords.detailNote).font(Theme.body(11)).foregroundStyle(Theme.muted).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
            .settingsAnchor("How much of each source goes into its page")
            ForEach(DetailLevels.rows, id: \.key) { row in
                SettingsRow(title: row.title) {
                    DropdownButton(title: engine.settings.detailLevel.level(row.key).label, height: 30) {
                        ForEach(DetailLevel.allCases, id: \.self) { level in
                            Button(level.label) {
                                var levels = engine.settings.detailLevel ?? DetailLevels()
                                levels.set(row.key, level)
                                engine.settings.detailLevel = levels
                            }
                        }
                    }
                    .fixedSize()
                    .accessibilityLabel(row.title)
                }
                .padding(.leading, 12)
            }
            Text(FullReadWords.detailCaption)
                .font(Theme.body(11)).foregroundStyle(Theme.faint).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Review

/// What the batch read, under the heading: lines of information, no buttons (canvas review-covered).
struct CoverageBlock: View {
    let coverage: CoverageSummary
    var stopped = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let read = FullReadWords.readLine(coverage, stopped: stopped)
            line(read.title, read.text, read.quiet, icon: "checkmark", ink: Theme.limeInk)
            if let d = coverage.detail {
                let detail = FullReadWords.detailLine(d)
                line(detail.title, detail.text, nil, icon: "text.magnifyingglass", ink: Theme.muted)
            }
            if let a = FullReadWords.archivedLine(coverage) {
                line(a.title, a.text, a.quiet, icon: "archivebox", ink: Theme.muted)
            }
            ForEach(coverage.partialWording, id: \.self) { page in
                quiet(FullReadWords.partialWordingLine(page), icon: "info.circle")
            }
            if let images = FullReadWords.imagesLine(coverage) { quiet(images, icon: "photo") }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
    }

    private func line(_ title: String, _ text: String, _ quiet: String?, icon: String, ink: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(ink).frame(width: 14)
            (Text(title).fontWeight(.bold).foregroundColor(Theme.ink)
             + Text(" · " + text).foregroundColor(Color(hex: 0x48463F))
             + Text(quiet.map { " · " + $0 } ?? "").foregroundColor(Theme.faint))
                .font(Theme.body(12.5)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func quiet(_ text: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint).frame(width: 14)
            Text(text).font(Theme.body(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "2 sources are read next, in a fresh session" (canvas review-split): they were taken out of this change.
struct LaterNotice: View {
    let later: [String]

    var body: some View {
        if let n = FullReadWords.laterNotice(later) {
            ReviewNotice(tone: .blue, title: n.title + " · " + n.names, text: n.text, systemImage: "arrow.triangle.2.circlepath")
        }
    }
}

/// The hard stop: "Not added · couldn’t be read", above Sources. No pick box and no way to approve it.
struct StoppedGroup: View {
    @EnvironmentObject var engine: AppModel
    let job: Job

    var body: some View {
        let held = engine.heldSources
        VStack(alignment: .leading, spacing: 10) {
            Label { Text(FullReadWords.stoppedTitle(job.stopped.count)).font(Theme.body(13, .bold)) } icon: {
                Image(systemName: "exclamationmark.circle").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.peachInk)
            ForEach(job.stopped) { s in
                VStack(alignment: .leading, spacing: 5) {
                    Text(s.name).font(Theme.body(14, .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(FullReadWords.stoppedText(s.reason)).font(Theme.body(12.5)).foregroundStyle(Color(hex: 0x48463F))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Text(FullReadWords.stoppedHint).font(Theme.body(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        SoftButton(title: held.retrying.contains(s.file) ? "Checking…" : "Try again", fill: .white, size: .small,
                                   systemImage: "arrow.clockwise") { held.retry(s.file, vaultPath: job.vaultPath) }
                            .disabled(held.retrying.contains(s.file))
                        SoftButton(title: "Show in Finder", fill: .white, size: .small) { reveal(s.file) }
                    }
                    .padding(.top, 2)
                }
                .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xFFF4EE)))
    }

    private func reveal(_ file: String) {
        let url = URL(fileURLWithPath: job.vaultPath).appendingPathComponent(file)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Queue

/// "Held in inbox/" (canvas queue-held): sources that couldn't be read in full, with Try again.
struct HeldSection: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: HeldStore

    var body: some View {
        if !store.held.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                (Text(FullReadWords.heldTitle).font(Theme.body(13, .bold)).foregroundColor(Theme.ink)
                 + Text("  " + FullReadWords.heldSubtitle).font(Theme.body(12)).foregroundColor(Theme.muted))
                ForEach(store.held) { h in
                    VStack(alignment: .leading, spacing: 4) {
                        QueueRowView(title: h.name, meta: FullReadWords.heldMeta(h), tileName: h.name,
                                     status: .problem(FullReadWords.heldPill), help: FullReadWords.heldHint(h.reason),
                                     hint: FullReadWords.heldHint(h.reason), onReveal: { reveal(h) })
                        HStack(spacing: 8) {
                            SoftButton(title: store.retrying.contains(h.file) ? "Checking…" : "Try again", size: .small,
                                       systemImage: "arrow.clockwise") { store.retry(h.file, vaultPath: engine.activeVault?.path) }
                                .disabled(store.retrying.contains(h.file))
                            SoftButton(title: "Show in Finder", size: .small) { reveal(h) }
                        }
                        .padding(.leading, 54)
                    }
                }
                Text(FullReadWords.heldCaption).font(Theme.body(11.5)).foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func reveal(_ h: HeldSource) {
        let base = engine.activeVault.map { URL(fileURLWithPath: $0.path) }
        let url = h.file.hasPrefix("/") ? URL(fileURLWithPath: h.file) : (base?.appendingPathComponent(h.file) ?? URL(fileURLWithPath: h.file))
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
