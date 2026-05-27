import Foundation
import AVFoundation

/// Streams mono int16 PCM samples to a WAV file on disk. Uses AVAudioFile under
/// the hood so we don't have to hand-write the RIFF header / fix up chunk sizes.
///
/// **Threading contract:** `append` is safe to call from any thread (including
/// AVAudioEngine's real-time mic tap callback) — it snapshots the samples and
/// dispatches the actual disk write onto an internal serial background queue
/// so the audio thread never blocks on I/O. `close()` is a barrier: it waits
/// for all enqueued writes to land before returning, so the caller can read
/// the file back immediately afterward (the retranscribe path relies on this).
///
/// On any background write failure, the writer flips into a stopped state and
/// silently swallows subsequent appends — failing per-frame writes would just
/// spam logs, and the caller can detect partial output by checking file size.
///
/// **Lifecycle:** callers MUST call `close()` before releasing the writer if
/// they need the file to be readable immediately afterward. Releasing the
/// writer without calling `close()` leaves the WAV header un-finalised until
/// the writer's deinit eventually fires (timing depends on whether pending
/// writes are still in flight on the background queue).
final class WavFileWriter {
    enum Error: Swift.Error {
        case formatBuildFailed
    }

    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private let queue: DispatchQueue
    private var stopped = false   // touched only on `queue`

    init(url: URL, sampleRate: Int, channels: Int) throws {
        precondition(channels == 1, "WavFileWriter currently only supports mono — the int16 copy path assumes a single channel.")
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else { throw Error.formatBuildFailed }
        self.format = fmt
        self.queue = DispatchQueue(label: "com.dousha.wavwriter.\(url.lastPathComponent)", qos: .utility)

        // settings dict tells AVAudioFile to write a WAV container (default
        // for .wav extension); pass the int16 format explicitly so it doesn't
        // promote to float32 on disk.
        self.file = try AVAudioFile(
            forWriting: url,
            settings: fmt.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
    }

    /// Append `count` int16 samples (mono — count == frame count for 1 channel).
    /// Returns immediately after snapshotting the bytes; the write happens on
    /// the writer's internal serial queue.
    ///
    /// Does not throw: write errors (PCM buffer alloc failure, AVAudioFile
    /// write failure) are logged via `NSLog` and transition the writer into a
    /// stopped state — subsequent appends are silently swallowed.
    func append(int16Samples ptr: UnsafePointer<Int16>, count: Int) {
        // Snapshot synchronously so the caller's buffer can be reused/freed.
        let snapshot = Array(UnsafeBufferPointer(start: ptr, count: count))
        let fmt = self.format
        queue.async { [weak self] in
            guard let self = self, !self.stopped else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(snapshot.count)) else {
                self.stopped = true
                NSLog("[WavFileWriter] PCM buffer alloc failed — stopping writes")
                return
            }
            buffer.frameLength = AVAudioFrameCount(snapshot.count)
            if let dst = buffer.int16ChannelData?[0] {
                snapshot.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: snapshot.count)
                }
            }
            guard let file = self.file else { return }
            do {
                try file.write(from: buffer)
            } catch {
                self.stopped = true
                NSLog("[WavFileWriter] write failed: \(error.localizedDescription) — stopping writes")
            }
        }
    }

    /// Barrier: waits for all queued writes to complete, then marks the writer
    /// stopped and releases the underlying `AVAudioFile`. AVAudioFile finalises
    /// the WAV header (patches the RIFF/data chunk sizes) on deinit, so we
    /// must drop our strong reference before returning — otherwise a caller
    /// that immediately reopens the file via `AVAudioFile(forReading:)` will
    /// see a zero-length data chunk.
    func close() throws {
        queue.sync {
            self.stopped = true
            self.file = nil
        }
    }
}
