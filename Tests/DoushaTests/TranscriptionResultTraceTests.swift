import XCTest
import DoubaoASR

final class TranscriptionResultTraceTests: XCTestCase {
    func test_traceIdDefaultsToNil() {
        let result = TranscriptionResult(
            text: "hello",
            audioDuration: 1.0,
            lastResponseAge: nil,
            lastTranscriptAge: nil,
            savedAudioURL: nil
        )

        XCTAssertNil(result.traceId)
    }

    func test_traceIdStoresRequestIdentifier() {
        let result = TranscriptionResult(
            text: "hello",
            audioDuration: 1.0,
            lastResponseAge: nil,
            lastTranscriptAge: nil,
            savedAudioURL: nil,
            traceId: "abc-123"
        )

        XCTAssertEqual(result.traceId, "abc-123")
    }
}
