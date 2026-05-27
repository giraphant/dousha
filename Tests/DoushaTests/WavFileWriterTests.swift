import XCTest
import AVFoundation
@testable import DoubaoASR

final class WavFileWriterTests: XCTestCase {
    private var tmpURL: URL!

    override func setUp() {
        super.setUp()
        tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WavFileWriterTests-\(UUID().uuidString).wav")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpURL)
        super.tearDown()
    }

    func testWritesValidWav_int16Mono16kHz() throws {
        let writer = try WavFileWriter(url: tmpURL, sampleRate: 16_000, channels: 1)
        // 0.5 seconds of silence
        let samples = [Int16](repeating: 0, count: 8_000)
        try samples.withUnsafeBufferPointer { buf in
            try writer.append(int16Samples: buf.baseAddress!, count: buf.count)
        }
        try writer.close()

        // Reopen via AVAudioFile and check duration + format
        let f = try AVAudioFile(forReading: tmpURL)
        XCTAssertEqual(f.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(f.fileFormat.channelCount, 1)
        XCTAssertEqual(f.length, 8_000)
    }

    func testAppend_accumulatesAcrossMultipleCalls() throws {
        let writer = try WavFileWriter(url: tmpURL, sampleRate: 16_000, channels: 1)
        for _ in 0..<5 {
            let samples = [Int16](repeating: 100, count: 1_600) // 0.1s each
            try samples.withUnsafeBufferPointer { buf in
                try writer.append(int16Samples: buf.baseAddress!, count: buf.count)
            }
        }
        try writer.close()
        let f = try AVAudioFile(forReading: tmpURL)
        XCTAssertEqual(f.length, 8_000)
    }

    /// The writer dispatches each append onto its own serial background queue
    /// so the audio thread is never blocked. close() must barrier-wait until
    /// all queued writes have landed before returning — otherwise calling
    /// AVAudioFile(forReading:) right after close() can race and observe a
    /// short file.
    func testClose_barriersUntilAllPendingWritesLand() throws {
        let writer = try WavFileWriter(url: tmpURL, sampleRate: 16_000, channels: 1)
        // Fire 50 appends back-to-back (typical real audio cadence is ~80 of
        // these per second), then close immediately.
        for _ in 0..<50 {
            let samples = [Int16](repeating: 1, count: 320) // 20ms each
            try samples.withUnsafeBufferPointer { buf in
                try writer.append(int16Samples: buf.baseAddress!, count: buf.count)
            }
        }
        try writer.close()
        let f = try AVAudioFile(forReading: tmpURL)
        XCTAssertEqual(f.length, 50 * 320)
    }
}
