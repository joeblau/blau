import AppKit
import Foundation
import SwiftData
import Testing
@testable import Pilot

@MainActor
struct NotesSecurityBoundaryTests {
    private final class TextChangeCounter: NSObject, NSTextViewDelegate {
        var notificationCount = 0

        func textDidChange(_ notification: Notification) {
            notificationCount += 1
        }
    }

    @Test("Env values are redacted in secondary presentation")
    func redactsEnvValues() {
        let body = "API_TOKEN=secret-value\nOrdinary prose"

        #expect(EnvSecret.redacted(body) == "API_TOKEN=••••••••\nOrdinary prose")
        #expect(Note(body: body).displayTitle == "API_TOKEN=••••••••")
    }

    @Test("Reveal and explicit-copy data use the exact parsed value")
    func parsesValueForRevealAndCopy() throws {
        let match = try #require(EnvSecret.matches(in: "export API_TOKEN=\"secret-value\"").first)

        #expect(match.key == "API_TOKEN")
        #expect(match.value == "secret-value")
        #expect(EnvSecret.redacted("API_TOKEN=secret-value", revealing: ["API_TOKEN"])
                == "API_TOKEN=secret-value")
    }

    @Test("The visual-only contract preserves plaintext persistence")
    func persistsPlaintextForCompatibility() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Note.self, configurations: configuration)
        let context = ModelContext(container)
        let note = Note(body: "API_TOKEN=secret-value")
        context.insert(note)
        try context.save()

        let saved = try #require(try context.fetch(FetchDescriptor<Note>()).first)
        #expect(saved.body == "API_TOKEN=secret-value")
        #expect(saved.displayTitle == "API_TOKEN=••••••••")
    }

    @Test("Refreshing the visual mask cannot edit or re-enter the text view")
    func maskRefreshPreservesTextStorage() throws {
        let scrollView = MultiCursorTextView.scrollableTextView()
        let textView = try #require(scrollView.documentView as? MultiCursorTextView)
        let maskController = EnvMaskController()
        let counter = TextChangeCounter()
        let plaintext = "API_TOKEN=secret-value\nOrdinary prose"

        textView.string = plaintext
        textView.delegate = counter
        textView.maskController = maskController
        maskController.textView = textView
        textView.layoutManager?.delegate = maskController

        maskController.refresh()
        maskController.refresh()

        #expect(textView.string == plaintext)
        #expect(counter.notificationCount == 0)
        #expect(textView.accessibilityValue() == "API_TOKEN=••••••••\nOrdinary prose")
    }
}
