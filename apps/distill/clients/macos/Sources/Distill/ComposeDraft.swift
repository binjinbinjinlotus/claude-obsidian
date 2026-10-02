import AppKit
import DistillKit

/// One image in the composer, staged as a file so `addNote` can copy it.
struct DraftImage: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var mode: NoteImage.Mode
    /// Pasted images live in a temp folder we delete after queueing; chosen
    /// or dropped files are the user's and are never touched.
    let isTemporary: Bool

    var name: String { url.lastPathComponent }

    init(url: URL, mode: NoteImage.Mode = .keep, isTemporary: Bool = false, id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.mode = mode
        self.isTemporary = isTemporary
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp"]

    static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }
}

/// The note being written (main composer or quick note).
struct ComposeDraft: Equatable {
    var title = ""
    var text = ""
    /// Source id from the taxonomy (`source_type`), or nil.
    var source: String?
    /// The group whose sources are shown (Discussion, Reference, …).
    var group: String?
    /// Link, channel or person, e.g. "#tea-club · with Mei".
    var sourceRef = ""
    var images: [DraftImage] = []

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty }
    var isEmpty: Bool { trimmedTitle.isEmpty && !hasContent && sourceRef.isEmpty }

    /// Why Add to queue is disabled (same rules as the core's validation), or nil.
    var blocker: String? {
        if !hasContent { return "Write something or add an image." }
        return nil
    }

    /// The core needs a title; a note without one gets its first line.
    var effectiveTitle: String {
        if !trimmedTitle.isEmpty { return trimmedTitle }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        if !firstLine.isEmpty { return String(firstLine.prefix(60)) }
        return images.first.map { ($0.name as NSString).deletingPathExtension } ?? "Note"
    }

    func request(suggest: Bool, vaultPath: String?) -> AddNoteRequest {
        let ref = sourceRef.trimmingCharacters(in: .whitespacesAndNewlines)
        return AddNoteRequest(
            title: effectiveTitle, text: text,
            images: images.isEmpty ? nil : images.map { NoteImage(path: $0.url.path, mode: $0.mode) },
            source: source, sourceRef: ref.isEmpty ? nil : ref, vaultPath: vaultPath,
            suggest: suggest ? .background : AddNoteRequest.Suggest.none, origin: .app)
    }

    /// "One note · 1 image attached · 1 image read as text."
    var summary: String {
        let kept = images.filter { $0.mode == .keep }.count
        let read = images.filter { $0.mode == .extract }.count
        var parts = ["One note"]
        if kept > 0 { parts.append("\(kept) \(kept == 1 ? "image" : "images") attached") }
        if read > 0 { parts.append("\(read) \(read == 1 ? "image" : "images") read as text") }
        return parts.joined(separator: " · ") + "."
    }

    mutating func toggleSource(_ id: String) {
        source = source == id ? nil : id
    }

    /// Removes pasted temp files (after queueing or Discard).
    func cleanUpTemporaryImages() {
        for image in images where image.isTemporary {
            try? FileManager.default.removeItem(at: image.url.deletingLastPathComponent())
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
}
