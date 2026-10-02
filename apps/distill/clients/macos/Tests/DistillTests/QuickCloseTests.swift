import XCTest
@testable import Distill
@testable import DistillKit

/// × or Esc on a quick window starts fresh next time (canvas: QuickSizing "Close, then open again").
@MainActor
final class QuickCloseTests: XCTestCase {
    private func model() -> AppModel {
        SlowAskProtocol.paths = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SlowAskProtocol.self]
        let app = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
        app.useClientForTesting(CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config)))
        return app
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    // MARK: Quick note

    func testClosingThrowsTheUnsavedNoteAway() {
        let app = model()
        var d = ComposeDraft()
        d.title = "Gyokuro at 60 °C"
        d.text = "Shop recommended 60 °C, 2 min first steep."
        app.notes.drafts[.quick] = d
        app.notes.addErrors[.quick] = "Couldn't queue the note."

        QuickNoteController.closed(app)

        XCTAssertNil(app.notes.drafts[.quick], "the next open is empty")
        XCTAssertEqual(app.notes.draft(.quick).title, "")
        XCTAssertEqual(app.notes.draft(.quick).text, "")
        XCTAssertNil(app.notes.addErrors[.quick])
    }

    func testClosingDuringTheLabelStepIsSkip() {
        let app = model()
        var d = ComposeDraft()
        d.title = "Gyokuro at 60 °C"
        app.notes.drafts[.quick] = d
        app.notes.steps[.quick] = LabelStep(requestID: "r1", title: "Gyokuro at 60 °C", suggesting: false)

        QuickNoteController.closed(app)

        XCTAssertNil(app.notes.steps[.quick], "× during the label step skips labeling; the note stays queued")
        XCTAssertEqual(app.notes.draft(.quick).title, "")
    }

    func testClosingWhileApplyingLabelsLeavesTheStep() {
        let app = model()
        var step = LabelStep(requestID: "r1", title: "Note", suggesting: false)
        _ = step.add("tea")
        step.applyStarted()
        XCTAssertEqual(step.phase, .applying)
        app.notes.steps[.quick] = step
        QuickNoteController.closed(app)
        XCTAssertNotNil(app.notes.steps[.quick], "applying finishes on its own")
    }

    func testClosingWhileQueueingKeepsTheDraft() {
        let app = model()
        var d = ComposeDraft()
        d.title = "Gyokuro"
        app.notes.drafts[.quick] = d
        app.notes.adding.insert(.quick)
        QuickNoteController.closed(app)
        XCTAssertEqual(app.notes.drafts[.quick]?.title, "Gyokuro", "the label step follows Add to queue")
    }

    // MARK: Quick ask

    func testClosingQuickAskKeepsTheRunAndStartsFresh() async {
        let app = model()
        let ask = app.ask
        ask.prepareQuickAsk()
        ask.quickVisible = true
        ask.quick.draft = "Best water temp for sencha?"
        ask.quick.filter.addLabel("tea")
        ask.send(ask.quick)
        XCTAssertTrue(ask.quick.isRunning)
        XCTAssertFalse(ask.quickInBackground, "no ring while the window is open")

        ask.closeQuick()

        XCTAssertTrue(ask.quick.isEmpty, "the quick chat starts over")
        XCTAssertTrue(ask.quick.filter.labels.isEmpty, "Settings defaults")
        XCTAssertEqual(ask.backgroundNew.map(\.pending.question), ["Best water temp for sencha?"], "History shows it answering")
        XCTAssertEqual(ask.quickBackgroundRun?.origin, .quick)
        XCTAssertTrue(ask.quickInBackground, "the flask's green ring")

        // Opening again: empty, while the old question keeps answering.
        ask.prepareQuickAsk()
        ask.quickVisible = true
        XCTAssertTrue(ask.quick.isEmpty)
        XCTAssertNotNil(ask.quickBackgroundRun)
        ask.quickVisible = false

        await waitUntil { ask.background.isEmpty }
        XCTAssertTrue(ask.background.isEmpty, "the answer landed (in History)")
        XCTAssertFalse(ask.quickInBackground, "the ring goes off")
        XCTAssertTrue(ask.quick.isEmpty, "the answer does not leak into the fresh chat")
        XCTAssertFalse(SlowAskProtocol.paths.contains { $0.hasSuffix("/cancel") }, "closing never stops the run")
    }

    func testOpeningQuickAskAfterAnAnswerIsFresh() async {
        let app = model()
        let ask = app.ask
        ask.quickVisible = true
        ask.quick.draft = "Best water temp for sencha?"
        ask.send(ask.quick)
        await waitUntil { !ask.quick.isRunning }
        XCTAssertEqual(ask.quick.entries.count, 1)

        // The shortcut fires again while the window is open: the chat on screen stays.
        ask.prepareQuickAsk(alreadyOpen: true)
        XCTAssertEqual(ask.quick.entries.count, 1)

        ask.closeQuick()
        ask.prepareQuickAsk()
        XCTAssertTrue(ask.quick.isEmpty)
        XCTAssertTrue(ask.background.isEmpty, "nothing was running")
    }

    func testMainWindowRunsDoNotLightTheRing() {
        let app = model()
        let ask = app.ask
        ask.main.draft = "Best water temp for sencha?"
        ask.send(ask.main)
        ask.newChat(ask.main)
        XCTAssertEqual(ask.background.values.first?.origin, .main)
        XCTAssertFalse(ask.quickInBackground)
    }

    // MARK: Size

    func testOpeningSizeIgnoresTheOldKeys() {
        let defaults = UserDefaults(suiteName: "distill.tests.quickclose")!
        defaults.removePersistentDomain(forName: "distill.tests.quickclose")
        defaults.set([420.0, 160.0], forKey: "distill.quickNote.size")
        XCTAssertEqual(QuickWindowSizer.loadFloor(QuickWindowSizer.quickNoteSizeKey, defaults: defaults), CGSize(width: 560, height: 214))
        defaults.set([700.0, 300.0], forKey: QuickWindowSizer.quickNoteSizeKey)
        XCTAssertEqual(QuickWindowSizer.loadFloor(QuickWindowSizer.quickNoteSizeKey, defaults: defaults), CGSize(width: 700, height: 300),
                       "a size the user dragged is the opening size")
        defaults.removePersistentDomain(forName: "distill.tests.quickclose")
    }
}
