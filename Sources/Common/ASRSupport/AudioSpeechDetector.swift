import Foundation
import ConcurrencySupport

/// Lightweight acoustic speech-activity detector for 16 kHz mono int16 PCM.
///
/// Prevents silent recordings, room noise, steady fan/AC hum, and brief
/// accidental key-click taps from reaching ASR finalization (where context-biased
/// models like Qwen3-ASR, Doubao, or Soniox can hallucinate glossary terms on
/// blank audio).
///
/// Signal pipeline:
///   1. 1st-order high-pass filter (~250 Hz @ 16 kHz) removes DC offset, 50/60 Hz
///      mains hum, AC rumble, desk vibrations, and breath pops while keeping
///      speech formants intact.
///   2. 20 ms frame RMS (320 samples per frame).
///   3. Adaptive threshold: `min(unconditionalSpeechRMS, max(absoluteFloorRMS,
///      noiseFloor * noiseFloorMultiplier))`, where `noiseFloor` is the 10th
///      percentile of frame RMS for recordings ≥ 300 ms (0 for shorter clips).
///      This rejects steady fan/AC noise without suppressing soft speech in a
///      quiet room or continuous speech that fills a whole clip.
///   4. Burst gate: requires at least `minDurationFrames` total frames (160 ms)
///      and at least `minConsecutiveActiveFrames` consecutive active frames
///      (80 ms), rejecting isolated 20–40 ms keyboard clicks and quick taps while
///      preserving short monosyllabic words ("是", "好", "OK").
public enum AudioSpeechDetector {
    public struct Analysis: Sendable, Equatable {
        public let hasSpeech: Bool
        public let durationSeconds: Double
        public let frameCount: Int
        public let maxFrameRMS: Float
        public let noiseFloorRMS: Float
        public let activeThresholdRMS: Float
        public let longestActiveRunFrames: Int

        public init(
            hasSpeech: Bool,
            durationSeconds: Double,
            frameCount: Int,
            maxFrameRMS: Float,
            noiseFloorRMS: Float,
            activeThresholdRMS: Float,
            longestActiveRunFrames: Int
        ) {
            self.hasSpeech = hasSpeech
            self.durationSeconds = durationSeconds
            self.frameCount = frameCount
            self.maxFrameRMS = maxFrameRMS
            self.noiseFloorRMS = noiseFloorRMS
            self.activeThresholdRMS = activeThresholdRMS
            self.longestActiveRunFrames = longestActiveRunFrames
        }
    }

    public static let sampleRate = 16_000
    /// 20 ms @ 16 kHz.
    public static let frameSamples = 320
    /// 160 ms minimum recording duration — filters accidental press-and-release taps.
    public static let minDurationFrames = 8
    /// 80 ms consecutive active speech energy — filters 20–40 ms keyboard clicks.
    public static let minConsecutiveActiveFrames = 4
    /// Minimum frame count (300 ms) before estimating a per-recording noise floor.
    public static let minFramesForNoiseFloor = 15
    /// High-passed RMS floor (~ -48 dBFS): above quiet-room mic floor, below soft speech.
    public static let absoluteFloorRMS: Float = 0.004
    /// High-passed RMS (~ -32 dBFS) above which sustained energy is always speech
    /// even if the entire clip is filled with continuous speech (no quiet margin).
    public static let unconditionalSpeechRMS: Float = 0.025
    /// Adaptive margin (+6.8 dB) above a recording's steady background noise floor.
    public static let noiseFloorMultiplier: Float = 2.2
    /// 1-pole high-pass coefficient for ~250 Hz cutoff at 16 kHz: 1 / (1 + 2π*250/16000).
    static let highPassAlpha: Float = 0.9106

    /// Analyze a full 16 kHz mono signed 16-bit little-endian PCM buffer.
    public static func analyze(pcm16LE data: Data) -> Analysis {
        let tracker = AudioSpeechTracker()
        tracker.append(pcm16LE: data)
        return tracker.analyze()
    }

    /// Convenience predicate for callers that only need the boolean decision.
    public static func hasSpeech(pcm16LE data: Data) -> Bool {
        analyze(pcm16LE: data).hasSpeech
    }

