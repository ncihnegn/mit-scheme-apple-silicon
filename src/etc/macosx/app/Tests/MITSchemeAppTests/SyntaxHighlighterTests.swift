import XCTest
@testable import MITSchemeCore

final class SyntaxHighlighterTests: XCTestCase {
    func testTokenizesKeywordsStringsNumbersAndNestedComments() {
        let source = """
        ; line comment
        #| outer #| inner |# outer |#
        (define (f x) ; inline
          (if #t "a \\"b\\"" #x2a))
        """
        let ns = source as NSString
        let tokens = SchemeSyntaxHighlighter.tokenize(source)

        let comments = tokens.filter { $0.kind == .comment }.map { ns.substring(with: $0.range) }
        XCTAssertEqual(comments.count, 3)
        XCTAssertEqual(comments[1], "#| outer #| inner |# outer |#")

        let strings = tokens.filter { $0.kind == .string }.map { ns.substring(with: $0.range) }
        XCTAssertEqual(strings, ["\"a \\\"b\\\"\""])

        let kws = tokens.filter { $0.kind == .keyword }.map { ns.substring(with: $0.range) }
        XCTAssertEqual(kws, ["define", "if"])

        let bools = tokens.filter { $0.kind == .boolean }.map { ns.substring(with: $0.range) }
        XCTAssertEqual(bools, ["#t"])

        let nums = tokens.filter { $0.kind == .number }.map { ns.substring(with: $0.range) }
        XCTAssertEqual(nums, ["#x2a"])
    }

    func testBalancedIgnoresParensInStringsCommentsAndChars() {
        XCTAssertTrue(SchemeSyntaxHighlighter.isBalanced("(define s \"((\") #\\( ; ((\n"))
        XCTAssertFalse(SchemeSyntaxHighlighter.isBalanced("(define x (+ 1 2"))
        XCTAssertFalse(SchemeSyntaxHighlighter.isBalanced("(display \"hello)"))
        XCTAssertFalse(SchemeSyntaxHighlighter.isBalanced("#| unclosed comment ("))
    }

    func testEnclosingTopLevelFormAndMatchingParen() {
        let src = "(define a 1)\n\n(define (b x)\n  (+ x 1))\n"
        let ns = src as NSString
        let secondOffset = ns.range(of: "(+ x 1)").location + 3

        let found = SchemeSyntaxHighlighter.enclosingTopLevelForm(in: src, utf16Offset: secondOffset)
        XCTAssertEqual(found?.text, "(define (b x)\n  (+ x 1))")

        let afterFirstOffset = ns.range(of: "(define a 1)").location + 12
        let matchIdx = SchemeSyntaxHighlighter.matchingParenIndex(in: src, utf16Offset: afterFirstOffset)
        XCTAssertEqual(matchIdx, 0)
    }
}
