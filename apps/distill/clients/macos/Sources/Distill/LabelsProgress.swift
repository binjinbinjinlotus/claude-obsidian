import Foundation
import DistillKit

/// Live progress for the label screens, from the core's `progress` events
/// (`kind` labelSuggest, key "note:<requestID>"; `kind` labelPages, key = job id).
///
struct LabelsProgress: Equatable {
    var message: String
    var done: Int?
    var total: Int?
    var startedAt: Date
    var model: String?
    var finished: Bool
    var error: String?

    @MainActor
    static func progress(_ engine: AppModel, key: String) -> LabelsProgress? {
        if let p = engine.notes.fixtureProgress[key] { return p }
        guard let p = engine.progress[key] else { return nil }
        return LabelsProgress(message: p.message, done: p.done, total: p.total, startedAt: p.startedAt,
                              model: p.model, finished: p.finished, error: p.error)
    }
}
