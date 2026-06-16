import Foundation
import Testing
@testable import Pilot

@Suite("File finder filtering")
struct FileFinderTests {

    private func item(_ relativePath: String) -> FileItem {
        FileItem(
            path: "/root/" + relativePath,
            relativePath: relativePath,
            name: (relativePath as NSString).lastPathComponent
        )
    }

    private func sample() -> [FileItem] {
        [
            "workers/rendezvous/src/index.ts",
            "workers/rendezvous/package.json",
            "workers/rendezvous/tsconfig.json",
            "workers/web/package.json",
            "apple/Sources/Pilot/EditorPaneView.swift",
            "apple/Sources/Pilot/FileFinder.swift",
            "apple/Tests/PilotTests/PaneCyclingTests.swift",
        ].map(item)
    }

    /// Regression: a query that only appears in the *directory* path (no file is
    /// named "rendezvous") must still surface the files inside that directory.
    /// The old name-only matcher returned nothing here.
    @Test("Files are findable by a directory-name substring")
    func findsByDirectorySubstring() {
        let results = FileFinder.filter(items: sample(), query: "rendezvous")
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.relativePath.contains("rendezvous") })
        #expect(results.contains { $0.name == "index.ts" })
        #expect(results.contains { $0.name == "package.json" })
    }

    /// Quick-open is preserved: a basename match outranks a path-only match of
    /// the same query, so typing a filename still lands that file first.
    @Test("A basename match outranks a path-only match")
    func basenameOutranksPath() {
        let files = [
            item("zoo/Sources/helpers/util.swift"),     // "pane" only via the dir? no — control row
            item("pane/Sources/helpers/util.swift"),    // "pane" only in the directory
            item("apple/Sources/Pilot/EditorPaneView.swift"), // "pane" in the basename
        ]
        let results = FileFinder.filter(items: files, query: "pane")
        #expect(results.first?.name == "EditorPaneView.swift")
    }

    /// A query containing "/" matches against the full relative path.
    @Test("A slash query matches the full path")
    func slashQueryMatchesPath() {
        let results = FileFinder.filter(items: sample(), query: "rendezvous/index")
        #expect(results.first?.relativePath == "workers/rendezvous/src/index.ts")
    }

    /// No query is the "browse" case: the whole list, alphabetized by path.
    @Test("Empty query returns the tree alphabetized")
    func emptyQueryAlphabetized() {
        let files = sample()
        let results = FileFinder.filter(items: files, query: "")
        #expect(results.count == files.count)
        let expected = files.map(\.relativePath)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        #expect(results.map(\.relativePath) == expected)
    }
}
