import XCTest
@testable import Distill
@testable import DistillKit

@MainActor
final class ActionsAppTests: XCTestCase {
    func testSlackCopyFormatAndInitials() {
        XCTAssertEqual(ActionText.slack("Hi **Mei**, *soon* ~~not~~ [PX-1](https://x/1)"), "Hi *Mei*, _soon_ ~not~ <https://x/1|PX-1>")
        XCTAssertEqual(ActionText.initials("Mei Tanaka"), "MT")
        XCTAssertEqual(ActionText.initials("You (Jin Liu)"), "JL")
        XCTAssertEqual(ActionText.addedWords(from: "a b c", to: "a x b c"), [1])
    }

    func testBatchStepsEndWithFindingActions() {
        XCTAssertEqual(BatchBanner.steps(["Read sources", "Ready for review"]), ["Read sources", "Ready for review", "Finding actions (after you apply)"])
        let core = ["Applied changes", "Finding actions", "Done"]
        XCTAssertEqual(BatchBanner.steps(core), core)
    }

    func testAnswerTitleIsTheFirstSentence() {
        XCTAssertEqual(AnswerActionButtons.title("You said you’d **book the room** [1]. Then more."), "You said you’d book the room")
    }

    func testFoundBlockMatchesItemsToTheirAnswer() {
        let e = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
        let store = e.actions
        func item(_ id: String, turn: Int?, quote: String, gap: Bool = false, status: ActionStatus = .pending) -> ActionItem {
            ActionItem(id: id, status: status, title: id,
                       source: .ask(conversationID: "c", question: nil, quote: quote, citedPaths: [], turnIndex: turn, gap: gap))
        }
        store.loadFixture(types: [], items: [item("t0", turn: 0, quote: "x"), item("t1", turn: 1, quote: "y"),
                                             item("q", turn: nil, quote: "book the room"), item("g", turn: 1, quote: "z", gap: true),
                                             ActionItem(id: "other", title: "o", source: .ask(conversationID: "d", question: nil, quote: nil, citedPaths: [], turnIndex: 0, gap: false))])
        XCTAssertEqual(Set(store.askItems(conversationID: "c", turnIndex: 0, answer: "You said you'd book the room.", isLast: false).map(\.id)), ["q", "t0"])
        XCTAssertEqual(Set(store.askItems(conversationID: "c", turnIndex: 1, answer: "Other", isLast: false).map(\.id)), ["t1", "g"])
        XCTAssertTrue(store.gapTaken(conversationID: "c", turnIndex: 1, answer: "Other", isLast: true))
        XCTAssertFalse(store.gapTaken(conversationID: "c", turnIndex: 0, answer: "", isLast: false))
        store.items["g"]?.status = .dismissed
        XCTAssertFalse(store.gapTaken(conversationID: "c", turnIndex: 1, answer: "Other", isLast: true), "a dismissed gap item shows the callout again")
    }

    func testEventsUpdateTheStore() {
        let e = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
        let store = e.actions
        store.loadFixture(types: [ActionTypeInfo(id: "todo", label: "To-do", pluralLabel: "To do")], items: [])
        store.apply(ActionItem(id: "a", title: "A"), deleted: false)
        store.apply(ActionItem(id: "b", status: .pending, title: "B"), deleted: false)
        XCTAssertEqual(store.counts, ["todo": 1])
        XCTAssertEqual(store.pending.map(\.id), ["b"])
        store.running["a"] = .drafting(Date())
        store.apply(ActionItem(id: "a", status: .ready, title: "A"), deleted: false)
        XCTAssertNil(store.running["a"])
        store.apply(ActionItem(id: "a", title: "A"), deleted: true)
        XCTAssertNil(store.items["a"])
    }
}
