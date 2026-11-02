import XCTest

/// Fixtures are an LG ULTRAWIDE's real `ColorElements` (#249): RGB and two YCbCr modes that
/// differ only in colorimetry, so they read the same.
final class DisplayColorModeTests: XCTestCase {
    private let timing: [[String: Any]] = [
        ["ID": 9, "ColorModes": [] as [[String: Any]]],
        ["ID": 27, "ColorModes": [
            ["ID": 60, "Depth": 8, "PixelEncoding": 3, "DynamicRange": 1, "EOTF": 0, "Score": 232999],
            ["ID": 57, "Depth": 8, "PixelEncoding": 0, "DynamicRange": 0, "EOTF": 0, "Score": 242999],
            ["ID": 59, "Depth": 8, "PixelEncoding": 3, "DynamicRange": 1, "EOTF": 0, "Score": 231999]
        ] as [[String: Any]]]
    ]

    private var modes: [DisplayColorMode] {
        DisplayColorMode.available(timingElements: timing, timingID: 27)
    }

    func testListsTheCurrentTimingsModesBestFirst() {
        XCTAssertEqual(modes.map(\.id), [57, 60, 59])
        XCTAssertEqual(DisplayColorMode.available(timingElements: timing, timingID: 9), [])
        XCTAssertEqual(DisplayColorMode.available(timingElements: timing, timingID: 1), [])
    }

    func testLabelsSpellOutEncodingDepthAndRange() {
        XCTAssertEqual(modes[0].label, "RGB 8-bit Full")
        XCTAssertEqual(modes[1].label, "YCbCr 8-bit Limited")
        let hdr = DisplayColorMode(id: 1, depth: 10, isRGB: true, isFullRange: true, isHDR: true, score: 0)
        XCTAssertEqual(hdr.label, "RGB 10-bit Full HDR")
    }

    func testAnElementMissingAFieldIsSkipped() {
        XCTAssertNil(DisplayColorMode(element: ["ID": 1, "Depth": 8]))
    }

    func testOnlyModesThatReadTheSameCarryTheirID() {
        let names = DisplayColorMode.names(of: modes)
        XCTAssertEqual(names[57], "RGB 8-bit Full")
        XCTAssertEqual(names[60], "YCbCr 8-bit Limited (60)")
        XCTAssertEqual(names[59], "YCbCr 8-bit Limited (59)")
    }

    func testResolvesAnIDOrANameInAnyCase() {
        XCTAssertEqual(DisplayColorMode.resolve("57", in: modes)?.id, 57)
        XCTAssertEqual(DisplayColorMode.resolve("rgb 8-BIT full", in: modes)?.id, 57)
        XCTAssertEqual(DisplayColorMode.resolve("ycbcr 8-bit limited (59)", in: modes)?.id, 59)
        XCTAssertNil(DisplayColorMode.resolve("ycbcr 8-bit limited", in: modes))
        XCTAssertNil(DisplayColorMode.resolve("99", in: modes))
    }
}

/// crispctl's rename and color commands (#249, #253).
final class CrispControlDisplaySettingTests: XCTestCase {
    private let live = CrispControlDisplay(id: 2, name: "LG", brightness: 50, isBuiltin: false, uuid: "L")
    private let held = CrispControlDisplay(id: 3, name: "Off", brightness: 0, isBuiltin: false, uuid: "H", connected: false)

    private func result(_ request: CrispControlRequest) throws -> CrispControlResult {
        CrispControlModel.handle(try CrispControlModel.encode(request), displays: [live, held])
    }

    func testParsesTheCommands() {
        XCTAssertEqual(CrispControlCLIModel.parse(arguments: ["display", "rename", "2", "Left"]),
                       .request(.init(command: .renameDisplay, selector: "2", name: "Left")))
        XCTAssertEqual(CrispControlCLIModel.parse(arguments: ["display", "rename", "2"]),
                       .request(.init(command: .renameDisplay, selector: "2")))
        XCTAssertEqual(CrispControlCLIModel.parse(arguments: ["display", "color", "list", "2"]),
                       .request(.init(command: .listColorModes, selector: "2")))
        XCTAssertEqual(CrispControlCLIModel.parse(arguments: ["display", "color", "set", "2", "RGB 8-bit Full"]),
                       .request(.init(command: .setColorMode, selector: "2", name: "RGB 8-bit Full")))
    }

