import XCTest
@testable import DistillKit

/// Collectors v6 DTOs, routes and events. The JSON is what a real core sent (a temp state dir,
/// 2026-10-04), with the long scratch paths shortened to /S.
final class CollectorScriptsTests: XCTestCase {
    var client: CoreClient!

    override func setUp() {
        StubProtocol.recorded = []
        StubProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config))
    }

    func respond(_ json: String, status: Int = 200) { StubProtocol.handler = { _ in (status, Data(json.utf8)) } }
    var last: StubProtocol.Recorded { StubProtocol.recorded.last! }
    func bodyJSON() throws -> JSONValue { try JSONDecoder.core.decode(JSONValue.self, from: last.body ?? Data()) }

    /// POST /v1/collectors with a manifest, before Allow (captured).
    static let created = #"""
    {"id":"col-519d","kind":"script","name":"Slack saved","vaultPath":"/S/vault","enabled":false,
     "schedule":{"cron":"0 * * * *","preset":"hourly"},"createdAt":"2026-10-05T00:42:13Z","updatedAt":"2026-10-05T00:42:13Z",
     "script":{"source":{"file":"/S/state/collectors/scripts/col-519d/collector.js","managed":true},"interpreter":"node","timeoutSeconds":300},
     "status":{"running":false,"nextRunAt":null,"lastRun":null,"needsConsent":true,"needsAttention":true,
       "script":{"path":"/S/state/collectors/scripts/col-519d/collector.js","dir":"/S/state/collectors/scripts/col-519d","managed":true,
         "manifest":{"name":"package.json","path":"/S/state/collectors/scripts/col-519d/package.json","exists":true,"hasDependencies":true,
           "packageCount":1,"sha256":"2f8e","installedSha256":null,"needsInstall":true,"installing":false,"lastInstall":null,"state":"needsInstall"},
         "lastTestRun":null},
       "currentSha256":"c9f0"}}
    """#

    /// GET /v1/collectors/:id/install after the install on Allow (captured).
    static let install = #"""
    {"install":{"id":"ins-f6de","collectorId":"col-519d","trigger":"allow","startedAt":"2026-10-05T00:42:20Z","result":"success",
     "command":"npm install --no-audit --no-fund","manifestName":"package.json","manifestSha256":"2f8e","exitCode":0,"signal":null,
     "outputTail":"$ npm install --no-audit --no-fund\nadded 1 package in 0.05s\n","endedAt":"2026-10-05T00:42:21Z","durationMs":539}}
    """#

    /// GET /v1/collectors/:id/script (captured).
    static let script = #"""
    {"collectorId":"col-519d","interpreter":"node","managed":true,"path":"/S/state/collectors/scripts/col-519d/collector.js",
     "dir":"/S/state/collectors/scripts/col-519d","code":"console.log(\"hi\");\n","sha256":"e150",
     "manifest":{"name":"package.json","path":"/S/state/collectors/scripts/col-519d/package.json","text":"{\n  \"dependencies\": {}\n}\n","sha256":"2f8e"}}
    """#

    /// A finished Test run from GET …/runs (captured, tails shortened).
    static let testRun = #"""
    {"id":"run-210f","collectorId":"col-519d","kind":"script","vaultPath":"/S/vault","trigger":"test","startedAt":"2026-10-05T00:42:30Z",
     "result":"success","counts":{"copied":0,"moved":0,"skipped":0,"waiting":0,"errors":0,"added":2},"filesAdded":["a.md","b.md"],
     "outputDir":"/S/state/collectors/test-runs/col-519d","sha256":"c9f0","exitCode":0,"signal":null,"stdoutTail":"wrote a.md\n",
     "stderrTail":"","endedAt":"2026-10-05T00:42:30Z","durationMs":71,"installId":"ins-1"}
    """#

    func testDecodesV6Status() throws {
        let c = try JSONDecoder.core.decode(Collector.self, from: Data(Self.created.utf8))
        XCTAssertTrue(c.script?.managed ?? false)
        XCTAssertTrue(c.isManaged)
        XCTAssertEqual(c.scriptPath, "/S/state/collectors/scripts/col-519d/collector.js")
        let m = try XCTUnwrap(c.manifest)
        XCTAssertEqual(m.name, "package.json")
        XCTAssertEqual(m.state, "needsInstall")
        XCTAssertEqual(m.packageCount, 1)
        XCTAssertNil(m.installedSha256)
        XCTAssertFalse(c.isInstalling)
        XCTAssertEqual(c.status?.script?.changes, [])

        // Re-encoding keeps `managed` on the source, so a round trip stays a managed file.
        let again = try JSONDecoder.core.decode(Collector.self, from: JSONEncoder().encode(c))
        XCTAssertTrue(again.script?.managed ?? false)
        XCTAssertEqual(again.manifest?.state, "needsInstall")

        // An older core: no status.script, no managed flag; still decodes.
        let old = try JSONDecoder.core.decode(Collector.self, from: Data(#"""
        {"id":"c","kind":"script","script":{"source":{"file":"/x.py"},"interpreter":"python3"},"status":{"running":false}}
        """#.utf8))
        XCTAssertFalse(old.isManaged)
        XCTAssertNil(old.manifest)
        XCTAssertEqual(old.scriptPath, "/x.py")

        // Unknown states and interpreters stay raw; changes and allowedFiles decode.
        let odd = try JSONDecoder.core.decode(Collector.self, from: Data(#"""
        {"id":"c","kind":"script","script":{"source":{"file":"/a.ts","managed":"yes"},"interpreter":"typescript",
          "allowedFiles":{"script":"aa","manifest":null}},
         "status":{"script":{"path":"/a.ts","managed":true,"changes":["manifest",3],"manifest":{"name":"package.json","state":"warp","installing":true}}}}
        """#.utf8))
        XCTAssertEqual(odd.script?.interpreter, .typescript)
        XCTAssertEqual(odd.script?.interpreter.language, "TypeScript")
        XCTAssertEqual(odd.script?.interpreter.command, "node")
        XCTAssertFalse(odd.script?.managed ?? true, "a wrong-typed managed reads as false; the status still says managed")
        XCTAssertTrue(odd.isManaged)
        XCTAssertEqual(odd.script?.allowedFiles, AllowedFiles(script: "aa", manifest: nil))
        XCTAssertEqual(odd.status?.script?.changes, ["manifest"])
        XCTAssertEqual(odd.manifest?.state, "warp")
        XCTAssertTrue(odd.isInstalling)
    }

    func testDecodesRunsInstallsAndFiles() throws {
        let run = try JSONDecoder.core.decode(CollectorRun.self, from: Data(Self.testRun.utf8))
        XCTAssertTrue(run.isTest)
        XCTAssertEqual(run.outputDir, "/S/state/collectors/test-runs/col-519d")
        XCTAssertEqual(run.filesAdded, ["a.md", "b.md"])
        XCTAssertEqual(run.installId, "ins-1")

        let files = try JSONDecoder.core.decode(CollectorScriptFiles.self, from: Data(Self.script.utf8))
        XCTAssertEqual(files.interpreter, .node)
        XCTAssertEqual(files.sha256, "e150")
        XCTAssertEqual(files.manifest?.sha256, "2f8e")
        XCTAssertEqual(files.manifest?.text?.contains("dependencies"), true)

        let none = try JSONDecoder.core.decode(CollectorScriptFiles.self, from: Data(#"{"interpreter":"zsh","managed":true,"path":"/a.zsh","code":null,"problem":"gone","manifest":null}"#.utf8))
        XCTAssertNil(none.code)
        XCTAssertNil(none.manifest)
        XCTAssertEqual(none.problem, "gone")
    }

    func testRoutes() async throws {
        respond(Self.script)
        let files = try await client.collectorScript("col 1")
        XCTAssertEqual(last.method, "GET"); XCTAssertEqual(last.path, "/v1/collectors/col 1/script")
        XCTAssertEqual(files.collectorId, "col-519d")

        // PUT: a removed manifest and "it didn't exist" are explicit nulls; unsent keys stay out.
        respond(Self.script)
        _ = try await client.saveCollectorScript("col-1", CollectorScriptUpdate(code: "x", manifest: .some(nil), baseSha256: "e150",
                                                                                baseManifestSha256: .some(nil)))
        XCTAssertEqual(last.method, "PUT"); XCTAssertEqual(last.path, "/v1/collectors/col-1/script")
        XCTAssertEqual(try bodyJSON(), .object(["code": .string("x"), "manifest": .null, "baseSha256": .string("e150"), "baseManifestSha256": .null]))
        respond(Self.script)
        _ = try await client.saveCollectorScript("col-1", CollectorScriptUpdate(manifest: "{}", baseManifestSha256: "2f8e"))
        XCTAssertEqual(try bodyJSON(), .object(["manifest": .string("{}"), "baseManifestSha256": .string("2f8e")]))

        // A stale base is a 409 the app can show (captured message).
        respond(#"{"error":{"code":"invalid_state","message":"The script changed on disk since you opened it; reload it first."}}"#, status: 409)
        do {
            _ = try await client.saveCollectorScript("col-1", CollectorScriptUpdate(code: "x", baseSha256: "0000"))
            XCTFail("expected a 409")
        } catch let e as CoreClientError {
            XCTAssertEqual(e.status, 409)
            XCTAssertEqual(e.code, "invalid_state")
            XCTAssertTrue(e.description.contains("changed on disk"))
        }

        respond(#"{"install":{"id":"ins-2","collectorId":"col-1","trigger":"manual","startedAt":"2026-10-05T00:50:00Z","result":"running","command":"npm install","manifestName":"package.json","manifestSha256":"2f8e","clean":true}}"#)
        let started = try await client.installCollectorPackages("col-1", clean: true)
        XCTAssertEqual(last.method, "POST"); XCTAssertEqual(last.path, "/v1/collectors/col-1/install")
        XCTAssertEqual(try bodyJSON(), .object(["clean": .bool(true)]))
        XCTAssertTrue(started.isRunning)
        XCTAssertTrue(started.clean)
        respond(#"{"install":{"id":"ins-3","collectorId":"col-1","startedAt":"2026-10-05T00:50:00Z","result":"running"}}"#)
        _ = try await client.installCollectorPackages("col-1")
        XCTAssertEqual(try bodyJSON(), .object([:]))

        respond(#"{"install":null}"#)
        let stopped = try await client.stopCollectorInstall("col-1")
        XCTAssertNil(stopped)
        XCTAssertEqual(last.path, "/v1/collectors/col-1/install/stop")

        respond(Self.install)
        let got = try await client.collectorInstall("col-1")
        XCTAssertEqual(last.method, "GET"); XCTAssertEqual(last.path, "/v1/collectors/col-1/install")
        XCTAssertEqual(got?.trigger, "allow")
        XCTAssertEqual(got?.result, "success")
        XCTAssertEqual(got?.outputTail?.contains("added 1 package"), true)
        respond(#"{"install":null}"#)
        let nothing = try await client.collectorInstall("col-1")
        XCTAssertNil(nothing)

        respond("{\"run\":\(Self.testRun)}")
        let test = try await client.testCollector("col-1")
        XCTAssertEqual(last.method, "POST"); XCTAssertEqual(last.path, "/v1/collectors/col-1/test")
        XCTAssertTrue(test.isTest)

        // Create with a manifest.
        respond(Self.created, status: 201)
        _ = try await client.createCollector(NewCollectorInput(kind: .script, script: .init(source: .inline("x"), interpreter: .typescript, manifest: "{}")))
        let body = try bodyJSON()
        XCTAssertEqual(body["script"]?["manifest"], .string("{}"))
        XCTAssertEqual(body["script"]?["interpreter"], .string("typescript"))
    }

    func testInstallEvents() throws {
        let started = try CoreEvent.decode(Data(#"{"type":"collector.install.started","install":{"id":"ins-1","collectorId":"c","startedAt":"2026-10-05T00:42:20Z","result":"running","command":"npm install"}}"#.utf8))
        guard case .collectorInstallStarted(let i) = started else { return XCTFail("\(started)") }
        XCTAssertEqual(i.command, "npm install")
        let out = try CoreEvent.decode(Data(#"{"type":"collector.install.output","collectorId":"c","installId":"ins-1","text":"added 1"}"#.utf8))
        XCTAssertEqual(out, .collectorInstallOutput(collectorId: "c", installId: "ins-1", text: "added 1"))
        let done = try CoreEvent.decode(Data(#"{"type":"collector.install.finished","install":{"id":"ins-1","collectorId":"c","result":"failed","error":{"code":"installFailed","message":"exit 1"}}}"#.utf8))
        guard case .collectorInstallFinished(let f) = done else { return XCTFail("\(done)") }
        XCTAssertEqual(f.error?.code, .installFailed)
    }
}
