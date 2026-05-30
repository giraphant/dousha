import Foundation
import AVFoundation
import TalkerCommonSync

/// Streams mono int16 PCM samples to a WAV file on disk. Uses AVAudioFile under
/// the hood so we don't have to hand-write the RIFF header / fix up chunk sizes.
///
/// **Threading contract:** `append` is safe to call from any thread (including
/// AVAudioEngine's real-time mic tap callback) — it snapshots the samples and
/// dispatches the actual disk write onto an internal serial background queue
/// so the audio thread never blocks on I/O. `close()` is a barrier: it waits
/// for all enqueued writes to land before returning, so the caller can read
/// the file back immediately afterward (the Soniox async upload relies on this).
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
public final class WavFileWriter {
    public enum Error: Swift.Error {
        case formatBuildFailed
    }

    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private let queue: DispatchQueue
    private var stopped = false   // touched only on `queue`
    private let url: URL

    public init(url: URL, sampleRate: Int, channels: Int) throws {
        precondition(channels == 1, "WavFileWriter currently only supports mono — the int16 copy path assumes a single channel.")
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else { throw Error.formatBuildFailed }
        self.format = fmt
        self.url = url
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
    public func append(int16Samples ptr: UnsafePointer<Int16>, count: Int) {
        // Snapshot synchronously so the caller's buffer can be reused/freed.
        let snapshot = Array(UnsafeBufferPointer(start: ptr, count: count))
        let fmt = self.format
        queue.async { [weak self] in
            guard let self = self, !self.stopped else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(snapshot.count)) else {
                self.stopped = true
                doushaLog("[WavFileWriter] PCM buffer alloc failed — stopping writes")
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
                doushaLog("[WavFileWriter] write failed: \(error.localizedDescription) — stopping writes")
            }
        }
    }

    /// Barrier: waits for all queued writes to complete, then marks the writer
    /// stopped and releases the underlying `AVAudioFile`. After nil-ing the
    /// AVAudioFile reference we also manually patch the WAV header via
    /// FileHandle because AVAudioFile's deinit (which normally fixes up the
    /// RIFF/data chunk sizes) does not always fire synchronously — empirically
    /// the data chunk size can be left at 0 even though the PCM bytes are
    /// physically on disk, causing AVAudioFile(forReading:) to return an empty
    /// buffer and silently breaking the Soniox async upload.
    public func close() throws {
        queue.sync {
            self.stopped = true
            self.file = nil
        }
        patchWavHeaderSizes(at: url)
    }

    /// Manually walks the WAV chunk list and rewrites both the RIFF size field
    /// and the data chunk size field to match the actual file length.
    ///
    /// This is necessary because AVAudioFile may insert JUNK/FLLR alignment
    /// padding chunks before the data chunk, so the data chunk's position is
    /// NOT fixed — it can appear at offset 36, 4088, or wherever AVFoundation
    /// decides. We therefore scan from offset 12 (past the RIFF header) until
    /// we find the chunk with id "data", then overwrite its size field.
    private func patchWavHeaderSizes(at url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else {
            doushaLog("[WavFileWriter] header patch: couldn't open file for update")
            return
        }
        defer { try? handle.close() }

        do {
            let fileSize = try handle.seekToEnd()
            guard fileSize >= 44 else { return }   // way too small to be a valid WAV

            // Patch RIFF size (defensive; AVFoundation usually gets this right)
            let riffSize = UInt32(fileSize - 8).littleEndian
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: withUnsafeBytes(of: riffSize) { Data($0) })

            // Scan chunks from offset 12 looking for 'data'
            var pos: UInt64 = 12
            while pos + 8 <= fileSize {
                try handle.seek(toOffset: pos)
                let header = try handle.read(upToCount: 8) ?? Data()
                guard header.count == 8 else { break }
                let chunkId = header[0..<4]
                let chunkSize = header.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }

                if chunkId.elementsEqual("data".utf8) {
                    let dataPayloadSize = UInt32(fileSize - pos - 8).littleEndian
                    try handle.seek(toOffset: pos + 4)
                    try handle.write(contentsOf: withUnsafeBytes(of: dataPayloadSize) { Data($0) })
                    return
                }
                // Advance past this chunk's payload. Chunk sizes are padded to 2-byte alignment.
                let advance = UInt64(chunkSize) + (UInt64(chunkSize) & 1)
                pos += 8 + advance
            }
            doushaLog("[WavFileWriter] header patch: no 'data' chunk found in \(fileSize)-byte file")
        } catch {
            doushaLog("[WavFileWriter] header patch failed: \(error.localizedDescription)")
        }
    }
}
