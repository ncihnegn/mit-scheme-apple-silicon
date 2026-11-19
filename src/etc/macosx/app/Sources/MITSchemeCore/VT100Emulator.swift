import Foundation

public enum TerminalColor: Equatable, Sendable {
    case defaultForeground
    case defaultBackground
    case ansi(UInt8)
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct TerminalAttributes: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let bold = TerminalAttributes(rawValue: 1 << 0)
    public static let dim = TerminalAttributes(rawValue: 1 << 1)
    public static let italic = TerminalAttributes(rawValue: 1 << 2)
    public static let underline = TerminalAttributes(rawValue: 1 << 3)
    public static let reverse = TerminalAttributes(rawValue: 1 << 4)
    public static let invisible = TerminalAttributes(rawValue: 1 << 5)
}

public struct TerminalStyle: Equatable, Sendable {
    public var foreground: TerminalColor = .defaultForeground
    public var background: TerminalColor = .defaultBackground
    public var attributes: TerminalAttributes = []

    public static let `default` = TerminalStyle()
}

public struct TerminalCell: Equatable, Sendable {
    public var character: Character
    public var style: TerminalStyle

    public init(character: Character = " ", style: TerminalStyle = .default) {
        self.character = character
        self.style = style
    }

    public static let blank = TerminalCell()
}

public final class VT100Emulator {
    public private(set) var rows: Int
    public private(set) var cols: Int

    public private(set) var screen: [[TerminalCell]]
    private var altScreen: [[TerminalCell]]
    public private(set) var usingAlternateScreen = false

    public private(set) var cursorRow = 0
    public private(set) var cursorCol = 0
    private var pendingWrap = false

    public private(set) var cursorVisible = true
    public private(set) var applicationCursorKeys = false
    public private(set) var autoWrap = true
    public private(set) var insertMode = false
    public private(set) var dirtyRevision: UInt64 = 0

    private var scrollTop = 0
    private var scrollBottom: Int
    private var currentStyle = TerminalStyle.default

    private struct SavedCursor {
        var row: Int
        var col: Int
        var style: TerminalStyle
        var autoWrap: Bool
    }
    private var savedPrimaryCursor: SavedCursor?
    private var savedAltCursor: SavedCursor?

    private enum ParserState {
        case ground
        case escape
        case escapeIntermediate
        case csiEntry
        case oscString
        case oscEscape
    }

    private var parserState: ParserState = .ground
    private var csiBytes: [UInt8] = []
    private var utf8Buffer: [UInt8] = []
    private var utf8Expected = 0

    public init(rows: Int = 24, cols: Int = 80) {
        let r = max(2, rows)
        let c = max(10, cols)
        self.rows = r
        self.cols = c
        self.scrollBottom = r - 1
        self.screen = Self.makeGrid(rows: r, cols: c)
        self.altScreen = Self.makeGrid(rows: r, cols: c)
    }

    private static func makeGrid(rows: Int, cols: Int) -> [[TerminalCell]] {
        let blankRow = [TerminalCell](repeating: .blank, count: cols)
        return [[TerminalCell]](repeating: blankRow, count: rows)
    }

