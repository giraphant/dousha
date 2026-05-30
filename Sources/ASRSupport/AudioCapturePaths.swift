import Foundation

/// Canonical on-disk locations for captured audio. Shared so the single
/// `AudioTapHub` (which owns the only mic tap + WAV) and the engines that
/// consume that WAV (e.g. Soniox async upload, a future retranscribe redo)
/// agree on one path instead of each writing its own file.
public enum AudioCapturePaths {
    /// The one shared WAV that the `AudioTapHub` writes for a recording.
    /// 16 kHz mono int16 — the format every PCM engine consumes.
    public static var sharedWAV: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dousha", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last_recording.wav")
    }
}
