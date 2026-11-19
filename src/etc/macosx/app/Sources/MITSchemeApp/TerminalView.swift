import AppKit
import MITSchemeCore
import SwiftUI

struct TerminalView: NSViewRepresentable {
    @ObservedObject var session: EdwinSession
    var revision: UInt64
    var fontSize: CGFloat
    var optionAsMeta: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> EdwinTerminalNSView {
        let view = EdwinTerminalNSView(session: session, fontSize: fontSize, optionAsMeta: optionAsMeta)
        context.coordinator.terminalView = view
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
            view.ensureStarted()
        }
        return view
    }

    func updateNSView(_ view: EdwinTerminalNSView, context: Context) {
        _ = revision
        view.updateConfiguration(fontSize: fontSize, optionAsMeta: optionAsMeta)
        view.needsDisplay = true
    }

    final class Coordinator {
        let session: EdwinSession
        weak var terminalView: EdwinTerminalNSView?

        init(session: EdwinSession) {
            self.session = session
        }
    }
}

final class EdwinTerminalNSView: NSView {
    private let session: EdwinSession
    private var fontSize: CGFloat
    private var optionAsMeta: Bool
    private var monoFont: NSFont
    private var boldMonoFont: NSFont
    private var italicMonoFont: NSFont
    private var cellWidth: CGFloat = 8
    private var lineHeight: CGFloat = 16
    private let padding: CGFloat = 8

