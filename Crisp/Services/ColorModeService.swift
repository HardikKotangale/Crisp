import Foundation
import CoreGraphics
import IOKit
import os.log

/// Reads and sets an external display's signal color mode on Apple Silicon (#249) through
/// IOMobileFramebuffer. See docs/display-notes.md (Color modes).
enum ColorModeService {
    private typealias Connection = UnsafeMutableRawPointer
    private typealias OpenFn = @convention(c) (io_service_t, mach_port_t, UInt32, UnsafeMutablePointer<Connection?>) -> Int32
    private typealias GetFn = @convention(c) (Connection, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias SetFn = @convention(c) (Connection, UInt32, UInt32) -> Int32

    private struct API: @unchecked Sendable {
        let open: OpenFn
        let get: GetFn
        let set: SetFn
    }

    private struct Framebuffer {
        let connection: Connection
        let color: UInt32
        let timing: UInt32
        let timingElements: [[String: Any]]
    }

    /// nil on Intel, or if macOS drops the symbols: the row and commands then go away.
    private static let api: API? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_LAZY
        ), let open = dlsym(handle, "IOMobileFramebufferOpen"),
           let get = dlsym(handle, "IOMobileFramebufferGetDigitalOutMode"),
           let set = dlsym(handle, "IOMobileFramebufferSetDigitalOutMode") else { return nil }
        return API(
            open: unsafeBitCast(open, to: OpenFn.self),
            get: unsafeBitCast(get, to: GetFn.self),
            set: unsafeBitCast(set, to: SetFn.self)
        )
    }()

    private static let log = Logger(subsystem: "com.crisp.app", category: "color")
    /// The framework has no close, and a framebuffer lives as long as the boot, so each is
    /// opened once and kept.
    nonisolated(unsafe) private static var connections: [UInt64: Connection] = [:]
    private static let lock = NSLock()

    /// The current mode's id and every mode the current timing offers; nil when this
    /// display has no framebuffer to ask (built-in, Intel, AirPlay, a virtual display).
    static func modes(for displayID: CGDirectDisplayID) -> (current: UInt32, modes: [DisplayColorMode])? {
        lock.withLock {
            guard let framebuffer = framebuffer(for: displayID) else { return nil }
            let modes = DisplayColorMode.available(
                timingElements: framebuffer.timingElements, timingID: framebuffer.timing
            )
            return modes.isEmpty ? nil : (framebuffer.color, modes)
        }
    }

    /// Sets a mode at the current timing and checks that it took. Lasts until the display
    /// reconnects, when macOS picks again; that is also the way out of a mode the monitor
    /// can't show. Blocks while the link retrains, so call it off the main thread.
    static func set(_ colorID: UInt32, for displayID: CGDirectDisplayID) -> Bool {
        lock.withLock {
            guard let api, let framebuffer = framebuffer(for: displayID) else { return false }
            let status = api.set(framebuffer.connection, colorID, framebuffer.timing)
            guard status == 0 else {
                log.notice("display \(displayID, privacy: .public): color mode \(colorID, privacy: .public) refused, \(String(format: "0x%08X", status), privacy: .public)")
                return false
            }
            for _ in 0..<20 {
                Thread.sleep(forTimeInterval: 0.1)
                var color: UInt32 = 0
                var timing: UInt32 = 0
                if api.get(framebuffer.connection, &color, &timing) == 0, color == colorID {
                    log.notice("display \(displayID, privacy: .public): color mode \(colorID, privacy: .public) set")
                    return true
                }
            }
            log.notice("display \(displayID, privacy: .public): color mode \(colorID, privacy: .public) did not take")
            return false
        }
    }

    /// Pairs the framebuffers that are driving something to the online externals the way
    /// DDCService pairs its channels. Idle framebuffers fail the mode read and drop out.
    private static func framebuffer(for displayID: CGDirectDisplayID) -> Framebuffer? {
        guard let api, CGDisplayIsBuiltin(displayID) == 0 else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var live: [(framebuffer: Framebuffer, identity: DDCServiceMatcher.Identity?)] = []
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            guard property(entry, "external") as? Bool == true,
                  let connection = connection(to: entry, api: api),
                  let elements = property(entry, "TimingElements") as? [[String: Any]] else { continue }
            var color: UInt32 = 0
            var timing: UInt32 = 0
            guard api.get(connection, &color, &timing) == 0 else { continue }
            live.append((
                Framebuffer(connection: connection, color: color, timing: timing, timingElements: elements),
                identity(of: entry)
            ))
        }

        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let displays = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.map {
            (id: $0, identity: DDCServiceMatcher.Identity(
                vendor: CGDisplayVendorNumber($0), product: CGDisplayModelNumber($0),
                serial: CGDisplaySerialNumber($0), location: DDCService.shared.channelLocation(for: $0)
            ))
        }
        let match = DDCServiceMatcher.match(services: live.map(\.identity), displays: displays)
        return match.byDisplayID[displayID].map { live[$0].framebuffer }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func identity(of entry: io_registry_entry_t) -> DDCServiceMatcher.Identity? {
        guard let attributes = property(entry, "DisplayAttributes") as? [String: Any],
              let product = attributes["ProductAttributes"] as? [String: Any] else { return nil }
        let path = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)
        defer { path.deallocate() }
        let location = IORegistryEntryGetPath(entry, kIOServicePlane, path) == KERN_SUCCESS ? String(cString: path) : nil
        return DDCService.displayIdentity(from: product, location: location)
    }

    private static func connection(to entry: io_registry_entry_t, api: API) -> Connection? {
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &registryID) == KERN_SUCCESS else { return nil }
        if let open = connections[registryID] { return open }
        var connection: Connection?
        guard api.open(entry, mach_task_self_, 0, &connection) == 0 else { return nil }
        connections[registryID] = connection
        return connection
    }
}
