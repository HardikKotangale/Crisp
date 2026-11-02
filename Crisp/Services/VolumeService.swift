import Foundation
import CoreGraphics
import CoreAudio
import AudioToolbox
import AppKit
import os.log

/// What a volume key or shortcut asks for.
enum VolumeKey {
    case up, down, mute
}

/// DDC/CI speaker volume (VCP 0x62) for external monitors (issue #23):
/// support probing, a coalesced writer, mute, and default-audio-output
/// matching for the volume keys. Mute is modeled as "volume 0 + remembered
/// previous level", which works on every monitor that answers 0x62. A monitor
/// that can't be reached over DDC falls back to scaling its audio in software.
/// ponytail: real VCP 0x8D mute is the upgrade if monitors misbehave on 0.
@MainActor
final class VolumeService: ObservableObject {
    static let shared = VolumeService()
    private init() {}

    private static let log = Logger(subsystem: "com.crisp.app", category: "volume")

    /// DDC max volume per display (usually 100), from the probe read through
    /// DDCVolumeMax.
    private var ddcMax: [CGDirectDisplayID: UInt16] = [:]
    /// Volume to restore on unmute, captured when toggleMute drops to zero.
    private var preMuteVolume: [CGDirectDisplayID: Double] = [:]

    /// UUIDs of displays that have ever answered a 0x62 read. VCP support is a
    /// hardware fact, so remember it: a flaky launch-time probe (the
    /// wedged-read AOC) can miss, and without the memory the feature vanishes.
    private let capableKey = "crisp.volumeCapableDisplays"
    private lazy var rememberedCapable: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: capableKey) ?? [])

    private func rememberCapable(_ uuid: String) {
        guard rememberedCapable.insert(uuid).inserted else { return }
        UserDefaults.standard.set(Array(rememberedCapable), forKey: capableKey)
    }

    /// UUIDs the user forced volume-capable (issue #57): some monitors accept
    /// 0x62 writes but never answer a 0x62 read, so the probe can't prove
    /// support. Forced displays run write-only at the assumed max of 100.
    private let forcedKey = "crisp.volumeForcedDisplays"
    /// Published so the Settings block's Show Volume Sliders row re-checks on
    /// toggle; DisplayInfo.volumeSupported alone only re-renders one card.
    @Published private var forcedCapable: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "crisp.volumeForcedDisplays") ?? [])

    func isForced(_ display: DisplayInfo) -> Bool {
        forcedCapable.contains(display.displayUUID)
    }

    func setForced(_ on: Bool, for display: DisplayInfo) {
        if on {
            forcedCapable.insert(display.displayUUID)
        } else {
            forcedCapable.remove(display.displayUUID)
        }
        UserDefaults.standard.set(Array(forcedCapable), forKey: forcedKey)
        // Un-forcing keeps the feature only if a real probe ever succeeded.
        display.volumeSupported = on || rememberedCapable.contains(display.displayUUID)
            || softwareDisplays[display.displayID] != nil
    }

    /// Drop per-display state for a disconnected display so a reused
    /// displayID cannot inherit it. rememberedCapable stays: it is UUID-keyed
    /// and deliberately permanent.
    func invalidate(for displayID: CGDirectDisplayID) {
        ddcMax.removeValue(forKey: displayID)
        preMuteVolume.removeValue(forKey: displayID)
        softwareDisplays.removeValue(forKey: displayID)
        attenuators.removeValue(forKey: displayID)
    }

    // MARK: - Software fallback

    /// Displays on the fallback, with their audio device's UID.
    private var softwareDisplays: [CGDirectDisplayID: String] = [:]
    /// Live taps. Stored as Any because the type needs macOS 14.2 and this class doesn't.
    private var attenuators: [CGDirectDisplayID: Any] = [:]

    /// UUIDs that fell back once. Remembered so the next launch starts on the fallback at
    /// 100 instead of waiting for a failed write from a forced display's slider, which
    /// starts at 0: a first press up would then take the sound to 6%.
    private let softwareKey = "crisp.softwareVolumeDisplays"
    private lazy var rememberedSoftware: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: softwareKey) ?? [])

    /// For a display that DDC can't reach and whose audio device has no volume of its own.
    /// Callers have the evidence: a probe failing on a display that never answered, or a
    /// write failing, which is what a forced display (write-only) has instead of a probe.
    /// Returns whether the fallback took it.
    private func adoptSoftwareVolume(for display: DisplayInfo) -> Bool {
        guard #available(macOS 14.2, *), softwareDisplays[display.displayID] == nil,
              let uid = volumelessAudioDeviceUID(named: display.systemName) else { return false }
        Self.log.notice("\(display.name, privacy: .public): no DDC and no native volume on its audio device, software volume")
        softwareDisplays[display.displayID] = uid
        display.volumeSupported = true
        if rememberedSoftware.insert(display.displayUUID).inserted {
            UserDefaults.standard.set(Array(rememberedSoftware), forKey: softwareKey)
        }
        return true
    }

    /// At 100 there is no tap, so a display left alone keeps its direct audio path and
    /// nothing asks for the permission.
    private func setSoftwareVolume(_ percent: Double, uid: String, for display: DisplayInfo) {
        guard #available(macOS 14.2, *) else { return }
        let id = display.displayID
        guard percent < 100 else {
            if attenuators.removeValue(forKey: id) != nil { Self.log.notice("software volume: back at 100, tap removed") }
            return
        }
        if let live = attenuators[id] as? AudioDeviceAttenuator {
            live.set(percent: percent)
            return
        }
        guard AudioCapturePermission.isGranted else {
            Self.log.notice("software volume: asking for System Audio Recording")
            AudioCapturePermission.request { granted in
                Task { @MainActor in
                    if granted {
                        self.setSoftwareVolume(display.volume, uid: uid, for: display)
                    } else {
                        Self.log.notice("software volume: System Audio Recording refused, volume stays at 100")
                        display.volume = 100
                    }
                }
            }
            return
        }
        guard let attenuator = AudioDeviceAttenuator(deviceUID: uid, percent: percent) else {
            display.volume = 100
            return
        }
        Self.log.notice("software volume: tap running at \(percent, privacy: .public)")
        attenuators[id] = attenuator
    }

    /// The UID of the HDMI or DisplayPort output with this name, if macOS gives it no volume.
    private func volumelessAudioDeviceUID(named name: String) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr,
              let device = devices.first(where: { audioDeviceName($0) == name }),
              let transport = audioTransportType(device),
              transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort else { return nil }

        var volume = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        for channel: UInt32 in 0...2 {
            volume.mElement = channel
            guard !AudioObjectHasProperty(device, &volume) else { return nil }
        }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    // MARK: - Probe

    /// Reads VCP 0x62 once: success marks the display volume-capable and
    /// adopts the monitor's level, failure leaves the feature hidden. Safe to
    /// re-run on every refresh; a monitor answering late heals next pass.
    func refreshVolume(for display: DisplayInfo) {
        guard !display.isBuiltin else { return }
        // Seed from memory (or the user's force override) so a failed probe
        // can't hide the feature; the read below still adopts the monitor's
        // current level whenever it works.
        if rememberedCapable.contains(display.displayUUID) || forcedCapable.contains(display.displayUUID) {
            display.volumeSupported = true
        }
        let id = display.displayID
        let uuid = display.displayUUID
        DDCService.shared.readAsync(displayID: id, command: DDCService.volumeVCP) { result in
            Task { @MainActor in
                guard let result else {
                    // Only while the feature is hidden: a remembered or forced
                    // display failing a probe is the DDC layer's line to log.
                    if !display.volumeSupported || self.rememberedSoftware.contains(uuid) {
                        Self.log.notice("\(display.name, privacy: .public): volume probe (VCP 0x62) got no valid reply; the Volume Control toggle forces write-only")
                        if self.adoptSoftwareVolume(for: display) { display.volume = 100 }
                    }
                    return
                }
                let volumeMax = DDCVolumeMax.from(result.max)
                if !self.rememberedCapable.contains(uuid) {
                    Self.log.notice("\(display.name, privacy: .public): volume probe ok \(result.current, privacy: .public)/\(volumeMax, privacy: .public), slider shown")
                }
                self.softwareDisplays.removeValue(forKey: id)
                self.attenuators.removeValue(forKey: id)
                if self.rememberedSoftware.remove(uuid) != nil {
                    UserDefaults.standard.set(Array(self.rememberedSoftware), forKey: self.softwareKey)
                }
                self.ddcMax[id] = volumeMax
                display.volumeSupported = true
                self.rememberCapable(uuid)
                // Adopt the hardware level only while our writer is idle, so a
                // stale cached read never fights an in-flight drag.
                if self.pending[id] == nil, !self.pumpActive.contains(id) {
                    display.volume = Double(result.current) / Double(volumeMax) * 100.0
                }
            }
        }
    }

    // MARK: - Set (coalesced)

    /// Latest pending percent per display; only one DDC write in flight each.
    private var pending: [CGDirectDisplayID: Double] = [:]
    private var pumpActive: Set<CGDirectDisplayID> = []

    /// Sets speaker volume (0–100). Coalesced like the brightness writer:
    /// latest value wins, writes paced to the MCCS ~50ms spacing so slider
    /// drags don't flood the I2C bus that brightness shares.
    func setVolume(_ percent: Double, for display: DisplayInfo) {
        let clamped = max(0.0, min(100.0, percent))
        display.volume = clamped
        if let uid = softwareDisplays[display.displayID] {
            setSoftwareVolume(clamped, uid: uid, for: display)
            return
        }
        pending[display.displayID] = clamped
        pump(for: display.displayID)
    }

    /// Mute key behavior: at zero, restore the remembered pre-mute level (or
    /// 25 if there is none); otherwise remember the level and drop to zero.
    func toggleMute(for display: DisplayInfo) {
        if display.volume <= 0 {
            setVolume(preMuteVolume[display.displayID] ?? 25, for: display)
        } else {
            preMuteVolume[display.displayID] = display.volume
            setVolume(0, for: display)
        }
    }

    private func pump(for id: CGDirectDisplayID) {
        guard !pumpActive.contains(id), let percent = pending.removeValue(forKey: id) else { return }
        pumpActive.insert(id)
        let raw = UInt16((percent / 100.0 * Double(ddcMax[id] ?? 100)).rounded())
        DDCService.shared.writeAsync(displayID: id, command: DDCService.volumeVCP, value: raw) { ok in
            Task { @MainActor in
                // The level this write carried was stepped from a slider that never knew the
                // real one, so the fallback starts at full rather than near silence.
                if !ok, let display = DisplayManagerAccessor.shared.displays.first(where: { $0.displayID == id }),
                   self.adoptSoftwareVolume(for: display) {
                    display.volume = 100
                }
                try? await Task.sleep(nanoseconds: 50_000_000)  // MCCS write spacing
                self.pumpActive.remove(id)
                self.pump(for: id)
            }
        }
    }

    // MARK: - Default output

    /// Steps the default output's own volume, for a shortcut when no monitor owns the
    /// output. Returns the new level, or nil if that device has no volume to move.
    func stepDefaultOutput(_ key: VolumeKey) -> Double? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr else { return nil }

        address.mScope = kAudioDevicePropertyScopeOutput
        address.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
        var volume: Float32 = 0
        size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr else { return nil }

        var muteAddress = address
        muteAddress.mSelector = kAudioDevicePropertyMute
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &size, &muted)

        if key == .mute {
            muted = muted == 0 ? 1 : 0
        } else {
            let percent = BrightnessKeySteps.next(from: Double(volume) * 100, up: key == .up)
            volume = Float32(max(0, min(100, percent)) / 100)
            muted = 0
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume)
        }
        AudioObjectSetPropertyData(deviceID, &muteAddress, 0, nil, size, &muted)
        return muted != 0 ? 0 : Double(volume) * 100
    }

    // MARK: - Volume-key routing

    /// The external display whose speakers own the default audio output, or
    /// nil to pass the keys through untouched. Matches by device name, with a
    /// single-candidate HDMI/DisplayPort fallback when names differ.
    /// ponytail: name + transport matching; per-display audio binding UI if
    /// same-model multi-monitor setups misroute.
    func displayForDefaultAudioOutput(in displays: [DisplayInfo]) -> DisplayInfo? {
        let candidates = displays.filter { !$0.isBuiltin && $0.volumeSupported }
        guard !candidates.isEmpty else { return nil }

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }

        if let name = audioDeviceName(deviceID),
           let byName = candidates.first(where: { $0.systemName == name }) {
            return byName
        }
        if candidates.count == 1, let transport = audioTransportType(deviceID),
           transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort {
            return candidates[0]
        }
        return nil
    }

    private func audioDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private func audioTransportType(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr else { return nil }
        return transport
    }
}
