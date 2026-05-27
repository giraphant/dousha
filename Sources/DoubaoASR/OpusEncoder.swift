import Foundation
import AVFoundation
import AudioToolbox

/// Encodes 16kHz Int16 mono PCM frames (320 samples / 640 bytes per 20ms frame) into Opus packets
/// using AVAudioConverter + AudioToolbox's native Opus codec. No third-party dependencies.
final class OpusEncoder {
    enum OpusError: Error, LocalizedError {
        case formatBuildFailed
        case converterInitFailed
        case noOutputBuffer
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .formatBuildFailed:        return "Failed to build Opus AVAudioFormat"
            case .converterInitFailed:      return "AVAudioConverter does not support Opus encoding on this machine"
            case .noOutputBuffer:           return "Could not allocate Opus output buffer"
            case .conversionFailed(let s):  return "Opus conversion failed: \(s)"
            }
        }
    }

    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let framesPerPacket: AVAudioFrameCount

    init(sampleRate: Int = DoubaoConstants.sampleRate,
         channels: Int = DoubaoConstants.channels,
         frameDurationMs: Int = DoubaoConstants.frameDurationMs) throws {

        let frames = AVAudioFrameCount(sampleRate * frameDurationMs / 1000)
        self.framesPerPacket = frames

        guard let inFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw OpusError.formatBuildFailed
        }
        self.inputFormat = inFmt

        var outASBD = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(frames),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let outFmt = AVAudioFormat(streamDescription: &outASBD) else {
            throw OpusError.formatBuildFailed
        }
        self.outputFormat = outFmt

        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw OpusError.converterInitFailed
        }
        self.converter = conv
    }

    /// Encodes one 20ms PCM Int16 frame (`bytesPerFrame` bytes) into an Opus packet.
    func encode(_ pcmFrame: Data) throws -> Data {
        precondition(pcmFrame.count == DoubaoConstants.bytesPerFrame,
                     "OpusEncoder expected \(DoubaoConstants.bytesPerFrame) bytes, got \(pcmFrame.count)")

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: framesPerPacket) else {
            throw OpusError.noOutputBuffer
        }
        inBuf.frameLength = framesPerPacket
        pcmFrame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            if let dst = inBuf.int16ChannelData?[0] {
                let src = raw.bindMemory(to: Int16.self)
                for i in 0..<Int(framesPerPacket) { dst[i] = src[i] }
            }
        }

        let outBuf = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 1, maximumPacketSize: 1500)
        var fed = false
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }

        if let err = convError {
            throw OpusError.conversionFailed(err.localizedDescription)
        }
        guard status == .haveData, outBuf.byteLength > 0 else {
            throw OpusError.conversionFailed("status=\(status.rawValue) bytes=\(outBuf.byteLength)")
        }

        let bytes = Int(outBuf.byteLength)
        let ptr = outBuf.data.assumingMemoryBound(to: UInt8.self)
        return Data(bytes: ptr, count: bytes)
    }
}
