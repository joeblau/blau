import Foundation
import SwiftData
import Testing
@testable import Pilot

@Suite("Pilot schema migration", .serialized)
@MainActor
struct PilotSchemaMigrationTests {
    /// A plan that knows only V1 — how shipped builds stamped users' stores
    /// before `ExtensionWorkspaceLink` existed.
    private enum V1OnlyPlan: SchemaMigrationPlan {
        static var schemas: [any VersionedSchema.Type] { [PilotSchemaV1.self] }
        static var stages: [MigrationStage] { [] }
    }

    @Test("Notes written at V1 stay readable through the live class after migration")
    func v1NotesRemainReadableAfterMigration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilot-schema-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Pilot.store")

        try autoreleasepool {
            let schema = Schema(versionedSchema: PilotSchemaV1.self)
            let container = try ModelContainer(
                for: schema,
                migrationPlan: V1OnlyPlan.self,
                configurations: ModelConfiguration(schema: schema, url: storeURL)
            )
            let context = container.mainContext
            let note = PilotSchemaV1.Note()
            note.body = "Keeps this note\nsecond line"
            note.sortOrder = 3
            context.insert(note)
            try context.save()
        }

        // The exact read path of the launch crash this guards: fetch through
        // the LIVE Note class (its frozen V1 twin also exists in the binary)
        // and pull `body` through the SwiftData getter.
        let container = try makeV2Container(at: storeURL)
        let context = container.mainContext
        let notes = try context.fetch(FetchDescriptor<Note>())
        #expect(notes.count == 1)
        #expect(notes.first?.body == "Keeps this note\nsecond line")
        #expect(notes.first?.sortOrder == 3)
        #expect(notes.first?.displayTitle == "Keeps this note")
    }

    @Test("V1 canonical workspace state survives V2 migration and accepts extension links")
    func v1StoreMigratesToV2WithoutLosingWorkspaceState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pilot-schema-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("Pilot.store")
        let fixture = try writeV1Fixture(to: storeURL)
        let extensionWorkspaceID = try migrateToV2AndInsertLink(at: storeURL, fixture: fixture)
        try verifyInsertedLinkAfterReopeningV2(
            at: storeURL,
            fixture: fixture,
            extensionWorkspaceID: extensionWorkspaceID
        )
    }

    /// Writes the store exactly as a shipped V1 build would have: through the
    /// FROZEN `PilotSchemaV1` snapshot classes (a container built from the V1
    /// schema registers those, not the live types) and a V1-only plan, so the
    /// store carries V1's version stamp.
    private func writeV1Fixture(to storeURL: URL) throws -> FixtureIDs {
        try autoreleasepool {
            let schema = Schema(versionedSchema: PilotSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(
                for: schema,
                migrationPlan: V1OnlyPlan.self,
                configurations: configuration
            )
            let context = container.mainContext

            let workspace = PilotSchemaV1.Workspace()
            workspace.name = "Canonical Workspace"
            workspace.axisRaw = PaneAxis.horizontal.rawValue
            workspace.isInspectorPresented = true
            workspace.inspectorTabRaw = InspectorTab.commits.rawValue
            workspace.isPinned = true
            workspace.workspaceSortOrder = 7
            workspace.rootPath = "/tmp/canonical-repository"
            workspace.rootPathSourceRaw = RootPathSource.manual.rawValue
            workspace.actionBadgeCount = 4

            let terminal = PilotSchemaV1.Pane()
            terminal.kindRaw = PaneKind.terminal.rawValue
            terminal.sortOrder = 0
            terminal.currentDirectory = "/tmp/canonical-repository/terminal"
            terminal.bellCount = 3
            terminal.sizeFraction = 0.35
            terminal.restoredSizeFraction = 0.4
            terminal.wasCollapsedBeforeFocus = true
            terminal.workspace = workspace

            let browser = PilotSchemaV1.Pane()
            browser.kindRaw = PaneKind.browser.rawValue
            browser.sortOrder = 1
            browser.workspace = workspace
            browser.currentDirectory = "/tmp/canonical-repository/browser"
            browser.bellCount = 2
            browser.sizeFraction = 0.65
            browser.isCollapsed = true
            browser.restoredSizeFraction = 0.6
            let browserState = PilotSchemaV1.BrowserState()
            browserState.urlText = "https://example.com/migration?pane=browser#state"
            browserState.appearanceModeRaw = AppearanceMode.dark.rawValue
            browserState.navigationRequestID = 12
            browserState.inspectorToggleRequestID = 5
            browser.browserState = browserState

            workspace.panes = [terminal, browser]
            workspace.selectedPaneID = browser.id
            workspace.frontmostTerminalPaneID = terminal.id
            workspace.focusedPaneID = browser.id

            context.insert(workspace)
            try context.save()

            return FixtureIDs(
                workspaceID: workspace.id,
                terminalPaneID: terminal.id,
                browserPaneID: browser.id
            )
        }
    }

    private func migrateToV2AndInsertLink(
        at storeURL: URL,
        fixture: FixtureIDs
    ) throws -> UUID {
        try autoreleasepool {
            let container = try makeV2Container(at: storeURL)
            let context = container.mainContext
            let canonical = try canonicalWorkspace(in: context, id: fixture.workspaceID)

            try verifyCanonicalState(canonical, fixture: fixture)
            #expect(try context.fetch(FetchDescriptor<ExtensionWorkspaceLink>()).isEmpty)

            let extensionWorkspace = Workspace(name: "Extension Projection")
            extensionWorkspace.rootPath = "/tmp/canonical-repository"
            extensionWorkspace.rootPathSource = .manual
            let link = ExtensionWorkspaceLink(
                sourceWorkspaceID: fixture.workspaceID,
                workspace: extensionWorkspace
            )
            context.insert(extensionWorkspace)
            context.insert(link)
            try context.save()

            let insertedLinks = try context.fetch(FetchDescriptor<ExtensionWorkspaceLink>())
            let inserted = try #require(insertedLinks.first)
            #expect(insertedLinks.count == 1)
            #expect(inserted.sourceWorkspaceID == fixture.workspaceID)
            #expect(inserted.workspace?.id == extensionWorkspace.id)
            return extensionWorkspace.id
        }
    }

    private func verifyInsertedLinkAfterReopeningV2(
        at storeURL: URL,
        fixture: FixtureIDs,
        extensionWorkspaceID: UUID
    ) throws {
        try autoreleasepool {
            let container = try makeV2Container(at: storeURL)
            let context = container.mainContext

            let canonical = try canonicalWorkspace(in: context, id: fixture.workspaceID)
            try verifyCanonicalState(canonical, fixture: fixture)

            let links = try context.fetch(FetchDescriptor<ExtensionWorkspaceLink>())
            let link = try #require(links.first)
            #expect(links.count == 1)
            #expect(link.sourceWorkspaceID == fixture.workspaceID)
            #expect(link.workspace?.id == extensionWorkspaceID)
            #expect(link.workspace?.name == "Extension Projection")
        }
    }

    private func makeV2Container(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: PilotSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        return try ModelContainer(
            for: schema,
            migrationPlan: PilotMigrationPlan.self,
            configurations: configuration
        )
    }

    private func canonicalWorkspace(in context: ModelContext, id: UUID) throws -> Workspace {
        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        return try #require(workspaces.first { $0.id == id })
    }

    private func verifyCanonicalState(_ workspace: Workspace, fixture: FixtureIDs) throws {
        #expect(workspace.name == "Canonical Workspace")
        #expect(workspace.axis == .horizontal)
        #expect(workspace.isInspectorPresented)
        #expect(workspace.inspectorTab == .commits)
        #expect(workspace.isPinned)
        #expect(workspace.workspaceSortOrder == 7)
        #expect(workspace.rootPath == "/tmp/canonical-repository")
        #expect(workspace.rootPathSource == .manual)
        #expect(workspace.actionBadgeCount == 4)
        #expect(workspace.selectedPaneID == fixture.browserPaneID)
        #expect(workspace.frontmostTerminalPaneID == fixture.terminalPaneID)
        #expect(workspace.focusedPaneID == fixture.browserPaneID)

        let panes = workspace.sortedPanes
        #expect(panes.count == 2)
        let terminal = try #require(panes.first { $0.id == fixture.terminalPaneID })
        #expect(terminal.workspace?.id == fixture.workspaceID)
        #expect(terminal.kind == .terminal)
        #expect(terminal.sortOrder == 0)
        #expect(terminal.currentDirectory == "/tmp/canonical-repository/terminal")
        #expect(terminal.bellCount == 3)
        #expect(terminal.sizeFraction == 0.35)
        #expect(!terminal.isCollapsed)
        #expect(terminal.restoredSizeFraction == 0.4)
        #expect(terminal.wasCollapsedBeforeFocus)

        let browser = try #require(panes.first { $0.id == fixture.browserPaneID })
        #expect(browser.workspace?.id == fixture.workspaceID)
        #expect(browser.kind == .browser)
        #expect(browser.sortOrder == 1)
        #expect(browser.currentDirectory == "/tmp/canonical-repository/browser")
        #expect(browser.bellCount == 2)
        #expect(browser.sizeFraction == 0.65)
        #expect(browser.isCollapsed)
        #expect(browser.restoredSizeFraction == 0.6)

        let browserState = try #require(browser.browserState)
        #expect(browserState.urlText == "https://example.com/migration?pane=browser#state")
        #expect(browserState.appearanceMode == .dark)
        #expect(browserState.navigationRequestID == 12)
        #expect(browserState.inspectorToggleRequestID == 5)
    }
}

private struct FixtureIDs {
    let workspaceID: UUID
    let terminalPaneID: UUID
    let browserPaneID: UUID
}
