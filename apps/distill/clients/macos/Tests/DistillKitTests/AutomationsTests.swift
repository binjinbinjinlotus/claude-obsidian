import XCTest
@testable import DistillKit

/// Automations (action-buttons.md): commands on scripts, buttons on types, runs on items, and the client routes.
final class AutomationsTests: XCTestCase {
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

    static let script = #"""
    {"source":{"file":"/tmp/slack.py"},"interpreter":"python3","timeoutSeconds":60,"collects":false,
     "commands":[{"id":"send","label":"Send a message","args":[{"name":"send","kind":"word","value":"send"},
       {"name":"thread","kind":"flag","flag":"--thread"},{"name":"target","kind":"positional","pattern":"^#","hint":"#channel"},
       {"name":"x","kind":"teleport"}],"result":{"keyPattern":"ts ([0-9.]+)"}}]}
    """#

    func testScriptSettingsDecodeCommandsLeniently() throws {
        let s = try JSONDecoder.core.decode(ScriptCollectorSettings.self, from: Data(Self.script.utf8))
        XCTAssertFalse(s.collects)
        XCTAssertEqual(s.commands.count, 1)
        let send = s.commands[0]
        XCTAssertEqual(send.args.map(\.name), ["send", "thread", "target", "x"])
        XCTAssertEqual(send.args[3].kind, .positional, "an unknown kind reads as a value")
        XCTAssertEqual(send.bindable.map(\.name), ["thread", "target", "x"])
        XCTAssertFalse(send.args[1].isRequired, "a flag is optional by default")
        XCTAssertTrue(send.args[2].isRequired, "a value is required by default")
        XCTAssertEqual(send.result?.keyPattern, "ts ([0-9.]+)")

        let older = try JSONDecoder.core.decode(ScriptCollectorSettings.self, from: Data(#"{"source":{"inline":"echo"},"interpreter":"zsh"}"#.utf8))
        XCTAssertTrue(older.collects, "an older core's script collects")
        XCTAssertEqual(older.commands, [])
        // Round trip keeps them; defaults aren't written.
        let again = try JSONDecoder.core.decode(ScriptCollectorSettings.self, from: JSONEncoder.core.encode(s))
        XCTAssertEqual(again.commands, s.commands)
        XCTAssertFalse(again.collects)
        let plain = String(decoding: try JSONEncoder.core.encode(older), as: UTF8.self)
        XCTAssertFalse(plain.contains("collects"))
        XCTAssertFalse(plain.contains("commands"))
    }

    func testTypeButtonsAndItemRuns() throws {
        let type = try JSONDecoder.core.decode(ActionTypeInfo.self, from: Data(#"""
        {"id":"slack","label":"Slack message","handlers":[],"buttons":[
          {"id":"btn-send","label":"Send in Slack","scriptId":"col-1","commandId":"send","bindings":{"target":"{fields.to}"},
           "slot":"send","onSuccess":"markSent","available":false,"reason":"Slack CLI needs your OK","scriptName":"Slack CLI","commandLabel":"Send a message"},
          {"id":"btn-x","label":"Later","scriptId":"col-1","commandId":"send","slot":"more","enabled":false,"available":true}]}
        """#.utf8))
        XCTAssertEqual(type.buttons.count, 2)
        let send = type.buttons[0]
        XCTAssertEqual(send.button.slot, .send)
        XCTAssertEqual(send.button.onSuccess, .markSent)
        XCTAssertTrue(send.button.confirm, "asks first by default")
        XCTAssertFalse(send.available)
        XCTAssertEqual(send.reason, "Slack CLI needs your OK")
        XCTAssertEqual(send.button.bindings["target"], "{fields.to}")

        let item = try JSONDecoder.core.decode(ActionItem.self, from: Data(#"""
        {"id":"a1","type":"slack","status":"sent","title":"Tell Mei","fields":{},"source":{"kind":"manual"},
         "activeRun":{"runId":"r2","buttonId":"btn-send"},
         "runs":[{"runId":"r1","buttonId":"btn-send","label":"Send in Slack","startedAt":"2026-10-05T10:42:00Z","endedAt":"2026-10-05T10:42:01Z",
                  "durationMs":1200,"result":"success","exitCode":0,"stdoutTail":"a\nb\nc\nsent (ts 1.2)","external":{"key":"1.2","url":null}}]}
        """#.utf8))
        XCTAssertEqual(item.runs.count, 1)
        XCTAssertEqual(item.runs[0].externalKey, "1.2")
        XCTAssertTrue(item.runs[0].succeeded)
        XCTAssertEqual(item.activeRun?.runId, "r2")
        let again = try JSONDecoder.core.decode(ActionItem.self, from: JSONEncoder.core.encode(item))
        XCTAssertEqual(again.runs, item.runs)
        XCTAssertEqual(again.activeRun, item.activeRun)

        // Slots: the send button for a ready item; a disabled one is left out; a sent item shows nothing by default.
        var ready = item; ready.status = .ready
        let slots = AutomationText.slots(type.buttons, for: ready)
        XCTAssertEqual(slots.send?.id, "btn-send")
        XCTAssertEqual(slots.more.map(\.id), [])
        XCTAssertNil(AutomationText.slots(type.buttons, for: item).send, "default when: open and ready")
    }

    func testDisplayText() {
        let run = ActionButtonRun(runId: "r", buttonId: "b", label: "Send in Slack", durationMs: 1200, result: "failed", exitCode: 3)
        XCTAssertEqual(AutomationText.runLine(run, time: "10:42 AM"), "Send in Slack · exit 3 · 1.2 s · 10:42 AM")
        var ok = run; ok.result = "success"; ok.durationMs = 80
        XCTAssertEqual(AutomationText.runLine(ok, time: "now"), "Send in Slack · 80 ms · now")
        XCTAssertEqual(AutomationText.lastLines("a\n\nb\nc\nd\n"), ["b", "c", "d"])
        XCTAssertEqual(AutomationText.slug("Send a message!", taken: []), "send-a-message")
        XCTAssertEqual(AutomationText.slug("Send", taken: ["send", "send-2"]), "send-3")
        XCTAssertEqual(AutomationText.slug("✓", taken: []), "command")
        let keys = AutomationText.templateKeys(fieldKeys: ["to"])
        XCTAssertTrue(keys.contains("fields.to"))
        XCTAssertTrue(keys.contains("summary"))
    }

    func testButtonsInSettingsKeepUnknownKeys() throws {
        var prefs = try JSONDecoder.core.decode(ActionPreferences.self, from: Data(#"""
        {"types":{"slack":{"enabled":true,"future":1,"buttons":[{"id":"btn-1","label":"Send","scriptId":"col-1","commandId":"send"},{"label":"broken"}]}}}
        """#.utf8))
        XCTAssertEqual(prefs.buttons("slack").map(\.id), ["btn-1"], "a button this build can't read is skipped")
        var list = prefs.buttons("slack")
        list[0].confirm = false
        prefs.setButtons("slack", list)
        XCTAssertEqual(prefs.typeValue("slack", "future"), .number(1))
        XCTAssertEqual(prefs.buttons("slack")[0].confirm, false)
        prefs.setButtons("slack", [])
        XCTAssertNil(prefs.typeValue("slack", "buttons"))
    }

    func testRunRoutesAndRefusals() async throws {
        respond(##"{"argv":["python3","/s.py","send","--","#general","hi"],"display":"python3 /s.py send -- '#general' hi","problems":[],"needsApproval":true,"approvalHash":"h"}"##)
        let preview = try await client.previewActionButton("a1", button: "btn-send")
        XCTAssertEqual(last.method, "POST")
        XCTAssertEqual(last.path, "/v1/actions/a1/buttons/btn-send/preview")
        XCTAssertEqual(preview.argv.count, 6)
        XCTAssertTrue(preview.needsApproval)

        respond(#"{"error":{"code":"invalid_state","message":"Check the command first.","needsApproval":true,"preview":{"argv":["x"],"display":"x","problems":[]}}}"#, status: 409)
        do {
            _ = try await client.runActionButton("a1", button: "btn-send", approve: false)
            XCTFail("expected a refusal")
        } catch let r as ActionButtonRefusal {
            XCTAssertTrue(r.needsApproval)
            XCTAssertFalse(r.needsConsent)
            XCTAssertEqual(r.preview?.argv, ["x"])
        }
        XCTAssertEqual(try bodyJSON()["approve"], .bool(false))

        respond(#"{"error":{"code":"invalid_state","message":"Slack CLI needs your OK.","needsConsent":true}}"#, status: 409)
        do {
            _ = try await client.runActionButton("a1", button: "btn-send", approve: true)
            XCTFail("expected a refusal")
        } catch let r as ActionButtonRefusal {
            XCTAssertTrue(r.needsConsent)
        }

        respond(#"{"error":{"code":"busy","message":"A button is already running for this item."}}"#, status: 409)
        do {
            _ = try await client.runActionButton("a1", button: "btn-send", approve: true)
            XCTFail("expected an error")
        } catch let e as CoreClientError {
            XCTAssertEqual(e.description, "A button is already running for this item.")
        }

        respond(#"{"run":{"id":"r1"},"item":{"id":"a1","type":"slack","status":"ready","title":"T","fields":{},"source":{"kind":"manual"},"activeRun":{"runId":"r1","buttonId":"btn-send"}}}"#, status: 202)
        let item = try await client.runActionButton("a1", button: "btn-send", approve: true)
        XCTAssertEqual(item.activeRun?.runId, "r1")
        XCTAssertEqual(try bodyJSON()["approve"], .bool(true))

        respond(#"{"ok":true}"#)
        try await client.stopActionButtonRun("a1")
        XCTAssertEqual(last.path, "/v1/actions/a1/buttons/stop")
    }

    func testDraftPreviewAndCommandsPatch() async throws {
        respond(#"{"argv":[],"display":"","problems":["target: needs a value"],"needsApproval":true}"#)
        let b = AutomationButton(id: "btn-1", label: "Send", scriptId: "col-1", commandId: "send", bindings: ["target": ""])
        let p = try await client.previewButtonDraft(typeId: "slack", button: b)
        XCTAssertEqual(p.problems, ["target: needs a value"])
        XCTAssertEqual(last.path, "/v1/action-buttons/preview")
        let body = try bodyJSON()
        XCTAssertEqual(body["typeId"], .string("slack"))
        XCTAssertEqual(body["button"]?["commandId"], .string("send"))

        respond(#"{"id":"col-1","kind":"script","name":"Slack CLI","enabled":true,"vaultPath":"/v","schedule":{"cron":"0 * * * *"},"createdAt":"2026-10-05T00:00:00Z","updatedAt":"2026-10-05T00:00:00Z"}"#)
        _ = try await client.updateScriptCommands("col-1", collects: false, commands: [ScriptCommand(id: "send", label: "Send")])
        XCTAssertEqual(last.method, "PATCH")
        let patch = try bodyJSON()
        XCTAssertEqual(patch["script"]?["collects"], .bool(false))
        guard case .array(let cmds)? = patch["script"]?["commands"] else { return XCTFail("commands") }
        XCTAssertEqual(cmds.first?["id"], .string("send"))
    }
}
