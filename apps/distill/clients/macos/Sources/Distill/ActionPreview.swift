import AppKit
import SwiftUI
import DistillKit

// Action context (canvas row 12: ActionContext; spec action-context.md): the To confirm row that opens
// into a preview of what Create draft will write, and the original's lines + wiki section shared by the
// preview, the item detail and Review's "Actions found".

enum ActionContextOpen {
    /// The original in the default app (Obsidian doesn't show `.raw/`, a dot folder). False = it's gone.
    @discardableResult
    static func openOriginal(_ raw: ActionRawRef, vault: String?) -> Bool {
        guard let vault, let path = raw.resolve(vault: vault) else { return false }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        return true
    }

    @discardableResult
    static func revealOriginal(_ raw: ActionRawRef, vault: String?) -> Bool {
        guard let vault, let path = raw.resolve(vault: vault) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return true
    }

    /// A wiki page in Obsidian (falls back to the default app).
    static func openPage(_ path: String, vault: String?) {
        guard let vault else { return }
        let full = path.hasPrefix("/") ? path : URL(fileURLWithPath: vault).appendingPathComponent(path).path
        guard FileManager.default.fileExists(atPath: full) else { return }
        var components = URLComponents(string: "obsidian://open")!
        components.queryItems = [URLQueryItem(name: "path", value: full)]
        if let url = components.url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: full)) }
    }

    static func exists(_ raw: ActionRawRef, vault: String?) -> Bool {
        guard let vault else { return true } // snapshots / unknown vault: don't claim it's gone
        return raw.resolve(vault: vault) != nil
    }
}

/// Small caps label: "FROM THE ORIGINAL".
struct ContextLabel: View {
    let text: String
    var ink: Color = Theme.faint
    var body: some View { Text(text.uppercased()).font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(ink) }
}

/// A blue text link with an icon ("Open original").
struct ContextLink: View {
    let title: String
    var icon = "doc.text"
    var ink: Color = Theme.primary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(Theme.body(11.5, .semibold))
            }
            .foregroundStyle(ink)
        }
        .buttonStyle(.plain)
    }
}

/// The original's lines with their numbers; `highlight` marks the quoted lines.
struct OriginalLines: View {
    let lines: [(Int, String)]
    var highlight = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(line.0)").font(Theme.body(11).monospacedDigit()).foregroundStyle(Theme.faint)
                        .frame(width: 34, alignment: .trailing)
                    Text(line.1).font(Theme.body(12)).foregroundStyle(Theme.ink).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 1.5)
                .background(highlight ? Color(hex: 0xFFF6D6) : Color.clear)
            }
        }
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// "FROM THE ORIGINAL" (or "CLOSEST LINES IN THE ORIGINAL", or why there is none), then the wiki section.
/// Older items (no context) show their quote as before.
struct ActionContextSections: View {
    @EnvironmentObject var engine: AppModel
    let item: ActionItem
    /// The detail's compact form: "ORIGINAL · LINES 210–214" with Open.
    var compact = false

