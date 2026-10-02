import AppKit
import SwiftUI
import DistillKit

/// Turns a pasteboard (clipboard or drag) into queue files.
@MainActor
enum PasteboardIntake {
    static let dragTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .string]

    /// Set while the Write a note composer is on screen: a paste goes into the
    /// note (images get Keep / Extract) instead of becoming a queue file. It
    /// returns false when the composer's window is not key, so the queue
    /// behavior is unchanged everywhere else.
    static var composeTarget: ((NSPasteboard) -> Bool)?

    /// Paste (⌘V, Paste into Queue) and drops. Drops pass `allowCompose: false`:
    /// dropping on the queue panel or the flask always queues the files.
    @discardableResult
    static func ingest(_ pb: NSPasteboard, engine: AppModel, allowCompose: Bool = true) -> Bool {
        if allowCompose, let target = composeTarget, target(pb) { return true }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            engine.enqueue(files: urls)
            return true
        }
        if let png = pngData(pb) {
            engine.enqueue(data: png, prefix: "Screenshot", ext: "png")
            return true
        }
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            engine.enqueue(data: Data(text.utf8), prefix: "Clipping", ext: "md")
            return true
        }
        return false
    }

    private static func pngData(_ pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        let tiff = pb.data(forType: .tiff) ?? NSImage(pasteboard: pb)?.tiffRepresentation
        guard let tiff, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// AppKit drop target; shared by the queue view and the floating icon.
class DropTargetView: NSView {
    var engine: AppModel?
    var onTargetChange: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(PasteboardIntake.dragTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onTargetChange?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTargetChange?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargetChange?(false)
        guard let engine else { return false }
        return PasteboardIntake.ingest(sender.draggingPasteboard, engine: engine, allowCompose: false)
    }
}

struct DropZone: NSViewRepresentable {
    @EnvironmentObject var engine: AppModel
    @Binding var isTargeted: Bool

    func makeNSView(context: Context) -> DropTargetView {
        let view = DropTargetView(frame: .zero)
        view.engine = engine
        view.onTargetChange = { targeted in isTargeted = targeted }
        return view
    }

    func updateNSView(_ view: DropTargetView, context: Context) {
        view.engine = engine
    }
}
