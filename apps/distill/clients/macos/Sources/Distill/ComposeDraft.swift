import AppKit
import DistillKit

/// One image in the composer, staged as a file so `addNote` can copy it. The
/// note text embeds it as `![[name]]` where it sits (ImagesInline.dc.html);
/// `name` is the file's own name and is unique within a draft.
struct DraftImage: Identifiable, Equatable {
    let id: UUID
    let url: URL
    /// Pasted images (and renamed copies) live in a temp folder we delete
    /// after queueing; chosen or dropped files are the user's and are never touched.
    let isTemporary: Bool
    /// File size for the hover chip ("412 KB"); nil when unknown.
    let byteCount: Int?

    var name: String { url.lastPathComponent }

    init(url: URL, isTemporary: Bool = false, byteCount: Int? = nil, id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.isTemporary = isTemporary
        self.byteCount = byteCount ?? ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp"]

    static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

    /// "brewing-card.png · 412 KB"
    var chipText: String {
        guard let byteCount else { return name }
        return "\(name) · \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))"
    }
}

/// An inline image's reading state (Extract content). Absent = idle.
enum InlineImageState: Equatable {
    /// Being read; `model` is shown ("Reading with Haiku…").
    case reading(model: String)
    /// The reading failed; the image stays.
    case failed(String)
    /// The model found no text; the image stays.
    case noText
}

/// The note being written (main composer or quick note).
struct ComposeDraft: Equatable {
    var title = ""
    /// Markdown; images are embedded as `![[name]]` where they sit.
    var text = ""
    /// Source id from the taxonomy (`source_type`), or nil.
    var source: String?
    /// The group whose sources are shown (Discussion, Reference, …).
    var group: String?
    /// Link, channel or person, e.g. "#tea-club · with Mei".
    var sourceRef = ""
    /// Every image added to this draft, by name. Only those the text embeds are
    /// sent (an extracted or deleted image stays here so ⌘Z can bring it back).
    var images: [DraftImage] = []
    /// Reading state per image name.
    var imageStates: [String: InlineImageState] = [:]

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isEmpty: Bool { trimmedTitle.isEmpty && !hasContent && sourceRef.isEmpty }

    /// Images the text embeds, in text order (each once). These are saved with the note.
    var keptImages: [DraftImage] {
        var seen = Set<String>()
        return Self.embeds(in: text).compactMap { name in
            guard !seen.contains(name), let image = images.first(where: { $0.name == name }) else { return nil }
            seen.insert(name)
            return image
        }
    }

    /// Images being read right now (Add to queue waits for them).
    var readingCount: Int {
        imageStates.values.filter { if case .reading = $0 { return true }; return false }.count
    }

    /// Why Add to queue is disabled (same rules as the core's validation), or nil.
    var blocker: String? {
        if !hasContent { return "Write something or add an image." }
        if readingCount > 0 { return "One note · reading \(readingCount) \(readingCount == 1 ? "image" : "images")…" }
        return nil
    }

    /// The core needs a title; a note without one gets its first line of text.
    var effectiveTitle: String {
        if !trimmedTitle.isEmpty { return trimmedTitle }
        for line in text.split(whereSeparator: \.isNewline) {
            let plain = Self.removingEmbeds(String(line)).trimmingCharacters(in: .whitespaces)
            if !plain.isEmpty { return String(plain.prefix(60)) }
        }
        return keptImages.first.map { ($0.name as NSString).deletingPathExtension } ?? "Note"
    }

    func request(suggest: Bool, vaultPath: String?) -> AddNoteRequest {
        let ref = sourceRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = keptImages
        return AddNoteRequest(
            title: effectiveTitle, text: text,
            images: kept.isEmpty ? nil : kept.map { NoteImage(path: $0.url.path, mode: .keep) },
            source: source, sourceRef: ref.isEmpty ? nil : ref, vaultPath: vaultPath,
            suggest: suggest ? .background : AddNoteRequest.Suggest.none, origin: .app)
    }

