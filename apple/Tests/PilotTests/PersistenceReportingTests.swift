import SwiftData
import Testing
@testable import Pilot

@Suite("Persistence failure recovery")
@MainActor
struct PersistenceReportingTests {
    private enum InjectedFailure: Error {
        case unavailable
    }

    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Note.self, configurations: configuration)
        return ModelContext(container)
    }

    @Test("Create failures keep the inserted model available for retry")
    func createFailureKeepsPendingInsert() throws {
        let context = try makeContext()
        let note = Note(body: "pending create")
        context.insert(note)

        let saved = context.saveReporting(operation: "Creating note") { _ in
            throw InjectedFailure.unavailable
        }

        #expect(!saved)
        #expect(try context.fetch(FetchDescriptor<Note>()).contains { $0.id == note.id })
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Note>()).contains { $0.id == note.id })
    }

    @Test("Edit failures keep the unsaved value available for retry")
    func editFailureKeepsPendingValue() throws {
        let context = try makeContext()
        let note = Note(body: "before")
        context.insert(note)
        try context.save()
        note.body = "after"

        let saved = context.saveReporting(operation: "Editing note") { _ in
            throw InjectedFailure.unavailable
        }

        #expect(!saved)
        #expect(note.body == "after")
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Note>()).first?.body == "after")
    }

    @Test("Delete failures roll back instead of pretending deletion was durable")
    func deleteFailureRollsBack() throws {
        let context = try makeContext()
        let note = Note(body: "keep me")
        context.insert(note)
        try context.save()
        context.delete(note)

        let saved = context.saveReporting(
            operation: "Deleting note",
            rollbackOnFailure: true
        ) { _ in
            throw InjectedFailure.unavailable
        }

        #expect(!saved)
        #expect(try context.fetch(FetchDescriptor<Note>()).contains { $0.id == note.id })
    }
}
