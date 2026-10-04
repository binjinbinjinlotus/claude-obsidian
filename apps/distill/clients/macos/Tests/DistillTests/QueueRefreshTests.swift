import XCTest
@testable import Distill
@testable import DistillKit

/// Answers /v1/queue/scan with a canned result (or 404, like an older core), after a short delay.
final class ScanProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var paths: [String] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock(); Self.paths.append("\(request.httpMethod ?? "") \(path)"); Self.lock.unlock()
        let (status, body) = path == "/v1/queue/scan" ? (Self.status, Self.body) : (200, #"{"entries":[]}"#)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// Refresh: "Checking…", then the result for a while, then "checked at …"; the list comes from the scan.
@MainActor
final class QueueRefreshTests: XCTestCase {
    private func model() -> AppModel {
        ScanProtocol.paths = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScanProtocol.self]
        let app = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
        app.useClientForTesting(CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config)))
        return app
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    override func tearDown() { AppModel.refreshResultSeconds = 4 }

    func testRefreshShowsCheckingThenTheResultThenCheckedAt() async {
        AppModel.refreshResultSeconds = 0.4
        ScanProtocol.status = 200
        ScanProtocol.body = #"""
        {"added":1,"removed":0,"changed":0,"checkedAt":"2026-10-04T03:41:00Z","trigger":"manual",
         "addedEntries":[{"path":"/q/Trip","name":"Trip","modified":"2026-10-04T03:40:00Z","size":4,"settled":true,"kind":"folder","fileCount":1}],
         "removedEntries":[],"changedEntries":[],
         "entries":[{"path":"/q/Trip","name":"Trip","modified":"2026-10-04T03:40:00Z","size":4,"settled":true,"kind":"folder","fileCount":1}]}
        """#
        let app = model()
        app.refreshQueueNow()
        XCTAssertEqual(app.refreshState, .checking)
        app.refreshQueueNow() // ignored while checking
        await waitUntil { app.refreshState != .checking }
        XCTAssertEqual(app.refreshState, .found("1 new item found"))
        XCTAssertEqual(app.queued.map(\.name), ["Trip"], "the scan's list replaces the queue at once")
        XCTAssertEqual(app.flashingPaths, ["/q/Trip"], "a new row flashes once")
        XCTAssertEqual(app.queueCheckedAt, ISO8601DateFormatter().date(from: "2026-10-04T03:41:00Z"))
        await waitUntil { app.refreshState == .idle }
        XCTAssertEqual(app.refreshState, .idle, "back to “checked at …” after the result time")
        XCTAssertEqual(ScanProtocol.paths.filter { $0 == "POST /v1/queue/scan" }.count, 1)
    }

    func testAnOlderCoreFallsBackToTheListWithoutABanner() async {
        ScanProtocol.status = 404
        ScanProtocol.body = #"{"error":{"code":"not_found","message":"no route for POST /v1/queue/scan"}}"#
        let app = model()
        app.refreshQueueNow()
        await waitUntil { app.refreshState == .idle && ScanProtocol.paths.contains("GET /v1/queue") }
        XCTAssertEqual(app.refreshState, .idle)
        XCTAssertNil(app.lastError)
        XCTAssertNil(app.queueCheckedAt, "no “checked at” without a scan")
    }

    func testPeriodicScansMoveCheckedAtButShowNoResult() {
        let app = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
        let at = Date()
        app.applyScan(QueueScanResult(added: 2, checkedAt: at, trigger: .periodic, entries: []))
        XCTAssertEqual(app.refreshState, .idle)
        XCTAssertEqual(app.queueCheckedAt, at)
        app.applyScan(QueueScanResult(checkedAt: at.addingTimeInterval(-60), trigger: .periodic))
        XCTAssertEqual(app.queueCheckedAt, at, "an older result never moves the time back")
    }

    func testTheWindowScanNeedsALiveCoreAndIsThrottled() {
        // A fixture model (no launcher, offline) never scans on window focus: snapshots and tests stay quiet.
        let app = model()
        app.scanQueueOnWindowActive()
        XCTAssertNil(app.lastWindowScan)
    }
}
