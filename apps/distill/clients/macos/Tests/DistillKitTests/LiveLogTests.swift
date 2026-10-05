import XCTest
@testable import DistillKit

final class LiveLogTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_791_200_000)

    func step(_ id: String, _ s: Double, _ phase: String = "agent", _ verb: String = "read", _ text: String = "Read “a”",
              state: String = "done", kind: String = "step", count: String? = nil, parent: String? = nil, detail: String? = nil) -> JobStep {
        JobStep(id: id, at: t0.addingTimeInterval(s), phase: phase, kind: kind, state: state, verb: verb, text: text,
                detail: detail, count: count, parent: parent)
    }

    func testJobStepEventAndPageDecodeLeniently() throws {
        let json = #"{"type":"job.step","jobId":"job-1","step":{"id":"a1-3","at":"2026-10-05T03:37:18.501Z","phase":"agent","kind":"step","state":"running","verb":"read","text":"Read “Kettle”","detail":"Read · inbox/Kettle.md","extra":1}}"#
        guard case .jobStep(let jobId, let s) = try CoreEvent.decode(Data(json.utf8)) else { return XCTFail("not a job step") }
        XCTAssertEqual(jobId, "job-1")
        XCTAssertEqual(s.state, "running")
        XCTAssertEqual(s.detail, "Read · inbox/Kettle.md")
        // A step this build can't read is a line it doesn't show, not a broken stream.
        let bad = #"{"type":"job.step","jobId":"job-1","step":{"text":"no id"}}"#
        XCTAssertEqual(try CoreEvent.decode(Data(bad.utf8)), .unknown(type: "job.step"))
        let page = try JSONDecoder.core.decode(JobStepsPage.self, from: Data(#"{"jobId":"j","steps":[{"id":"x","text":"t"},{"bad":true}],"kept":true}"#.utf8))
        XCTAssertEqual(page.steps.map(\.id), ["x"])
        XCTAssertTrue(page.kept)
        let old = try JSONDecoder.core.decode(JobStepsPage.self, from: Data(#"{"jobId":"j","steps":[],"kept":false}"#.utf8))
        XCTAssertFalse(old.kept)
    }

    func testProgressCurrentAndRunOutputLogAndRuntimeDecode() throws {
        let p = try JSONDecoder.core.decode(CoreProgress.self, from: Data(#"{"key":"j","kind":"batch","message":"m","startedAt":"2026-10-05T03:33:13Z","current":"inbox/a.md"}"#.utf8))
        XCTAssertEqual(p.current, "inbox/a.md")
        let run = try JSONDecoder.core.decode(CollectorRun.self, from: Data(#"{"id":"r","result":"success","outputLog":[{"stream":"stderr","text":"x\n","at":"2026-10-05T10:14:01Z"},{"stream":"other","text":"y"}],"runtime":{"label":"python3 (.venv)","path":"/Users/me/col/.venv/bin/python3"}}"#.utf8))
        XCTAssertEqual(run.outputLog.map(\.stream), ["stderr", "stdout"])
        XCTAssertEqual(run.runtime?.label, "python3 (.venv)")
        XCTAssertEqual(run.runtime?.line(home: "/Users/me"), "python3 (.venv) · ~/…/.venv/bin/python3")
        XCTAssertEqual(CollectorRuntime(label: "zsh", path: "/bin/zsh").line(home: "/Users/me"), "zsh · /bin/zsh")
        // Round trip keeps them.
        let back = try JSONDecoder.core.decode(CollectorRun.self, from: JSONEncoder().encode(run))
        XCTAssertEqual(back.outputLog, run.outputLog)
        XCTAssertEqual(back.runtime, run.runtime)
    }

    func testMergeKeepsFirstOrderAndNewestVersion() {
        var steps = LiveLog.merge([], step("a", 0, state: "running"))
        steps = LiveLog.merge(steps, step("b", 1))
        steps = LiveLog.merge(steps, step("a", 0, state: "done"))
        XCTAssertEqual(steps.map(\.id), ["a", "b"])
        XCTAssertEqual(steps[0].state, "done")
    }

    func testRowsPhasesFoldingNotesAndTimes() {
        var steps = [step("m", 0, "prepare", "move", "Moved 3 files from the queue to your inbox")]
        for i in 0..<4 { steps.append(step("r\(i)", 240 + Double(i), "agent", "read", "Read “f\(i)”")) }
        steps.append(step("n", 300, "agent", "note", "Still reading.", kind: "note"))
        steps.append(step("c", 301, "agent", "command", "Ran a command: shasum"))
        steps.append(step("w", 302, "agent", "write", "Wrote a draft (s1.md)", state: "running"))
        let rows = LiveLog.rows(steps, runner: "Claude", calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(rows.map(\.kind), [.phase, .step, .phase, .group, .note, .step, .step])
        XCTAssertEqual(rows[0].text, "GETTING READY")
        XCTAssertEqual(rows[2].text, "CLAUDE’S STEPS")
        XCTAssertEqual(rows[3].text, "Read 4 sources")
        XCTAssertEqual(rows[4].text, "“Still reading.”")
        // The time shows only when the minute changes (the phase head carries it).
        XCTAssertNil(rows[1].time)
        XCTAssertNil(rows[3].time)
        XCTAssertNotNil(rows[4].time)
        // Opened, the group lists its steps at level 1.
        let open = LiveLog.rows(steps, expanded: ["g-r0"], details: true)
        XCTAssertEqual(open.filter { $0.level == 1 }.count, 4)
        XCTAssertNil(open.first { $0.id == "r0" }?.detail)
        // Two in a row stay as they are.
        XCTAssertEqual(LiveLog.rows(Array(steps.prefix(3))).filter { $0.kind == .group }.count, 0)
    }

    func testRunningDraftsGroupAndDetails() {
        let steps = (1...4).map { step("w\($0)", Double($0), "agent", "write", "Wrote a draft (s\($0).md)", state: $0 == 4 ? "running" : "done", detail: "Write · d/s\($0).md") }
        let rows = LiveLog.rows(steps)
        XCTAssertEqual(rows[1].text, "Writing drafts")
        XCTAssertEqual(rows[1].count, "4 so far")
        XCTAssertEqual(rows[1].state, "running")
        let done = LiveLog.rows(steps.map { var s = $0; s.state = "done"; return s })
        XCTAssertEqual(done[1].text, "Wrote 4 drafts")
        let single = LiveLog.rows([steps[0]], details: true)
        XCTAssertEqual(single[1].detail, "Write · d/s1.md")
    }

    func testLabelsGroupOpenWhileRunningFoldsOlderFiles() {
        var steps = [step("labels", 0, "prepare", "labels", "Suggesting labels", state: "running", count: "6 of 8")]
        for i in 0..<6 { steps.append(step("l\(i)", Double(i), "prepare", "label", "File \(i)", count: "2 labels", parent: "labels")) }
        steps.append(step("l6", 7, "prepare", "label", "File 6", state: "running", parent: "labels"))
        let rows = LiveLog.rows(steps)
        let group = rows.first { $0.id == "labels" }!
        XCTAssertEqual(group.kind, .group)
        XCTAssertTrue(group.expanded)
        XCTAssertEqual(group.progress?.done, 6)
        XCTAssertEqual(group.progress?.total, 8)
        XCTAssertEqual(rows.filter { $0.level == 1 }.map(\.text), ["4 files done", "File 4", "File 5", "File 6"])
        // The user closed it.
        XCTAssertEqual(LiveLog.rows(steps, expanded: ["labels"]).filter { $0.level == 1 }.count, 0)
        // Three labels running at once (a 3-wide pool): all of them show.
        var pool = steps
        pool.append(step("l7", 8, "prepare", "label", "File 7", state: "running", parent: "labels"))
        XCTAssertEqual(LiveLog.rows(pool).filter { $0.state == "running" && $0.level == 1 }.count, 2)
        XCTAssertEqual(LiveLog.now(pool), "Labeling “File 7”")
    }

    func testSettledLeavesNoSpinnerAfterTheJob() {
        let steps = [step("a", 0, state: "running"), step("b", 1, "review", "review", "Waiting for your review", state: "review"), step("c", 2)]
        XCTAssertEqual(LiveLog.settled(steps, job: .running).map(\.state), ["running", "review", "done"])
        XCTAssertEqual(LiveLog.settled(steps, job: .awaitingApproval).map(\.state), ["done", "review", "done"])
        XCTAssertEqual(LiveLog.settled(steps, job: .completed).map(\.state), ["done", "done", "done"])
        XCTAssertEqual(LiveLog.settled(steps, job: .failed).map(\.state), ["failed", "done", "done"])
    }

    func testNowLineAndCopy() {
        let steps = [step("m", 0, "prepare", "move", "Moved 2 files from the queue to your inbox"),
                     step("r", 60, "agent", "read", "Read “Kettle”", state: "running", detail: "Read · inbox/Kettle.md"),
                     step("n", 61, "agent", "note", "Reading.", kind: "note")]
        XCTAssertEqual(LiveLog.now(steps), "Read “Kettle”")
        XCTAssertEqual(LiveLog.now([steps[0]]), "Moved 2 files from the queue to your inbox")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let text = LiveLog.copyText(steps, title: "Batch · 2 files", calendar: cal)
        XCTAssertEqual(text.components(separatedBy: "\n").count, 4)
        XCTAssertTrue(text.contains("Read “Kettle”   [Read · inbox/Kettle.md]"))
        XCTAssertTrue(text.contains("Note: “Reading.”"))
    }

    func testOutputRowsStreamsTimesAndCopy() {
        let chunks = [CollectorOutputChunk(stream: "stdout", text: "$ python3 x.py\nhello\n", at: t0),
                      CollectorOutputChunk(stream: "stderr", text: "oops\n", at: t0),
                      CollectorOutputChunk(stream: "stdout", text: "[exit 0]\n", at: t0.addingTimeInterval(2))]
        let rows = LiveLog.outputRows(chunks)
        XCTAssertEqual(rows.map(\.stream), ["cmd", "stdout", "stderr", "system"])
        XCTAssertEqual(rows.map { $0.time != nil }, [true, false, false, true])
        XCTAssertEqual(LiveLog.copyOutput(chunks, title: "T"), "T\n$ python3 x.py\nhello\nerr  oops\n[exit 0]")
    }

    func testAppendMergesWithinASecondAndStaysBounded() {
        var c = LiveLog.append([], stream: "stdout", text: "a", at: t0)
        c = LiveLog.append(c, stream: "stdout", text: "b", at: t0.addingTimeInterval(0.2))
        c = LiveLog.append(c, stream: "stderr", text: "c", at: t0.addingTimeInterval(0.3))
        XCTAssertEqual(c.map(\.text), ["ab", "c"])
        var big: [CollectorOutputChunk] = []
        for i in 0..<20 { big = LiveLog.append(big, stream: i % 2 == 0 ? "stdout" : "stderr", text: String(repeating: "x", count: 10), at: t0.addingTimeInterval(Double(i)), limit: 55) }
        XCTAssertLessThanOrEqual(big.reduce(0) { $0 + $1.text.utf8.count }, 55)
        XCTAssertEqual(big.last?.stream, "stderr")
    }
}
