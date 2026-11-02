import CoreGraphics

/// Applies DisplayScale steps through ResolutionService. See docs/display-notes.md
/// (Display scale).
@MainActor
enum DisplayScaleService {
    /// kDisplayModeNativeFlag: the panel's own size. `DisplayInfo.nativeResolution` is the
    /// largest 1x mode, which on a monitor taking a bigger input than its panel (a
    /// 3440x1440 LG offering 3840x2160) isn't the panel, and every percentage would be off.
    private static let nativeFlag: UInt32 = 0x0200_0000

    private static func panelSize(of displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return nil }
        return modes.first { $0.ioFlags & nativeFlag != 0 && $0.pixelWidth == $0.width }
            .map { ($0.width, $0.height) }
    }

    /// Externals only: the built-in's sizes already are this, in System Settings' own
    /// terms, and a mirror's size belongs to MirroredModeService.
    static func options(for display: DisplayInfo) -> (scales: [DisplayScale], current: Int)? {
        guard !display.isBuiltin, !display.isRotated, !MirroredModeService.shared.isActive(for: display.displayID),
              let panel = panelSize(of: display.displayID),
              // Live: DisplayInfo's copy lags a change made outside the panel.
              let mode = CGDisplayCopyDisplayMode(display.displayID) else { return nil }
        let modes = display.availableModes.map {
            DisplayScale.Mode(id: $0.id, width: $0.width, height: $0.height,
                              refreshRate: $0.refreshRate, isHiDPI: $0.isHiDPI)
        }
        let scales = DisplayScale.options(modes: modes, nativeWidth: panel.width, nativeHeight: panel.height,
                                          refreshRate: mode.refreshRate)
        return scales.count > 1 ? (scales, DisplayScale.percent(width: mode.width, nativeWidth: panel.width)) : nil
    }

    static func apply(_ scale: DisplayScale, to display: DisplayInfo) async -> Bool {
        guard let mode = display.availableModes.first(where: { $0.id == scale.mode.id }) else { return false }
        let done = await ResolutionService.shared.setDisplayMode(mode, for: display.displayID)
        // Refreshes the row, which watches this.
        if done { display.currentDisplayMode = DisplayMode.currentMode(for: display.displayID) }
        return done
    }
}
