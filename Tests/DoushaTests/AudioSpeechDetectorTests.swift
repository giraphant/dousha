import XCTest
import Foundation
@testable import ASRSupport

final class AudioSpeechDetectorTests: XCTestCase {

    // MARK: - Synthetic PCM helpers (16 kHz mono s16le)

    private func makeSamples(durationSeconds: Double, generator: (Int) -> Float) -> [Int16] {
        let count = Int(durationSeconds * Double(AudioSpeechDetector.sampleRate))
        return (0..<count).map { i in
            let clamped = max(-1.0, min(1.0, generator(i)))
            return Int16(clamped * 32_767.0)
        }
    }

    private func pcmData(from samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var le = sample.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func sine(at index: Int, frequency: Double, amplitude: Float) -> Float {
        let t = Double(index) / Double(AudioSpeechDetector.sampleRate)
        return amplitude * Float(sin(2.0 * .pi * frequency * t))
    }

    /// Deterministic pseudo-random stationary noise with target RMS.
    private func deterministicNoise(count: Int, rms: Float, seed: UInt64 = 0x1234_5678) -> [Float] {
        var state = seed
        let scale = rms * sqrt(3.0)
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(Int32(bitPattern: UInt32(truncatingIfNeeded: state >> 32))) / Float(Int32.max)
            return unit * scale
        }
    }

    // MARK: - Rejection cases (must NOT detect speech)

    func testEmptyAndDigitalSilence_hasNoSpeech() {
        XCTAssertFalse(AudioSpeechDetector.hasSpeech(pcm16LE: Data()))
        let silence = Data(repeating: 0, count: 16_000 * 2 * 2) // 2 seconds of zeros
        let analysis = AudioSpeechDetector.analyze(pcm16LE: silence)
        XCTAssertFalse(analysis.hasSpeech)
        XCTAssertEqual(analysis.maxFrameRMS, 0)
        XCTAssertEqual(analysis.longestActiveRunFrames, 0)
    }

    func testQuietRoomNoiseFloor_hasNoSpeech() {
        let noise = deterministicNoise(count: 16_000 * 2, rms: 0.002)
        let samples = noise.map { Int16(max(-1, min(1, $0)) * 32_767) }
        let analysis = AudioSpeechDetector.analyze(pcm16LE: pcmData(from: samples))
        XCTAssertFalse(analysis.hasSpeech)
        XCTAssertLessThan(analysis.maxFrameRMS, AudioSpeechDetector.absoluteFloorRMS)
    }

    func testDCOffsetAndMainsHum_rejectedByHighPassFilter() {
        let samples = makeSamples(durationSeconds: 1.5) { i in
            0.05 + sine(at: i, frequency: 50, amplitude: 0.02)
        }
        let analysis = AudioSpeechDetector.analyze(pcm16LE: pcmData(from: samples))
        XCTAssertFalse(analysis.hasSpeech, "DC offset and 50 Hz mains hum must be filtered out")
    }

    func testHighFrequencyHissAndRustle_attenuatedByLowPassFilter() {
        // 6.5 kHz hiss/rustle — outside the 250-3400 Hz speech band.
        let samples = makeSamples(durationSeconds: 2.0) { i in
            sine(at: i, frequency: 6_500, amplitude: 0.015)
        }
        let analysis = AudioSpeechDetector.analyze(pcm16LE: pcmData(from: samples))
        XCTAssertFalse(analysis.hasSpeech, "High-frequency hiss/rustle should be attenuated below speech floor")
    }

    func testTenSecondsFluctuatingAmbientRoomNoise_hasNoSpeech() {
        // Simulates 10s of real room ambient sound: base noise ~0.005 with
        // periodic 200ms ambient swells up to ~0.010 (AC cycling, distant street).
        let total = 16_000 * 10
        let base = deterministicNoise(count: total, rms: 0.006, seed: 0xDEAD_BEEF)
        let samples: [Int16] = (0..<total).map { i in
            let second = i / 16_000
            let offsetInSecond = i % 16_000
            // 200ms mild ambient swell every 3 seconds
            let swell: Float = (second % 3 == 1 && offsetInSecond < 3_200) ? 1.8 : 1.0
            let v = base[i] * swell
            return Int16(max(-1, min(1, v)) * 32_767)
        }
        let analysis = AudioSpeechDetector.analyze(pcm16LE: pcmData(from: samples))
        XCTAssertFalse(analysis.hasSpeech, "10s fluctuating ambient room noise must not trigger speech")
    }

    func testTenSecondsSteadyFanNoiseWithMildBursts_rejectedByAdaptiveFloor() {
        // 10s of steady laptop fan (~0.012 raw broadband → ~0.0085 band-passed)
        // plus mild 150ms ambient ripples (~2× floor).
        let total = 16_000 * 10
        let base = deterministicNoise(count: total, rms: 0.012, seed: 0xCAFE_BABE)
        let samples: [Int16] = (0..<total).map { i in
            let inRipple = i >= 80_000 && i < 82_400 // 150ms
            let v = base[i] * (inRipple ? 1.9 : 1.0)
            return Int16(max(-1, min(1, v)) * 32_767)
        }
        let analysis = AudioSpeechDetector.analyze(pcm16LE: pcmData(from: samples))
        XCTAssertFalse(analysis.hasSpeech, "Steady fan noise with mild ripples must stay below 3x adaptive floor")
    }

