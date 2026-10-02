import Foundation

/// Where a running core listens: from `<state dir>/server.json` and `<state dir>/token`.
public struct CoreEndpoint: Equatable, Sendable {
    public var port: Int
    public var token: String
    public var pid: Int32?

    public init(port: Int, token: String, pid: Int32? = nil) {
        self.port = port
        self.token = token
        self.pid = pid
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
}

public enum CoreClientError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The core did not answer (not running, wrong port, connection dropped).
    case unreachable(String)
    /// The core answered with `{error: {code, message}}` (or a non-JSON error).
    case api(status: Int, code: String, message: String)
    /// The response did not have the expected shape.
    case badResponse(String)

    public var description: String {
        switch self {
        case .unreachable(let m): return "Cannot reach the Distill core: \(m)"
        case .api(_, _, let message): return message
        case .badResponse(let m): return "Unexpected response from the Distill core: \(m)"
        }
    }

    public var isUnreachable: Bool { if case .unreachable = self { return true }; return false }

    /// The route exists in the contract but this core does not serve it yet
    /// (501 not_implemented, or an older core without the route).
    public var isNotAvailable: Bool {
        if case .api(let status, let code, let message) = self {
            return status == 501 || code == "not_implemented"
                || (status == 404 && code == "not_found" && message.hasPrefix("no route for"))
        }
        return false
    }

    public var status: Int? { if case .api(let s, _, _) = self { return s }; return nil }
    public var code: String? { if case .api(_, let c, _) = self { return c }; return nil }
}

/// Thin async client for the core's local HTTP API (core/src/server/http.ts).
/// Every request carries `Authorization: Bearer <token>`. It holds no state:
/// the app model owns what is on screen, the core owns everything else.
public final class CoreClient: Sendable {
    public let endpoint: CoreEndpoint
    private let session: URLSession

    /// Regular calls; Ask has its own, longer limit.
    public static let defaultTimeout: TimeInterval = 30
    public static let askTimeout: TimeInterval = 15 * 60

    public init(endpoint: CoreEndpoint, session: URLSession? = nil) {
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:] // never send localhost traffic through a proxy
            config.timeoutIntervalForResource = 24 * 3600
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: Status & settings

    public func status() async throws -> StatusResponse { try await get("/v1/status") }
    public func settings() async throws -> Settings { try await get("/v1/settings") }

    /// `PUT /v1/settings` with only the changed keys (see `Settings.patch(from:to:)`).
    public func updateSettings(_ patch: [String: JSONValue]) async throws -> Settings {
        try await send("PUT", "/v1/settings", body: JSONValue.object(patch))
    }

    // MARK: Queue

    public func queue() async throws -> [QueueEntry] {
        try await get("/v1/queue", as: Wrapped<[QueueEntry]>.self, key: "entries").value
    }

    /// Copies files into the active vault's queue; originals stay where they are.
    public func addQueueFiles(_ paths: [String]) async throws -> [QueueEntry] {
        try await send("POST", "/v1/queue/files", body: ["paths": paths], as: Wrapped<[QueueEntry]>.self, key: "entries").value
    }

    /// Returns the started job, or nil when nothing was ready or the vault is busy
    /// (the reason arrives as a `log` event).
    public func processQueue(force: Bool) async throws -> Job? {
        try await send("POST", "/v1/queue/process", body: ["force": force], as: Wrapped<Job?>.self, key: "job").value
    }

    // MARK: Notes

    public func addNote(_ request: AddNoteRequest) async throws -> AddNoteResult {
        try await send("POST", "/v1/notes", body: request)
    }

    public func labelNote(requestID: String, labels: [String]) async throws -> LabelNoteResult {
        try await send("POST", "/v1/notes/\(Self.segment(requestID))/labels", body: ["labels": labels])
    }

    // MARK: Jobs

    public func jobs() async throws -> [Job] {
        try await get("/v1/jobs", as: Wrapped<[Job]>.self, key: "jobs").value
    }

    public func job(_ id: String) async throws -> Job { try await get("/v1/jobs/\(Self.segment(id))") }

