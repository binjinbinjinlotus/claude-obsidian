import AppKit
import SwiftUI
import DistillKit

// Images inside the text (ImagesInline.dc.html). In the text view an image is
// one U+FFFC character carrying an `InlineImageAttachment`; everywhere else
// (the binding, the draft, the note) it is `![[name]]`. Hovering shows Extract
// content and ×, a click selects it (Delete removes it), right-click has the
// same actions. Extract content reads the image with the imageText model and
// replaces it, in place and undoably, by the Markdown that comes back.

/// What an editor needs to show and read images. Built fresh each render by
/// the owner (Write a note, quick note); editors without one take no images.
struct InlineImageHost {
    /// Groups editors that share a draft (one per `ComposeOwner`).
    var key: ComposeOwner
    /// Every image of the draft, by name.
    var images: [String: DraftImage]
    var states: [String: InlineImageState]
    /// Adds images to the draft (deduped names); returns them as they will be embedded.
    var register: ([DraftImage]) -> [DraftImage]
    var extract: (DraftImage) async throws -> ExtractImageTextResult
    var setState: (String, InlineImageState?) -> Void
    /// "Haiku": the model a new reading uses.
    var readingModel: () -> String
    var openSettings: () -> Void
    /// Snapshot-only state the live editor gets from the mouse.
    var fixture: InlineImageFixture? = nil
}

/// Forced hover / selection / extracted note for `--snapshot` renders.
struct InlineImageFixture {
    var hovered: String? = nil
    var selected: String? = nil
    /// Text already in the draft that was "just extracted" from `name`.
    var extracted: (text: String, name: String, model: String)? = nil
}

/// The live editor of each owner, so ⌘V, drops and the Image button outside
/// the text view insert at its cursor.
@MainActor
enum InlineImageEditors {
    private final class Weak { weak var controller: MarkdownEditorController?; init(_ c: MarkdownEditorController) { controller = c } }
    private static var editors: [ComposeOwner: Weak] = [:]

    static func register(_ controller: MarkdownEditorController, for key: ComposeOwner) {
        editors[key] = Weak(controller)
    }

    static func editor(for key: ComposeOwner) -> MarkdownEditorController? {
        guard let c = editors[key]?.controller, c.textView?.window != nil else { return nil }
        return c
    }
}

/// Size of an image in the text: its own aspect, at most the box width and 320 pt tall.
enum InlineImageLayout {
    static let maxHeight: CGFloat = 320

    static func fit(_ natural: CGSize, maxWidth: CGFloat) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return CGSize(width: min(maxWidth, 200), height: 120) }
        var w = min(natural.width, max(40, maxWidth))
        var h = w * natural.height / natural.width
        if h > maxHeight { h = maxHeight; w = h * natural.width / natural.height }
        return CGSize(width: floor(w), height: floor(h))
    }
}

// MARK: - Attachment

final class InlineImageAttachment: NSTextAttachment {
    let draftImage: DraftImage

