import Foundation
import Testing
@testable import Pilot

@Suite("GitHub task decoding")
struct GitHubTaskDecodingTests {

    private func decode(_ json: String) throws -> [GitHubTask] {
        try JSONDecoder().decode([GitHubTask].self, from: Data(json.utf8))
    }

    @Test("Assignees decode from the gh issue list payload")
    func decodesAssignees() throws {
        let tasks = try decode(
            """
            [{
              "number": 268,
              "title": "create a nauty docker image",
              "url": "https://github.com/o/r/issues/268",
              "state": "OPEN",
              "assignees": [
                { "id": "MDQ6", "login": "joeblau", "name": "Joe Blau" },
                { "id": "MDQ7", "login": "octocat", "name": "" }
              ]
            }]
            """
        )

        #expect(tasks.count == 1)
        #expect(tasks[0].assignees.map(\.login) == ["joeblau", "octocat"])
        #expect(tasks[0].assignees[0].fullDescription == "Joe Blau (joeblau)")
        // An empty display name falls back to the handle rather than rendering
        // an empty parenthetical.
        #expect(tasks[0].assignees[1].fullDescription == "octocat")
    }

    @Test("A null display name falls back to the handle")
    func nullNameFallsBackToLogin() throws {
        let tasks = try decode(
            """
            [{
              "number": 1, "title": "t", "url": "u", "state": "OPEN",
              "assignees": [{ "login": "dependabot", "name": null }]
            }]
            """
        )

        #expect(tasks[0].assignees[0].fullDescription == "dependabot")
    }

    @Test("An unassigned issue decodes to no assignees")
    func unassignedIssue() throws {
        let tasks = try decode(
            """
            [{ "number": 2, "title": "t", "url": "u", "state": "OPEN", "assignees": [] }]
            """
        )

        #expect(tasks[0].assignees.isEmpty)
    }

    /// A payload without the field must still list issues: dropping the whole
    /// tab because one optional field is missing is the worse failure.
    @Test("A payload missing the assignees field still decodes")
    func missingAssigneesField() throws {
        let tasks = try decode(
            """
            [{ "number": 3, "title": "t", "url": "u", "state": "OPEN" }]
            """
        )

        #expect(tasks[0].number == 3)
        #expect(tasks[0].assignees.isEmpty)
    }
}
