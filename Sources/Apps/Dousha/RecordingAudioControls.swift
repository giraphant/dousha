import Cocoa
@preconcurrency import AudioToolbox
@preconcurrency import CoreAudio
import Darwin
import IOKit.hidsystem
import ConcurrencySupport

/// Best-effort controls that reduce computer-generated background audio during a
/// recording. The snapshot is owned by the recording hub and restored on both stop
/// and cancel.
final class RecordingAudioControls: @unchecked Sendable {
    typealias MediaPlaybackState = @Sendable () -> Bool?
    typealias MediaKeyAction = @Sendable () -> Bool

    private let muteSystemAudio: Bool
    private let pauseMedia: Bool
    private let mediaPlaybackState: MediaPlaybackState
    private let mediaKeySender: MediaKeyAction
    private let lock = NSLock()
    private var active = false
    private var outputSnapshot: OutputAudioSnapshot?
    private var didPauseMedia = false

    init(muteSystemAudio: Bool,
         pauseMedia: Bool,
         mediaPlaybackState: @escaping MediaPlaybackState = { MediaRemotePlaybackProbe.shared.isPlaying() },
         mediaKeySender: @escaping MediaKeyAction = { MediaKeySender.postPlayPause() }) {
        self.muteSystemAudio = muteSystemAudio
        self.pauseMedia = pauseMedia
        self.mediaPlaybackState = mediaPlaybackState
        self.mediaKeySender = mediaKeySender
    }

    func begin() {
        guard muteSystemAudio || pauseMedia else { return }
        lock.lock()
        guard !active else { lock.unlock(); return }
        active = true
        lock.unlock()

        var didPauseMedia = false
        if pauseMedia {
            switch mediaPlaybackState() {
            case .some(true):
                didPauseMedia = mediaKeySender()
                if didPauseMedia {
                    doushaLog("[RecordingAudioControls] media pause requested")
                } else {
                    doushaLog("[RecordingAudioControls] media pause failed")
                }
            case .some(false):
                doushaLog("[RecordingAudioControls] media pause skipped (nothing playing)")
            case .none:
                doushaLog("[RecordingAudioControls] media pause skipped (playback state unknown)")
            }
        }
        let snapshot = muteSystemAudio ? SystemOutputAudio.muteDefaultOutput() : nil

        lock.lock()
        outputSnapshot = snapshot
        self.didPauseMedia = didPauseMedia
        lock.unlock()
    }

    func end() {
        lock.lock()
        guard active else { lock.unlock(); return }
        active = false
        let snapshot = outputSnapshot
        let shouldResumeMedia = didPauseMedia
        outputSnapshot = nil
        didPauseMedia = false
        lock.unlock()

        if let snapshot {
            SystemOutputAudio.restore(snapshot)
        }
        if shouldResumeMedia {
            if mediaKeySender() {
                doushaLog("[RecordingAudioControls] media resume requested")
            } else {
                doushaLog("[RecordingAudioControls] media resume failed")
            }
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
        return try coreAudioProperty(object: deviceID,
                                     selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                     scope: kAudioDevicePropertyScopeOutput,
                                     element: kAudioObjectPropertyElementMain,
                                     operation: "get virtual master volume") as Float32
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
        try coreAudioProperty(object: AudioObjectID(kAudioObjectSystemObject),
                              selector: kAudioHardwarePropertyDefaultOutputDevice,
                              scope: kAudioObjectPropertyScopeGlobal,
                              element: kAudioObjectPropertyElementMain,
                              operation: "get default output device")
    }

    private static func uint32Property(_ selector: AudioObjectPropertySelector,
                                       objectID: AudioObjectID,
                                       scope: AudioObjectPropertyScope,
                                       element: AudioObjectPropertyElement) throws -> UInt32 {
        try coreAudioProperty(object: objectID,
                              selector: selector,
                              scope: scope,
                              element: element,
                              operation: "get uint32 property \(selector)")
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

/// Best-effort bridge to the system Now Playing state. macOS does not expose a
/// public process-wide "is media playing" API; MediaRemote is what Control Center
/// uses. Load it dynamically and fail closed so we never fall back to the old blind
/// Play/Pause toggle that could start idle media.
private final class MediaRemotePlaybackProbe: @unchecked Sendable {
    static let shared = MediaRemotePlaybackProbe()

    private typealias IsPlayingCallback = @convention(block) (Bool) -> Void
    private typealias GetIsPlaying = @convention(c) (DispatchQueue, @escaping IsPlayingCallback) -> Void

    private let getIsPlaying: GetIsPlaying?
    private let callbackQueue = DispatchQueue(label: "com.dousha.media-remote.playback-state")

    private init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            getIsPlaying = nil
            return
        }
        guard let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else {
            dlclose(handle)
            getIsPlaying = nil
            return
        }
        getIsPlaying = unsafeBitCast(symbol, to: GetIsPlaying.self)
    }

    func isPlaying() -> Bool? {
        guard let getIsPlaying else { return nil }

        let result = MediaPlaybackResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        getIsPlaying(callbackQueue) { isPlaying in
            result.set(isPlaying)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + .milliseconds(250)) == .success else {
            doushaLog("[RecordingAudioControls] media playback state timed out")
            return nil
        }
        return result.value
    }
}

private final class MediaPlaybackResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool?

    func set(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

private enum MediaKeySender {
    static func postPlayPause() -> Bool {
        guard let down = event(key: Int32(NX_KEYTYPE_PLAY), down: true),
              let up = event(key: Int32(NX_KEYTYPE_PLAY), down: false) else {
            doushaLog("[RecordingAudioControls] media key event creation failed")
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func event(key: Int32, down: Bool) -> CGEvent? {
        let keyState: Int32 = down ? 0xA : 0xB
        let data1 = Int((key << 16) | (keyState << 8))
        return NSEvent.otherEvent(with: .systemDefined,
                                  location: .zero,
                                  modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyState << 8)),
                                  timestamp: 0,
                                  windowNumber: 0,
                                  context: nil,
                                  subtype: 8,
                                  data1: data1,
                                  data2: -1)?.cgEvent
    }
}