    @discardableResult public func approve(_ id: String) async throws -> Job? { try await jobAction(id, "approve") }
    @discardableResult public func reply(_ id: String, text: String) async throws -> Job? {
        try await jobAction(id, "reply", body: ["text": .string(text)])
    }
    @discardableResult public func allow(_ id: String, rules: [String]) async throws -> Job? {
        try await jobAction(id, "allow", body: ["rules": .array(rules.map(JSONValue.string))])
    }
    @discardableResult public func reject(_ id: String) async throws -> Job? { try await jobAction(id, "reject") }
    @discardableResult public func cancel(_ id: String) async throws -> Job? { try await jobAction(id, "cancel") }

    private func jobAction(_ id: String, _ action: String, body: [String: JSONValue] = [:]) async throws -> Job? {
        try await send("POST", "/v1/jobs/\(Self.segment(id))/\(action)", body: JSONValue.object(body), as: Wrapped<Job?>.self, key: "job").value
    }

    // MARK: Ask

    public func ask(_ request: AskRequest) async throws -> AskResponse {
        try await send("POST", "/v1/ask", body: request, timeout: Self.askTimeout)
    }

    public func conversations() async throws -> [AskConversationSummary] {
        try await get("/v1/conversations", as: Wrapped<[AskConversationSummary]>.self, key: "conversations").value
    }

    public func conversation(_ id: String) async throws -> AskConversation {
        try await get("/v1/conversations/\(Self.segment(id))")
    }

    public func deleteConversation(_ id: String) async throws {
        let _: JSONValue = try await send("DELETE", "/v1/conversations/\(Self.segment(id))", body: Optional<JSONValue>.none)
    }

    public func setConversationPinned(_ id: String, pinned: Bool) async throws -> AskConversationSummary {
        try await send("POST", "/v1/conversations/\(Self.segment(id))/pin", body: ["pinned": pinned])
    }

    // MARK: Labels

    public func labels(vaultPath: String? = nil) async throws -> [LabelCount] {
        try await get("/v1/labels" + Self.vaultQuery(vaultPath), as: Wrapped<[LabelCount]>.self, key: "labels").value
    }

    public func labelReview(vaultPath: String? = nil) async throws -> LabelReview {
        try await get("/v1/labels/review" + Self.vaultQuery(vaultPath))
    }

    public func suggestLabels(paths: [String], vaultPath: String? = nil, selection: ModelSelection? = nil) async throws -> Job {
        struct Body: Encodable { let paths: [String]; let vaultPath: String?; let selection: ModelSelection? }
        return try await send("POST", "/v1/labels/suggest", body: Body(paths: paths, vaultPath: vaultPath, selection: selection),
                              as: Wrapped<Job>.self, key: "job").value
    }

    public func confirmLabels(_ items: [LabeledPage], vaultPath: String? = nil) async throws -> Job {
        struct Body: Encodable { let items: [LabeledPage]; let vaultPath: String? }
        return try await send("POST", "/v1/labels/confirm", body: Body(items: items, vaultPath: vaultPath),
                              as: Wrapped<Job>.self, key: "job").value
    }

    // MARK: Runners

    public func runners() async throws -> [RunnerInfo] {
        try await get("/v1/runners", as: Wrapped<[RunnerInfo]>.self, key: "runners").value
    }

    /// nil clears the secret (stored in the Keychain by the core; never echoed back).
    public func setRunnerSecret(runnerID: String, name: String, value: String?) async throws {
        let body: [String: JSONValue] = ["value": value.map(JSONValue.string) ?? .null]
        let _: JSONValue = try await send("PUT", "/v1/runners/\(Self.segment(runnerID))/secrets/\(Self.segment(name))",
                                          body: JSONValue.object(body))
    }

    // MARK: Events

    /// One connection to `GET /v1/events`. The stream ends (or throws) when the
    /// connection drops; `CoreEventStream` reconnects.
    public func events() -> AsyncThrowingStream<CoreEvent, Error> {
        let request = makeRequest("GET", "/v1/events", body: nil, timeout: 24 * 3600, accept: "text/event-stream")
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        throw Self.apiError(status: status, data: data)
                    }
                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        if let event = parser.feed(line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch let error as CoreClientError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: CoreClientError.unreachable(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await perform(makeRequest("GET", path, body: nil, timeout: Self.defaultTimeout))
    }

    private func get<W: WrappedDecodable>(_ path: String, as: W.Type, key: String) async throws -> W {
        try await performWrapped(makeRequest("GET", path, body: nil, timeout: Self.defaultTimeout), key: key)
    }

    private func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, body: B?, timeout: TimeInterval = defaultTimeout) async throws -> T {
        try await perform(makeRequest(method, path, body: try body.map(Self.encode), timeout: timeout))
    }