    func testIsolatedKeyPressAndReleaseClicks_rejectedByBurstGate() {
        // 1.0s recording with a loud 50ms press click and 50ms release click.
        let samples = makeSamples(durationSeconds: 1.0) { i in
            let inPressClick = i >= 800 && i < 1_600       // 50 ms (2-3 frames)
            let inReleaseClick = i >= 13_600 && i < 14_400 // 50 ms (2-3 frames)
            if inPressClick || inReleaseClick {
                return sine(at: i, frequency: 1_500, amplitude: 0.25)
            }
            return 0
        }
        let analysis = AudioSpeechDetector.analyze(pcm16LE: pcmData(from: samples))
        XCTAssertFalse(analysis.hasSpeech, "Isolated 50 ms key clicks must not pass the 100 ms burst gate")
        XCTAssertLessThan(analysis.longestActiveRunFrames, AudioSpeechDetector.minConsecutiveActiveFrames)
    }

    func testAccidentalQuickTapUnderMinimumDuration_rejectedEvenWhenLoud() {
        let samples = makeSamples(durationSeconds: 0.12) { i in
            sine(at: i, frequency: 800, amplitude: 0.2)
        }
        let analysis = AudioSpeechDetector.analyze(pcm16LE: pcmData(from: samples))
        XCTAssertFalse(analysis.hasSpeech)
        XCTAssertLessThan(analysis.frameCount, AudioSpeechDetector.minDurationFrames)
    }

    // MARK: - Acceptance cases (must detect real speech)

    func testShortSingleSyllableWord_detectedAsSpeech() {
        // 0.6s clip containing a 160 ms voiced syllable at 500 Hz (~0.025 band-passed RMS).
        let samples = makeSamples(durationSeconds: 0.6) { i in
            if i >= 3_200 && i < 5_760 { // 200ms..360ms (160ms)
                return sine(at: i, frequency: 500, amplitude: 0.04)
            }
            return 0
        }
        let analysis = AudioSpeechDetector.analyze(pcm16LE: pcmData(from: samples))
        XCTAssertTrue(analysis.hasSpeech)
        XCTAssertGreaterThanOrEqual(analysis.longestActiveRunFrames, AudioSpeechDetector.minConsecutiveActiveFrames)
    }

    func testSoftConversationalSpeechInQuietRoom_detectedAsSpeech() {
        // 1.0s clip with quiet room floor + 220 ms soft speech (~0.013 band-passed RMS).
        let room = deterministicNoise(count: 16_000, rms: 0.0015)
        let samples: [Int16] = (0..<16_000).map { i in
            var v = room[i]
            if i >= 4_800 && i < 8_320 { // 220 ms
                v += sine(at: i, frequency: 700, amplitude: 0.022)
            }
            return Int16(max(-1, min(1, v)) * 32_767)
        }
        let analysis = AudioSpeechDetector.analyze(pcm16LE: pcmData(from: samples))
        XCTAssertTrue(analysis.hasSpeech, "Soft speech in a quiet room must still be detected")
    }

    func testContinuousSpeechFillingEntireClip_detectedDespiteNoQuietMargin() {
        // 1.0s clip filled 100% with speech (~0.045 band-passed RMS) — capped by unconditionalSpeechRMS.
        let samples = makeSamples(durationSeconds: 1.0) { i in
            sine(at: i, frequency: 600, amplitude: 0.075)
        }
        let analysis = AudioSpeechDetector.analyze(pcm16LE: pcmData(from: samples))
        XCTAssertTrue(analysis.hasSpeech)
        XCTAssertEqual(analysis.activeThresholdRMS, AudioSpeechDetector.unconditionalSpeechRMS)
    }

    func testNormalSpeechOverTenSecondsOfSteadyFanNoise_detectedAsSpeech() {
        // 10.0s clip with steady fan noise + 300 ms normal speech (~0.06 RMS).
        let total = 16_000 * 10
        let fan = deterministicNoise(count: total, rms: 0.010)
        let samples: [Int16] = (0..<total).map { i in
            var v = fan[i]
            if i >= 80_000 && i < 84_800 { // 300 ms at t=5s
                v += sine(at: i, frequency: 650, amplitude: 0.10)
            }
            return Int16(max(-1, min(1, v)) * 32_767)
        }
        let analysis = AudioSpeechDetector.analyze(pcm16LE: pcmData(from: samples))
        XCTAssertTrue(analysis.hasSpeech)
    }

    func testIncrementalTrackerMatchesBatchAnalysisAcrossArbitraryChunks() {
        let samples = makeSamples(durationSeconds: 0.8) { i in
            if i >= 3_200 && i < 6_400 {
                return sine(at: i, frequency: 550, amplitude: 0.06)
            }
            return sine(at: i, frequency: 400, amplitude: 0.001)
        }
        let batch = AudioSpeechDetector.analyze(pcm16LE: pcmData(from: samples))

        let tracker = AudioSpeechTracker()
        let chunkSizes = [17, 319, 320, 513, 1024]
        var offset = 0
        var chunkIdx = 0
        samples.withUnsafeBufferPointer { buf in
            while offset < samples.count {
                let n = min(chunkSizes[chunkIdx % chunkSizes.count], samples.count - offset)
                tracker.append(int16Samples: buf.baseAddress!.advanced(by: offset), count: n)
                offset += n
                chunkIdx += 1
            }
        }
        let incremental = tracker.analyze()

        XCTAssertEqual(incremental, batch)
        XCTAssertTrue(incremental.hasSpeech)
    }
}