    /// "One note · 2 images." (images that stay).
    var summary: String {
        let kept = keptImages.count
        return "One note" + (kept > 0 ? " · \(kept) \(kept == 1 ? "image" : "images")" : "") + "."
    }

    mutating func toggleSource(_ id: String) {
        source = source == id ? nil : id
    }

    /// Adds images to the draft and returns them as they will be embedded. An
    /// image already in the draft is reused; a different file with a taken name
    /// (or a name Obsidian can't embed) is copied to a temp folder under a free name.
    mutating func register(_ incoming: [DraftImage]) -> [DraftImage] {
        var out: [DraftImage] = []
        for image in incoming {
            if let same = images.first(where: { $0.url.standardizedFileURL == image.url.standardizedFileURL }) {
                out.append(same)
                continue
            }
            let wanted = Self.embeddableName(image.name)
            let taken = Set(images.map(\.name))
            guard wanted != image.name || taken.contains(wanted) else {
                images.append(image)
                out.append(image)
                continue
            }
            let name = Self.freeName(wanted, taken: taken)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Distill-note-\(UUID().uuidString)", isDirectory: true)
            let copy = dir.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: image.url, to: copy)
            } catch {
                continue
            }
            if image.isTemporary { try? FileManager.default.removeItem(at: image.url.deletingLastPathComponent()) }
            let staged = DraftImage(url: copy, isTemporary: true)
            images.append(staged)
            out.append(staged)
        }
        return out
    }

    /// Removes pasted temp files (after queueing or Discard).
    func cleanUpTemporaryImages() {
        for image in images where image.isTemporary {
            try? FileManager.default.removeItem(at: image.url.deletingLastPathComponent())
        }
    }

    // MARK: Embeds

    /// `![[name]]`, `![[name|300]]`: group 1 is the name.
    static let embedPattern = try! NSRegularExpression(pattern: "!\\[\\[([^\\]|#^\\n]+)(?:[|#^][^\\]\\n]*)?\\]\\]")

    static func embed(_ name: String) -> String { "![[\(name)]]" }

    /// Embedded file names, in text order.
    static func embeds(in text: String) -> [String] {
        let ns = text as NSString
        return embedPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
    }

    static func removingEmbeds(_ text: String) -> String {
        embedPattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
    }

    /// The name without characters Obsidian reads inside `![[…]]`.
    static func embeddableName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "[\\[\\]|#^]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "Image" + cleaned : cleaned
    }

    /// "card.png" → "card 2.png" while the name is taken.
    static func freeName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = "\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }
}

/// Reads images for the composer from a pasteboard (⌘V, drop): image files
/// are referenced in place, raw image data is written to a temp file.
@MainActor
enum ComposeImageIntake {
    static func images(from pb: NSPasteboard, date: Date = Date()) -> [DraftImage] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.filter(DraftImage.isImage).map { DraftImage(url: $0) }
            if !images.isEmpty { return images }
        }
        guard let png = pngData(pb) else { return [] }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Distill-note-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent(AppModel.intakeName(prefix: "Screenshot", ext: "png", date: date))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: file, options: .atomic)
            return [DraftImage(url: file, isTemporary: true)]
        } catch {
            return []
        }
    }

    static func hasImage(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: DraftImage.isImage) { return true }
        return pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil
    }

    static func choose() -> [DraftImage] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        return panel.runModal() == .OK ? panel.urls.map { DraftImage(url: $0) } : []
    }

    private static func pngData(_ pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        guard let tiff = pb.data(forType: .tiff) ?? NSImage(pasteboard: pb)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// A file the core can read (png, jpg, gif, webp): others (heic, tiff, bmp)
    /// are converted to a temp PNG; `cleanup` removes it.
    static func readable(_ image: DraftImage) -> (url: URL, cleanup: () -> Void)? {
        let ext = image.url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) { return (image.url, {}) }
        guard let ns = NSImage(contentsOf: image.url), let tiff = ns.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Distill-read-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent((image.name as NSString).deletingPathExtension + ".png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: file)
        } catch { return nil }
        return (file, { try? FileManager.default.removeItem(at: dir) })
    }
}
