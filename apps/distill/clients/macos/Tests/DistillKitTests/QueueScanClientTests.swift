import XCTest
@testable import DistillKit

/// `POST /v1/queue/scan`: the trigger in the body, the result decoded, an older core's 404.
final class QueueScanClientTests: XCTestCase {
    var client: CoreClient!

    override func setUp() {
        StubProtocol.recorded = []
        StubProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: String(repeating: "f", count: 64)), session: URLSession(configuration: config))
    }

    func testScanSendsTheTriggerAndDecodesTheResult() async throws {
        StubProtocol.handler = { _ in (200, Data(#"""
        {"added":2,"removed":1,"changed":0,"checkedAt":"2026-10-04T03:41:00Z","trigger":"window","addedEntries":[],"removedEntries":[],
         "changedEntries":[],"entries":[]}
        """#.utf8)) }
        let r = try await client.scanQueue(trigger: .window)
        XCTAssertEqual(r.added, 2)
        XCTAssertEqual(r.removed, 1)
        XCTAssertEqual(r.trigger, .window)
        let last = try XCTUnwrap(StubProtocol.recorded.last)
        XCTAssertEqual(last.method, "POST")
        XCTAssertEqual(last.path, "/v1/queue/scan")
        XCTAssertEqual(try JSONDecoder.core.decode(JSONValue.self, from: last.body ?? Data()), .object(["trigger": .string("window")]))
    }

    func testAnOlderCoreHasNoScanRoute() async {
        StubProtocol.handler = { _ in (404, Data(#"{"error":{"code":"not_found","message":"no route for POST /v1/queue/scan"}}"#.utf8)) }
        do {
            _ = try await client.scanQueue()
            XCTFail("expected an error")
        } catch let e as CoreClientError {
            XCTAssertTrue(e.isNotAvailable)
        } catch {
            XCTFail("\(error)")
        }
    }
}
