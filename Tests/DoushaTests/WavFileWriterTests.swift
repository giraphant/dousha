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
        samples.withUnsafeBufferPointer { buf in
            writer.append(int16Samples: buf.baseAddress!, count: buf.count)
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
            samples.withUnsafeBufferPointer { buf in
                writer.append(int16Samples: buf.baseAddress!, count: buf.count)
            }
        }
        try writer.close()
        let f = try AVAudioFile(forReading: tmpURL)
        XCTAssertEqual(f.length, 8_000)
    }

    /// The barrier in close() must hold even when appends and close happen on
    /// different threads. We fan out 50 appends onto a global concurrent queue
    /// and call close() from this thread without waiting — if the barrier is
    /// broken (e.g., queue.async in close instead of queue.sync), some writes
    /// will land after AVAudioFile(forReading:) opens the file, and the length
    /// will be less than 50 * 320.
    func testClose_barriersConcurrentlyEnqueuedAppends() throws {
        let writer = try WavFileWriter(url: tmpURL, sampleRate: 16_000, channels: 1)
        let group = DispatchGroup()
        let producer = DispatchQueue(label: "test.producer", attributes: .concurrent)
        for _ in 0..<50 {
            group.enter()
            producer.async {
                let samples = [Int16](repeating: 1, count: 320)
                samples.withUnsafeBufferPointer { buf in
                    writer.append(int16Samples: buf.baseAddress!, count: buf.count)
                }
                group.leave()
            }
        }
        // Wait for all appends to be ENQUEUED (not necessarily executed) before
        // calling close. The barrier inside close() must then drain whatever's
        // pending on the writer's serial queue.
        group.wait()
        try writer.close()
        let f = try AVAudioFile(forReading: tmpURL)
        XCTAssertEqual(f.length, 50 * 320)
    }

    /// The class-level doc promises that appends after close() are silently
    /// swallowed (the `stopped` flag short-circuits them on the serial queue).
    /// Verify they neither crash nor extend the file.
    func testAppend_afterClose_isSilentlySwallowed() throws {
        let writer = try WavFileWriter(url: tmpURL, sampleRate: 16_000, channels: 1)
        let firstBatch = [Int16](repeating: 1, count: 320)
        firstBatch.withUnsafeBufferPointer { buf in
            writer.append(int16Samples: buf.baseAddress!, count: buf.count)
        }
        try writer.close()

        // These should be silently ignored, not crash.
        let postClose = [Int16](repeating: 2, count: 320)
        postClose.withUnsafeBufferPointer { buf in
            writer.append(int16Samples: buf.baseAddress!, count: buf.count)
        }

        let f = try AVAudioFile(forReading: tmpURL)
        XCTAssertEqual(f.length, 320, "Post-close appends must not change file length")
    }
}