    private var blinkTimer: Timer?
    private var cursorBlinkOn = true

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    private static let ansiPalette: [NSColor] = [
        NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1), // 0 black
        NSColor(calibratedRed: 0.80, green: 0.24, blue: 0.22, alpha: 1), // 1 red
        NSColor(calibratedRed: 0.28, green: 0.72, blue: 0.42, alpha: 1), // 2 green
        NSColor(calibratedRed: 0.86, green: 0.68, blue: 0.24, alpha: 1), // 3 yellow
        NSColor(calibratedRed: 0.28, green: 0.56, blue: 0.88, alpha: 1), // 4 blue
        NSColor(calibratedRed: 0.72, green: 0.42, blue: 0.82, alpha: 1), // 5 magenta
        NSColor(calibratedRed: 0.24, green: 0.72, blue: 0.78, alpha: 1), // 6 cyan
        NSColor(calibratedRed: 0.88, green: 0.90, blue: 0.92, alpha: 1), // 7 white
        NSColor(calibratedRed: 0.42, green: 0.45, blue: 0.50, alpha: 1), // 8 bright black
        NSColor(calibratedRed: 0.96, green: 0.42, blue: 0.38, alpha: 1), // 9 bright red
        NSColor(calibratedRed: 0.44, green: 0.86, blue: 0.56, alpha: 1), // 10 bright green
        NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.40, alpha: 1), // 11 bright yellow
        NSColor(calibratedRed: 0.46, green: 0.72, blue: 0.98, alpha: 1), // 12 bright blue
        NSColor(calibratedRed: 0.86, green: 0.58, blue: 0.94, alpha: 1), // 13 bright magenta
        NSColor(calibratedRed: 0.42, green: 0.86, blue: 0.92, alpha: 1), // 14 bright cyan
        NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.99, alpha: 1), // 15 bright white
    ]

    init(session: EdwinSession, fontSize: CGFloat, optionAsMeta: Bool) {
        self.session = session
        self.fontSize = fontSize
        self.optionAsMeta = optionAsMeta
        self.monoFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        self.boldMonoFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        self.italicMonoFont = NSFontManager.shared.convert(self.monoFont, toHaveTrait: .italicFontMask)
        super.init(frame: .zero)
        recomputeMetrics()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        blinkTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.cursorBlinkOn.toggle()
                    self.needsDisplay = true
                }
            }
        } else if window == nil {
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
    }

    func updateConfiguration(fontSize newFontSize: CGFloat, optionAsMeta newOpt: Bool) {
        self.optionAsMeta = newOpt
        if abs(newFontSize - fontSize) > 0.01 {
            fontSize = newFontSize
            monoFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            boldMonoFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
            italicMonoFont = NSFontManager.shared.convert(monoFont, toHaveTrait: .italicFontMask)
            recomputeMetrics()
            resizeEmulatorToBounds()
        }
    }

    func ensureStarted() {
        let grid = gridSize(for: bounds.size)
        session.startIfNeeded(rows: grid.rows, cols: grid.cols)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeEmulatorToBounds()
    }

    override func becomeFirstResponder() -> Bool {
        cursorBlinkOn = true
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    @objc func paste(_ sender: Any?) {
        if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty {
            let crNormalized = str.replacingOccurrences(of: "\n", with: "\r")
            session.sendText(crNormalized)
        }
    }

    private func recomputeMetrics() {
        let sample = "MMMMMMMMMM" as NSString
        let w = sample.size(withAttributes: [.font: monoFont]).width / 10.0
        cellWidth = max(4.0, w)
        lineHeight = ceil(monoFont.ascender - monoFont.descender + monoFont.leading) + 2.0
    }

    private func gridSize(for size: NSSize) -> (rows: Int, cols: Int) {
        let usableW = max(100, size.width - padding * 2)
        let usableH = max(60, size.height - padding * 2)
        let cols = max(20, Int(floor(usableW / cellWidth)))
        let rows = max(6, Int(floor(usableH / lineHeight)))
        return (rows, cols)
    }

    private func resizeEmulatorToBounds() {
        let grid = gridSize(for: bounds.size)
        session.resize(rows: grid.rows, cols: grid.cols)
    }

    private var defaultForegroundColor: NSColor {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(calibratedWhite: 0.92, alpha: 1) : NSColor(calibratedWhite: 0.10, alpha: 1)
    }

    private var defaultBackgroundColor: NSColor {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark ? NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1) : NSColor.textBackgroundColor
    }

    private func resolveColor(_ color: TerminalColor, isForeground: Bool) -> NSColor {
        switch color {
        case .defaultForeground:
            return defaultForegroundColor
        case .defaultBackground:
            return defaultBackgroundColor
        case let .ansi(idx):
            return Self.ansiPalette[Int(idx) & 0x0F]
        case let .indexed(idx):
            if idx < 16 {
                return Self.ansiPalette[Int(idx)]
            } else if idx < 232 {
                let n = Int(idx) - 16
                let r = (n / 36) % 6
                let g = (n / 6) % 6
                let b = n % 6
                let cvt: (Int) -> CGFloat = { v in v == 0 ? 0 : CGFloat(55 + v * 40) / 255.0 }
                return NSColor(calibratedRed: cvt(r), green: cvt(g), blue: cvt(b), alpha: 1)
            } else {
                let gray = CGFloat(8 + (Int(idx) - 232) * 10) / 255.0
                return NSColor(calibratedWhite: gray, alpha: 1)
            }
        case let .rgb(r, g, b):
            return NSColor(
                calibratedRed: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1
            )
        }
    }

    private func effectiveColors(for style: TerminalStyle) -> (fg: NSColor, bg: NSColor, isNonDefaultBG: Bool) {
        var fg = resolveColor(style.foreground, isForeground: true)
        var bg = resolveColor(style.background, isForeground: false)
        var nonDefaultBG = (style.background != .defaultBackground)
        if style.attributes.contains(.reverse) {
            swap(&fg, &bg)
            nonDefaultBG = true
        }
        if style.attributes.contains(.dim) {
            fg = fg.withAlphaComponent(0.65)
        }
        if style.attributes.contains(.invisible) {
            fg = .clear
        }
        return (fg, bg, nonDefaultBG)
    }

    override func draw(_ dirtyRect: NSRect) {
        let baseBG = defaultBackgroundColor
        baseBG.setFill()
        dirtyRect.fill()

        if let errorMessage = session.errorMessage, !session.isRunning {
            let msg = NSAttributedString(
                string: "Unable to start Edwin:\n\(errorMessage)",
                attributes: [
                    .font: monoFont,
                    .foregroundColor: NSColor.systemRed,
                ]
            )
            msg.draw(at: NSPoint(x: padding, y: padding))
            return
        }

        let emu = session.emulator
        let grid = emu.screen
        let maxRow = min(grid.count, emu.rows)
        let firstVisibleRow = max(0, Int(floor((dirtyRect.minY - padding) / lineHeight)))
        let lastVisibleRow = min(maxRow - 1, Int(ceil((dirtyRect.maxY - padding) / lineHeight)))
        guard firstVisibleRow <= lastVisibleRow else { return }

        for row in firstVisibleRow...lastVisibleRow {
            let cells = grid[row]
            let y = padding + CGFloat(row) * lineHeight
            let colCount = min(cells.count, emu.cols)

            // 1. Background fill runs
            var col = 0
            while col < colCount {
                let firstEff = effectiveColors(for: cells[col].style)
                let runStyle = cells[col].style
                var endCol = col + 1
                while endCol < colCount && cells[endCol].style == runStyle {
                    endCol += 1
                }
                if firstEff.isNonDefaultBG {
                    firstEff.bg.setFill()
                    let rect = NSRect(
                        x: padding + CGFloat(col) * cellWidth,
                        y: y,
                        width: CGFloat(endCol - col) * cellWidth + 0.5,
                        height: lineHeight
                    )
                    rect.fill()
                }
                col = endCol
            }

            // 2. Text runs
            col = 0
            while col < colCount {
                let runStyle = cells[col].style
                var endCol = col + 1
                while endCol < colCount && cells[endCol].style == runStyle {
                    endCol += 1
                }

                // Skip empty whitespace spans unless underlined
                let hasUnderline = runStyle.attributes.contains(.underline)
                let slice = cells[col..<endCol]
                let allSpaces = !hasUnderline && slice.allSatisfy { $0.character == " " }
                if !allSpaces {
                    let eff = effectiveColors(for: runStyle)
                    let font: NSFont
                    if runStyle.attributes.contains(.bold) {
                        font = boldMonoFont
                    } else if runStyle.attributes.contains(.italic) {
                        font = italicMonoFont
                    } else {
                        font = monoFont
                    }
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: eff.fg,
                    ]
                    if hasUnderline {
                        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    }
                    let text = String(slice.map(\.character))
                    (text as NSString).draw(
                        at: NSPoint(x: padding + CGFloat(col) * cellWidth, y: y + 1),
                        withAttributes: attrs
                    )
                }
                col = endCol
            }
        }

        // 3. Draw terminal cursor
        if emu.cursorVisible && emu.cursorRow >= 0 && emu.cursorRow < emu.rows
            && emu.cursorCol >= 0 && emu.cursorCol < emu.cols {
            let cursorRect = NSRect(
                x: padding + CGFloat(emu.cursorCol) * cellWidth,
                y: padding + CGFloat(emu.cursorRow) * lineHeight,
                width: cellWidth,
                height: lineHeight
            )
            let isFocused = (window?.firstResponder === self)
            if isFocused && cursorBlinkOn {
                NSColor.controlAccentColor.withAlphaComponent(0.75).setFill()
                cursorRect.fill()
                let cellChar = String(grid[emu.cursorRow][emu.cursorCol].character)
                if cellChar != " " {
                    (cellChar as NSString).draw(
                        at: NSPoint(x: cursorRect.minX, y: cursorRect.minY + 1),
                        withAttributes: [
                            .font: monoFont,
                            .foregroundColor: NSColor.white,
                        ]
                    )
                }
            } else if !isFocused {
                NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
                let outline = NSBezierPath(rect: cursorRect.insetBy(dx: 0.5, dy: 0.5))
                outline.lineWidth = 1
                outline.stroke()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Let Cmd+ shortcuts pass through to the macOS menu bar & Edit -> Paste.
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        cursorBlinkOn = true
        if let encoded = encodeKeyEvent(event, flags: flags) {
            session.sendBytes(encoded)
            return
        }

        super.keyDown(with: event)
    }

    private func encodeKeyEvent(_ event: NSEvent, flags: NSEvent.ModifierFlags) -> Data? {
        let appCursor = session.emulator.applicationCursorKeys
        let ctrl = flags.contains(.control)
        let opt = flags.contains(.option)

        // Special non-character keys first
        switch event.keyCode {
        case 36, 76: // Return / Keypad Enter
            return opt ? Data([0x1B, 0x0D]) : Data([0x0D])
        case 48: // Tab
            if flags.contains(.shift) {
                return Data("\u{1B}[Z".utf8)
            }
            return Data([0x09])
        case 51: // Backspace / Delete
            return opt ? Data([0x1B, 0x7F]) : Data([0x7F])
        case 53: // Escape
            return Data([0x1B])
        case 117: // Forward delete
            return Data("\u{1B}[3~".utf8)
        case 115: // Home
            return Data("\u{1B}[H".utf8)
        case 119: // End
            return Data("\u{1B}[F".utf8)
        case 116: // Page Up
            return Data("\u{1B}[5~".utf8)
        case 121: // Page Down
            return Data("\u{1B}[6~".utf8)
        case 126: // Up
            return Data((appCursor ? "\u{1B}OA" : "\u{1B}[A").utf8)
        case 125: // Down
            return Data((appCursor ? "\u{1B}OB" : "\u{1B}[B").utf8)
        case 124: // Right
            return Data((appCursor ? "\u{1B}OC" : "\u{1B}[C").utf8)
        case 123: // Left
            return Data((appCursor ? "\u{1B}OD" : "\u{1B}[D").utf8)
        case 122: return Data("\u{1B}OP".utf8) // F1
        case 120: return Data("\u{1B}OQ".utf8) // F2
        case 99:  return Data("\u{1B}OR".utf8) // F3
        case 118: return Data("\u{1B}OS".utf8) // F4
        case 96:  return Data("\u{1B}[15~".utf8) // F5
        case 97:  return Data("\u{1B}[17~".utf8) // F6
        case 98:  return Data("\u{1B}[18~".utf8) // F7
        case 100: return Data("\u{1B}[19~".utf8) // F8
        case 101: return Data("\u{1B}[20~".utf8) // F9
        case 109: return Data("\u{1B}[21~".utf8) // F10
        case 103: return Data("\u{1B}[23~".utf8) // F11
        case 111: return Data("\u{1B}[24~".utf8) // F12
        default:
            break
        }

        // Control chords (Ctrl+Space, Ctrl+A..Z, Ctrl+[, Ctrl+\, Ctrl+], Ctrl+^, Ctrl+_, Ctrl+/)
        if ctrl {
            let base = event.charactersIgnoringModifiers ?? ""
            if let scalar = base.unicodeScalars.first {
                let v = scalar.value
                var ctrlByte: UInt8?
                if v == 0x20 || v == 0x40 { // Ctrl+Space / Ctrl+@
                    ctrlByte = 0x00
                } else if v >= 0x41 && v <= 0x5A { // 'A'..'Z'
                    ctrlByte = UInt8(v - 0x40)
                } else if v >= 0x61 && v <= 0x7A { // 'a'..'z'
                    ctrlByte = UInt8(v - 0x60)
                } else if v == 0x5B { // [
                    ctrlByte = 0x1B
                } else if v == 0x5C { // backslash
                    ctrlByte = 0x1C
                } else if v == 0x5D { // ]
                    ctrlByte = 0x1D
                } else if v == 0x5E || v == 0x36 { // ^ or 6
                    ctrlByte = 0x1E
                } else if v == 0x5F || v == 0x2F || v == 0x2D { // _ / -
                    ctrlByte = 0x1F
                }
                if let byte = ctrlByte {
                    return opt ? Data([0x1B, byte]) : Data([byte])
                }
            }
        }

        // Option-as-Meta (e.g. Option+x -> ESC x, Option+Shift+< -> ESC <)
        if opt && optionAsMeta {
            let rawWithoutOpt = event.characters(byApplyingModifiers: flags.subtracting(.option))
                ?? event.charactersIgnoringModifiers
                ?? ""
            if !rawWithoutOpt.isEmpty, let payload = rawWithoutOpt.data(using: .utf8) {
                var out = Data([0x1B])
                out.append(payload)
                return out
            }
        }

        // Normal printable Unicode characters
        if let chars = event.characters, !chars.isEmpty, let data = chars.data(using: .utf8) {
            return data
        }

        return nil
    }
}
