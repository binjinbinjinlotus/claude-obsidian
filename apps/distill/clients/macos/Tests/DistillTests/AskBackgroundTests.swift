import XCTest
@testable import Distill
@testable import DistillKit

/// Answers /v1/ask after a delay so a question is still running when the user moves on.
final class SlowAskProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var paths: [String] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.lock.lock(); Self.paths.append("\(request.httpMethod ?? "") \(path)"); Self.lock.unlock()
        let body: String
        var delay = 0.0
        if path == "/v1/ask" {
            delay = 0.4
            body = #"{"conversationID":"11111111-1111-4111-8111-111111111111","answer":"70–80 °C","citations":[],"gaps":[],"costUSD":0}"#
        } else if path == "/v1/conversations" {
            body = #"{"conversations":[]}"#
        } else {
            body = "{}"
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

/// The bug: New chat while a question was answering stopped it and the question was lost.
@MainActor
final class AskBackgroundTests: XCTestCase {
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

    func testNewChatKeepsTheRunningQuestion() async {
        let app = model()
        let ask = app.ask
        ask.main.draft = "Best water temp for sencha?"
        ask.send(ask.main)
        XCTAssertTrue(ask.main.isRunning)

        ask.newChat(ask.main)

        XCTAssertTrue(ask.main.isEmpty, "the new chat starts empty")
        XCTAssertEqual(ask.backgroundNew.map(\.pending.question), ["Best water temp for sencha?"], "History shows it answering")
        XCTAssertFalse(SlowAskProtocol.paths.contains { $0.hasSuffix("/cancel") }, "the run is not stopped")

        await waitUntil { ask.background.isEmpty }
        XCTAssertTrue(ask.background.isEmpty, "the answer landed")
        XCTAssertTrue(ask.main.isEmpty, "the answer does not leak into the new chat")
        XCTAssertTrue(SlowAskProtocol.paths.contains("GET /v1/conversations"), "History reloads to show the saved chat")
    }

    func testReopeningARunningChatShowsTheAnswerArriving() async {
        let app = model()
        let ask = app.ask
        ask.main.draft = "Best water temp for sencha?"
        ask.send(ask.main)
        guard let id = ask.main.inFlightID else { return XCTFail("no run id") }
        ask.newChat(ask.main)

        ask.open(conversationID: id)
        XCTAssertTrue(ask.main.isRunning, "reopened while answering")
        XCTAssertEqual(ask.main.pending?.question, "Best water temp for sencha?")
        XCTAssertTrue(ask.background.isEmpty)

        await waitUntil { !ask.main.isRunning }
        XCTAssertEqual(ask.main.entries.map(\.question), ["Best water temp for sencha?"])
        XCTAssertEqual(ask.main.entries.first?.response.answer, "70–80 °C")
    }

    func testStopStillStops() async {
        let app = model()
        let ask = app.ask
        ask.main.draft = "Best water temp for sencha?"
        ask.send(ask.main)
        ask.stop(ask.main)
        await waitUntil { SlowAskProtocol.paths.contains { $0.hasSuffix("/cancel") } }
        XCTAssertTrue(SlowAskProtocol.paths.contains { $0.hasSuffix("/cancel") })
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(ask.main.entries.isEmpty, "a stopped question adds no answer")
    }
}
