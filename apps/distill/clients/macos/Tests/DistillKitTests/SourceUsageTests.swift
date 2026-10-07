import XCTest
@testable import DistillKit

/// Review's "used in" (SourceUsage.swift): which changed paths are pages, and reading them from a
/// transaction bundle or the vault, in a temp folder.
final class SourceUsageTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("distill-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ text: String) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func bundle(_ writes: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["operation_id": "op", "writes": writes])
        let url = dir.appendingPathComponent("bundle.json")
        try data.write(to: url)
        return url.path
    }

    func testWhatCountsAsAPage() {
        XCTAssertTrue(SourceUsage.isPage("wiki/concepts/Retry.MD"))
        XCTAssertTrue(SourceUsage.isPage("wiki/sub/log.md"), "only the vault's own log is bookkeeping")
        XCTAssertFalse(SourceUsage.isPage("wiki/a.json"))
        XCTAssertFalse(SourceUsage.isPage("wiki/hot.md"))
        XCTAssertFalse(SourceUsage.isPage("wiki/index.md"))
        XCTAssertFalse(SourceUsage.isPage(".raw/notes.md"))
        XCTAssertFalse(SourceUsage.isPage(".vault-meta/x.md"))
        XCTAssertEqual(SourceUsage.title("wiki/concepts/Retry policy.md"), "Retry policy")
        XCTAssertEqual(SourceUsage.title("Plain"), "Plain")
    }

    func testUsedInNeedsAPathNotABareName() {
        let pages: [(path: String, text: String)] = [(path: "wiki/a.md", text: "notes/x.md and y.md"), (path: "wiki/b.md", text: "inbox/y.md")]
        // A queue file at the top of the inbox: only its full path counts.
        XCTAssertEqual(SourceUsage.pages(using: "inbox/y.md", in: pages), ["b"])
        // A bare name is never enough.
        XCTAssertEqual(SourceUsage.pages(using: "y.md", in: pages), [])
        // Outside the inbox: the path as given.
        XCTAssertEqual(SourceUsage.pages(using: "other/2026/notes/x.md", in: pages), [])
        XCTAssertEqual(SourceUsage.pages(using: "inbox/2026/notes/x.md", in: pages), ["a"])
        XCTAssertEqual(SourceUsage.pages(using: "inbox/2026/x.md", in: pages), [], "x.md alone is a bare name")
    }

    func testBundlePagesReadInlineAndFileContent() throws {
        try write("drafts/b.md", "body of b")
        try write("/abs-c.md", "body of c")
        let path = try bundle([
            ["path": "wiki/a.md", "content": "body of a"],
            ["path": "wiki/b.md", "content_file": "drafts/b.md"],
            ["path": "wiki/c.md", "content_file": dir.appendingPathComponent("abs-c.md").path],
            ["path": "wiki/log.md", "content": "log"],
            ["path": "wiki/d.md"],
            ["content": "no path"],
        ])
        let all = try XCTUnwrap(SourceUsage.bundlePages(path, changed: []))
        XCTAssertEqual(all.map(\.path), ["wiki/a.md", "wiki/b.md", "wiki/c.md"])
        XCTAssertEqual(all.map(\.text), ["body of a", "body of b", "body of c"])
        // Only the changed pages, when the plan lists them (bookkeeping in the list doesn't narrow it to nothing).
        let some = try XCTUnwrap(SourceUsage.bundlePages(path, changed: ["wiki/b.md", "wiki/log.md"]))
        XCTAssertEqual(some.map(\.path), ["wiki/b.md"])
        let bookkeepingOnly = try XCTUnwrap(SourceUsage.bundlePages(path, changed: ["wiki/log.md"]))
        XCTAssertEqual(bookkeepingOnly.count, 3)
    }

    func testABundleThatCantBeReadInFullIsNil() throws {
        XCTAssertNil(SourceUsage.bundlePages(dir.appendingPathComponent("missing.json").path, changed: []))
        try write("bad.json", "{not json")
        XCTAssertNil(SourceUsage.bundlePages(dir.appendingPathComponent("bad.json").path, changed: []))
        try write("nowrites.json", #"{"writes":"x"}"#)
        XCTAssertNil(SourceUsage.bundlePages(dir.appendingPathComponent("nowrites.json").path, changed: []))
        let gone = try bundle([["path": "wiki/a.md", "content": "a"], ["path": "wiki/b.md", "content_file": "drafts/missing.md"]])
        XCTAssertNil(SourceUsage.bundlePages(gone, changed: []), "a missing content file: nothing says not used")
        // A missing content file for a non-page doesn't matter.
        let skipped = try bundle([["path": "wiki/a.md", "content": "a"], ["path": "wiki/meta/x.md", "content_file": "drafts/missing.md"]])
        XCTAssertEqual(SourceUsage.bundlePages(skipped, changed: [])?.map(\.path), ["wiki/a.md"])
    }

    func testVaultPagesReadEveryChangedPage() throws {
        try write("wiki/a.md", "A")
        try write("wiki/b.md", "B")
        let pages = try XCTUnwrap(SourceUsage.vaultPages(dir.path, changed: ["wiki/b.md", "wiki/log.md", "wiki/a.md", "wiki/x.json"]))
        XCTAssertEqual(pages.map(\.path), ["wiki/b.md", "wiki/a.md"])
        XCTAssertEqual(pages.map(\.text), ["B", "A"])
        XCTAssertEqual(SourceUsage.vaultPages(dir.path, changed: [])?.count, 0)
        XCTAssertNil(SourceUsage.vaultPages(dir.path, changed: ["wiki/a.md", "wiki/gone.md"]))
    }
}