    func testARenameWithoutANameGoesBackToMacOSsName() throws {
        let change = try result(.init(command: .renameDisplay, selector: "2")).renameChange
        XCTAssertEqual(change, .init(displayID: 2, input: ""))
    }

    func testRoutesColorCommandsToTheDisplay() throws {
        XCTAssertEqual(try result(.init(command: .listColorModes, selector: "2")).colorListDisplayID, 2)
        let change = try result(.init(command: .setColorMode, selector: "L", name: "57")).colorChange
        XCTAssertEqual(change, .init(displayID: 2, input: "57"))
    }

    func testRefusesADisconnectedDisplayAndAnEmptyMode() throws {
        XCTAssertEqual(try result(.init(command: .renameDisplay, selector: "H", name: "x")).response.error,
                       "display is not connected")
        XCTAssertEqual(try result(.init(command: .setColorMode, selector: "2")).response.error,
                       "color mode is required")
    }
}

/// Scale steps (Windows-style) against an LG ULTRAWIDE's real modes.
final class DisplayScaleTests: XCTestCase {
    private func mode(_ id: Int32, _ width: Int, _ height: Int, hiDPI: Bool, hz: Double = 50) -> DisplayScale.Mode {
        .init(id: id, width: width, height: height, refreshRate: hz, isHiDPI: hiDPI)
    }

    private var modes: [DisplayScale.Mode] {
        [
            mode(1, 3840, 2160, hiDPI: false, hz: 30), mode(2, 3440, 1440, hiDPI: false),
            mode(3, 3120, 1306, hiDPI: true), mode(4, 2752, 1152, hiDPI: true),
            mode(5, 2752, 1152, hiDPI: true, hz: 30), mode(6, 2752, 1152, hiDPI: false),
            mode(7, 2288, 958, hiDPI: true), mode(8, 1720, 720, hiDPI: true), mode(9, 1280, 960, hiDPI: true)
        ]
    }

    func testMapsPercentagesOntoSharpModesAtTheCurrentRefreshRate() {
        let options = DisplayScale.options(modes: modes, nativeWidth: 3440, nativeHeight: 1440, refreshRate: 50)
        XCTAssertEqual(options.map(\.percent), [100, 110, 125, 150, 200])
        XCTAssertEqual(options.map(\.mode.id), [2, 3, 4, 7, 8])
    }

    func testFallsBackToTheFastestRateWhenTheCurrentOneIsMissing() {
        let options = DisplayScale.options(modes: modes, nativeWidth: 3440, nativeHeight: 1440, refreshRate: 60)
        XCTAssertEqual(options.first { $0.percent == 125 }?.mode.id, 4)
    }

    func testNeverFillsAStepWithA1xModeOrOneOffAspect() {
        let blurry = [mode(1, 3440, 1440, hiDPI: false), mode(2, 2752, 1152, hiDPI: false), mode(3, 2752, 1500, hiDPI: true)]
        let options = DisplayScale.options(modes: blurry, nativeWidth: 3440, nativeHeight: 1440, refreshRate: 50)
        XCTAssertEqual(options.map(\.percent), [100])
    }

    func testNamesASizeNoPresetDoes() {
        XCTAssertEqual(DisplayScale.percent(width: 3440, nativeWidth: 3440), 100)
        XCTAssertEqual(DisplayScale.percent(width: 2648, nativeWidth: 3440), 130)
    }

    func testParsesTheCommands() {
        XCTAssertEqual(CrispControlCLIModel.parse(arguments: ["display", "scale", "list", "2"]),
                       .request(.init(command: .listScales, selector: "2")))
        XCTAssertEqual(CrispControlCLIModel.parse(arguments: ["display", "scale", "set", "2", "125%"]),
                       .request(.init(command: .setScale, selector: "2", name: "125%")))
    }
}
