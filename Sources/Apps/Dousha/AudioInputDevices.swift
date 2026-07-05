import Foundation
@preconcurrency import AVFoundation
@preconcurrency import AudioToolbox
@preconcurrency import CoreAudio
import ConcurrencySupport

/// A CoreAudio input device that can provide microphone samples.
struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannelCount: Int
    let transportType: UInt32
    let isDefaultInput: Bool

    var transportDescription: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "内建"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth: return "蓝牙"
        case kAudioDeviceTransportTypeBluetoothLE: return "蓝牙 LE"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeVirtual: return "虚拟"
        case kAudioDeviceTransportTypeAggregate: return "聚合"
        default: return "其他"
        }
    }

    var isProbablyVirtual: Bool {
        if transportType == kAudioDeviceTransportTypeVirtual ||
            transportType == kAudioDeviceTransportTypeAggregate {
            return true
        }
        let haystack = "\(name) \(uid)".lowercased()
        return haystack.contains("nomachine") ||
            haystack.contains("blackhole") ||
            haystack.contains("loopback") ||
            haystack.contains("soundflower") ||
            haystack.contains("aggregate") ||
            haystack.contains("virtual") ||
            haystack.contains("audio adapter")
    }
}

/// Per-recording microphone route snapshot. Settings can change between
/// recordings, but an active `AudioTapHub` keeps one immutable copy.
struct MicrophoneSelectionPreference: Equatable, Sendable {
    var useSystemDefault: Bool
    var priorityUIDs: [String]

    static let systemDefault = MicrophoneSelectionPreference(useSystemDefault: true,
                                                             priorityUIDs: [])
}

struct AudioInputDeviceSelection: Sendable {
    let device: AudioInputDevice?
    let shouldApplyToAudioUnit: Bool
    let reason: String

    var logDescription: String {
        guard let device else { return "reason=\(reason) device=none" }
        return "reason=\(reason) name=\"\(device.name)\" uid=\(device.uid) id=\(device.id) channels=\(device.inputChannelCount) transport=\(device.transportDescription) default=\(device.isDefaultInput) explicit=\(shouldApplyToAudioUnit)"
    }
}

enum AudioInputDevices {
    static func currentInputDevices() -> [AudioInputDevice] {
        do {
            let defaultID = try? defaultInputDeviceID()
            return try deviceIDs().compactMap { id in
                let channelCount = inputChannelCount(for: id)
                guard channelCount > 0 else { return nil }
                let uid = (try? stringProperty(kAudioDevicePropertyDeviceUID, objectID: id)) ?? "coreaudio:\(id)"
                let name = (try? stringProperty(kAudioObjectPropertyName, objectID: id)) ?? "Audio Device \(id)"
                let transport = (try? uint32Property(kAudioDevicePropertyTransportType, objectID: id)) ?? kAudioDeviceTransportTypeUnknown
                return AudioInputDevice(id: id,
                                        uid: uid,
                                        name: name,
                                        inputChannelCount: channelCount,
                                        transportType: transport,
                                        isDefaultInput: defaultID == id)
            }.sorted(by: recommendedSort)
        } catch {
            doushaLog("[AudioInputDevices] list failed: \(error.localizedDescription)")
            return []
        }
    }

    static func orderedInputDevices(_ devices: [AudioInputDevice], priorityUIDs: [String]) -> [AudioInputDevice] {
        var remaining = Dictionary(uniqueKeysWithValues: devices.map { ($0.uid, $0) })
        var ordered: [AudioInputDevice] = []
        for uid in priorityUIDs {
            if let device = remaining.removeValue(forKey: uid) {
                ordered.append(device)
            }
        }
        ordered.append(contentsOf: remaining.values.sorted(by: recommendedSort))
        return ordered
    }

    static func resolve(_ preference: MicrophoneSelectionPreference) -> AudioInputDeviceSelection {
        let devices = currentInputDevices()
        if preference.useSystemDefault {
            let device = devices.first { $0.isDefaultInput }
            return AudioInputDeviceSelection(device: device,
                                             shouldApplyToAudioUnit: false,
                                             reason: device == nil ? "systemDefaultMissing" : "systemDefault")
        }

        let ordered = orderedInputDevices(devices, priorityUIDs: preference.priorityUIDs)
        guard let device = ordered.first else {
            return AudioInputDeviceSelection(device: nil,
                                             shouldApplyToAudioUnit: false,
                                             reason: "noInputDevices")
        }
        let reason = preference.priorityUIDs.contains(device.uid) ? "priorityList" : "recommendedFallback"
        return AudioInputDeviceSelection(device: device,
                                         shouldApplyToAudioUnit: true,
                                         reason: reason)
    }

    static func apply(_ selection: AudioInputDeviceSelection, to inputNode: AVAudioInputNode) throws {
        guard selection.shouldApplyToAudioUnit, let device = selection.device else { return }
        guard let audioUnit = inputNode.audioUnit else {
            throw CoreAudioCallError(operation: "get input audio unit", status: -1)
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(audioUnit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw CoreAudioCallError(operation: "set input current device", status: status)
        }
    }

    private static func recommendedSort(_ lhs: AudioInputDevice, _ rhs: AudioInputDevice) -> Bool {
        let leftRank = recommendedRank(lhs)
        let rightRank = recommendedRank(rhs)
        if leftRank != rightRank { return leftRank < rightRank }
        if lhs.isDefaultInput != rhs.isDefaultInput { return lhs.isDefaultInput }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func recommendedRank(_ device: AudioInputDevice) -> Int {
        if device.transportType == kAudioDeviceTransportTypeBuiltIn { return 0 }
        if !device.isProbablyVirtual { return 1 }
        if device.isDefaultInput { return 2 }
        return 3
    }

    private static func deviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                                    &address,
                                                    0,
                                                    nil,
                                                    &dataSize)
        guard status == noErr else {
            throw CoreAudioCallError(operation: "get device list size", status: status)
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = ids.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       &address,
                                       0,
                                       nil,
                                       &dataSize,
                                       buffer.baseAddress!)
        }
        guard status == noErr else {
            throw CoreAudioCallError(operation: "get device list", status: status)
        }
        return ids
    }

    private static func defaultInputDeviceID() throws -> AudioDeviceID {
        try audioDeviceIDProperty(kAudioHardwarePropertyDefaultInputDevice,
                                  operation: "get default input device")
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector,
                                       objectID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID,
                                       &address,
                                       0,
                                       nil,
                                       &dataSize,
                                       pointer)
        }
        guard status == noErr else {
            throw CoreAudioCallError(operation: "get string property \(selector)", status: status)
        }
        return (value as String?) ?? ""
    }

    private static func uint32Property(_ selector: AudioObjectPropertySelector,
                                       objectID: AudioObjectID) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID,
                                                &address,
                                                0,
                                                nil,
                                                &dataSize,
                                                &value)
        guard status == noErr else {
            throw CoreAudioCallError(operation: "get uint32 property \(selector)", status: status)
        }
        return value
    }

    private static func audioDeviceIDProperty(_ selector: AudioObjectPropertySelector,
                                              operation: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address,
                                                0,
                                                nil,
                                                &dataSize,
                                                &value)
        guard status == noErr else {
            throw CoreAudioCallError(operation: operation, status: status)
        }
        return value
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID,
                                                    &address,
                                                    0,
                                                    nil,
                                                    &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize),
                                                  alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(deviceID,
                                            &address,
                                            0,
                                            nil,
                                            &dataSize,
                                            raw)
        guard status == noErr else { return 0 }

        let audioBufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

struct CoreAudioCallError: Error, LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed (OSStatus \(status))"
    }
}
