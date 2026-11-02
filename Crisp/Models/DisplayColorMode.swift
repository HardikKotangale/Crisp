import Foundation

/// One way the Mac can encode the signal to a display at its current timing (#249): an
/// entry of the framebuffer's `ColorElements`. See docs/display-notes.md (Color modes).
struct DisplayColorMode: Equatable, Identifiable, Sendable {
    let id: UInt32
    let depth: Int
    let isRGB: Bool
    let isFullRange: Bool
    let isHDR: Bool
    /// macOS's own ranking of the modes; higher is what it would rather use.
    let score: Int

    init(id: UInt32, depth: Int, isRGB: Bool, isFullRange: Bool, isHDR: Bool, score: Int) {
        self.id = id
        self.depth = depth
        self.isRGB = isRGB
        self.isFullRange = isFullRange
        self.isHDR = isHDR
        self.score = score
    }

    init?(element: [String: Any]) {
        guard let id = element["ID"] as? Int, let depth = element["Depth"] as? Int,
              let encoding = element["PixelEncoding"] as? Int,
              let range = element["DynamicRange"] as? Int else { return nil }
        self.init(
            id: UInt32(id), depth: depth, isRGB: encoding == 0, isFullRange: range == 0,
            isHDR: (element["EOTF"] as? Int ?? 0) != 0, score: element["Score"] as? Int ?? 0
        )
    }

    /// YCbCr without a subsampling: the registry's encoding numbers aren't documented,
    /// and a wrong "4:4:4" is worse than none.
    var label: String {
        var parts = ["\(isRGB ? "RGB" : "YCbCr") \(depth)-bit", isFullRange ? "Full" : "Limited"]
        if isHDR { parts.append("HDR") }
        return parts.joined(separator: " ")
    }

    /// The modes `timingID` offers, best first, or [] if the timing isn't listed. Two modes
    /// can read the same (they differ in colorimetry), so those carry their id too.
    static func available(timingElements: [[String: Any]], timingID: UInt32) -> [DisplayColorMode] {
        guard let timing = timingElements.first(where: { ($0["ID"] as? Int).map(UInt32.init) == timingID }),
              let elements = timing["ColorModes"] as? [[String: Any]] else { return [] }
        return elements.compactMap(DisplayColorMode.init(element:)).sorted { $0.score > $1.score }
    }

    /// What a list shows: `label`, plus the id where another mode has the same label.
    static func names(of modes: [DisplayColorMode]) -> [UInt32: String] {
        var names: [UInt32: String] = [:]
        for mode in modes {
            let shared = modes.filter { $0.label == mode.label }.count > 1
            names[mode.id] = shared ? "\(mode.label) (\(mode.id))" : mode.label
        }
        return names
    }

    /// Finds a mode by what a person typed: its id, or its name in any case.
    static func resolve(_ selector: String, in modes: [DisplayColorMode]) -> DisplayColorMode? {
        let names = Self.names(of: modes)
        return modes.first {
            String($0.id) == selector || names[$0.id]?.caseInsensitiveCompare(selector) == .orderedSame
        }
    }
}
