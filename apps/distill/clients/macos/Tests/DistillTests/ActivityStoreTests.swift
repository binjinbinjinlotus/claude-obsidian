import XCTest
@testable import Distill
@testable import DistillKit

/// A canned core for the activity routes: the page, the trash, the restore entries and Restore.
final class ActivityProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var page = #"{"entries":[],"nextCursor":null}"#
    nonisolated(unsafe) static var trash = #"{"items":[]}"#
    nonisolated(unsafe) static var restore: (Int, String) = (200, "{}")
    nonisolated(unsafe) static var requests: [String] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? "", query = request.url?.query ?? ""
        Self.lock.lock(); Self.requests.append("\(request.httpMethod ?? "") \(path)?\(query)"); Self.lock.unlock()
        let (status, body): (Int, String) = {
            if path == "/v1/trash" { return (200, Self.trash) }
            if path.hasSuffix("/restore") { return Self.restore }
            if path == "/v1/activity" && query.contains("restored") { return (200, #"{"entries":[],"nextCursor":null}"#) }
            if path == "/v1/activity" { return (200, Self.page) }
            return (200, "{}")
        }()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class ActivityStoreTests: XCTestCase {
    /// Models stay alive: stores are keyed by the model's identity.
    private static var models: [AppModel] = []

    private func model() -> AppModel {
        ActivityProtocol.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ActivityProtocol.self]
        let app = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
        app.useClientForTesting(CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config)))
        Self.models.append(app)
        return app
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    static let deleted = #"""
    {"id":"1791155040000-0001-a1b2c3","at":"2026-10-04T23:04:00.000Z","type":"collector.deleted","source":"app",
     "object":{"kind":"collector","id":"col-1","name":"Meeting notes"},"summary":"Deleted the script collector “Meeting notes”","outcome":"ok",
     "details":{"kind":"script"},"recovery":{"kind":"trash","trashId":"trash-1","expiresAt":"2026-11-03T23:04:00.000Z"},"pid":1}
    """#
    static let trashItem = #"{"items":[{"id":"trash-1","kind":"collector","objectID":"col-1","name":"Meeting notes","deletedAt":"2026-10-04T23:04:00Z","expiresAt":"2026-11-03T23:04:00Z"}]}"#

    func testLoadShowsInTrashAndRestoreTurnsItRestored() async throws {
        ActivityProtocol.page = "{\"entries\":[\(Self.deleted)],\"nextCursor\":null}"
        ActivityProtocol.trash = Self.trashItem
        ActivityProtocol.restore = (200, #"{"item":{"id":"trash-1","kind":"collector","objectID":"col-1","name":"Meeting notes"},"objectID":"col-1"}"#)
        let store = model().activity
        store.load()
        await waitUntil { store.phase == .loaded }
        let e = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(store.tag(e), "In trash")
        store.restore(e)
        await waitUntil { store.restoring.isEmpty && store.restores["trash-1"] != nil }
        XCTAssertEqual(store.tag(e), "Restored")
        XCTAssertTrue(ActivityProtocol.requests.contains("POST /v1/trash/trash-1/restore?"))
    }

    func testRestoreOfAnExpiredCopySaysSoAndDropsRestore() async throws {
        ActivityProtocol.page = "{\"entries\":[\(Self.deleted)],\"nextCursor\":null}"
        ActivityProtocol.trash = Self.trashItem
        ActivityProtocol.restore = (404, #"{"error":{"code":"not_found","message":"No trash item trash-1 (it may have expired)."}}"#)
        let store = model().activity
        store.load()
        await waitUntil { store.phase == .loaded }
        let e = try XCTUnwrap(store.entries.first)
        store.restore(e)
        await waitUntil { store.restoring.isEmpty && store.restoreErrors["trash-1"] != nil }
        XCTAssertEqual(store.restoreErrors["trash-1"], "It’s no longer in Distill’s trash (it may have expired).")
        if case .trashGone = store.recovery(e) {} else { XCTFail("Restore must not stay offered: \(String(describing: store.recovery(e)))") }
    }

    func testLiveEntriesJoinTheListOrReloadForASearch() async throws {
        ActivityProtocol.page = #"{"entries":[],"nextCursor":null}"#
        ActivityProtocol.trash = #"{"items":[]}"#
        let store = model().activity
        store.load()
        await waitUntil { store.phase == .loaded }
        let e = try JSONDecoder.core.decode(ActivityEntry.self, from: Data(Self.deleted.utf8))
        store.received(e)
        XCTAssertEqual(store.entries.map(\.id), [e.id])
        XCTAssertEqual(store.tag(e), "In trash", "the event's trash id counts until the next listing")
        store.received(e)
        XCTAssertEqual(store.entries.count, 1, "no duplicates")

        // A filter that excludes it, then a search (matched by the core).
        store.filter.what = .chats
        await waitUntil { ActivityProtocol.requests.contains { $0.contains("type=chat") } }
        await waitUntil { store.phase == .loaded && store.entries.isEmpty }
        let before = ActivityProtocol.requests.count
        store.received(ActivityEntry(id: "1791155099999-0002-x", at: Date(), type: "collector.run", source: .scheduler,
                                     object: ActivityObject(kind: "collector"), summary: "ran"))
        XCTAssertTrue(store.entries.isEmpty)
        store.filter.text = "notes"
        await waitUntil { ActivityProtocol.requests.contains { $0.contains("q=notes") } }
        XCTAssertGreaterThan(ActivityProtocol.requests.count, before)
    }

    func testShowEverythingAddsARemovableChip() throws {
        let store = model().activity
        let e = try JSONDecoder.core.decode(ActivityEntry.self, from: Data(Self.deleted.utf8))
        store.showEverything(for: e)
        XCTAssertEqual(store.filter.chips.map(\.text), ["For: Meeting notes"])
        store.filter.remove(store.filter.chips[0])
        XCTAssertNil(store.filter.object)
    }
}