    @MainActor
    init(image: DraftImage) {
        self.draftImage = image
        super.init(data: nil, ofType: nil)
        attachmentCell = InlineImageCell(image: image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Draws the image (rounded, hairline edge) at `InlineImageLayout` size.
final class InlineImageCell: NSTextAttachmentCell {
    let picture: NSImage
    let natural: CGSize

    @MainActor
    init(image: DraftImage) {
        let art = InlineImageArt.picture(for: image)
        picture = art.image
        natural = art.size
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func cellSize() -> NSSize { natural }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let width = textContainer.size.width - textContainer.lineFragmentPadding * 2
        let size = InlineImageLayout.fit(natural, maxWidth: width)
        return NSRect(x: 0, y: 0, width: size.width, height: size.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(roundedRect: cellFrame, xRadius: 10, yRadius: 10)
        path.addClip()
        picture.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(hex: 0x1D1C1A).withAlphaComponent(0.06).setStroke()
        let edge = NSBezierPath(roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5), xRadius: 9.5, yRadius: 9.5)
        edge.lineWidth = 1
        edge.stroke()
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func wantsToTrackMouse() -> Bool { false }
}

/// The picture for an image: the file, or a drawn stand-in when it can't be read
/// (snapshots use made-up paths).
@MainActor
enum InlineImageArt {
    private static var cache: [URL: (NSImage, CGSize)] = [:]

    static func picture(for image: DraftImage) -> (image: NSImage, size: CGSize) {
        if let hit = cache[image.url] { return hit }
        let result: (NSImage, CGSize)
        if let ns = NSImage(contentsOf: image.url), ns.size.width > 0, ns.size.height > 0 {
            result = (ns, ns.size)
        } else {
            let card = image.name.lowercased().contains("card")
            let size = card ? CGSize(width: 440, height: 176) : CGSize(width: 300, height: 176)
            let renderer = ImageRenderer(content: InlineImageStandIn(card: card).frame(width: size.width, height: size.height))
            renderer.scale = 2
            result = (renderer.nsImage ?? NSImage(size: size), size)
        }
        cache[image.url] = result
        return result
    }
}

/// The design's stand-ins: a brewing card, or a photo.
struct InlineImageStandIn: View {
    var card: Bool

    var body: some View {
        if card {
            ZStack(alignment: .topLeading) {
                Color(hex: 0xE3EEFF)
                VStack(alignment: .leading, spacing: 7) {
                    Text("Gyokuro brewing card").font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(hex: 0x1F3B6E))
                    ForEach([0.88, 0.7, 0.8, 0.55, 0.64], id: \.self) { w in
                        GeometryReader { g in
                            Capsule().fill(Color(hex: 0x1F3B6E).opacity(0.18)).frame(width: g.size.width * w, height: 8)
                        }
                        .frame(height: 8)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 16)
            }
        } else {
            ZStack(alignment: .bottom) {
                LinearGradient(stops: [.init(color: Color(hex: 0xDDF2FF), location: 0), .init(color: Color(hex: 0xDDF2FF), location: 0.5),
                                       .init(color: Color(hex: 0xCDEBC0), location: 0.5), .init(color: Color(hex: 0xCDEBC0), location: 1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                UnevenRoundedRectangle(topLeadingRadius: 50, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: 50)
                    .fill(Color(hex: 0xF4E3C3)).frame(width: 100, height: 54).padding(.bottom, 30).offset(x: -10)
            }
        }
    }
}

// MARK: - Hover chrome

/// What sits over one image: hover actions and chip, selection ring, reading
/// shimmer, failure strip. Transparent where there is nothing to show.
struct InlineImageChrome: View {
    let image: DraftImage
    var state: InlineImageState?
    var selected: Bool
    var editable: Bool
    var forceHover: Bool
    var extract: () -> Void
    var cancel: () -> Void
    var remove: () -> Void
    var select: () -> Void
    var dismiss: () -> Void
    var openSettings: () -> Void
    @State private var hover = false

    private var showsActions: Bool { editable && (hover || forceHover) && state == nil }

    var body: some View {
        ZStack {
            Color.white.opacity(0.001) // takes hover and clicks over the whole image
            if case .reading(let model) = state { reading(model) }
            if showsActions { actions }
            if case .failed(let message) = state { strip("Couldn’t read this image: \(message)", settings: true) }
            if state == .noText { strip("No text found in this image.", settings: false) }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.primary, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { select() }
        .contextMenu {
            if case .reading = state {
                Button("Cancel reading", action: cancel)
            } else {
                Button("Extract content", action: extract).disabled(!editable)
            }
            Button("Remove image", action: remove).disabled(!editable)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image \(image.name)")
    }

    private var actions: some View {
        ZStack {
            VStack {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button(action: extract) {
                        HStack(spacing: 6) {
                            SparkleShape().fill(Color.white).frame(width: 12, height: 12)
                            Text("Extract content").font(Theme.body(12, .bold)).lineLimit(1)
                        }
                        .padding(.horizontal, 11).frame(height: 26)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(Theme.primary).shadow(color: Theme.primary.opacity(0.3), radius: 6, y: 4))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Read the text in this image and put it here instead")
                    Button(action: remove) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.muted)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.95)).shadow(color: Color(hex: 0x1D1C1A).opacity(0.15), radius: 3, y: 2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove image")
                    .help("Remove image")
                }
                Spacer(minLength: 0)
                HStack {
                    Text(image.chipText).font(Theme.body(10, .bold)).lineLimit(1)
                        .padding(.horizontal, 8).frame(height: 20)
                        .foregroundStyle(Color(hex: 0x48463F))
                        .background(Capsule().fill(Color.white.opacity(0.92)))
                    Spacer(minLength: 0)
                }
            }
            .padding(8)
        }
    }

    private func reading(_ model: String) -> some View {
        ZStack {
            Color.white.opacity(0.55)
            ReadingSweep()
            HStack(spacing: 8) {
                Spinner(color: Theme.primary, size: 12)
                Text("Reading with \(model)…").font(Theme.body(12, .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                Button(action: cancel) {
                    Text("Cancel").font(Theme.body(11, .bold)).foregroundStyle(Color(hex: 0x48463F))
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(Capsule().fill(Theme.panel))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 12).padding(.trailing, 6).frame(height: 30)
            .background(Capsule().fill(Color.white).shadow(color: Color(hex: 0x1D1C1A).opacity(0.18), radius: 8, y: 6))
            .fixedSize()
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func strip(_ message: String, settings: Bool) -> some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text(message).font(Theme.body(11, .semibold)).foregroundStyle(Theme.peachInk)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if editable {
                    link("Try again", extract)
                    if settings { link("Settings", openSettings) } else { link("OK", dismiss) }
                }
            }
            .padding(.leading, 11).padding(.trailing, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0xFFF4EE)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0xFFD9C5)))
        }
        .padding(8)
    }

    private func link(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(Theme.body(11, .bold)).foregroundStyle(Theme.primary).fixedSize() }
            .buttonStyle(.plain)
    }
}

/// The light band that sweeps across an image while it is read.
private struct ReadingSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, Color.white.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.4)
                .rotationEffect(.degrees(10))
                .offset(x: -g.size.width * 0.4 + phase * g.size.width * 1.4)
        }
        .onAppear {
            phase = 0.5
            guard !reduceMotion else { return }
            phase = 0
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
        }
        .allowsHitTesting(false)
    }
}

