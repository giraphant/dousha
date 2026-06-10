// Windows microphone capture for the Dousha shell (QUA-209).
//
// winmm waveIn, not WASAPI: the engine wants 16kHz mono s16le and waveIn
// resamples from whatever the device runs at for free, with a C API that is
// callable from Swift without COM. WASAPI would buy lower latency we don't
// need — dictation tolerates the ~20-60ms waveIn adds.
//
// Threading: CALLBACK_EVENT + a dedicated reader thread. waveIn's
// CALLBACK_FUNCTION mode forbids calling back into waveIn* from the callback
// (deadlock per MSDN), so instead the driver just signals an event and the
// reader thread sweeps WHDR_DONE buffers, hands the bytes to `onChunk`, and
// re-queues. `onChunk` is called on the reader thread — DoubaoASR.ingest()
// is nonisolated and thread-safe, which is the only consumer.
#if os(Windows)
import WinSDK
import Foundation
import TalkerCommonSync

final class WaveInCapture: @unchecked Sendable {
    struct CaptureError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let onChunk: @Sendable (Data) -> Void

    private var handle: HWAVEIN?
    private var event: HANDLE?
    private var thread: Thread?

    // 8 × 20ms double-buffering. Headers and sample storage must stay at
    // stable addresses while the driver owns them — manual allocation, freed
    // in stop().
    private let bufferCount = 8
    private let bufferBytes = 640   // 20ms @ 16kHz mono s16le
    private var headers: UnsafeMutablePointer<WAVEHDR>?
    private var storage: [UnsafeMutablePointer<CHAR>] = []

    /// Set on the control thread in stop(); read by the reader thread.
    private let stopped = ManagedAtomicBool()

    init(onChunk: @escaping @Sendable (Data) -> Void) {
        self.onChunk = onChunk
    }

    func start() throws {
        var fmt = WAVEFORMATEX(
            wFormatTag: WORD(WAVE_FORMAT_PCM),
            nChannels: 1,
            nSamplesPerSec: 16_000,
            nAvgBytesPerSec: 32_000,
            nBlockAlign: 2,
            wBitsPerSample: 16,
            cbSize: 0
        )

        guard let ev = CreateEventW(nil, false, false, nil) else {
            throw CaptureError(message: "CreateEvent failed (\(GetLastError()))")
        }
        event = ev

        var h: HWAVEIN?
        let rc = waveInOpen(&h, UINT(bitPattern: -1) /* WAVE_MAPPER */, &fmt,
                            UINT_PTR(UInt(bitPattern: ev)), 0, DWORD(CALLBACK_EVENT))
        guard rc == MMSYSERR_NOERROR, let h else {
            throw CaptureError(message: "waveInOpen failed (mmsys \(rc)) — no microphone, or audio device unavailable in this session")
        }
        handle = h

        let hdrs = UnsafeMutablePointer<WAVEHDR>.allocate(capacity: bufferCount)
        hdrs.initialize(repeating: WAVEHDR(), count: bufferCount)
        headers = hdrs
        for i in 0..<bufferCount {
            let buf = UnsafeMutablePointer<CHAR>.allocate(capacity: bufferBytes)
            storage.append(buf)
            hdrs[i].lpData = buf
            hdrs[i].dwBufferLength = DWORD(bufferBytes)
            let prc = waveInPrepareHeader(h, hdrs + i, UINT(MemoryLayout<WAVEHDR>.size))
            guard prc == MMSYSERR_NOERROR else {
                throw CaptureError(message: "waveInPrepareHeader failed (mmsys \(prc))")
            }
            waveInAddBuffer(h, hdrs + i, UINT(MemoryLayout<WAVEHDR>.size))
        }

        stopped.value = false
        let t = Thread { [weak self] in self?.readerLoop() }
        t.name = "dousha.wavein"
        thread = t
        t.start()

        let src = waveInStart(h)
        guard src == MMSYSERR_NOERROR else {
            throw CaptureError(message: "waveInStart failed (mmsys \(src))")
        }
        doushaLog("[WaveInCapture] started 16kHz mono s16le, \(bufferCount)×\(bufferBytes)B buffers")
    }

    private func readerLoop() {
        guard let h = handle, let hdrs = headers, let ev = event else { return }
        while !stopped.value {
            WaitForSingleObject(ev, 100)
            sweepDone(h: h, hdrs: hdrs, requeue: true)
        }
    }

    private func sweepDone(h: HWAVEIN, hdrs: UnsafeMutablePointer<WAVEHDR>, requeue: Bool) {
        for i in 0..<bufferCount {
            guard hdrs[i].dwFlags & DWORD(WHDR_DONE) != 0 else { continue }
            let n = Int(hdrs[i].dwBytesRecorded)
            if n > 0, let p = hdrs[i].lpData {
                onChunk(Data(bytes: p, count: n))
            }
            hdrs[i].dwFlags &= ~DWORD(WHDR_DONE)
            hdrs[i].dwBytesRecorded = 0
            if requeue && !stopped.value {
                waveInAddBuffer(h, hdrs + i, UINT(MemoryLayout<WAVEHDR>.size))
            }
        }
    }

    /// Stops capture and drains the in-flight tail synchronously: waveInReset
    /// returns every queued buffer marked done, and the final sweep below
    /// pushes those last samples through `onChunk` BEFORE this returns — the
    /// Windows equivalent of the Mac hub's stop-then-drain ordering, so the
    /// spoken tail reaches the engine before `stop()` is called on it.
    func stop() {
        guard let h = handle else { return }
        stopped.value = true
        waveInStop(h)
        waveInReset(h)
        if let ev = event { SetEvent(ev) }
        // Reader thread exits its loop on `stopped`; give it a beat, then do
        // the authoritative final sweep ourselves (reader may have already
        // taken some — flags make the sweep idempotent).
        while let t = thread, !t.isFinished { Thread.sleep(forTimeInterval: 0.005) }
        if let hdrs = headers {
            sweepDone(h: h, hdrs: hdrs, requeue: false)
            for i in 0..<bufferCount {
                waveInUnprepareHeader(h, hdrs + i, UINT(MemoryLayout<WAVEHDR>.size))
            }
            hdrs.deallocate()
            headers = nil
        }
        for buf in storage { buf.deallocate() }
        storage = []
        waveInClose(h)
        handle = nil
        if let ev = event { CloseHandle(ev); event = nil }
        thread = nil
        doushaLog("[WaveInCapture] stopped + drained")
    }
}

/// Minimal atomic bool (no swift-atomics dependency): protects the
/// reader-loop exit flag, written by stop() on another thread.
final class ManagedAtomicBool: @unchecked Sendable {
    private var raw: Int32 = 0
    private let lock = NSLock()
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return raw != 0 }
        set { lock.lock(); raw = newValue ? 1 : 0; lock.unlock() }
    }
}
#endif
