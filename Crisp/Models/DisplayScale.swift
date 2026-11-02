import Foundation

/// A Windows-style Scale step: everything on screen drawn larger, by the percentage over
/// the panel's native size, and still sharp because the mode behind it renders at 2x and
/// downsamples. See docs/display-notes.md (Display scale).
struct DisplayScale: Equatable, Sendable {
    struct Mode: Equatable, Sendable {
        let id: Int32
        let width: Int
        let height: Int
        let refreshRate: Double
        let isHiDPI: Bool
    }

    static let presets = [100, 110, 125, 150, 175, 200]
    /// How far a mode's width may sit from a preset's and still answer to it.
    private static let tolerance = 0.02

    let percent: Int
    let mode: Mode

    /// The steps this display can really do, one mode each. 100 is the 1x native mode and
    /// the rest are HiDPI only: a 1x mode below native is the blurry look this replaces,
    /// so a preset with no HiDPI mode is left out rather than filled with one.
    static func options(modes: [Mode], nativeWidth: Int, nativeHeight: Int, refreshRate: Double) -> [DisplayScale] {
        guard nativeWidth > 0, nativeHeight > 0 else { return [] }
        let aspect = Double(nativeWidth) / Double(nativeHeight)
        return presets.compactMap { percent in
            let target = Double(nativeWidth) * 100 / Double(percent)
            let fits = modes.filter { mode in
                if percent == 100 {
                    return !mode.isHiDPI && mode.width == nativeWidth && mode.height == nativeHeight
                }
                return mode.isHiDPI && mode.height > 0
                    && abs(Double(mode.width) - target) / target <= tolerance
                    && abs(Double(mode.width) / Double(mode.height) - aspect) / aspect <= tolerance
            }
            guard let closest = fits.map({ abs(Double($0.width) - target) }).min() else { return nil }
            let nearest = fits.filter { abs(Double($0.width) - target) == closest }
            // Keeps the refresh rate, so a step never changes more than the size.
            let mode = nearest.first { abs($0.refreshRate - refreshRate) < 1 }
                ?? nearest.max { $0.refreshRate < $1.refreshRate }
            return mode.map { DisplayScale(percent: percent, mode: $0) }
        }
    }

    /// The percentage a logical width comes to, for a size no preset names.
    static func percent(width: Int, nativeWidth: Int) -> Int {
        width > 0 ? Int((Double(nativeWidth) * 100 / Double(width)).rounded()) : 100
    }
}
