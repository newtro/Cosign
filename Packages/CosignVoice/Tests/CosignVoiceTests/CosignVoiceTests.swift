import XCTest
@testable import CosignVoice
import CosignCore

final class CosignVoiceTests: XCTestCase {
    func testExpressiveTagParsingAndStripping() {
        let input = "[chuckle] Hold on Marcus, that won't survive contact with reality. [sigh] Ask me how I know."
        let segments = ExpressiveTagFormatter.parseSegments(input)
        XCTAssertEqual(segments, [
            .cue("chuckles"),
            .words(" Hold on Marcus, that won't survive contact with reality. "),
            .cue("sighs"),
            .words(" Ask me how I know.")
        ])

        let stripped = ExpressiveTagFormatter.stripTags(input)
        XCTAssertEqual(stripped, "Hold on Marcus, that won't survive contact with reality. Ask me how I know.")
    }

    @MainActor
    func testBundledVoiceSeedsResolveForEveryDefaultPersona() {
        let engine = VoiceEngine(cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for persona in DefaultRoster.personas {
            let path = engine.resolveReferenceAudioPath(for: persona)
            XCTAssertNotNil(path, "Expected bundled voice seed for \(persona.name)")
            if let path {
                XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Seed file missing at \(path)")
            }
        }
    }
}
