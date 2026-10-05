import XCTest
import DistillKit
@testable import Distill

/// v6 script editing: a kept script's code never goes through PATCH (PUT carries it with the loaded
/// hashes), switching kinds, and the board's wording for installs, Test runs and Run now.
@MainActor
final class CollectorScriptsLogicTests: XCTestCase {
    let text = CollectorText(home: "/Users/mei")

    func managed(_ i: CollectorInterpreter = .node, manifest: CollectorManifestStatus? = nil) -> Collector {
        let path = "/S/collectors/scripts/col-1/collector.\(i.fileExtension)"
        return Collector(id: "col-1", kind: .script, name: "Slack", vaultPath: "/v", schedule: .hourly,
                         script: ScriptCollectorSettings(source: .file(path), managed: true, interpreter: i, allowedSha256: "aa"),
                         status: CollectorStatus(currentSha256: "aa",
                                                 script: CollectorScriptStatus(path: path, dir: "/S/collectors/scripts/col-1", managed: true,
                                                                               manifest: manifest)))
    }

    func files(code: String = "a\n", manifest: String? = "{}\n") -> CollectorScriptFiles {
        CollectorScriptFiles(collectorId: "col-1", interpreter: .node, managed: true, path: "/S/collectors/scripts/col-1/collector.js",
                             code: code, sha256: "s1", manifest: .init(name: "package.json", text: manifest, sha256: manifest == nil ? nil : "m1"))
    }

    func testKeptCodeGoesThroughPutWithTheLoadedHashes() {
        let c = managed()
        var d = CollectorDraft(c, text: text)
        XCTAssertTrue(d.v6)
        XCTAssertTrue(d.managed)
        XCTAssertNil(d.scriptUpdate(stillManaged: true), "nothing until the files are loaded")
        d.take(files())
        XCTAssertNil(d.scriptUpdate(stillManaged: true))
        d.code = "b\n"
        d.manifest = "{\"dependencies\":{\"x\":\"1\"}}\n"
        let patch = d.patch(from: c, text: text)
        XCTAssertNil(patch.script, "code never travels in PATCH for a kept script")
        let u = d.scriptUpdate(stillManaged: true)
        XCTAssertEqual(u?.code, "b\n")
        XCTAssertEqual(u?.baseSha256, "s1")
        XCTAssertEqual(u?.manifest, .some("{\"dependencies\":{\"x\":\"1\"}}\n"))
        XCTAssertEqual(u?.baseManifestSha256, .some("m1"))
        XCTAssertTrue(d.asksAgain(from: c, text: text))

        // Emptying a manifest that existed removes it; one that never existed sends nothing.
        d.code = "a\n"
        d.manifest = "  "
        XCTAssertEqual(d.scriptUpdate(stillManaged: true)?.manifest, .some(nil))
        d.take(files(manifest: nil))
        d.manifest = ""
        XCTAssertNil(d.scriptUpdate(stillManaged: true))
    }

    func testLanguageAndKindSwitches() {
        let c = managed()
        var d = CollectorDraft(c, text: text)
        d.take(files())
        d.setLanguage(.typescript) // same manifest kind: keeps the text
        XCTAssertEqual(d.manifest, "{}\n")
        d.setLanguage(.python3) // requirements.txt: starts empty
        XCTAssertEqual(d.manifest, "")
        XCTAssertEqual(d.patch(from: c, text: text).script?.interpreter, .python3)
        d.setLanguage(.node)
        XCTAssertEqual(d.manifest, "{}\n", "back to the loaded kind brings its text back")

        // Kept → your own file sends the path; your own file → kept sends the code once (the core writes the file).
        d.managed = false
        d.scriptFile = "~/Scripts/x.js"
        XCTAssertEqual(d.patch(from: c, text: text).script?.source, .file("/Users/mei/Scripts/x.js"))
        XCTAssertNil(d.scriptUpdate(stillManaged: false))

        let own = Collector(id: "c2", kind: .script, name: "Own", vaultPath: "/v",
                            script: ScriptCollectorSettings(source: .file("/Users/mei/x.py"), interpreter: .python3),
                            status: CollectorStatus(script: CollectorScriptStatus(path: "/Users/mei/x.py")))
        var o = CollectorDraft(own, text: text)
        XCTAssertFalse(o.managed)
        XCTAssertEqual(o.scriptFile, "~/x.py")
        o.managed = true
        o.code = "print(1)\n"
        XCTAssertEqual(o.patch(from: own, text: text).script?.source, .inline("print(1)\n"))
    }

    func testWordingForInstallsTestRunsAndRunNow() {
        let now = Date()
        var c = managed(manifest: CollectorManifestStatus(name: "package.json", hasDependencies: true, packageCount: 3, installing: true, state: "installing"))
        XCTAssertEqual(text.statusKind(c), .running)
        XCTAssertEqual(text.rowSummary(c, now: now), "Installing packages…")
        c.status?.script?.manifest = CollectorManifestStatus(name: "package.json", hasDependencies: true, packageCount: 3, state: "failed")
        c.status?.needsAttention = true
        XCTAssertEqual(text.rowSummary(c, now: now), "Couldn’t install packages")
        XCTAssertTrue(text.titleLine(c, now: now).hasSuffix("waits for its packages"))

        c.status?.needsAttention = false
        c.status?.script?.manifest?.state = "ready"
        c.status?.needsConsent = true
        c.status?.script?.changes = ["manifest"]
        XCTAssertEqual(text.rowSummary(c, now: now), "package.json changed")
        XCTAssertTrue(text.manifestOnlyChanged(c))

        c.status?.needsConsent = false
        let test = CollectorRun(id: "t", collectorId: "col-1", kind: .script, trigger: "test", startedAt: now, result: .success,
                                filesAdded: ["a.md", "b.md"], outputDir: "/S/test-runs/col-1")
        XCTAssertEqual(text.rowSummary(c, now: now, latest: test), "Test run · 2 files, not queued")
        XCTAssertEqual(text.runSummary(test, now: now), "Test run · 2 files in the test folder")
        let manual = CollectorRun(id: "r", collectorId: "col-1", kind: .script, trigger: "now", startedAt: now, result: .success,
                                  counts: .init(added: 2), exitCode: 0)
        XCTAssertEqual(text.runSummary(manual, now: now), "Run now · added 2 files")
        let waits = CollectorRun(id: "w", collectorId: "col-1", kind: .script, trigger: "now", startedAt: now, result: .queued, waiting: "install")
        XCTAssertEqual(text.runSummary(waits, now: now), "Run now · waits for packages")
        let notRun = CollectorRun(id: "n", collectorId: "col-1", kind: .script, startedAt: now, result: .failed,
                                  error: .init(code: .installFailed, message: "x"))
        XCTAssertEqual(text.runSummary(notRun, now: now), "Not run · packages aren’t installed")
        XCTAssertEqual(text.runMeta(notRun), "Install again first")
    }

    func testManifestCount() {
        XCTAssertEqual(ManifestCount.count("package.json", "{\"dependencies\":{\"a\":\"1\",\"b\":\"2\"},\"devDependencies\":{\"c\":\"3\"}}"), 3)
        XCTAssertEqual(ManifestCount.count("package.json", "{ not json"), 0)
        XCTAssertEqual(ManifestCount.count("requirements.txt", "requests>=2\n# comment\n\n-r other.txt\nkeyring\n"), 2)
    }
}