    public func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        for byte in data {
            processByte(byte)
        }
        dirtyRevision &+= 1
    }

    public func feed(_ string: String) {
        if let data = string.data(using: .utf8) {
            feed(data)
        }
    }

    public func resize(rows newRows: Int, cols newCols: Int) {
        let r = max(2, newRows)
        let c = max(10, newCols)
        guard r != rows || c != cols else { return }

        screen = Self.resizedGrid(screen, rows: r, cols: c)
        altScreen = Self.resizedGrid(altScreen, rows: r, cols: c)
        rows = r
        cols = c
        scrollTop = 0
        scrollBottom = r - 1
        cursorRow = max(0, min(cursorRow, r - 1))
        cursorCol = max(0, min(cursorCol, c - 1))
        pendingWrap = false
        dirtyRevision &+= 1
    }

    private static func resizedGrid(_ old: [[TerminalCell]], rows: Int, cols: Int) -> [[TerminalCell]] {
        var grid = makeGrid(rows: rows, cols: cols)
        let copyRows = min(old.count, rows)
        for r in 0..<copyRows {
            let copyCols = min(old[r].count, cols)
            for c in 0..<copyCols {
                grid[r][c] = old[r][c]
            }
        }
        return grid
    }

    public func plainTextSnapshot() -> String {
        screen.map { row in
            var line = String(row.map(\.character))
            while line.last == " " {
                line.removeLast()
            }
            return line
        }.joined(separator: "\n")
    }

    private func processByte(_ byte: UInt8) {
        switch parserState {
        case .ground:
            if utf8Expected > 0 {
                if (byte & 0b1100_0000) == 0b1000_0000 {
                    utf8Buffer.append(byte)
                    utf8Expected -= 1
                    if utf8Expected == 0 {
                        let s = String(decoding: utf8Buffer, as: UTF8.self)
                        utf8Buffer.removeAll(keepingCapacity: true)
                        for ch in s {
                            putChar(ch)
                        }
                    }
                    return
                } else {
                    utf8Buffer.removeAll(keepingCapacity: true)
                    utf8Expected = 0
                }
            }

            switch byte {
            case 0x1B: // ESC
                parserState = .escape
            case 0x07: // BEL
                break
            case 0x08: // BS
                pendingWrap = false
                if cursorCol > 0 {
                    cursorCol -= 1
                }
            case 0x09: // TAB
                pendingWrap = false
                let nextStop = ((cursorCol / 8) + 1) * 8
                cursorCol = min(cols - 1, nextStop)
            case 0x0A, 0x0B, 0x0C: // LF, VT, FF
                lineFeed()
            case 0x0D: // CR
                pendingWrap = false
                cursorCol = 0
            case 0x0E, 0x0F: // SO / SI (shift out/in charset)
                break
            case 0x20...0x7E:
                putChar(Character(UnicodeScalar(byte)))
            case 0xC2...0xDF:
                utf8Buffer = [byte]
                utf8Expected = 1
            case 0xE0...0xEF:
                utf8Buffer = [byte]
                utf8Expected = 2
            case 0xF0...0xF4:
                utf8Buffer = [byte]
                utf8Expected = 3
            default:
                break
            }

        case .escape:
            switch byte {
            case 0x5B: // '[' CSI
                csiBytes.removeAll(keepingCapacity: true)
                parserState = .csiEntry
            case 0x5D: // ']' OSC
                parserState = .oscString
            case 0x28, 0x29, 0x2A, 0x2B, 0x23, 0x20: // '(' ')' etc. G0/G1 designation
                parserState = .escapeIntermediate
            case 0x37: // DECSC (ESC 7)
                saveCursor()
                parserState = .ground
            case 0x38: // DECRC (ESC 8)
                restoreCursor()
                parserState = .ground
            case 0x44: // IND (ESC D)
                lineFeed()
                parserState = .ground
            case 0x45: // NEL (ESC E)
                pendingWrap = false
                cursorCol = 0
                lineFeed()
                parserState = .ground
            case 0x4D: // RI (ESC M)
                reverseIndex()
                parserState = .ground
            case 0x63: // RIS (ESC c) reset
                resetAll()
                parserState = .ground
            case 0x3D, 0x3E: // DECKPAM / DECKPNM
                parserState = .ground
            case 0x1B:
                parserState = .escape
            default:
                parserState = .ground
            }

        case .escapeIntermediate:
            if byte == 0x1B {
                parserState = .escape
            } else if byte >= 0x30 {
                parserState = .ground
            }

        case .csiEntry:
            if byte == 0x1B {
                csiBytes.removeAll(keepingCapacity: true)
                parserState = .escape
            } else if byte < 0x20 {
                // Allow control bytes inside CSI safely (ignore or execute C0 controls)
                switch byte {
                case 0x08:
                    pendingWrap = false
                    if cursorCol > 0 { cursorCol -= 1 }
                case 0x0A, 0x0B, 0x0C:
                    lineFeed()
                case 0x0D:
                    pendingWrap = false
                    cursorCol = 0
                default:
                    break
                }
            } else if byte >= 0x40 && byte <= 0x7E {
                dispatchCSI(final: byte)
                csiBytes.removeAll(keepingCapacity: true)
                parserState = .ground
            } else {
                csiBytes.append(byte)
            }

        case .oscString:
            if byte == 0x07 {
                parserState = .ground
            } else if byte == 0x1B {
                parserState = .oscEscape
            }

        case .oscEscape:
            if byte == 0x5C { // ST = ESC backslash
                parserState = .ground
            } else if byte == 0x1B {
                parserState = .oscEscape
            } else {
                parserState = .oscString
            }
        }
    }

    private func eraseStyle() -> TerminalStyle {
        var st = TerminalStyle.default
        st.background = currentStyle.background
        return st
    }

    private func blankCellWithEraseBG() -> TerminalCell {
        TerminalCell(character: " ", style: eraseStyle())
    }

    private func putChar(_ ch: Character) {
        if pendingWrap && autoWrap {
            cursorCol = 0
            lineFeed()
        }
        pendingWrap = false

        let row = max(0, min(cursorRow, rows - 1))
        let col = max(0, min(cursorCol, cols - 1))

        if insertMode && col < cols - 1 {
            for c in stride(from: cols - 1, through: col + 1, by: -1) {
                screen[row][c] = screen[row][c - 1]
            }
        }
        screen[row][col] = TerminalCell(character: ch, style: currentStyle)

        if col >= cols - 1 {
            pendingWrap = autoWrap
        } else {
            cursorCol = col + 1
        }
    }

    private func lineFeed() {
        pendingWrap = false
        if cursorRow == scrollBottom {
            scrollUp(count: 1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private func reverseIndex() {
        pendingWrap = false
        if cursorRow == scrollTop {
            scrollDown(count: 1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    private func scrollUp(count: Int) {
        let top = max(0, scrollTop)
        let bottom = min(rows - 1, scrollBottom)
        guard top <= bottom, count > 0 else { return }
        let n = min(count, bottom - top + 1)
        for r in top..<(bottom - n + 1) {
            screen[r] = screen[r + n]
        }
        let blankRow = [TerminalCell](repeating: blankCellWithEraseBG(), count: cols)
        for r in (bottom - n + 1)...bottom {
            screen[r] = blankRow
        }
    }

    private func scrollDown(count: Int) {
        let top = max(0, scrollTop)
        let bottom = min(rows - 1, scrollBottom)
        guard top <= bottom, count > 0 else { return }
        let n = min(count, bottom - top + 1)
        for r in stride(from: bottom, through: top + n, by: -1) {
            screen[r] = screen[r - n]
        }
        let blankRow = [TerminalCell](repeating: blankCellWithEraseBG(), count: cols)
        for r in top..<(top + n) {
            screen[r] = blankRow
        }
    }

    private func saveCursor() {
        let sc = SavedCursor(row: cursorRow, col: cursorCol, style: currentStyle, autoWrap: autoWrap)
        if usingAlternateScreen {
            savedAltCursor = sc
        } else {
            savedPrimaryCursor = sc
        }
    }

    private func restoreCursor() {
        let sc = usingAlternateScreen ? savedAltCursor : savedPrimaryCursor
        guard let sc else { return }
        cursorRow = max(0, min(sc.row, rows - 1))
        cursorCol = max(0, min(sc.col, cols - 1))
        currentStyle = sc.style
        autoWrap = sc.autoWrap
        pendingWrap = false
    }

    private func resetAll() {
        screen = Self.makeGrid(rows: rows, cols: cols)
        altScreen = Self.makeGrid(rows: rows, cols: cols)
        usingAlternateScreen = false
        cursorRow = 0
        cursorCol = 0
        pendingWrap = false
        cursorVisible = true
        applicationCursorKeys = false
        autoWrap = true
        insertMode = false
        scrollTop = 0
        scrollBottom = rows - 1
        currentStyle = .default
        savedPrimaryCursor = nil
        savedAltCursor = nil
    }

    private func setAlternateScreen(_ enable: Bool, clearAlt: Bool) {
        if enable == usingAlternateScreen {
            if enable && clearAlt {
                screen = Self.makeGrid(rows: rows, cols: cols)
                cursorRow = 0
                cursorCol = 0
                pendingWrap = false
            }
            return
        }
        swap(&screen, &altScreen)
        usingAlternateScreen = enable
        if enable && clearAlt {
            screen = Self.makeGrid(rows: rows, cols: cols)
            cursorRow = 0
            cursorCol = 0
        }
        pendingWrap = false
    }

    private func dispatchCSI(final: UInt8) {
        let raw = String(decoding: csiBytes, as: UTF8.self)
        let isPrivate = raw.hasPrefix("?")
        let paramStr = isPrivate ? String(raw.dropFirst()) : raw

        // Strip any trailing intermediate bytes (e.g. ' ' before final) for clean integer parsing
        let cleaned = paramStr.filter { $0.isNumber || $0 == ";" }
        func parseParams(defaultVal: Int) -> [Int] {
            if paramStr.isEmpty {
                return [defaultVal]
            }
            let parts = cleaned.split(separator: ";", omittingEmptySubsequences: false)
            if parts.isEmpty {
                return [defaultVal]
            }
            return parts.map { part in
                part.isEmpty ? defaultVal : (Int(part) ?? defaultVal)
            }
        }

        if isPrivate {
            let params = parseParams(defaultVal: 0)
            let enable = (final == 0x68) // 'h' vs 'l'
            guard final == 0x68 || final == 0x6C else { return }
            for mode in params {
                switch mode {
                case 1: // DECCKM
                    applicationCursorKeys = enable
                case 7: // DECAWM
                    autoWrap = enable
                case 25: // DECTCEM
                    cursorVisible = enable
                case 47, 1047:
                    setAlternateScreen(enable, clearAlt: false)
                case 1049:
                    if enable {
                        saveCursor()
                        setAlternateScreen(true, clearAlt: true)
                    } else {
                        setAlternateScreen(false, clearAlt: false)
                        restoreCursor()
                    }
                default:
                    break
                }
            }
            return
        }

        switch final {
        case 0x41: // CUU - Cursor Up
            let n = max(1, parseParams(defaultVal: 1)[0])
            pendingWrap = false
            let minRow = (cursorRow >= scrollTop && cursorRow <= scrollBottom) ? scrollTop : 0
            cursorRow = max(minRow, cursorRow - n)

        case 0x42: // CUD - Cursor Down
            let n = max(1, parseParams(defaultVal: 1)[0])
            pendingWrap = false
            let maxRow = (cursorRow >= scrollTop && cursorRow <= scrollBottom) ? scrollBottom : (rows - 1)
            cursorRow = min(maxRow, cursorRow + n)

        case 0x43: // CUF - Cursor Forward
            let n = max(1, parseParams(defaultVal: 1)[0])
            pendingWrap = false
            cursorCol = min(cols - 1, cursorCol + n)

        case 0x44: // CUB - Cursor Backward
            let n = max(1, parseParams(defaultVal: 1)[0])
            pendingWrap = false
            cursorCol = max(0, cursorCol - n)

        case 0x47, 0x60: // CHA / HPA - Cursor Horizontal Absolute
            let col = max(1, parseParams(defaultVal: 1)[0]) - 1
            pendingWrap = false
            cursorCol = max(0, min(cols - 1, col))

        case 0x48, 0x66: // CUP / HVP - Cursor Position
            let params = parseParams(defaultVal: 1)
            let row = max(1, params[0]) - 1
            let col = max(1, params.count > 1 ? params[1] : 1) - 1
            pendingWrap = false
            cursorRow = max(0, min(rows - 1, row))
            cursorCol = max(0, min(cols - 1, col))

        case 0x4A: // ED - Erase Display
            let mode = parseParams(defaultVal: 0)[0]
            let blank = blankCellWithEraseBG()
            switch mode {
            case 0:
                for c in cursorCol..<cols {
                    screen[cursorRow][c] = blank
                }
                for r in (cursorRow + 1)..<rows {
                    screen[r] = [TerminalCell](repeating: blank, count: cols)
                }
            case 1:
                for r in 0..<cursorRow {
                    screen[r] = [TerminalCell](repeating: blank, count: cols)
                }
                for c in 0...min(cursorCol, cols - 1) {
                    screen[cursorRow][c] = blank
                }
            case 2, 3:
                let blankRow = [TerminalCell](repeating: blank, count: cols)
                screen = [[TerminalCell]](repeating: blankRow, count: rows)
            default:
                break
            }

        case 0x4B: // EL - Erase Line
            let mode = parseParams(defaultVal: 0)[0]
            let blank = blankCellWithEraseBG()
            switch mode {
            case 0:
                for c in cursorCol..<cols {
                    screen[cursorRow][c] = blank
                }
            case 1:
                for c in 0...min(cursorCol, cols - 1) {
                    screen[cursorRow][c] = blank
                }
            case 2:
                screen[cursorRow] = [TerminalCell](repeating: blank, count: cols)
            default:
                break
            }

        case 0x4C: // IL - Insert Lines
            guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
            let n = min(max(1, parseParams(defaultVal: 1)[0]), scrollBottom - cursorRow + 1)
            pendingWrap = false
            for r in stride(from: scrollBottom, through: cursorRow + n, by: -1) {
                screen[r] = screen[r - n]
            }
            let blankRow = [TerminalCell](repeating: blankCellWithEraseBG(), count: cols)
            for r in cursorRow..<(cursorRow + n) {
                screen[r] = blankRow
            }

        case 0x4D: // DL - Delete Lines
            guard cursorRow >= scrollTop && cursorRow <= scrollBottom else { return }
            let n = min(max(1, parseParams(defaultVal: 1)[0]), scrollBottom - cursorRow + 1)
            pendingWrap = false
            for r in cursorRow..<(scrollBottom - n + 1) {
                screen[r] = screen[r + n]
            }
            let blankRow = [TerminalCell](repeating: blankCellWithEraseBG(), count: cols)
            for r in (scrollBottom - n + 1)...scrollBottom {
                screen[r] = blankRow
            }

        case 0x40: // ICH - Insert Blank Characters
            let n = min(max(1, parseParams(defaultVal: 1)[0]), cols - cursorCol)
            pendingWrap = false
            let blank = blankCellWithEraseBG()
            for c in stride(from: cols - 1, through: cursorCol + n, by: -1) {
                screen[cursorRow][c] = screen[cursorRow][c - n]
            }
            for c in cursorCol..<(cursorCol + n) {
                screen[cursorRow][c] = blank
            }

        case 0x50: // DCH - Delete Characters
            let n = min(max(1, parseParams(defaultVal: 1)[0]), cols - cursorCol)
            pendingWrap = false
            let blank = blankCellWithEraseBG()
            for c in cursorCol..<(cols - n) {
                screen[cursorRow][c] = screen[cursorRow][c + n]
            }
            for c in (cols - n)..<cols {
                screen[cursorRow][c] = blank
            }

        case 0x53: // SU - Scroll Up
            scrollUp(count: max(1, parseParams(defaultVal: 1)[0]))

        case 0x54: // SD - Scroll Down
            scrollDown(count: max(1, parseParams(defaultVal: 1)[0]))

        case 0x58: // ECH - Erase Characters
            let n = min(max(1, parseParams(defaultVal: 1)[0]), cols - cursorCol)
            let blank = blankCellWithEraseBG()
            for c in cursorCol..<(cursorCol + n) {
                screen[cursorRow][c] = blank
            }

        case 0x64: // VPA - Vertical Position Absolute
            let row = max(1, parseParams(defaultVal: 1)[0]) - 1
            pendingWrap = false
            cursorRow = max(0, min(rows - 1, row))

        case 0x68, 0x6C: // SM / RM (Standard Mode)
            let enable = (final == 0x68)
            for mode in parseParams(defaultVal: 0) {
                if mode == 4 { // IRM Insert/Replace Mode (used by Edwin)
                    insertMode = enable
                }
            }

        case 0x6D: // SGR - Select Graphic Rendition
            applySGR(parseParams(defaultVal: 0))

        case 0x72: // DECSTBM - Set Top and Bottom Margins
            let params = parseParams(defaultVal: 0)
            let top = (params[0] > 0 ? params[0] : 1) - 1
            let bottom = ((params.count > 1 && params[1] > 0) ? params[1] : rows) - 1
            if top >= 0 && bottom < rows && top < bottom {
                scrollTop = top
                scrollBottom = bottom
            } else {
                scrollTop = 0
                scrollBottom = rows - 1
            }
            cursorRow = 0
            cursorCol = 0
            pendingWrap = false

        case 0x73: // SCP - Save Cursor Position
            saveCursor()

        case 0x75: // RCP - Restore Cursor Position
            restoreCursor()

        default:
            break
        }
    }

    private func applySGR(_ params: [Int]) {
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                currentStyle = .default
            case 1:
                currentStyle.attributes.insert(.bold)
            case 2:
                currentStyle.attributes.insert(.dim)
            case 3:
                currentStyle.attributes.insert(.italic)
            case 4:
                currentStyle.attributes.insert(.underline)
            case 7:
                currentStyle.attributes.insert(.reverse)
            case 8:
                currentStyle.attributes.insert(.invisible)
            case 22:
                currentStyle.attributes.remove([.bold, .dim])
            case 23:
                currentStyle.attributes.remove(.italic)
            case 24:
                currentStyle.attributes.remove(.underline)
            case 27:
                currentStyle.attributes.remove(.reverse)
            case 28:
                currentStyle.attributes.remove(.invisible)
            case 30...37:
                currentStyle.foreground = .ansi(UInt8(p - 30))
            case 38:
                if i + 2 < params.count && params[i + 1] == 5 {
                    let idx = max(0, min(255, params[i + 2]))
                    currentStyle.foreground = .indexed(UInt8(idx))
                    i += 2
                } else if i + 4 < params.count && params[i + 1] == 2 {
                    let r = UInt8(max(0, min(255, params[i + 2])))
                    let g = UInt8(max(0, min(255, params[i + 3])))
                    let b = UInt8(max(0, min(255, params[i + 4])))
                    currentStyle.foreground = .rgb(r, g, b)
                    i += 4
                }
            case 39:
                currentStyle.foreground = .defaultForeground
            case 40...47:
                currentStyle.background = .ansi(UInt8(p - 40))
            case 48:
                if i + 2 < params.count && params[i + 1] == 5 {
                    let idx = max(0, min(255, params[i + 2]))
                    currentStyle.background = .indexed(UInt8(idx))
                    i += 2
                } else if i + 4 < params.count && params[i + 1] == 2 {
                    let r = UInt8(max(0, min(255, params[i + 2])))
                    let g = UInt8(max(0, min(255, params[i + 3])))
                    let b = UInt8(max(0, min(255, params[i + 4])))
                    currentStyle.background = .rgb(r, g, b)
                    i += 4
                }
            case 49:
                currentStyle.background = .defaultBackground
            case 90...97:
                currentStyle.foreground = .ansi(UInt8(p - 90 + 8))
            case 100...107:
                currentStyle.background = .ansi(UInt8(p - 100 + 8))
            default:
                break
            }
            i += 1
        }
    }
}
