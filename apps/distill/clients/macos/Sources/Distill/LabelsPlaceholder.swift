import SwiftUI
import DistillKit

// DELETE ON MERGE: placeholders for the mac-notes branch, which defines the
// real `LabelsSection` (Labels.swift), `labelsToReviewCount` and
// `noteLabelSuggestions` (AppModel+Notes.swift). They exist only so this
// branch compiles on its own.

struct LabelsSection: View {
    var body: some View {
        EmptyState(title: "Labels", message: "Label review arrives with the notes branch.")
    }
}

extension AppModel {
    var labelsToReviewCount: Int { 0 }
    func noteLabelSuggestions(requestID: String, notePath: String, labels: [LabelSuggestion], error: String?) {}
}
