import Foundation
import Testing
@testable import Pilot

/// The pure parsing and validation `EmulatorBridge` applies to `emulator`
/// output. AVD names become an `@name` argv element and render in the picker,
/// so the validation is a security boundary as much as a formatting one.
@Suite("EmulatorBridge AVD parsing")
struct EmulatorBridgeTests {
    // MARK: - parseAVDList

    @Test
    func parsesAndSortsAVDNames() {
        let output = """
        Pixel_7_API_34
        Medium_Phone_API_35
        """
        #expect(EmulatorBridge.parseAVDList(output) == ["Medium_Phone_API_35", "Pixel_7_API_34"])
    }

    @Test
    func sortsNumericallyNotLexically() {
        // Numeric-aware ordering keeps AVD_2 before AVD_10.
        let output = "AVD_10\nAVD_2\nAVD_1\n"
        #expect(EmulatorBridge.parseAVDList(output) == ["AVD_1", "AVD_2", "AVD_10"])
    }

    @Test
    func dropsNonNameNoiseLines() {
        // Some setups emit an INFO/warning banner on stdout before the names.
        let output = """
        INFO    | Storing crashdata in: /tmp/foo, detection is enabled
        Medium_Phone_API_35
        WARNING: userdata partition is resized
        """
        #expect(EmulatorBridge.parseAVDList(output) == ["Medium_Phone_API_35"])
    }

    @Test
    func deduplicatesRepeatedNames() {
        let output = "Medium_Phone_API_35\nMedium_Phone_API_35\n"
        #expect(EmulatorBridge.parseAVDList(output) == ["Medium_Phone_API_35"])
    }

    @Test
    func emptyOutputYieldsNoAVDs() {
        #expect(EmulatorBridge.parseAVDList("").isEmpty)
        #expect(EmulatorBridge.parseAVDList("\n  \n").isEmpty)
    }

    @Test
    func boundsTheNumberOfAVDs() {
        let output = (1...200).map { "AVD_\($0)" }.joined(separator: "\n")
        #expect(EmulatorBridge.parseAVDList(output).count == 64)
    }

    // MARK: - isValidAVDName

    @Test
    func acceptsWellFormedNames() {
        for name in ["Medium_Phone_API_35", "Pixel.7", "a", "AVD-1", "sdk_gphone64_arm64"] {
            #expect(EmulatorBridge.isValidAVDName(name), "\(name) should be valid")
        }
    }

    @Test
    func rejectsMalformedOrHostileNames() {
        for name in [
            "",                       // empty
            "Pixel 7",                // space (never emitted by -list-avds)
            "-no-window",             // could be read as a flag
            "a/b",                    // path separator
            "a;rm -rf",               // shell metacharacters
            "a\nb",                   // newline
            String(repeating: "x", count: 129), // too long
        ] {
            #expect(!EmulatorBridge.isValidAVDName(name), "\(name) should be rejected")
        }
    }

    @Test
    func malformedNamesAreFilteredFromTheList() {
        let output = "Good_AVD\n-no-window\nbad name\n"
        #expect(EmulatorBridge.parseAVDList(output) == ["Good_AVD"])
    }

    // MARK: - displayName

    @Test
    func displayNameRelaxesUnderscoresToSpaces() {
        #expect(EmulatorBridge.displayName(for: "Medium_Phone_API_35") == "Medium Phone API 35")
        #expect(EmulatorBridge.displayName(for: "Pixel7") == "Pixel7")
    }
}
