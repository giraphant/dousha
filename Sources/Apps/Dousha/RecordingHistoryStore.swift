import Foundation
import ConcurrencySupport

/// One saved recording in the re-transcribe history: `<id>.wav` + `<id>.json`
/// sidecar under the history dir. `id` is the timestamp stem, so filename
/// order == chronological order.
struct RecordingHistoryEntry: Identifiable, Equatable {
    let id: String
    let date: Date
    let duration: TimeInterval
    var transcript: String
    var engine: String
    /// Set when the original dictation failed — the prime re-transcribe case.
    var error: String?
}

extension Notification.Name {
    /// Posted (main thread) after any history mutation; the settings pane
    /// listens to refresh its list.
    static let doushaHistoryChanged = Notification.Name("DoushaHistoryChanged")
}

/// Disk store for the last-N recordings (re-transcribe feature). App layer.
/// All IO is small + synchronous; callers are the controller's environment
/// closures and the settings pane, both on the main actor.
final class RecordingHistoryStore {
    /// Sidecar JSON payload. Duration is NOT stored — derived from wav size,
    /// so an orphan wav (crash between copy and sidecar write) still shows one.
    private struct Sidecar: Codable {
        var date: Date
        var transcript: String
        var engine: String
        var error: String?
    }

    let dir: URL

    static let defaultDir: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Dousha/history", isDirectory: true)

    init(dir: URL = RecordingHistoryStore.defaultDir) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func wavURL(id: String) -> URL { dir.appendingPathComponent(id + ".wav") }
    private func jsonURL(id: String) -> URL { dir.appendingPathComponent(id + ".json") }

    /// Copy a finished recording into history, write its sidecar, prune.
    /// Called only once a final has arrived — the source WAV is complete then.
    @discardableResult
    func save(wavFrom source: URL, date: Date, engine: String,
              transcript: String, error: String?, limit: Int) -> String? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let id = fmt.string(from: date)
        do {
            try? FileManager.default.removeItem(at: wavURL(id: id))
            try FileManager.default.copyItem(at: source, to: wavURL(id: id))
        } catch {
            doushaLog("[History] save copy failed: \(error.localizedDescription)")
            return nil
        }
        writeSidecar(Sidecar(date: date, transcript: transcript, engine: engine, error: error), id: id)
        prune(limit: limit)
        doushaLog("[History] saved id=\(id) len=\(transcript.count) error=\(error ?? "nil")")
        notifyChanged()
        return id
    }

    /// A successful re-transcription refreshes the stored text (spec §4).
    func updateTranscript(id: String, transcript: String) {
        guard var sc = readSidecar(id: id) else { return }
        sc.transcript = transcript
        sc.error = nil
        writeSidecar(sc, id: id)
        notifyChanged()
    }

    /// Newest first. Lists from the wav files on disk, so entries self-heal:
    /// system-cleaned wav → not listed; orphan wav without sidecar → listed
    /// with empty text (still re-transcribable).
    func entries() -> [RecordingHistoryEntry] {
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".wav") }
            .map { String($0.dropLast(4)) }
            .sorted(by: >)   // timestamp stem: lexicographic == chronological
        return ids.map { id in
            let sc = readSidecar(id: id)
            return RecordingHistoryEntry(id: id,
                                         date: sc?.date ?? .distantPast,
                                         duration: duration(id: id),
                                         transcript: sc?.transcript ?? "",
                                         engine: sc?.engine ?? "",
                                         error: sc?.error)
        }
    }

    func newest() -> RecordingHistoryEntry? { entries().first }

    func remove(id: String) {
        try? FileManager.default.removeItem(at: wavURL(id: id))
        try? FileManager.default.removeItem(at: jsonURL(id: id))
        notifyChanged()
    }

    /// Delete the oldest entries beyond `limit` (wav+json pairs).
    func prune(limit: Int) {
        let ids = entries().map(\.id)
        guard ids.count > limit else { return }
        for id in ids.dropFirst(limit) {
            try? FileManager.default.removeItem(at: wavURL(id: id))
            try? FileManager.default.removeItem(at: jsonURL(id: id))
        }
        notifyChanged()
    }

    // MARK: - Private

    private func readSidecar(id: String) -> Sidecar? {
        guard let data = try? Data(contentsOf: jsonURL(id: id)) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
    }

    private func writeSidecar(_ sc: Sidecar, id: String) {
        if let data = try? JSONEncoder().encode(sc) {
            try? data.write(to: jsonURL(id: id))
        }
    }

    /// ponytail: assumes our own WavFileWriter's fixed 44-byte header
    /// (16 kHz mono s16 = 32000 B/s); a foreign wav just shows a wrong length.
    private func duration(id: String) -> TimeInterval {
        let attrs = try? FileManager.default.attributesOfItem(atPath: wavURL(id: id).path)
        let size = attrs?[.size] as? Int ?? 0
        return max(0, Double(size - 44)) / 32_000.0
    }

    private func notifyChanged() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .doushaHistoryChanged, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .doushaHistoryChanged, object: nil)
            }
        }
    }
}
