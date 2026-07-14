import AppKit
import Foundation
import Testing
@testable import Pilot

@Suite("Markdown image parsing")
struct MarkdownImageTests {
    @Test("Parses an inline image and its complete UTF-16 range")
    func standardImage() {
        let markdown = "😀 before ![Build graph](https://example.com/build.png) after"

        let matches = MarkdownImage.matches(in: markdown)

        #expect(matches.count == 1)
        #expect(matches.first?.altText == "Build graph")
        #expect(matches.first?.urlString == "https://example.com/build.png")
        #expect(matches.first?.url == URL(string: "https://example.com/build.png"))
        if let range = matches.first?.range {
            #expect((markdown as NSString).substring(with: range) == "![Build graph](https://example.com/build.png)")
        }
    }

    @Test("Preserves an angle-wrapped destination exactly and excludes the title")
    func angleWrappedDestinationAndTitle() {
        let destination = "https://cdn.example.com/image%20one.png?raw=1#preview"
        let markdown = "![Diagram](<\(destination)> \"Full-sized image\")"

        let match = MarkdownImage.matches(in: markdown).first

        #expect(match?.altText == "Diagram")
        #expect(match?.urlString == destination)
        #expect(match?.url.absoluteString == destination)
    }

    @Test("Accepts quoted titles and balanced parentheses in a bare destination")
    func titlesAndBalancedParentheses() {
        let markdown = "![One](https://example.com/a_(1).png 'Version 1')"

        let matches = MarkdownImage.matches(in: markdown)

        #expect(matches.count == 1)
        #expect(matches.first?.urlString == "https://example.com/a_(1).png")
    }

    @Test("Finds multiple images while ignoring ordinary links")
    func multipleImages() {
        let markdown = "[Docs](https://example.com) ![One](https://img.example/one.png) text ![Two](<https://img.example/two.png> \"Second\")"

        let matches = MarkdownImage.matches(in: markdown)

        #expect(matches.map(\.altText) == ["One", "Two"])
        #expect(matches.map(\.urlString) == ["https://img.example/one.png", "https://img.example/two.png"])
    }

    @Test("Ignores image examples inside inline code")
    func inlineCode() {
        let markdown = "`![Hidden](https://img.example/inline.png)` and ``![Also hidden](https://img.example/two.png)`` then ![Visible](https://img.example/visible.png)"

        let matches = MarkdownImage.matches(in: markdown)

        #expect(matches.map(\.altText) == ["Visible"])
        #expect(matches.map(\.urlString) == ["https://img.example/visible.png"])
    }

    @Test("Ignores image examples inside fenced code blocks")
    func fencedCode() {
        let markdown = """
        ![Before](https://img.example/before.png)
        ```markdown
        ![Hidden](https://img.example/fenced.png)
        ```
        ~~~
        ![Also hidden](https://img.example/tilde.png)
        ~~~
        ![After](https://img.example/after.png)
        """

        let matches = MarkdownImage.matches(in: markdown)

        #expect(matches.map(\.altText) == ["Before", "After"])
        #expect(matches.map(\.urlString) == [
            "https://img.example/before.png",
            "https://img.example/after.png",
        ])
    }

    @Test("Rejects relative and unsupported destinations because global notes have no base URL")
    func unsupportedDestinations() {
        let markdown = "![Relative](image.png) ![FTP](ftp://example.com/image.png)"

        #expect(MarkdownImage.matches(in: markdown).isEmpty)
    }

    @Test("Ignores escaped and malformed image syntax")
    func malformedImages() {
        let samples = [
            #"\![Escaped](escaped.png)"#,
            "![No destination]",
            "![No closing parenthesis](image.png",
            "![Broken angle](<image.png)",
            "![Broken title](image.png \"unterminated)",
            "![Unexpected suffix](image.png title)",
        ]

        for markdown in samples {
            #expect(MarkdownImage.matches(in: markdown).isEmpty, "Unexpected match in: \(markdown)")
        }
    }

    @MainActor
    @Test("Styling preserves source and reserves preview space without creating an ordinary link")
    func stylingContract() throws {
        let markdown = "Before\n![Diagram](https://example.com/diagram.png)\nAfter"
        let storage = NSTextStorage(string: markdown)

        MarkdownStyler(baseSize: 13).style(storage)

        #expect(storage.string == markdown)
        let image = try #require(MarkdownImage.matches(in: markdown).first)
        let line = (markdown as NSString).lineRange(
            for: NSRange(location: image.range.location, length: 0)
        )
        let paragraph = try #require(
            storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil)
                as? NSParagraphStyle
        )
        #expect(paragraph.paragraphSpacing == MarkdownImagePresentation.stride)

        // The image parser claims this range before normal Markdown links, so
        // clicking its alt text cannot launch the image as a regular link.
        let altTextLocation = image.range.location + 2
        #expect(storage.attribute(.link, at: altTextLocation, effectiveRange: nil) == nil)
    }
}
