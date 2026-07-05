import Cocoa
@preconcurrency import AudioToolbox
@preconcurrency import CoreAudio
import IOKit.hidsystem
import ConcurrencySupport

/// Best-effort controls that reduce computer-generated background audio during a
/// recording. The snapshot is owned by the recording hub and restored on both stop
/// and cancel.
final class RecordingAudioControls: @unchecked Sendable {
    private let muteSystemAudio: Bool
    private let pauseMedia: Bool
    private let lock = NSLock()
    private var active = false
    private var outputSnapshot: OutputAudioSnapshot?

    init(muteSystemAudio: Bool, pauseMedia: Bool) {
        self.muteSystemAudio = muteSystemAudio
        self.pauseMedia = pauseMedia
    }

    func begin() {
        guard muteSystemAudio || pauseMedia else { return }
        lock.lock()
        guard !active else { lock.unlock(); return }
        active = true
        lock.unlock()

        if pauseMedia {
            MediaKeySender.postPlayPause()
            doushaLog("[RecordingAudioControls] media pause requested")
        }
        let snapshot = muteSystemAudio ? SystemOutputAudio.muteDefaultOutput() : nil

        lock.lock()
        outputSnapshot = snapshot
        lock.unlock()
    }

    func end() {
        lock.lock()
        guard active else { lock.unlock(); return }
        active = false
        let snapshot = outputSnapshot
        outputSnapshot = nil
        lock.unlock()

        if let snapshot {
            SystemOutputAudio.restore(snapshot)
        }
    }
}

private enum OutputAudioSnapshot: Sendable {
    case mute(deviceID: AudioDeviceID, values: [OutputMuteValue])
    case volume(deviceID: AudioDeviceID, value: Float32)
}

private struct OutputMuteValue: Sendable {
    let element: AudioObjectPropertyElement
    let value: UInt32
}

private enum SystemOutputAudio {
    static func muteDefaultOutput() -> OutputAudioSnapshot? {
        do {
            let deviceID = try defaultOutputDeviceID()
            if let snapshot = try muteSnapshot(for: deviceID), !snapshot.isEmpty {
                doushaLog("[RecordingAudioControls] system output muted via mute property")
                return .mute(deviceID: deviceID, values: snapshot)
            }
            if let volume = try virtualMasterVolume(for: deviceID) {
                try setVirtualMasterVolume(0, for: deviceID)
                doushaLog("[RecordingAudioControls] system output volume set to 0")
                return .volume(deviceID: deviceID, value: volume)
            }
            doushaLog("[RecordingAudioControls] default output has no settable mute/volume property")
            return nil
        } catch {
            doushaLog("[RecordingAudioControls] mute failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func restore(_ snapshot: OutputAudioSnapshot) {
        do {
            switch snapshot {
            case .mute(let deviceID, let values):
                for value in values {
                    try setMute(value.value, for: deviceID, element: value.element)
                }
                doushaLog("[RecordingAudioControls] system output mute restored")
            case .volume(let deviceID, let value):
                try setVirtualMasterVolume(value, for: deviceID)
                doushaLog("[RecordingAudioControls] system output volume restored")
            }
        } catch {
            doushaLog("[RecordingAudioControls] restore failed: \(error.localizedDescription)")
        }
    }

    private static func muteSnapshot(for deviceID: AudioDeviceID) throws -> [OutputMuteValue]? {
        let candidates: [AudioObjectPropertyElement] = [
            kAudioObjectPropertyElementMain,
            1,
            2
        ]
        var snapshot: [OutputMuteValue] = []
        for element in candidates {
            guard isSettable(selector: kAudioDevicePropertyMute,
                             scope: kAudioDevicePropertyScopeOutput,
                             element: element,
                             objectID: deviceID) else { continue }
            let value = try uint32Property(kAudioDevicePropertyMute,
                                           objectID: deviceID,
                                           scope: kAudioDevicePropertyScopeOutput,
                                           element: element)
            try setMute(1, for: deviceID, element: element)
            snapshot.append(OutputMuteValue(element: element, value: value))
        }
        return snapshot.isEmpty ? nil : snapshot
    }

    private static func virtualMasterVolume(for deviceID: AudioDeviceID) throws -> Float32? {
        guard hasProperty(selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                          scope: kAudioDevicePropertyScopeOutput,
                          element: kAudioObjectPropertyElementMain,
                          objectID: deviceID),
              isSettable(selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                         scope: kAudioDevicePropertyScopeOutput,
                         element: kAudioObjectPropertyElementMain,
                         objectID: deviceID) else {
            return nil
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID,
                                                &address,
                                                0,
                                                nil,
                                                &dataSize,
                                                &value)
        guard status == noErr else {
            throw CoreAudioCallError(operation: "get virtual master volume", status: status)
        }
        return value
    }

    private static func setVirtualMasterVolume(_ value: Float32, for deviceID: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var mutable = value
        let dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID,
                                                &address,
                                                0,
                                                nil,
                                                dataSize,
                                                &mutable)
        guard status == noErr else {
            throw CoreAudioCallError(operation: "set virtual master volume", status: status)
        }
    }

    private static func setMute(_ value: UInt32,
                                for deviceID: AudioDeviceID,
                                element: AudioObjectPropertyElement) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: element)
        var mutable = value
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID,
                                                &address,
                                                0,
                                                nil,
                                                dataSize,
                                                &mutable)
        guard status == noErr else {
            throw CoreAudioCallError(operation: "set output mute", status: status)
        }
    }

    private static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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
            throw CoreAudioCallError(operation: "get default output device", status: status)
        }
        return value
    }

    private static func uint32Property(_ selector: AudioObjectPropertySelector,
                                       objectID: AudioObjectID,
                                       scope: AudioObjectPropertyScope,
                                       element: AudioObjectPropertyElement) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: scope,
                                                 mElement: element)
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

    private static func hasProperty(selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope,
                                    element: AudioObjectPropertyElement,
                                    objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: scope,
                                                 mElement: element)
        return AudioObjectHasProperty(objectID, &address)
    }

    private static func isSettable(selector: AudioObjectPropertySelector,
                                   scope: AudioObjectPropertyScope,
                                   element: AudioObjectPropertyElement,
                                   objectID: AudioObjectID) -> Bool {
        guard hasProperty(selector: selector, scope: scope, element: element, objectID: objectID) else {
            return false
        }
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: scope,
                                                 mElement: element)
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(objectID, &address, &settable)
        return status == noErr && settable.boolValue
    }
}

private enum MediaKeySender {
    static func postPlayPause() {
        post(key: Int32(NX_KEYTYPE_PLAY), down: true)
        post(key: Int32(NX_KEYTYPE_PLAY), down: false)
    }

    private static func post(key: Int32, down: Bool) {
        let keyState: Int32 = down ? 0xA : 0xB
        let data1 = Int((key << 16) | (keyState << 8))
        guard let event = NSEvent.otherEvent(with: .systemDefined,
                                             location: .zero,
                                             modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyState << 8)),
                                             timestamp: 0,
                                             windowNumber: 0,
                                             context: nil,
                                             subtype: 8,
                                             data1: data1,
                                             data2: -1)?.cgEvent else {
            doushaLog("[RecordingAudioControls] media key event creation failed")
            return
        }
        event.post(tap: .cghidEventTap)
    }
}
