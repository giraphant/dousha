import Foundation

/// Mirrors `asr.proto`. Field tags:
///   AsrRequest:  token=2 service_name=3 method_name=5 payload=6 audio_data=7 request_id=8 frame_state=9
///   AsrResponse: request_id=1 task_id=2 service_name=3 message_type=4 status_code=5 status_message=6 result_json=7
@_spi(SmokeCLI) public enum FrameState: Int32, Sendable {
    case unspecified = 0
    case first = 1
    case middle = 3
    case last = 9
}

struct AsrRequest {
    var token: String = ""
    var serviceName: String = "ASR"
    var methodName: String = ""
    var payload: String = ""
    var audioData: Data = Data()
    var requestId: String = ""
    var frameState: FrameState = .unspecified

    func encode() -> Data {
        var buf = Data()
        Wire.writeString(field: 2, token, into: &buf)
        Wire.writeString(field: 3, serviceName, into: &buf)
        Wire.writeString(field: 5, methodName, into: &buf)
        Wire.writeString(field: 6, payload, into: &buf)
        Wire.writeBytes(field: 7, audioData, into: &buf)
        Wire.writeString(field: 8, requestId, into: &buf)
        Wire.writeInt32(field: 9, frameState.rawValue, into: &buf)
        return buf
    }
}

@_spi(SmokeCLI) public struct AsrResponse: Sendable {
    public var requestId: String = ""
    public var messageType: String = ""
    public var statusCode: Int32 = 0
    public var statusMessage: String = ""
    public var resultJson: String = ""

    public static func decode(_ data: Data) throws -> AsrResponse {
        let fields = try Wire.decodeFields(data)
        var r = AsrResponse()
        if case let .length(d) = fields[1] ?? .varint(0) { r.requestId     = String(data: d, encoding: .utf8) ?? "" }
        if case let .length(d) = fields[4] ?? .varint(0) { r.messageType   = String(data: d, encoding: .utf8) ?? "" }
        if case let .varint(v) = fields[5] ?? .length(Data()) { r.statusCode = Int32(truncatingIfNeeded: v) }
        if case let .length(d) = fields[6] ?? .varint(0) { r.statusMessage = String(data: d, encoding: .utf8) ?? "" }
        if case let .length(d) = fields[7] ?? .varint(0) { r.resultJson    = String(data: d, encoding: .utf8) ?? "" }
        return r
    }
}

@_spi(SmokeCLI) public enum AsrMessageBuilder {
    public static func startTask(requestId: String, token: String) -> Data {
        var r = AsrRequest()
        r.token = token
        r.serviceName = "ASR"
        r.methodName = "StartTask"
        r.requestId = requestId
        return r.encode()
    }

    public static func startSession(requestId: String, token: String, configJSON: String) -> Data {
        var r = AsrRequest()
        r.token = token
        r.serviceName = "ASR"
        r.methodName = "StartSession"
        r.requestId = requestId
        r.payload = configJSON
        return r.encode()
    }

    public static func finishSession(requestId: String, token: String) -> Data {
        var r = AsrRequest()
        r.token = token
        r.serviceName = "ASR"
        r.methodName = "FinishSession"
        r.requestId = requestId
        return r.encode()
    }

    public static func taskRequest(audio: Data, requestId: String, frameState: FrameState, timestampMs: Int64) -> Data {
        // The official Android client signals end-of-audio via `finish_audio: true`
        // in the per-block extra JSON in addition to the protobuf frame_state.
        // Without this hint, the server's VAD has been observed to leave the
        // tail utterance unfinalized on long recordings.
        let extraJSON = frameState == .last ? "{\"finish_audio\":true}" : "{}"
        var r = AsrRequest()
        r.serviceName = "ASR"
        r.methodName = "TaskRequest"
        r.payload = "{\"extra\":\(extraJSON),\"timestamp_ms\":\(timestampMs)}"
        r.audioData = audio
        r.requestId = requestId
        r.frameState = frameState
        return r.encode()
    }
}
