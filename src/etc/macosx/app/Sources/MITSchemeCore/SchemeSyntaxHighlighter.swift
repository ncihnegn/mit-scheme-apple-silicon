import Foundation

public enum SchemeTokenKind: Sendable, Equatable {
    case comment
    case string
    case keyword
    case boolean
    case character
    case number
    case quote
    case paren
}

public struct SchemeToken: Sendable, Equatable {
    public let kind: SchemeTokenKind
    public let range: NSRange

    public init(kind: SchemeTokenKind, range: NSRange) {
        self.kind = kind
        self.range = range
    }
}

public enum SchemeSyntaxHighlighter {
    private static let keywords: Set<String> = [
        "define", "define-syntax", "define-record-type", "define-structure",
        "define-integrable", "define-generic", "define-method", "define-library",
        "define-condition-type", "define-deferred", "define-bundle-interface",
        "lambda", "case-lambda", "named-lambda",
        "let", "let*", "letrec", "letrec*", "let-values", "let*-values",
        "let-syntax", "letrec-syntax", "fluid-let", "receive", "do",
        "if", "cond", "case", "when", "unless", "and", "or", "not", "begin",
        "else", "=>", "set!", "quote", "quasiquote", "unquote", "unquote-splicing",
        "syntax-rules", "er-macro-transformer", "sc-macro-transformer",
        "declare", "usual-integrations", "import", "export", "library",
        "load", "load-option", "compile-file", "compile-procedure", "eval", "apply",
        "call-with-current-continuation", "call/cc", "dynamic-wind",
        "values", "call-with-values", "parameterize", "make-parameter",
        "guard", "with-exception-handler", "bind-condition-handler", "raise", "error",
        "edit", "sf", "cf",
    ]

    private struct ScanResult {
        var tokens: [SchemeToken] = []
        var pairs: [(open: Int, close: Int)] = []
        var topLevelForms: [NSRange] = []
        var parenDepth: Int = 0
        var hasUnclosedString: Bool = false
        var blockCommentDepth: Int = 0
    }

    public static func tokenize(_ text: String) -> [SchemeToken] {
        scan(text).tokens
    }

    public static func isBalanced(_ text: String) -> Bool {
        let res = scan(text)
        return !res.hasUnclosedString && res.blockCommentDepth == 0 && res.parenDepth == 0
    }

    public static func matchingParenIndex(in text: String, utf16Offset: Int) -> Int? {
        let res = scan(text)
        var pairMap: [Int: Int] = [:]
        pairMap.reserveCapacity(res.pairs.count * 2)
        for p in res.pairs {
            pairMap[p.open] = p.close
            pairMap[p.close] = p.open
        }
        if utf16Offset > 0, let partner = pairMap[utf16Offset - 1] {
            return partner
        }
        if let partner = pairMap[utf16Offset] {
            return partner
        }
        return nil
    }

    public static func enclosingTopLevelForm(
        in text: String,
        utf16Offset: Int
    ) -> (range: NSRange, text: String)? {
        let forms = scan(text).topLevelForms
        guard !forms.isEmpty else { return nil }
        let ns = text as NSString
        let clamped = max(0, min(utf16Offset, ns.length))

        // Prefer form directly containing cursor (including just after its closing delimiter).
        for form in forms {
            if clamped >= form.location && clamped <= form.location + form.length {
                return (form, ns.substring(with: form))
            }
        }
        // Otherwise pick the nearest preceding top-level form before cursor.
        var best: NSRange?
        for form in forms where form.location + form.length <= clamped {
            best = form
        }
        if let best {
            return (best, ns.substring(with: best))
        }
        // Fallback to first top-level form if cursor precedes everything.
        let first = forms[0]
        return (first, ns.substring(with: first))
    }

