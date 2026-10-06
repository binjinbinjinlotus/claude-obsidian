import XCTest
@testable import Distill
@testable import DistillKit

/// action-summary.md: the summary field, clean source names, the row line and the selection after Add.
final class ActionSummaryTests: XCTestCase {
    private func decode(_ json: String) throws -> ActionItem {
        try JSONDecoder().decode(ActionItem.self, from: Data(json.utf8))
    }

    func testSummaryDecodesLenientlyAndRoundTrips() throws {
        let with = try decode(#"{"id":"a","title":"T","summary":"What it is about."}"#)
        XCTAssertEqual(with.summary, "What it is about.")
        let back = try decode(String(decoding: JSONEncoder().encode(with), as: UTF8.self))
        XCTAssertEqual(back.summary, "What it is about.")
        XCTAssertNil(try decode(#"{"id":"a","title":"T"}"#).summary, "older items have none")
        XCTAssertNil(try decode(#"{"id":"a","title":"T","summary":42}"#).summary, "a wrong type reads as missing")
        XCTAssertNil(try decode(#"{"id":"a","title":"T","summary":"  "}"#).summary, "blank reads as missing")
    }

    func testSourceNamesArePlainText() {
        XCTAssertEqual(ActionContextText.plainTitle("**✍ Quick notes**"), "✍ Quick notes")
        XCTAssertEqual(ActionContextText.plainTitle("# _Team_ `sync`"), "Team sync")
        XCTAssertEqual(ActionContextText.plainTitle("[[Polaris|Polaris stack]] notes"), "Polaris stack notes")
        XCTAssertEqual(ActionContextText.plainTitle("snake_case_name"), "snake_case_name")
        XCTAssertEqual(ActionContextText.plainTitle("**"), "**")
    }

    func testRowLineFallsBackToSummarizingThenWhy() {
        var item = ActionItem(id: "a", title: "T", why: "Mei asked")
        XCTAssertEqual(ActionSummaryText.rowLine(item, summarizing: false), .init(text: "Why: Mei asked", italic: true))
        XCTAssertEqual(ActionSummaryText.rowLine(item, summarizing: true), .init(text: "Summarizing…", italic: true))
        item.summary = "Book the room for the tea club."
        XCTAssertEqual(ActionSummaryText.rowLine(item, summarizing: true), .init(text: "Book the room for the tea club.", italic: false))
        XCTAssertNil(ActionSummaryText.rowLine(ActionItem(id: "b", title: "T"), summarizing: false))
    }

    func testSelectionMovesToTheNextRowAfterAddOrDismiss() {
        XCTAssertEqual(ConfirmSelection.next(after: "b", in: ["a", "b", "c"]), "c")
        XCTAssertEqual(ConfirmSelection.next(after: "c", in: ["a", "b", "c"]), "b")
        XCTAssertNil(ConfirmSelection.next(after: "a", in: ["a"]))
        XCTAssertEqual(ConfirmSelection.next(after: "x", in: ["a", "b"]), "a")
    }
}

/// A stale "applying" mark (approve came back to Review without applying) must not keep Send reply disabled.
final class ApplyFlagTests: XCTestCase {
    func testClaudeComingBackClearsTheMark() throws {
        let since = Date(timeIntervalSince1970: 1_000)
        var job = try JSONDecoder().decode(Job.self, from: Data(#"{"id":"j","state":"awaitingApproval","vaultPath":"/v"}"#.utf8))
        XCTAssertFalse(ApplyFlag.cameBack(job, since: since), "no answer yet: still applying")
        job.turns = [TurnRecord(id: "t", date: since.addingTimeInterval(-5), author: .worker, text: "plan")]
        XCTAssertFalse(ApplyFlag.cameBack(job, since: since), "an older turn doesn't count")
        job.turns.append(TurnRecord(id: "u", date: since.addingTimeInterval(30), author: .worker, text: "Apply did not run"))
        XCTAssertTrue(ApplyFlag.cameBack(job, since: since))
    }
}
