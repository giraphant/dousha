import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

public enum AudioLevel {
    /// Returns a 0...1 RMS level suitable for driving a waveform UI.
    /// Boosts raw RMS (~0.02-0.15 for normal speech) so the bars react well.
    ///
    /// Platform-neutral core (QUA-209): operates on raw float samples so the
    /// Windows capture path can reuse it without AVFoundation.
    public static func computeRMS(samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let v = samples[i]
            sum += v * v
        }
        let rms = sqrt(sum / Float(count))
        let boosted = rms * 6.0
        return min(1.0, max(0.0, boosted))
    }

    #if canImport(AVFoundation)
    /// Convenience overload for the macOS AVAudioEngine tap path.
    public static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        return computeRMS(samples: channelData, count: Int(buffer.frameLength))
    }
    #endif
}
