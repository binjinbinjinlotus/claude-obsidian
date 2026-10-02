import XCTest
@testable import DistillKit

/// Answers requests from a handler instead of the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded { let method: String; let path: String; let query: String?; let headers: [String: String]; let body: Data? }
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data)?)?
    nonisolated(unsafe) static var recorded: [Recorded] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable { let n = stream.read(buf, maxLength: 4096); if n <= 0 { break }; data.append(buf, count: n) }
            buf.deallocate()
            stream.close()
            body = data
        }
        Self.lock.lock()
        Self.recorded.append(Recorded(method: request.httpMethod ?? "", path: request.url?.path ?? "", query: request.url?.query,
                                      headers: request.allHTTPHeaderFields ?? [:], body: body))
        let answer = Self.handler?(request)
        Self.lock.unlock()
        guard let (status, data) = answer else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CoreClientTests: XCTestCase {
    let token = String(repeating: "f", count: 64)
    var client: CoreClient!

    override func setUp() {
        StubProtocol.recorded = []
        StubProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: token), session: URLSession(configuration: config))
    }

    func respond(_ json: String, status: Int = 200) {
        StubProtocol.handler = { _ in (status, Data(json.utf8)) }
    }

    var last: StubProtocol.Recorded { StubProtocol.recorded.last! }

    func bodyJSON() throws -> JSONValue { try JSONDecoder.core.decode(JSONValue.self, from: last.body ?? Data()) }

    func testSendsBearerTokenToLoopback() async throws {
        respond(#"{"version":"0.1.0","problems":[],"queueCount":0,"pendingApprovals":0,"runningJobs":0,"runners":[]}"#)
        let status = try await client.status()
        XCTAssertEqual(status.version, "0.1.0")
        XCTAssertEqual(last.method, "GET")
        XCTAssertEqual(last.path, "/v1/status")
        XCTAssertEqual(last.headers["Authorization"], "Bearer \(token)")
        XCTAssertEqual(client.makeRequest("GET", "/v1/status", body: nil, timeout: 1).url?.host, "127.0.0.1")
    }

    func testErrorShapeBecomesAPIError() async {
        respond(#"{"error":{"code":"invalid_state","message":"Job j is not awaiting approval."}}"#, status: 409)
        do {
            try await client.approve("j")
            XCTFail("expected an error")
        } catch let e as CoreClientError {
            XCTAssertEqual(e, .api(status: 409, code: "invalid_state", message: "Job j is not awaiting approval."))
            XCTAssertEqual(e.description, "Job j is not awaiting approval.")
            XCTAssertFalse(e.isNotAvailable)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(last.path, "/v1/jobs/j/approve")
        XCTAssertEqual(last.method, "POST")
    }

    func testUnreachable() async {
        StubProtocol.handler = { _ in nil }
        do {
            _ = try await client.jobs()
            XCTFail("expected an error")
        } catch let e as CoreClientError {
            XCTAssertTrue(e.isUnreachable)
        } catch { XCTFail("\(error)") }
    }

    func testNotAvailableForV2RoutesOnOlderCores() async {
        respond(#"{"error":{"code":"not_found","message":"no route for /v1/runners"}}"#, status: 404)
        do { _ = try await client.runners(); XCTFail() } catch let e as CoreClientError { XCTAssertTrue(e.isNotAvailable) } catch { XCTFail() }
        respond(#"{"error":{"code":"not_implemented","message":"listLabels: not implemented"}}"#, status: 501)
        do { _ = try await client.labels(); XCTFail() } catch let e as CoreClientError { XCTAssertTrue(e.isNotAvailable) } catch { XCTFail() }
        respond(#"{"error":{"code":"job_not_found","message":"no job with id \"x\""}}"#, status: 404)
        do { _ = try await client.job("x"); XCTFail() } catch let e as CoreClientError { XCTAssertFalse(e.isNotAvailable) } catch { XCTFail() }
    }

    func testListRoutesAcceptWrappedAndBare() async throws {
        respond(#"{"jobs":[\#(Fixtures.tsJob)]}"#)
        let wrapped = try await client.jobs()
        XCTAssertEqual(wrapped.count, 1)
        respond("[\(Fixtures.swiftJob)]")
        let bare = try await client.jobs()
        XCTAssertEqual(bare.first?.id, "job-20260930-080000-1f2e")
    }

    func testQueueAndIntake() async throws {
        respond(#"{"entries":[{"path":"/q/Screenshot 2026-10-01 120000.png","name":"Screenshot 2026-10-01 120000.png","modified":"2026-10-01T12:00:00Z","size":5,"settled":true}]}"#)
        let entries = try await client.addQueueFiles(["/tmp/Screenshot 2026-10-01 120000.png"])
        XCTAssertEqual(entries.first?.name, "Screenshot 2026-10-01 120000.png")
        XCTAssertEqual(last.path, "/v1/queue/files")
        XCTAssertEqual(try bodyJSON(), .object(["paths": .array([.string("/tmp/Screenshot 2026-10-01 120000.png")])]))
        XCTAssertEqual(last.headers["Content-Type"], "application/json")

        respond(#"{"job":null}"#)
        let job = try await client.processQueue(force: true)
        XCTAssertNil(job)
        XCTAssertEqual(try bodyJSON(), .object(["force": .bool(true)]))
    }

    func testJobActionsSendTheirBodies() async throws {
        respond(#"{"job":\#(Fixtures.tsJob)}"#)
        let job = try await client.reply("job-1", text: "Use the Green tea page")
        XCTAssertEqual(job?.id, "job-20261001-120000-abcd")
        XCTAssertEqual(last.path, "/v1/jobs/job-1/reply")
        XCTAssertEqual(CoreClient.segment("a/b c"), "a%2Fb%20c")
        XCTAssertEqual(try bodyJSON(), .object(["text": .string("Use the Green tea page")]))
        _ = try await client.allow("j", rules: ["Read(//x)"])
        XCTAssertEqual(try bodyJSON(), .object(["rules": .array([.string("Read(//x)")])]))
        for action in ["reject", "cancel"] {
            if action == "reject" { _ = try await client.reject("j") } else { _ = try await client.cancel("j") }
            XCTAssertEqual(last.path, "/v1/jobs/j/\(action)")
        }
    }

    func testSettingsPatchIsPUT() async throws {
        respond(Fixtures.settingsV2)
        let saved = try await client.updateSettings(["model": .string("opus"), "nodePath": .null])
        XCTAssertEqual(saved.model, "opus")
        XCTAssertEqual(last.method, "PUT")
        XCTAssertEqual(try bodyJSON(), .object(["model": .string("opus"), "nodePath": .null]))
    }

    func testV2Routes() async throws {
        respond(#"{"labels":[{"name":"tea","count":3,"unconfirmed":1}]}"#)
        let labels = try await client.labels(vaultPath: "/My Vault")
        XCTAssertEqual(labels.first?.unconfirmed, 1)
        XCTAssertEqual(last.path, "/v1/labels")
        XCTAssertEqual(last.query, "vault=/My%20Vault")

        respond(#"{"notePath":"/q/n.md","labels":["tea"]}"#)
        _ = try await client.labelNote(requestID: "r1", labels: ["tea"])
        XCTAssertEqual(last.path, "/v1/notes/r1/labels")

        respond(#"{"job":\#(Fixtures.tsJob)}"#)
        _ = try await client.confirmLabels([LabeledPage(path: "wiki/a.md", labels: ["tea"])])
        XCTAssertEqual(last.path, "/v1/labels/confirm")
        XCTAssertEqual(try bodyJSON()["items"], .array([.object(["path": .string("wiki/a.md"), "labels": .array([.string("tea")])])]))
        _ = try await client.suggestLabels(paths: ["wiki/a.md"])
        XCTAssertEqual(last.path, "/v1/labels/suggest")

        respond(#"{"conversations":[{"id":"c1","title":"Q","vaultPath":"/v","createdAt":"2026-10-01T12:00:00Z","updatedAt":"2026-10-01T12:00:00Z","pinned":false,"turnCount":1}]}"#)
        let conversations = try await client.conversations()
        XCTAssertEqual(conversations.first?.id, "c1")
        respond(#"{"id":"c1","title":"Q","vaultPath":"/v","createdAt":"2026-10-01T12:00:00Z","updatedAt":"2026-10-01T12:00:00Z","pinned":true,"turnCount":1}"#)
        let pinned = try await client.setConversationPinned("c1", pinned: true)
        XCTAssertEqual(pinned.pinned, true)
        XCTAssertEqual(try bodyJSON(), .object(["pinned": .bool(true)]))
        respond(#"{"id":"c1","deleted":true}"#)
        try await client.deleteConversation("c1")
        XCTAssertEqual(last.method, "DELETE")

        respond(#"{"runnerID":"openrouter","name":"apiKey","isSet":false}"#)
        try await client.setRunnerSecret(runnerID: "openrouter", name: "apiKey", value: nil)
        XCTAssertEqual(last.method, "PUT")
        XCTAssertEqual(last.path, "/v1/runners/openrouter/secrets/apiKey")
        XCTAssertEqual(try bodyJSON(), .object(["value": .null]))
    }

    func testAskSendsFilters() async throws {
        respond(#"{"conversationID":"c1","answer":"a","citations":[],"gaps":[],"selection":{"runnerID":"claude-code","model":"sonnet"},"costUSD":0}"#)
        _ = try await client.ask(AskRequest(question: "How hot?", labels: ["tea"], labelMatch: .all))
        let body = try bodyJSON()
        XCTAssertEqual(body["labelMatch"], .string("all"))
        XCTAssertNil(body["conversationID"])
    }

    func testEventStreamDecodesBody() async throws {
        let body = "retry: 2000\n: connected\n\nevent: log\ndata: {\"type\":\"log\",\"level\":\"error\",\"message\":\"x\"}\n\n"
        StubProtocol.handler = { _ in (200, Data(body.utf8)) }
        var events: [CoreEvent] = []
        for try await e in client.events() { events.append(e) }
        XCTAssertEqual(events, [.log(level: "error", message: "x")])
        XCTAssertEqual(last.headers["Accept"], "text/event-stream")
    }

    func testEventStreamAuthFailureThrows() async {
        respond(#"{"error":{"code":"unauthorized","message":"missing or invalid bearer token"}}"#, status: 401)
        do {
            for try await _ in client.events() {}
            XCTFail("expected an error")
        } catch let e as CoreClientError {
            XCTAssertEqual(e.code, "unauthorized")
        } catch { XCTFail("\(error)") }
    }
}
