import XCTest
@testable import MITSchemeCore

final class VT100EmulatorTests: XCTestCase {
    func testCursorMovementAndOverwrite() {
        let vt = VT100Emulator(rows: 5, cols: 20)
        vt.feed("Hello World\u{1B}[1;7HScheme")
        XCTAssertEqual(vt.plainTextSnapshot().split(separator: "\n", omittingEmptySubsequences: false).first, "Hello Scheme")
    }

    func testEraseLineAndDisplay() {
        let vt = VT100Emulator(rows: 4, cols: 20)
        vt.feed("abcdef\r\n123456\u{1B}[1;4H\u{1B}[K")
        let lines = vt.plainTextSnapshot().split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], "abc")
        XCTAssertEqual(lines[1], "123456")

        vt.feed("\u{1B}[2J\u{1B}[1;1Hclean")
        let cleared = vt.plainTextSnapshot().split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(cleared[0], "clean")
        XCTAssertEqual(cleared[1], "")
    }

    func testScrollRegionInsertAndDeleteLines() {
        let vt = VT100Emulator(rows: 5, cols: 10)
        vt.feed("\u{1B}[1;1HR0\u{1B}[2;1HR1\u{1B}[3;1HR2\u{1B}[4;1HR3\u{1B}[5;1HR4")
        vt.feed("\u{1B}[2;4r") // scroll region rows 2..4 (1-based)
        vt.feed("\u{1B}[2;1H\u{1B}[1L") // IL 1 at row 2 -> pushes R1,R2 down, drops R3, keeps R4!
        let lines = vt.plainTextSnapshot().split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], "R0")
        XCTAssertEqual(lines[1], "")
        XCTAssertEqual(lines[2], "R1")
        XCTAssertEqual(lines[3], "R2")
        XCTAssertEqual(lines[4], "R4")

        vt.feed("\u{1B}[2;1H\u{1B}[1M") // DL 1 at row 2 -> pulls R1,R2 back up
        let afterDL = vt.plainTextSnapshot().split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(afterDL[1], "R1")
        XCTAssertEqual(afterDL[2], "R2")
        XCTAssertEqual(afterDL[3], "")
        XCTAssertEqual(afterDL[4], "R4")
    }

    func testInsertModeIRMAndDeleteChar() {
        let vt = VT100Emulator(rows: 3, cols: 12)
        vt.feed("acdf\u{1B}[1;2H\u{1B}[4hb\u{1B}[4l")
        XCTAssertEqual(vt.plainTextSnapshot().split(separator: "\n").first, "abcdf")
        vt.feed("\u{1B}[1;4H\u{1B}[1P")
        XCTAssertEqual(vt.plainTextSnapshot().split(separator: "\n").first, "abcf")
    }

    func testSGRColorsAndReverseVideo() {
        let vt = VT100Emulator(rows: 2, cols: 20)
        vt.feed("\u{1B}[1;7;38;5;196;48;2;10;20;30mX\u{1B}[0mY")
        let cell0 = vt.screen[0][0]
        XCTAssertEqual(cell0.character, "X")
        XCTAssertTrue(cell0.style.attributes.contains(.bold))
        XCTAssertTrue(cell0.style.attributes.contains(.reverse))
        XCTAssertEqual(cell0.style.foreground, .indexed(196))
        XCTAssertEqual(cell0.style.background, .rgb(10, 20, 30))

        let cell1 = vt.screen[0][1]
        XCTAssertEqual(cell1.character, "Y")
        XCTAssertEqual(cell1.style, .default)
    }

    func testAlternateScreenSwitchPreservesPrimary() {
        let vt = VT100Emulator(rows: 3, cols: 20)
        vt.feed("primary")
        vt.feed("\u{1B}[?1049h\u{1B}[1;1Hedwin")
        XCTAssertTrue(vt.usingAlternateScreen)
        XCTAssertEqual(vt.plainTextSnapshot().split(separator: "\n").first, "edwin")
        vt.feed("\u{1B}[?1049l")
        XCTAssertFalse(vt.usingAlternateScreen)
        XCTAssertEqual(vt.plainTextSnapshot().split(separator: "\n").first, "primary")
    }

    func testUTF8DecodingAcrossChunks() {
        let vt = VT100Emulator(rows: 2, cols: 10)
        let bytes = Array("λ→42".utf8)
        vt.feed(Data(bytes[0..<1]))
        vt.feed(Data(bytes[1..<bytes.count]))
        XCTAssertEqual(vt.plainTextSnapshot().split(separator: "\n").first, "λ→42")
    }
}
