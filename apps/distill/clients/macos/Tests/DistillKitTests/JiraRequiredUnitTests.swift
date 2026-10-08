import XCTest
@testable import DistillKit

/// Jira required fields (actions.md), the pure helpers one at a time: lenient decoding, which fields are
/// asked, the value in force, the footer's order, the words, the value encodings and saved values.
final class JiraRequiredUnitTests: XCTestCase {
    let team = JiraField(id: "cf_team", name: "Team", kind: .option, options: [JiraOption(id: "1", name: "Platform")])

    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testFieldDecodesLeniently() throws {
        let f = try decode(JiraField.self, #"{"id":"cf_1","name":"Team","required":true,"kind":"options","options":[{"id":"1","name":"A"},{"id":2}],"hasDefault":true}"#)
        XCTAssertEqual(f, JiraField(id: "cf_1", name: "Team", required: true, kind: .options, options: [JiraOption(id: "1", name: "A")], hasDefault: true))
        let bare = try decode(JiraField.self, #"{"required":"yes","kind":7,"options":"x","hasDefault":"yes"}"#)
        XCTAssertEqual(bare, JiraField(id: "", name: "", required: false, kind: .unsupported, options: [], hasDefault: false))
        XCTAssertEqual(bare.key, "jira.")
        XCTAssertEqual(try decode(JiraField.self, #"{"id":"d","kind":"date"}"#).kind, .date)
    }

    func testAskedIsRequiredWithoutAJiraDefault() {
        XCTAssertTrue(JiraField(id: "a", name: "A", required: true, kind: .text).asked)
        XCTAssertFalse(JiraField(id: "a", name: "A", required: true, kind: .text, hasDefault: true).asked)
        XCTAssertFalse(JiraField(id: "a", name: "A", required: false, kind: .text).asked)
        XCTAssertFalse(JiraField(id: "a", name: "A", required: false, kind: .text, hasDefault: true).asked)
        XCTAssertEqual(team.key, "jira.cf_team")
    }

    func testCreateScreenDecodesLeniently() throws {
        let s = try decode(JiraCreateScreen.self, #"{"project":"TLS","typeId":"1","priorities":null}"#)
        XCTAssertEqual(s, JiraCreateScreen(project: "TLS", typeId: "1", priorities: nil))
        XCTAssertEqual(s.extra, [])
        let odd = try decode(JiraCreateScreen.self, #"{"project":3,"priorities":["High"],"extra":[{"id":"x","name":"X","kind":"text"}]}"#)
        XCTAssertEqual(odd.project, "")
        XCTAssertEqual(odd.typeId, "")
        XCTAssertEqual(odd.priorities, ["High"])
        XCTAssertEqual(odd.extra.map(\.kind), [.text])
    }

    func testKeys() {
        XCTAssertEqual(JiraRequired.key("cf_1"), "jira.cf_1")
        XCTAssertEqual(JiraRequired.fromKey("cf_1"), "jira.cf_1:from")
        XCTAssertEqual(JiraRequired.defaultsKey("  tls ", " Task "), "TLS|Task")
    }

    func testIsEmpty() {
        for v in [nil, "", "   ", "\n\t", "[]", " [] ", "{}", "\n{}\n"] as [String?] { XCTAssertTrue(JiraRequired.isEmpty(v), "\(String(describing: v))") }
        for v in ["x", "0", "[ ]", "[\"\"]", "{\"a\":1}"] { XCTAssertFalse(JiraRequired.isEmpty(v), v) }
    }

    func testShownAndValueInForce() {
        let optional = JiraField(id: "o", name: "Squad", required: false, kind: .text)
        let filled = JiraField(id: "f", name: "Region", kind: .option, hasDefault: true)
        let saved = ["f": JiraRequiredDefault(name: "Region", value: "EU")]
        XCTAssertEqual(JiraRequired.shown([optional, team, filled], defaults: saved).map(\.id), ["cf_team", "f"], "order kept; a Jira default with a saved value shows")
        XCTAssertEqual(JiraRequired.shown([], defaults: saved), [])

        let d = ["cf_team": JiraRequiredDefault(name: "Team", value: "Payments")]
        XCTAssertEqual(JiraRequired.value(team, values: ["jira.cf_team": "Platform"], defaults: d), "Platform")
        XCTAssertEqual(JiraRequired.value(team, values: ["jira.cf_team": " [] "], defaults: d), "Payments")
        XCTAssertEqual(JiraRequired.value(team, values: [:], defaults: d), "Payments")
        XCTAssertNil(JiraRequired.value(team, values: ["cf_team": "Platform"], defaults: [:]), "only under jira.<id>")
        XCTAssertNil(JiraRequired.value(team, values: [:], defaults: ["cf_team": JiraRequiredDefault(name: "Team", value: "  ")]))
    }

    func testMissingNamesTheFirstAskedFieldInOrder() {
        let plan = JiraField(id: "plan", name: "Rollout plan", kind: .unsupported)
        let optionalPlan = JiraField(id: "plan2", name: "Notes", required: false, kind: .unsupported)
        let due = JiraField(id: "due", name: "Due", kind: .date)
        XCTAssertNil(JiraRequired.missing([], values: [:], defaults: [:]))
        XCTAssertNil(JiraRequired.missing([optionalPlan], values: [:], defaults: [:]), "not asked: never blocks")
        XCTAssertEqual(JiraRequired.missing([team, due], values: ["jira.cf_team": "Platform"], defaults: [:])?.message, "Fill in Due first")
        XCTAssertEqual(JiraRequired.missing([team, due], values: [:], defaults: [:])?.field, "jira.cf_team")
        XCTAssertEqual(JiraRequired.missing([plan], values: ["jira.plan": "x"], defaults: [:])?.message, "Rollout plan can only be filled in Jira", "even with a value")
        XCTAssertEqual(JiraRequired.missing([plan], values: [:], defaults: [:])?.field, "jira.plan")
        XCTAssertNil(JiraRequired.missing([team], values: [:], defaults: ["cf_team": JiraRequiredDefault(name: "Team", value: "Platform")]))
    }

    func testWords() {
        XCTAssertEqual(JiraRequired.placeholder("Area"), "Choose an area")
        XCTAssertEqual(JiraRequired.placeholder("Owner"), "Choose an owner")
        XCTAssertEqual(JiraRequired.placeholder("Unit"), "Choose an unit", "a vowel letter, not a vowel sound")
        XCTAssertEqual(JiraRequired.placeholder("Squad"), "Choose a squad")
        XCTAssertEqual(JiraRequired.placeholder(""), "Choose a ")
        XCTAssertEqual(JiraRequired.menuTitle("Components", project: "OPS"), "COMPONENTS IN OPS")
        XCTAssertEqual(JiraRequired.menuTitle("team", project: "TLS"), "TEAMS IN TLS")
        XCTAssertEqual(JiraRequired.useForFuture(project: "TLS", type: " Bugs "), "Use for future TLS Bugs")
        XCTAssertEqual(JiraRequired.useForFuture(project: "OPS", type: "Story"), "Use for future OPS Storys")
        XCTAssertEqual(JiraRequired.initials("Aditya Pradhan Kumar"), "AP")
        XCTAssertEqual(JiraRequired.initials("mei"), "M")
        XCTAssertEqual(JiraRequired.initials(""), "")
    }

    func testNamesUsersAndPairs() {
        XCTAssertEqual(JiraRequired.names(#"["A","B"]"#), ["A", "B"])
        XCTAssertEqual(JiraRequired.names(" A , ,B "), ["A", "B"], "comma text when not a JSON list")
        XCTAssertEqual(JiraRequired.names(nil), [])
        XCTAssertEqual(JiraRequired.names(#"{"a":1}"#), [#"{"a":1}"#])
        XCTAssertEqual(JiraRequired.encode(["A", "B"]), #"["A","B"]"#)
        XCTAssertEqual(JiraRequired.encode([String]()), "[]")
        XCTAssertNil(JiraRequired.user(nil))
        XCTAssertNil(JiraRequired.user("Mei"))
        XCTAssertNil(JiraRequired.user(#"{"name":"Mei"}"#))
        let u = JiraUser(accountId: "a1", name: "Mei")
        XCTAssertEqual(u.id, "a1")
        XCTAssertEqual(try decode([String: String].self, JiraRequired.encode(u)), ["accountId": "a1", "name": "Mei"], "the core's {accountId, name}")
        XCTAssertTrue(JiraRequired.pair(nil) == (nil, nil))
        XCTAssertTrue(JiraRequired.pair("Prod") == ("Prod", nil))
        XCTAssertTrue(JiraRequired.pair(#"["Staging","us-east-1","x"]"#) == ("Staging", "us-east-1"))
    }

    func testFromNote() {
        let comps = JiraField(id: "c", name: "Components", kind: .options)
        XCTAssertEqual(JiraRequired.fromNote(team, values: ["jira.cf_team": "Platform"]), [], "no tag")
        XCTAssertEqual(JiraRequired.fromNote(team, values: ["jira.cf_team": "Platform", "jira.cf_team:from": ""]), [], "an empty tag")
        XCTAssertEqual(JiraRequired.fromNote(team, values: ["jira.cf_team:from": "note"]), [""], "note with no value")
        XCTAssertEqual(JiraRequired.fromNote(comps, values: ["jira.c": #"["API","Web"]"#, "jira.c:from": "note"]), ["API", "Web"], "note on several: every name")
        XCTAssertEqual(JiraRequired.fromNote(team, values: ["jira.cf_team": "Platform", "jira.cf_team:from": #"["Platform"]"#]), ["Platform"])
    }

    func testDates() throws {
        XCTAssertNil(JiraRequired.date(nil))
        XCTAssertNil(JiraRequired.date("2026-10-6"))
        XCTAssertNil(JiraRequired.date("2026-10-016"))
        XCTAssertNil(JiraRequired.date("Oct 16 '26"))
        let d = try XCTUnwrap(JiraRequired.date("2026-10-16"))
        XCTAssertEqual(d.timeIntervalSince1970, 1_792_108_800 + 12 * 3600, "UTC noon")
        XCTAssertEqual(JiraRequired.dayString(Date(timeIntervalSince1970: 1_792_108_800 + 23 * 3600)), "2026-10-16")
        XCTAssertEqual(JiraRequired.dayLabel("2026-01-05"), "Jan 5, 2026")
        XCTAssertNil(JiraRequired.dayLabel("not a day"))
    }

    func testDisplay() {
        let f = { (k: JiraFieldKind) in JiraField(id: "x", name: "X", kind: k) }
        XCTAssertNil(JiraRequired.display(f(.text), nil))
        XCTAssertNil(JiraRequired.display(f(.options), "[]"))
        XCTAssertEqual(JiraRequired.display(f(.options), #"["API","Gateway"]"#), "API, Gateway")
        XCTAssertEqual(JiraRequired.display(f(.user), #"{"accountId":"a","name":"Aditya Pradhan"}"#), "Aditya Pradhan")
        XCTAssertEqual(JiraRequired.display(f(.user), "Aditya"), "Aditya", "not a person: as written")
        XCTAssertEqual(JiraRequired.display(f(.cascading), "Prod"), "Prod")
        XCTAssertEqual(JiraRequired.display(f(.date), "2026-10-16"), "Oct 16, 2026")
        XCTAssertEqual(JiraRequired.display(f(.date), "16/10/2026"), "16/10/2026")
        XCTAssertEqual(JiraRequired.display(f(.text), " as is "), " as is ")
        XCTAssertEqual(JiraRequired.display(f(.option), #"["A","B"]"#), #"["A","B"]"#, "one choice is the text itself")
    }

    func testTicketText() {
        let comps = JiraField(id: "c", name: "Components", kind: .options)
        let due = JiraField(id: "d", name: "Due", kind: .date)
        let empty = JiraField(id: "e", name: "Squad", kind: .text)
        let values = ["jira.c": #"["API","Gateway"]"#, "jira.d": "2026-10-16"]
        XCTAssertEqual(JiraRequired.ticketText(title: "Cap retries", body: "Why it matters", fields: [team, comps, due, empty], values: values,
                                               defaults: ["cf_team": JiraRequiredDefault(name: "Team", value: "Platform")]),
                       "Cap retries\n\nWhy it matters\n\nTeam: Platform\nComponents: API, Gateway\nDue: Oct 16, 2026")
        XCTAssertEqual(JiraRequired.ticketText(title: "Cap retries", body: nil, fields: [empty], values: [:], defaults: [:]), "Cap retries",
                       "no description and no filled field: the title alone")
        XCTAssertEqual(JiraRequired.ticketText(title: "", body: "", fields: [team], values: ["jira.cf_team": "Data"], defaults: [:]), "Team: Data")
    }

    func testSavedValuesDecodeLeniently() {
        XCTAssertEqual(ActionPreferences().jiraRequiredDefaults, [:])
        XCTAssertEqual(ActionPreferences(raw: ["types": .object(["jira": .object(["requiredDefaults": .string("x")])])]).jiraRequiredDefaults, [:])
        let p = ActionPreferences(raw: ["types": .object(["jira": .object(["requiredDefaults": .object([
            "TLS|Task": .object([
                "cf_team": .object(["name": .string("Team"), "value": .string("Platform")]),
                "cf_2": .object(["value": .string("A")]),
                "blank": .object(["name": .string("Blank"), "value": .string(" ")]),
                "list": .object(["name": .string("List"), "value": .string("[]")]),
                "num": .object(["name": .string("Num"), "value": .number(3)]),
            ]),
            "TLS|Bug": .object(["blank": .object(["value": .string("")])]),
            "OPS|Story": .string("x"),
        ])])])])
        XCTAssertEqual(p.jiraRequiredDefaults, ["TLS|Task": [
            "cf_team": JiraRequiredDefault(name: "Team", value: "Platform"),
            "cf_2": JiraRequiredDefault(name: "cf_2", value: "A"),
        ]])
    }

    func testRemovingOneSavedValueKeepsTheOthers() {
        var p = ActionPreferences()
        p.setJiraRequiredDefault("TLS|Task", field: "a", JiraRequiredDefault(name: "A", value: "1"))
        p.setJiraRequiredDefault("TLS|Task", field: "b", JiraRequiredDefault(name: "B", value: "2"))
        p.setJiraRequiredDefault("TLS|Bug", field: "a", JiraRequiredDefault(name: "A", value: "3"))
        p.setJiraRequiredDefault("TLS|Task", field: "a", nil)
        XCTAssertEqual(p.jiraRequiredDefaults, ["TLS|Task": ["b": JiraRequiredDefault(name: "B", value: "2")], "TLS|Bug": ["a": JiraRequiredDefault(name: "A", value: "3")]])
        XCTAssertNotNil(p.value(["types", "jira", "requiredDefaults", "TLS|Task"]))
        p.setJiraRequiredDefault("TLS|Bug", field: "a", nil)
        XCTAssertNil(p.value(["types", "jira", "requiredDefaults", "TLS|Bug"]))
        XCTAssertNotNil(p.value(["types", "jira", "requiredDefaults", "TLS|Task", "b"]))
    }

    func testCheckOrderAndTheTypesSavedValues() {
        let projects = [JiraProject(key: "TLS", name: "Telus")]
        let types = ["TLS": [JiraIssueType(id: "1", name: "Task"), JiraIssueType(id: "2", name: "Bug")]]
        let screens = ["TLS|1": JiraCreateScreen(project: "TLS", typeId: "1", priorities: ["High"], extra: [team]),
                       "TLS|2": JiraCreateScreen(project: "TLS", typeId: "2", priorities: nil, extra: [team])]
        let saved = ["TLS|Task": ["cf_team": JiraRequiredDefault(name: "Team", value: "Platform")]]
        // A priority outside the list comes before a missing field.
        let c = JiraPick.check(["project": "TLS", "issueType": "task", "priority": "Low"], projects: projects, types: types, screens: screens)
        XCTAssertEqual(c?.field, "priority")
        // The saved value is the type's: Task's doesn't fill Bug's.
        XCTAssertNil(JiraPick.check(["project": "tls", "issueType": "task"], projects: projects, types: types, screens: screens, defaults: saved))
        let bug = JiraPick.check(["project": "TLS", "issueType": "Bug"], projects: projects, types: types, screens: screens, defaults: saved)
        XCTAssertEqual(bug?.field, "jira.cf_team")
        XCTAssertEqual(bug?.message, "Fill in Team first")
        XCTAssertEqual(bug?.footer, "Fill in Team first")
        // No screen loaded yet: nothing to say.
        XCTAssertNil(JiraPick.check(["project": "TLS", "issueType": "Task"], projects: projects, types: types, screens: [:]))
    }
}