    private func send<B: Encodable, W: WrappedDecodable>(_ method: String, _ path: String, body: B, as: W.Type, key: String) async throws -> W {
        try await performWrapped(makeRequest(method, path, body: try Self.encode(body), timeout: Self.defaultTimeout), key: key)
    }

    private static func encode<B: Encodable>(_ body: B) throws -> Data {
        do { return try JSONEncoder.core.encode(body) } catch { throw CoreClientError.badResponse("could not encode request: \(error)") }
    }

    func makeRequest(_ method: String, _ path: String, body: Data?, timeout: TimeInterval, accept: String = "application/json") -> URLRequest {
        var request = URLRequest(url: URL(string: path, relativeTo: endpoint.baseURL)!.absoluteURL, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func data(for request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CoreClientError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.apiError(status: status, data: data) }
        return data
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await data(for: request)
        do {
            return try JSONDecoder.core.decode(T.self, from: data.isEmpty ? Data("null".utf8) : data)
        } catch {
            throw CoreClientError.badResponse("\(request.httpMethod ?? "") \(request.url?.path ?? ""): \(error)")
        }
    }

    private func performWrapped<W: WrappedDecodable>(_ request: URLRequest, key: String) async throws -> W {
        let data = try await data(for: request)
        do {
            return try W.decode(data, key: key)
        } catch {
            throw CoreClientError.badResponse("\(request.httpMethod ?? "") \(request.url?.path ?? ""): \(error)")
        }
    }

    static func apiError(status: Int, data: Data) -> CoreClientError {
        struct Body: Decodable { struct E: Decodable { let code: String?; let message: String? }; let error: E? }
        if let body = try? JSONDecoder().decode(Body.self, from: data), let e = body.error {
            return .api(status: status, code: e.code ?? "http_\(status)", message: e.message ?? "HTTP \(status)")
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self)
        return .api(status: status, code: "http_\(status)", message: text.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(text)")
    }

    static func segment(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }

    static func vaultQuery(_ vaultPath: String?) -> String {
        guard let vaultPath else { return "" }
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "vault", value: vaultPath)]
        return c.url?.query.map { "?" + $0 } ?? ""
    }
}

// MARK: - Response wrappers

protocol WrappedDecodable {
    static func decode(_ data: Data, key: String) throws -> Self
}

/// `{key: value}` or a bare `value`: list routes wrap their arrays
/// (`{"jobs": [...]}`), and both forms are accepted so a small server change
/// does not break the app.
struct Wrapped<T: Decodable>: WrappedDecodable {
    let value: T

    static func decode(_ data: Data, key: String) throws -> Wrapped<T> {
        let json = try JSONDecoder.core.decode(JSONValue.self, from: data.isEmpty ? Data("null".utf8) : data)
        if case .object(let o) = json, let inner = o[key] {
            return Wrapped(value: try JSONDecoder.core.decode(T.self, from: JSONEncoder.core.encode(inner)))
        }
        return Wrapped(value: try JSONDecoder.core.decode(T.self, from: data.isEmpty ? Data("null".utf8) : data))
    }
}

// MARK: - Server-sent events

/// Parses the core's SSE stream line by line. The server writes one
/// `data: <CoreEvent JSON>` line per event (the JSON carries `type`), so each
/// data line is decoded on its own; comments (`:`), `event:`, `id:` and
/// `retry:` lines are ignored. `AsyncLineSequence` drops blank lines, so the
/// parser does not rely on blank-line framing.
public struct SSEParser: Sendable {
    public private(set) var malformed = 0

    public init() {}

    public mutating func feed(_ rawLine: String) -> CoreEvent? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        guard line.hasPrefix("data:") else { return nil }
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        do {
            return try CoreEvent.decode(Data(payload.utf8))
        } catch {
            malformed += 1
            return nil
        }
    }
}
