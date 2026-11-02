import Foundation
import CoreAudio
import os.log

/// Volume for a display whose audio device has none and whose monitor takes no DDC, such
/// as HDMI through a USB-C adapter that doesn't forward it: taps what's playing to that
/// device, scales it and plays it back. See docs/ddc-notes.md (Software volume).
@available(macOS 14.2, *)
final class AudioDeviceAttenuator: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.crisp.app", category: "volume")

    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    /// Read on the audio thread, once per buffer. A Float store is atomic on arm64 and
    /// x86_64, and a late read only moves the ramp one buffer later.
    private let target = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let current = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    /// Starts in the muted-when-tapped state, so the device plays only what this writes,
    /// and macOS plays it directly again if this process dies.
    init?(deviceUID: String, percent: Double) {
        target.pointee = Self.gain(percent)
        current.pointee = target.pointee
        guard start(deviceUID: deviceUID) else {
            stop()
            return nil
        }
    }

    deinit {
        stop()
        target.deallocate()
        current.deallocate()
    }

    func set(percent: Double) {
        target.pointee = Self.gain(percent)
    }

    /// Squared, because hearing is closer to logarithmic: a linear slider has nearly all
    /// its audible change in the bottom quarter.
    static func gain(_ percent: Double) -> Float {
        let fraction = Float(max(0, min(100, percent)) / 100)
        return fraction * fraction
    }

    private func start(deviceUID: String) -> Bool {
        var ownProcess = AudioObjectID(kAudioObjectUnknown)
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess
        ) == noErr else { return false }

        // This process is excluded or the tap would hear what it plays back.
        let description = CATapDescription(__excludingProcesses: [NSNumber(value: ownProcess)],
                                           andDeviceUID: deviceUID, withStream: 0)
        description.name = "Crisp volume"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        guard check(AudioHardwareCreateProcessTap(description, &tap), "create tap") else { return false }

        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Crisp volume",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        guard check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &aggregate),
                    "create aggregate") else { return false }

        let target = self.target
        let current = self.current
        let created = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, DispatchQueue(
            label: "com.crisp.volume", qos: .userInteractive
        )) { _, input, _, output, _ in
            let from = current.pointee
            let to = target.pointee
            let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let destinations = UnsafeMutableAudioBufferListPointer(output)
            for (source, destination) in zip(sources, destinations) {
                guard let samples = source.mData?.assumingMemoryBound(to: Float32.self),
                      let out = destination.mData?.assumingMemoryBound(to: Float32.self) else { continue }
                let count = Int(min(source.mDataByteSize, destination.mDataByteSize)) / MemoryLayout<Float32>.size
                let channels = max(1, Int(source.mNumberChannels))
                let frames = max(1, count / channels)
                // Ramped across the buffer, or a change clicks.
                for frame in 0..<frames {
                    let gain = from + (to - from) * Float(frame + 1) / Float(frames)
                    for channel in 0..<channels where frame * channels + channel < count {
                        out[frame * channels + channel] = samples[frame * channels + channel] * gain
                    }
                }
            }
            current.pointee = to
        }
        guard check(created, "create proc") else { return false }
        return check(AudioDeviceStart(aggregate, proc), "start")
    }

    private func check(_ status: OSStatus, _ step: String) -> Bool {
        if status != noErr { Self.log.error("software volume: \(step, privacy: .public) failed, \(status, privacy: .public)") }
        return status == noErr
    }

    /// Reverse order: nothing may still be calling the proc when its device goes.
    private func stop() {
        if aggregate != kAudioObjectUnknown {
            if let proc {
                AudioDeviceStop(aggregate, proc)
                AudioDeviceDestroyIOProcID(aggregate, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        proc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }
}

/// System Audio Recording, which a tap needs. Without it a tap delivers silence while the
/// device stays muted, so this is asked before one exists. macOS has no API for it; these
/// are the TCC calls System Settings' list is backed by.
enum AudioCapturePermission {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @Sendable (Bool) -> Void) -> Void
    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }
    private static var handle: UnsafeMutableRawPointer? {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }

    static var isGranted: Bool {
        guard let symbol = dlsym(handle, "TCCAccessPreflight") else { return false }
        return unsafeBitCast(symbol, to: Preflight.self)(service, nil) == 0
    }

    static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let symbol = dlsym(handle, "TCCAccessRequest") else { return completion(false) }
        unsafeBitCast(symbol, to: Request.self)(service, nil, completion)
    }
}