    private static func isDelimiter(_ cu: UInt16) -> Bool {
        switch cu {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, // whitespace
             0x28, 0x29, // ( )
             0x5B, 0x5D, // [ ]
             0x22,       // "
             0x3B,       // ;
             0x27,       // '
             0x60,       // `
             0x2C:       // ,
            return true
        default:
            return false
        }
    }

    private static func isQuoteChar(_ cu: UInt16) -> Bool {
        cu == 0x27 || cu == 0x60 || cu == 0x2C // ' ` ,
    }

    private static func looksLikeNumber(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let lower = word.lowercased()
        if lower.hasPrefix("#x") || lower.hasPrefix("#b") || lower.hasPrefix("#o")
            || lower.hasPrefix("#d") || lower.hasPrefix("#e") || lower.hasPrefix("#i") {
            return word.count >= 3
        }
        var idx = word.startIndex
        if word[idx] == "+" || word[idx] == "-" {
            idx = word.index(after: idx)
            if idx == word.endIndex { return false }
        } else if word[idx] == "." {
            idx = word.index(after: idx)
            if idx == word.endIndex { return false }
        }
        return word[idx].isASCII && word[idx].isNumber
    }

    private static func scan(_ text: String) -> ScanResult {
        let units = Array(text.utf16)
        let n = units.count
        var result = ScanResult()
        var parenStack: [(idx: Int, char: UInt16, formStart: Int)] = []
        var i = 0

        // Track pending prefix like ' or `(expr) so topLevelForms includes leading quote.
        var pendingPrefixStart: Int? = nil

        while i < n {
            let c = units[i]

            // Whitespace resets pending quote prefix only if separated? No, '(a) can have space after ',
            // keep pendingPrefixStart only across adjacent quote markers/trivia? Actually Scheme allows
            // whitespace/comments, only reset when depth > 0 or consumed.
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                i += 1
                continue
            }

            // Line comment ; ... \n
            if c == 0x3B {
                let start = i
                i += 1
                while i < n && units[i] != 0x0A {
                    i += 1
                }
                result.tokens.append(SchemeToken(kind: .comment, range: NSRange(location: start, length: i - start)))
                continue
            }

            // String literal "..."
            if c == 0x22 {
                let start = i
                i += 1
                var closed = false
                while i < n {
                    let ch = units[i]
                    if ch == 0x5C { // '\'
                        i = min(i + 2, n)
                    } else if ch == 0x22 {
                        i += 1
                        closed = true
                        break
                    } else {
                        i += 1
                    }
                }
                if !closed {
                    result.hasUnclosedString = true
                }
                result.tokens.append(SchemeToken(kind: .string, range: NSRange(location: start, length: i - start)))
                if parenStack.isEmpty && closed {
                    let fStart = pendingPrefixStart ?? start
                    result.topLevelForms.append(NSRange(location: fStart, length: i - fStart))
                }
                pendingPrefixStart = nil
                continue
            }

            // Dispatch # constructs: #| ... |#, #\..., #t, #f, #(...) / #x...
            if c == 0x23 { // '#'
                if i + 1 < n && units[i + 1] == 0x7C { // #| nested block comment
                    let start = i
                    i += 2
                    var depth = 1
                    while i < n && depth > 0 {
                        if i + 1 < n && units[i] == 0x23 && units[i + 1] == 0x7C {
                            depth += 1
                            i += 2
                        } else if i + 1 < n && units[i] == 0x7C && units[i + 1] == 0x23 {
                            depth -= 1
                            i += 2
                        } else {
                            i += 1
                        }
                    }
                    if depth > 0 {
                        result.blockCommentDepth = depth
                    }
                    result.tokens.append(SchemeToken(kind: .comment, range: NSRange(location: start, length: i - start)))
                    continue
                }

                if i + 1 < n && units[i + 1] == 0x5C { // #\ character literal
                    let start = i
                    i += 2
                    if i < n {
                        i += 1
                        while i < n && !isDelimiter(units[i]) {
                            i += 1
                        }
                    }
                    result.tokens.append(SchemeToken(kind: .character, range: NSRange(location: start, length: i - start)))
                    if parenStack.isEmpty {
                        let fStart = pendingPrefixStart ?? start
                        result.topLevelForms.append(NSRange(location: fStart, length: i - fStart))
                    }
                    pendingPrefixStart = nil
                    continue
                }

                if i + 1 < n && units[i + 1] == 0x28 { // #( vector literal
                    if parenStack.isEmpty && pendingPrefixStart == nil {
                        pendingPrefixStart = i
                    }
                    result.tokens.append(SchemeToken(kind: .quote, range: NSRange(location: i, length: 1)))
                    i += 1
                    continue
                }

                // Read #... word (booleans #t/#f or radix numbers #x10)
                let start = i
                i += 1
                while i < n && !isDelimiter(units[i]) {
                    i += 1
                }
                let word = String(decoding: units[start..<i], as: UTF16.self)
                let lower = word.lowercased()
                if lower == "#t" || lower == "#f" || lower == "#true" || lower == "#false" {
                    result.tokens.append(SchemeToken(kind: .boolean, range: NSRange(location: start, length: i - start)))
                } else if looksLikeNumber(word) {
                    result.tokens.append(SchemeToken(kind: .number, range: NSRange(location: start, length: i - start)))
                }
                if parenStack.isEmpty {
                    let fStart = pendingPrefixStart ?? start
                    result.topLevelForms.append(NSRange(location: fStart, length: i - fStart))
                }
                pendingPrefixStart = nil
                continue
            }

            // Quote / quasiquote / unquote
            if isQuoteChar(c) {
                let start = i
                if parenStack.isEmpty && pendingPrefixStart == nil {
                    pendingPrefixStart = start
                }
                if c == 0x2C && i + 1 < n && units[i + 1] == 0x40 { // ,@
                    i += 2
                } else {
                    i += 1
                }
                result.tokens.append(SchemeToken(kind: .quote, range: NSRange(location: start, length: i - start)))
                continue
            }

            // Open paren / bracket
            if c == 0x28 || c == 0x5B {
                let formStart = parenStack.isEmpty ? (pendingPrefixStart ?? i) : i
                pendingPrefixStart = nil
                result.tokens.append(SchemeToken(kind: .paren, range: NSRange(location: i, length: 1)))
                parenStack.append((idx: i, char: c, formStart: formStart))
                result.parenDepth = parenStack.count
                i += 1
                continue
            }

            // Close paren / bracket
            if c == 0x29 || c == 0x5D {
                pendingPrefixStart = nil
                result.tokens.append(SchemeToken(kind: .paren, range: NSRange(location: i, length: 1)))
                if let top = parenStack.last {
                    let matches = (top.char == 0x28 && c == 0x29) || (top.char == 0x5B && c == 0x5D)
                    if matches {
                        parenStack.removeLast()
                        result.pairs.append((open: top.idx, close: i))
                        result.parenDepth = parenStack.count
                        if parenStack.isEmpty {
                            result.topLevelForms.append(
                                NSRange(location: top.formStart, length: (i + 1) - top.formStart)
                            )
                        }
                    }
                }
                i += 1
                continue
            }

            // Identifier / keyword / number
            let start = i
            while i < n && !isDelimiter(units[i]) {
                i += 1
            }
            let word = String(decoding: units[start..<i], as: UTF16.self)
            if keywords.contains(word) {
                result.tokens.append(SchemeToken(kind: .keyword, range: NSRange(location: start, length: i - start)))
            } else if looksLikeNumber(word) {
                result.tokens.append(SchemeToken(kind: .number, range: NSRange(location: start, length: i - start)))
            }
            if parenStack.isEmpty {
                let fStart = pendingPrefixStart ?? start
                result.topLevelForms.append(NSRange(location: fStart, length: i - fStart))
            }
            pendingPrefixStart = nil
        }

        return result
    }
}