/// The four-point sparkle of the design (24-unit path).
struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        p.move(to: pt(12, 3)); p.addLine(to: pt(13.8, 8.2)); p.addLine(to: pt(19, 10)); p.addLine(to: pt(13.8, 11.8))
        p.addLine(to: pt(12, 17)); p.addLine(to: pt(10.2, 11.8)); p.addLine(to: pt(5, 10)); p.addLine(to: pt(10.2, 8.2))
        p.closeSubpath()
        return p
    }
}

/// "✦ Extracted from brewing-card.png by Haiku · Undo ⌘Z" under extracted text.
struct ExtractedNoteLine: View {
    let name: String
    let model: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SparkleShape().fill(Color(hex: 0x5B8C1E)).frame(width: 12, height: 12)
            Text("Extracted from \(name) by \(model)").font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(1)
            Button(action: undo) { Text("Undo ⌘Z").font(Theme.body(11, .bold)).foregroundStyle(Theme.primary).fixedSize() }
                .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
    }
}

/// An NSHostingView that takes the first click (the window may not be key).
final class InlineOverlayHost: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Controller: conversion, insertion, extract, overlays

/// The just-extracted text: tinted, with the note line under it, until the next edit or a few seconds.
struct ExtractedText {
    var range: NSRange
    var name: String
    var model: String
    let attachment: InlineImageAttachment
}

extension MarkdownEditorController {
    static let attachmentChar = "\u{FFFC}"