    /// Pure decision function over precomputed 20 ms high-passed frame RMS values.
    static func evaluate(frameRMS: [Float], totalSamples: Int) -> Analysis {
        let durationSeconds = Double(totalSamples) / Double(sampleRate)
        let frameCount = frameRMS.count
        guard frameCount > 0 else {
            return Analysis(
                hasSpeech: false,
                durationSeconds: durationSeconds,
                frameCount: 0,
                maxFrameRMS: 0,
                noiseFloorRMS: 0,
                activeThresholdRMS: absoluteFloorRMS,
                longestActiveRunFrames: 0
            )
        }

        var maxRMS: Float = 0
        for rms in frameRMS where rms > maxRMS { maxRMS = rms }

        let noiseFloor: Float
        if frameCount >= minFramesForNoiseFloor {
            let sorted = frameRMS.sorted()
            noiseFloor = sorted[frameCount / 10]
        } else {
            noiseFloor = 0
        }

        let threshold = min(unconditionalSpeechRMS, max(absoluteFloorRMS, noiseFloor * noiseFloorMultiplier))

        var longestRun = 0
        var currentRun = 0
        for rms in frameRMS {
            if rms >= threshold {
                currentRun += 1
                if currentRun > longestRun { longestRun = currentRun }
            } else {
                currentRun = 0
            }
        }

        let hasSpeech = frameCount >= minDurationFrames && longestRun >= minConsecutiveActiveFrames
        return Analysis(
            hasSpeech: hasSpeech,
            durationSeconds: durationSeconds,
            frameCount: frameCount,
            maxFrameRMS: maxRMS,
            noiseFloorRMS: noiseFloor,
            activeThresholdRMS: threshold,
            longestActiveRunFrames: longestRun
        )
    }
}

/// Incremental, thread-safe speech-activity tracker fed directly from the audio
/// tap thread. Pre-reserves ~20 s of frame RMS slots so typical dictations do
/// zero heap allocations on the real-time audio path.
public final class AudioSpeechTracker: Sendable {
    private struct State {
        var prevX: Float = 0
        var prevY: Float = 0
        var frameSumSquares: Float = 0
        var frameSampleCount: Int = 0
        var totalSamples: Int = 0
        var frameRMS: [Float]

        init(reservedFrames: Int) {
            var buffer: [Float] = []
            buffer.reserveCapacity(reservedFrames)
            self.frameRMS = buffer
        }
    }

    private let state: Lock<State>

    /// - Parameter reservedFrames: Pre-allocated 20 ms frame slots (default 1024 ≈ 20.5 s).
    public init(reservedFrames: Int = 1024) {
        self.state = Lock(State(reservedFrames: reservedFrames))
    }

    /// Feed 16 kHz mono int16 samples directly from `AVAudioPCMBuffer.int16ChannelData`.
    public func append(int16Samples samples: UnsafePointer<Int16>, count: Int) {
        guard count > 0 else { return }
        let alpha = AudioSpeechDetector.highPassAlpha
        let frameSamples = AudioSpeechDetector.frameSamples
        let invScale: Float = 1.0 / 32_768.0
        let invFrameCount: Float = 1.0 / Float(frameSamples)

        state.withLock { s in
            s.totalSamples += count
            for i in 0..<count {
                let x = Float(samples[i]) * invScale
                let y = alpha * (s.prevY + x - s.prevX)
                s.prevX = x
                s.prevY = y
                s.frameSumSquares += y * y
                s.frameSampleCount += 1
                if s.frameSampleCount == frameSamples {
                    s.frameRMS.append(sqrt(s.frameSumSquares * invFrameCount))
                    s.frameSumSquares = 0
                    s.frameSampleCount = 0
                }
            }
        }
    }

    /// Feed raw 16 kHz mono signed 16-bit little-endian PCM bytes.
    public func append(pcm16LE data: Data) {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return }
        let alpha = AudioSpeechDetector.highPassAlpha
        let frameSamples = AudioSpeechDetector.frameSamples
        let invScale: Float = 1.0 / 32_768.0
        let invFrameCount: Float = 1.0 / Float(frameSamples)

        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            state.withLock { s in
                s.totalSamples += sampleCount
                for idx in 0..<sampleCount {
                    let offset = idx * 2
                    let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                    let x = Float(Int16(bitPattern: bits)) * invScale
                    let y = alpha * (s.prevY + x - s.prevX)
                    s.prevX = x
                    s.prevY = y
                    s.frameSumSquares += y * y
                    s.frameSampleCount += 1
                    if s.frameSampleCount == frameSamples {
                        s.frameRMS.append(sqrt(s.frameSumSquares * invFrameCount))
                        s.frameSumSquares = 0
                        s.frameSampleCount = 0
                    }
                }
            }
        }
    }

    /// Snapshot and evaluate all accumulated audio.
    public func analyze() -> AudioSpeechDetector.Analysis {
        let (frames, totalSamples) = state.withLock { ($0.frameRMS, $0.totalSamples) }
        return AudioSpeechDetector.evaluate(frameRMS: frames, totalSamples: totalSamples)
    }
}
