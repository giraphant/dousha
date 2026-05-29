import Foundation
import AVFoundation

public enum AudioLevel {
    /// Returns a 0...1 RMS level suitable for driving a waveform UI.
    /// Boosts raw RMS (~0.02-0.15 for normal speech) so the bars react well.
    public static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frameLength {
            let v = channelData[i]
            sum += v * v
        }
        let rms = sqrt(sum / Float(frameLength))
        let boosted = rms * 6.0
        return min(1.0, max(0.0, boosted))
    }
}