    /// The binding's Markdown for the text view's storage (`![[name]]` for each image).
    static func markdown(from s: NSAttributedString) -> String {
        let str = s.string
        guard str.contains(attachmentChar) else { return str }
        let ns = str as NSString
        var out = ""
        var last = 0
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, range, _ in
            guard let att = value as? InlineImageAttachment else { return }
            for i in range.location..<NSMaxRange(range) where ns.character(at: i) == 0xFFFC {
                out += ns.substring(with: NSRange(location: last, length: i - last))
                out += ComposeDraft.embed(att.draftImage.name)
                last = i + 1
            }
        }
        out += ns.substring(from: last)
        // An object character without an image (pasted from elsewhere) has nothing to save.
        return out.replacingOccurrences(of: attachmentChar, with: "")
    }

    /// Markdown as the text view's storage: each `![[name]]` of a known image becomes its attachment.
    static func attributed(_ markdown: String, images: [String: DraftImage], attributes: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(string: markdown, attributes: attributes)
        guard !images.isEmpty, markdown.contains("![[") else { return out }
        let ns = markdown as NSString
        for m in ComposeDraft.embedPattern.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: m.range(at: 1))
            guard ns.substring(with: m.range) == ComposeDraft.embed(name), let image = images[name] else { continue }
            let a = NSMutableAttributedString(attachment: InlineImageAttachment(image: image))
            a.addAttributes(attributes, range: NSRange(location: 0, length: a.length))
            out.replaceCharacters(in: m.range, with: a)
        }
        return out
    }

    func markdownText() -> String {
        guard let storage = textView?.textStorage else { return "" }
        return Self.markdown(from: storage)
    }

    /// True when `text` embeds an image this editor knows (paste and drop turn those back into images).
    func embedsKnownImage(_ text: String) -> Bool {
        guard let images = imageHost?.images, !images.isEmpty else { return false }
        return ComposeDraft.embeds(in: text).contains { images[$0] != nil }
    }

    /// Replace the selection with Markdown, its known embeds as images (undoable).
    @discardableResult
    func insertMarkdown(_ markdown: String) -> Bool {
        guard let tv = textView, let storage = tv.textStorage, tv.isEditable else { return false }
        let insert = Self.attributed(markdown, images: imageHost?.images ?? [:], attributes: MarkdownStyler.baseAttributes(size: size))
        let range = tv.selectedRange()
        guard tv.shouldChangeText(in: range, replacementString: insert.string) else { return false }
        storage.replaceCharacters(in: range, with: insert)
        tv.didChangeText()
        let end = NSRange(location: range.location + insert.length, length: 0)
        tv.setSelectedRange(end)
        tv.scrollRangeToVisible(end)
        return true
    }

    // MARK: Insert

    /// Images at the cursor, each on its own line; typing carries on under them.
    @discardableResult
    func insertImages(_ images: [DraftImage]) -> Bool {
        guard let tv = textView, let storage = tv.textStorage, tv.isEditable, !images.isEmpty else { return false }
        let attrs = MarkdownStyler.baseAttributes(size: size)
        let ns = storage.string as NSString
        let sel = tv.selectedRange()
        let atLineStart = sel.location == 0 || ns.character(at: sel.location - 1) == 0x0A
        let end = NSMaxRange(sel)
        let atTextEnd = end >= ns.length
        let atLineEnd = atTextEnd || ns.character(at: end) == 0x0A
        let insert = NSMutableAttributedString()
        if !atLineStart { insert.append(NSAttributedString(string: "\n", attributes: attrs)) }
        for (i, image) in images.enumerated() {
            if i > 0 { insert.append(NSAttributedString(string: "\n", attributes: attrs)) }
            let a = NSMutableAttributedString(attachment: InlineImageAttachment(image: image))
            a.addAttributes(attrs, range: NSRange(location: 0, length: a.length))
            insert.append(a)
        }
        if atTextEnd || !atLineEnd { insert.append(NSAttributedString(string: "\n", attributes: attrs)) }
        if tv.window?.firstResponder !== tv { tv.window?.makeFirstResponder(tv) }
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(in: sel, replacementString: insert.string) else { return false }
        storage.replaceCharacters(in: sel, with: insert)
        tv.didChangeText()
        tv.undoManager?.setActionName(images.count == 1 ? "Add Image" : "Add Images")
        // After the image: at the start of the next line (the text under it, or the new empty line).
        let cursor = sel.location + insert.length + (!atTextEnd && atLineEnd ? 1 : 0)
        let caret = NSRange(location: min(cursor, storage.length), length: 0)
        tv.setSelectedRange(caret)
        tv.scrollRangeToVisible(caret)
        return true
    }

    /// Register images with the draft, then insert them at the cursor.
    @discardableResult
    func addImages(_ images: [DraftImage]) -> Bool {
        guard let host = imageHost, !images.isEmpty else { return false }
        return insertImages(host.register(images))
    }

    /// ⌘V in the text view: an image clipboard (image files, or picture data with no text) becomes images here.
    func pasteImages(from pb: NSPasteboard) -> Bool {
        guard imageHost != nil, ComposeImageIntake.hasImage(pb) else { return false }
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard files.contains(where: DraftImage.isImage) || pb.string(forType: .string) == nil else { return false }
        return addImages(ComposeImageIntake.images(from: pb))
    }

    /// The Image button at the end of the full bar.
    func chooseImages() {
        addImages(ComposeImageIntake.choose())
    }

    // MARK: Find, select, remove

    func range(of attachment: InlineImageAttachment) -> NSRange? {
        guard let storage = textView?.textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if (value as AnyObject?) === attachment { found = NSRange(location: range.location, length: 1); stop.pointee = true }
        }
        return found
    }

    func selectImage(_ attachment: InlineImageAttachment) {
        guard let tv = textView, let r = range(of: attachment) else { return }
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(r)
        refreshImageOverlays()
    }

    /// × or Remove image: the image and, when it had the line to itself, its line break (undoable).
    func removeImage(_ attachment: InlineImageAttachment) {
        guard let tv = textView, let storage = tv.textStorage, tv.isEditable, var r = range(of: attachment) else { return }
        cancelRead(attachment)
        let ns = storage.string as NSString
        let line = ns.lineRange(for: r)
        if ns.substring(with: line).trimmingCharacters(in: .newlines) == Self.attachmentChar {
            if NSMaxRange(line) > NSMaxRange(r) { r = line } else if r.location > 0 { r = NSRange(location: r.location - 1, length: 2) }
        }
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(in: r, replacementString: "") else { return }
        storage.replaceCharacters(in: r, with: "")
        tv.didChangeText()
        tv.undoManager?.setActionName("Remove Image")
        tv.setSelectedRange(NSRange(location: min(r.location, storage.length), length: 0))
    }

    // MARK: Extract content

    func extractImage(_ attachment: InlineImageAttachment) {
        guard let host = imageHost, textView?.isEditable == true else { return }
        let id = ObjectIdentifier(attachment)
        guard readTasks[id] == nil else { return }
        let name = attachment.draftImage.name, image = attachment.draftImage
        let extract = host.extract, setState = host.setState
        setState(name, .reading(model: host.readingModel()))
        let task = Task { [weak self, weak attachment] in
            do {
                let result = try await extract(image)
                if Task.isCancelled { return }
                self?.readTasks[id] = nil
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    setState(name, .noText)
                } else {
                    setState(name, nil)
                    if let self, let attachment { self.replaceImage(attachment, with: text, model: result.model) }
                }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                self?.readTasks[id] = nil
                setState(name, .failed(Self.readFailure(error)))
            }
        }
        readTasks[id] = (name, task)
    }

    static func readFailure(_ error: Error) -> String {
        var message = (error as? CoreClientError)?.description ?? error.localizedDescription
        while message.hasSuffix(".") { message.removeLast() }
        return message + "."
    }

    func cancelRead(_ attachment: InlineImageAttachment) {
        guard let (name, task) = readTasks.removeValue(forKey: ObjectIdentifier(attachment)) else { return }
        task.cancel()
        imageHost?.setState(name, nil)
    }

    /// The editor goes away (mode switch, window closed): stop every reading so Add to queue is never stuck.
    func cancelAllReads() {
        let tasks = readTasks
        readTasks = [:]
        guard let setState = imageHost?.setState else { return }
        for (name, task) in tasks.values {
            task.cancel()
            // Not during the SwiftUI update that tears the editor down.
            DispatchQueue.main.async { setState(name, nil) }
        }
    }

    /// The image becomes the Markdown read from it, in place; ⌘Z brings it back.
    func replaceImage(_ attachment: InlineImageAttachment, with markdown: String, model: String) {
        guard let tv = textView, let storage = tv.textStorage, let r = range(of: attachment) else { return }
        let insert = Self.attributed(markdown, images: imageHost?.images ?? [:], attributes: MarkdownStyler.baseAttributes(size: size))
        let selection = tv.selectedRange()
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(in: r, replacementString: insert.string) else { return }
        extractEditing = true
        storage.replaceCharacters(in: r, with: insert)
        tv.didChangeText()
        extractEditing = false
        tv.undoManager?.setActionName("Extract Content")
        tv.breakUndoCoalescing()
        // Keep the cursor where the user was typing.
        let delta = insert.length - r.length
        if selection.location >= NSMaxRange(r) {
            tv.setSelectedRange(NSRange(location: selection.location + delta, length: selection.length))
        }
        showExtracted(ExtractedText(range: NSRange(location: r.location, length: insert.length), name: attachment.draftImage.name,
                                    model: model, attachment: attachment), timed: true)
    }

    func showExtracted(_ ex: ExtractedText?, timed: Bool) {
        extracted = ex
        extractedClear?.cancel()
        restyleNow()
        refreshImageOverlays()
        guard ex != nil, timed else { return }
        let work = DispatchWorkItem { [weak self] in self?.showExtracted(nil, timed: false) }
        extractedClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// The note line's Undo: the extracted text goes back to the image.
    func restoreExtracted() {
        guard let ex = extracted, let tv = textView, let storage = tv.textStorage, NSMaxRange(ex.range) <= storage.length else { return }
        let a = NSMutableAttributedString(attachment: ex.attachment)
        a.addAttributes(MarkdownStyler.baseAttributes(size: size), range: NSRange(location: 0, length: a.length))
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(in: ex.range, replacementString: a.string) else { return }
        storage.replaceCharacters(in: ex.range, with: a)
        tv.didChangeText()
        tv.undoManager?.setActionName("Restore Image")
        showExtracted(nil, timed: false)
    }

    /// The tinted range while the extracted note shows.
    var extractedHighlight: NSRange? {
        guard let ex = extracted, let storage = textView?.textStorage, NSMaxRange(ex.range) <= storage.length else { return nil }
        return ex.range
    }

    /// Room under the extracted text for the note line (applied after styling).
    func addExtractedSpacing(_ storage: NSTextStorage) {
        guard let r = extractedHighlight, r.length > 0 else { return }
        let ns = storage.string as NSString
        let last = ns.paragraphRange(for: NSRange(location: NSMaxRange(r) - 1, length: 0))
        storage.enumerateAttribute(.paragraphStyle, in: last) { value, sub, _ in
            let p = ((value as? NSParagraphStyle) ?? NSParagraphStyle.default).mutableCopy() as! NSMutableParagraphStyle
            p.paragraphSpacing += 26
            storage.addAttribute(.paragraphStyle, value: p, range: sub)
        }
    }

    // MARK: Overlays

    /// Rect of the image at `index` in the text view's (flipped) coordinates.
    func imageFrame(at index: Int) -> NSRect? {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        lm.ensureLayout(for: tc)
        let glyph = lm.glyphIndexForCharacter(at: index)
        guard glyph < lm.numberOfGlyphs else { return nil }
        let frag = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let pos = lm.location(forGlyphAt: glyph)
        let size = lm.attachmentSize(forGlyphAt: glyph)
        guard size.width > 0, size.height > 0 else { return nil }
        let o = tv.textContainerOrigin
        return NSRect(x: frag.minX + pos.x + o.x, y: frag.minY + pos.y - size.height + o.y, width: size.width, height: size.height)
    }

    /// Place (or remove) the chrome over each image and the extracted note line.
    func refreshImageOverlays() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        guard let host = imageHost else {
            imageOverlays.values.forEach { $0.removeFromSuperview() }
            imageOverlays = [:]
            return
        }
        var live = Set<ObjectIdentifier>()
        let selection = tv.selectedRange()
        let focused = tv.window?.firstResponder === tv
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let att = value as? InlineImageAttachment, let frame = imageFrame(at: range.location) else { return }
            let id = ObjectIdentifier(att)
            live.insert(id)
            let name = att.draftImage.name
            let selected = host.fixture?.selected == name || (focused && selection == NSRange(location: range.location, length: 1))
            let chrome = InlineImageChrome(
                image: att.draftImage, state: host.states[name], selected: selected, editable: tv.isEditable,
                forceHover: host.fixture?.hovered == name,
                extract: { [weak self, weak att] in if let att { self?.extractImage(att) } },
                cancel: { [weak self, weak att] in if let att { self?.cancelRead(att) } },
                remove: { [weak self, weak att] in if let att { self?.removeImage(att) } },
                select: { [weak self, weak att] in if let att { self?.selectImage(att) } },
                dismiss: { host.setState(name, nil) },
                openSettings: host.openSettings)
            let root = AnyView(chrome.environment(\.colorScheme, .light))
            let view: InlineOverlayHost
            if let existing = imageOverlays[id] {
                view = existing
                view.rootView = root
            } else {
                view = InlineOverlayHost(rootView: root)
                tv.addSubview(view)
                imageOverlays[id] = view
            }
            if view.frame != frame { view.frame = frame }
        }
        for (id, view) in imageOverlays where !live.contains(id) {
            view.removeFromSuperview()
            imageOverlays[id] = nil
        }
        placeExtractedNote()
    }

    private func placeExtractedNote() {
        guard let tv = textView, let lm = tv.layoutManager, let ex = extracted, let r = extractedHighlight, r.length > 0 else {
            extractedNote?.removeFromSuperview()
            extractedNote = nil
            return
        }
        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: NSMaxRange(r) - 1, length: 1), actualCharacterRange: nil)
        let used = lm.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let o = tv.textContainerOrigin
        let frame = NSRect(x: o.x, y: used.maxY + o.y + 6, width: max(10, tv.bounds.width - o.x * 2), height: 18)
        let root = AnyView(ExtractedNoteLine(name: ex.name, model: ex.model) { [weak self] in self?.restoreExtracted() }
            .environment(\.colorScheme, .light))
        if let note = extractedNote {
            note.rootView = root
            note.frame = frame
        } else {
            let note = InlineOverlayHost(rootView: root)
            note.frame = frame
            tv.addSubview(note)
            extractedNote = note
        }
    }
}
