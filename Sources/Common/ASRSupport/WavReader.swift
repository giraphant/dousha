import Foundation

/// Minimal RIFF/WAVE reader (QUA-209): rejects anything that isn't the
/// expected PCM shape rather than resampling — generate fixtures with
/// `afconvert`/`ffmpeg`. Pure Foundation so it runs on Windows (WavFileWriter
/// next door is the AVFoundation-backed, Darwin-only write side).
///
/// Consumers: the Doubao smoke harness (`smoke-cli transcribe`) and the
/// Windows shell's `--doctor --wav` mode, which feeds a WAV through the live
/// engine when no microphone is available.
public enum WavReader {
    struct WavError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Both ASR engines consume 16 kHz mono s16le, hence the defaults.
    public static func readPCM(
        path: String,
        sampleRate: Int = 16_000,
        channels: Int = 1
    ) throws -> Data {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count > 44,
              data.prefix(4) == Data("RIFF".utf8),
              data.subdata(in: 8..<12) == Data("WAVE".utf8) else {
            throw WavError(message: "not a RIFF/WAVE file: \(path)")
        }

        var offset = 12
        var fmtOK = false
        var pcm: Data?
        while offset + 8 <= data.count {
            let chunkId = data.subdata(in: offset..<offset + 4)
            let chunkSize = Int(readUInt32LE(data, at: offset + 4))
            let body = offset + 8
            guard body + chunkSize <= data.count else { break }

            if chunkId == Data("fmt ".utf8), chunkSize >= 16 {
                let format = readUInt16LE(data, at: body)
                let fileChannels = Int(readUInt16LE(data, at: body + 2))
                let fileRate = Int(readUInt32LE(data, at: body + 4))
                let bits = Int(readUInt16LE(data, at: body + 14))
                guard format == 1, fileChannels == channels,
                      fileRate == sampleRate, bits == 16 else {
                    throw WavError(message: "need \(sampleRate)Hz \(channels)ch 16-bit PCM, got format=\(format) ch=\(fileChannels) rate=\(fileRate) bits=\(bits). Convert: ffmpeg -i in.wav -ar \(sampleRate) -ac \(channels) -sample_fmt s16 out.wav")
                }
                fmtOK = true
            } else if chunkId == Data("data".utf8) {
                pcm = data.subdata(in: body..<body + chunkSize)
            }
            // Chunks are word-aligned.
            offset = body + chunkSize + (chunkSize % 2)
        }

        guard fmtOK else { throw WavError(message: "no fmt chunk found") }
        guard let pcm, !pcm.isEmpty else { throw WavError(message: "no data chunk found") }
        return pcm
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(readUInt16LE(data, at: offset)) | (UInt32(readUInt16LE(data, at: offset + 2)) << 16)
    }
}