    private var vault: String? { item.vaultPath ?? engine.activeVault?.path }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            original
            ForEach(Array(item.context.wiki.prefix(compact ? 1 : 2).enumerated()), id: \.offset) { _, w in wiki(w) }
        }
    }

    @ViewBuilder private var original: some View {
        let ctx = item.context
        if let raw = ctx.raw, raw.lines != nil, !raw.numberedLines.isEmpty {
            let gone = !ActionContextOpen.exists(raw, vault: vault)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ContextLabel(text: compact ? "Original · \(raw.linesText ?? "")" : raw.isClosest ? "Closest lines in the original" : "From the original")
                    Spacer(minLength: 6)
                    if gone {
                        Text("The original is gone").font(Theme.body(11)).foregroundStyle(Theme.faint)
                    } else {
                        ContextLink(title: compact ? "Open" : "Open original", icon: "archivebox") { ActionContextOpen.openOriginal(raw, vault: vault) }
                        if !compact {
                            ContextLink(title: "Show in Finder", icon: "folder", ink: Theme.muted) { ActionContextOpen.revealOriginal(raw, vault: vault) }
                        }
                    }
                }
                if !compact { Text(originalCaption(raw)).font(Theme.body(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
                OriginalLines(lines: raw.numberedLines, highlight: !raw.isClosest)
            }
        } else if ctx.isWikiOnly || (ctx.raw == nil && ctx.note != nil) {
            notice("Wiki only.", ctx.note ?? "The cited pages have no archived original, so the context is the wiki section.")
        } else if let raw = ctx.raw, raw.match == "none" {
            VStack(alignment: .leading, spacing: 6) {
                notice("Quote not found in the original.", "These are the AI’s words; Distill couldn’t find them in \(((raw.inboxPath ?? raw.path) as NSString).lastPathComponent).")
                if let quote = item.source.quote, !quote.isEmpty { quoteText(quote) }
            }
        } else if let quote = item.source.quote, !quote.isEmpty {
            quoteText(quote)
        }
    }

    private func originalCaption(_ raw: ActionRawRef) -> String {
        let name = ActionContextText.sourceName(item) ?? ((raw.inboxPath ?? raw.path) as NSString).lastPathComponent
        if raw.isClosest {
            return "The answer cites \(name); these lines share the most words with the action. They are not a quote."
        }
        let where_ = raw.path.hasPrefix(".raw/") ? " · archived in .raw/captured/" : ""
        return "\(name) · \(raw.linesText ?? "")\(where_)"
    }

    private func wiki(_ w: ActionWikiRef) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ContextLabel(text: compact ? "Wiki · \(w.heading ?? w.pageName)" : "From the wiki")
                Spacer(minLength: 6)
                ContextLink(title: compact ? "Open" : "Open page", icon: "book") { ActionContextOpen.openPage(w.path, vault: vault) }
            }
            VStack(alignment: .leading, spacing: 4) {
                if !compact {
                    (Text(w.pageName).fontWeight(.semibold)
                     + Text(w.heading.map { "  ›  \($0)" } ?? "").foregroundColor(Theme.muted))
                        .font(Theme.body(12)).foregroundStyle(Theme.ink)
                }
                if let ex = w.excerpt, !ex.isEmpty {
                    Text(ex).font(Theme.body(12)).foregroundStyle(Theme.softInk).lineSpacing(2).lineLimit(compact ? 5 : 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(compact ? 0 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(compact ? Color.clear : Color.white)
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(compact ? Color.clear : Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    private func notice(_ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            (Text(title + " ").fontWeight(.bold).foregroundColor(Theme.ink) + Text(text))
                .font(Theme.body(12)).foregroundStyle(Theme.softInk).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
    }

    private func quoteText(_ quote: String) -> some View {
        Text("“\(quote)”").font(Theme.body(12).italic()).foregroundStyle(Theme.softInk)
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 10).padding(.vertical, 2)
            .overlay(alignment: .leading) { Rectangle().fill(ActionsTheme.quoteBar).frame(width: 3) }
    }
}

/// The open To confirm row: Why, the original's lines, the fields already filled, the wiki section, and
/// what Create draft (or Add) will do.
struct ActionPreview: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActionsStore
    let item: ActionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let why = item.why, !why.isEmpty {
                (Text("Why: ").fontWeight(.bold).foregroundColor(Theme.ink) + Text(why))
                    .font(Theme.body(12.5)).foregroundStyle(Theme.softInk).fixedSize(horizontal: false, vertical: true)
            }
            ActionContextSections(item: item)
            filled
            willWrite
        }
        .padding(.leading, 46).padding(.trailing, 14).padding(.bottom, 14).padding(.top, 2)
    }

    @ViewBuilder private var filled: some View {
        let specs = store.type(item.type)?.fields ?? []
        let f = ActionContextText.fields(item, specs: specs)
        if !f.set.isEmpty || !f.unset.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ContextLabel(text: "Already filled")
                ForEach(f.set, id: \.0) { row in
                    HStack(spacing: 10) {
                        Text(row.0).font(Theme.body(12)).foregroundStyle(Theme.muted).frame(width: 84, alignment: .leading)
                        Text(row.1).font(Theme.body(12.5, .semibold)).foregroundStyle(Theme.ink)
                    }
                }
                if !f.unset.isEmpty {
                    HStack(spacing: 10) {
                        Text("Not set yet").font(Theme.body(12)).foregroundStyle(Theme.muted).frame(width: 84, alignment: .leading)
                        Text(f.unset.joined(separator: ", ")).font(Theme.body(12).italic()).foregroundStyle(Theme.faint)
                    }
                }
            }
        }
    }

    private var willWrite: some View {
        let label = store.type(item.type)?.label ?? item.type
        let model = ModelChoice.shortName(SettingsEdits.draftSelection(item.type, engine.settings).model)
        let text = ActionContextText.willWrite(item, typeLabel: label, model: model)
        let todo = item.type == "todo"
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: todo ? "checkmark.circle" : "pencil").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(todo ? Theme.muted : Theme.primary)
            (Text(todo ? "What Add does. " : "What Create draft will write. ").fontWeight(.bold).foregroundColor(Theme.ink) + Text(text))
                .font(Theme.body(12)).foregroundStyle(Theme.softInk).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(todo ? Theme.panel : Theme.primaryTint))
    }
}

/// One found item: chevron, type tile, the full title (two lines), "Jira ticket · PAY · Task · Tomasz and
/// Jin · lines 210–214", the buttons, and the preview when open. Used by To confirm and Review.
struct ActionConfirmRow: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    @Binding var expanded: Bool
    /// To confirm: Add / Create draft and ×. Review: none.
    var buttons = true
    /// Review: its source is left out of this change.
    var leftOut: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.muted).frame(width: 12).padding(.top, 6)
                let style = ActionsTheme.typeStyle(item.type)
                Image(systemName: style.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(style.2)
                    .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 7).fill(style.1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(Theme.body(14, .semibold)).lineLimit(expanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    meta
                }
                Spacer(minLength: 6)
                if buttons {
                    ActionButton(title: item.type == "todo" ? "Add" : "Create draft", icon: "plus", kind: .soft, height: 26) { store.confirm([item.id]) }
                    IconButton(systemImage: "xmark", size: 26, help: "Dismiss") { store.dismiss([item.id]) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
            .help(expanded ? "Hide the preview" : "Show what it will create")
            if expanded { ActionPreview(store: store, item: item) }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(expanded ? Color.white : Theme.primaryTint.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(expanded ? ActionsTheme.selectedStroke : .clear, lineWidth: 1.5))
        .opacity(leftOut == nil ? 1 : 0.5)
    }

    private var meta: some View {
        let label = store.type(item.type)?.label ?? item.type
        var parts = [ActionContextText.target(item, typeLabel: label)]
        if let leftOut {
            parts.append(leftOut)
        } else {
            if let name = ActionContextText.sourceName(item) { parts.append(name) } else if item.source.conversationID != nil { parts.append("Ask chat") }
            if let lines = item.context.raw?.linesText { parts.append(lines) } else if item.context.isWikiOnly { parts.append("wiki only") }
        }
        return Text(parts.joined(separator: " · "))
            .font(Theme.body(11)).foregroundStyle(leftOut == nil ? Theme.muted : Theme.peachInk).lineLimit(2)
    }
}
