import XCTest
@testable import MITSchemeCore

final class REPLParserTests: XCTestCase {
    func testStripANSIAndSplitNormalPrompt() {
        let raw = "\u{1B}[0m;Value: 42\r\n\r\n1 ]=> "
        let clean = REPLOutputParser.stripANSI(raw)
        let split = REPLOutputParser.extractPromptSplit(in: clean)
        XCTAssertEqual(split?.body, ";Value: 42")
        XCTAssertEqual(split?.prompt, REPLPrompt(level: 1, kind: .normal))
    }

    func testDebuggerPromptAndRestartsParsing() {
        let raw = """
        ;Unbound variable: foo
        ;To continue, call RESTART with an option number:
        ; (RESTART 3) => Specify a value to use instead of foo.
        ; (RESTART 2) => Define foo to a given value.
        ; (RESTART 1) => Return to read-eval-print level 1.

        2 error> 
        """
        let split = REPLOutputParser.extractPromptSplit(in: raw)
        XCTAssertEqual(split?.prompt, REPLPrompt(level: 2, kind: .debugger))
        let restarts = REPLOutputParser.parseRestarts(in: split?.body ?? "")
        XCTAssertEqual(restarts.count, 3)
        XCTAssertEqual(restarts[0], REPLRestartOption(number: 3, description: "Specify a value to use instead of foo."))
        XCTAssertEqual(restarts[2], REPLRestartOption(number: 1, description: "Return to read-eval-print level 1."))
    }

    func testBannerSummaryExtraction() {
        let banner = "Image saved on Thursday November 19, 2026\n  Release 13.0.50 || SF || LIAR/AArch64"
        XCTAssertEqual(
            REPLOutputParser.parseBannerSummary(in: banner),
            "MIT/GNU Scheme 13.0.50 · SF || LIAR/AArch64"
        )
    }
}
