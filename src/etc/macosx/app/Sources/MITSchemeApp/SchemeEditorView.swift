import AppKit
import MITSchemeCore
import SwiftUI

struct SchemeEditorView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var onSelectionChange: (NSRange) -> Void
    var onEvaluateCurrent: () -> Void
    var onEvaluateBuffer: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = SchemeNSTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.backgroundColor = SchemeTheme.editorBackground
        textView.textColor = SchemeTheme.plainText
        textView.insertionPointColor = SchemeTheme.plainText

        scrollView.documentView = textView
        scrollView.backgroundColor = SchemeTheme.editorBackground

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.rulerView = ruler

        textView.string = text
        context.coordinator.applyHighlighting(to: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? SchemeNSTextView else { return }

        let targetFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let fontChanged = textView.font?.pointSize != targetFont.pointSize
        if fontChanged {
            textView.font = targetFont
            context.coordinator.rulerView?.font = NSFont.monospacedDigitSystemFont(
                ofSize: max(9, fontSize - 2),
                weight: .regular
            )
        }

        if textView.string != text {
            let previousSelection = textView.selectedRange()
            textView.string = text
            let len = (text as NSString).length
            let clampedLoc = min(previousSelection.location, len)
            textView.setSelectedRange(NSRange(location: clampedLoc, length: 0))
            context.coordinator.applyHighlighting(to: textView)
            context.coordinator.rulerView?.needsDisplay = true
        } else if fontChanged {
            context.coordinator.applyHighlighting(to: textView)
            context.coordinator.rulerView?.needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SchemeEditorView
        weak var textView: SchemeNSTextView?
        weak var rulerView: LineNumberRulerView?
        private var lastHighlightedParenRange: NSRange?

        init(_ parent: SchemeEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            applyHighlighting(to: tv)
            updateParenMatch(in: tv)
            rulerView?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.onSelectionChange(tv.selectedRange())
            updateParenMatch(in: tv)
        }

        func applyHighlighting(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let fullString = storage.string
            let fullRange = NSRange(location: 0, length: storage.length)
            let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)

            storage.beginEditing()
            storage.setAttributes([
                .font: font,
                .foregroundColor: SchemeTheme.plainText,
            ], range: fullRange)

            for token in SchemeSyntaxHighlighter.tokenize(fullString) {
                guard NSMaxRange(token.range) <= storage.length else { continue }
                storage.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
                if token.kind == .keyword {
                    storage.addAttribute(
                        .font,
                        value: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold),
                        range: token.range
                    )
                }
            }
            storage.endEditing()
        }

        private func updateParenMatch(in textView: NSTextView) {
            guard let lm = textView.layoutManager, let storage = textView.textStorage else { return }
            if let old = lastHighlightedParenRange, NSMaxRange(old) <= storage.length {
                lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old)
            }
            lastHighlightedParenRange = nil

            let sel = textView.selectedRange()
            guard sel.length == 0 else { return }
            if let partner = SchemeSyntaxHighlighter.matchingParenIndex(
                in: textView.string,
                utf16Offset: sel.location
            ), partner >= 0, partner < storage.length {
                let range = NSRange(location: partner, length: 1)
                lm.addTemporaryAttribute(.backgroundColor, value: SchemeTheme.parenMatch, forCharacterRange: range)
                lastHighlightedParenRange = range
            }
        }

        private func color(for kind: SchemeTokenKind) -> NSColor {
            switch kind {
            case .comment: return SchemeTheme.comment
            case .string: return SchemeTheme.string
            case .keyword: return SchemeTheme.keyword
            case .boolean: return SchemeTheme.boolean
            case .character: return SchemeTheme.character
            case .number: return SchemeTheme.number
            case .quote: return SchemeTheme.quote
            case .paren: return SchemeTheme.paren
            }
        }
    }
}

final class SchemeNSTextView: NSTextView {
    weak var coordinator: SchemeEditorView.Coordinator?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = (event.keyCode == 36 || event.keyCode == 76)

        if isReturn && flags.contains(.command) {
            if flags.contains(.shift) {
                coordinator?.parent.onEvaluateBuffer()
            } else {
                coordinator?.parent.onEvaluateCurrent()
            }
            return
        }

        if isReturn && flags.isEmpty {
            let indent = computedIndentForNewline()
            insertText("\n" + indent, replacementRange: selectedRange())
            return
        }

        super.keyDown(with: event)
    }

    private func computedIndentForNewline() -> String {
        let ns = string as NSString
        let cursor = min(selectedRange().location, ns.length)
        let prefix = ns.substring(to: cursor)
        let units = Array(prefix.utf16)

        var stack: [Int] = []
        var i = 0
        while i < units.count {
            let c = units[i]
            if c == 0x3B { // ';'
                while i < units.count && units[i] != 0x0A { i += 1 }
            } else if c == 0x22 { // '"'
                i += 1
                while i < units.count {
                    if units[i] == 0x5C {
                        i += 2
                    } else if units[i] == 0x22 {
                        i += 1
                        break
                    } else {
                        i += 1
                    }
                }
            } else if c == 0x28 || c == 0x5B {
                stack.append(i)
                i += 1
            } else if (c == 0x29 || c == 0x5D), !stack.isEmpty {
                stack.removeLast()
                i += 1
            } else {
                i += 1
            }
        }

        guard let openIdx = stack.last else { return "" }
        var lineStart = openIdx
        while lineStart > 0 && units[lineStart - 1] != 0x0A {
            lineStart -= 1
        }
        let col = openIdx - lineStart
        return String(repeating: " ", count: min(col + 2, 48))
    }
}

final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    var font: NSFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) {
        didSet { needsDisplay = true }
    }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 40
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(invalidateGutter),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func invalidateGutter() {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        SchemeTheme.gutterBackground.setFill()
        rect.fill()

        SchemeTheme.gutterSeparator.setStroke()
        let border = NSBezierPath()
        border.move(to: NSPoint(x: bounds.maxX - 0.5, y: rect.minY))
        border.line(to: NSPoint(x: bounds.maxX - 0.5, y: rect.maxY))
        border.lineWidth = 1
        border.stroke()

        let visibleRect = scrollView?.documentVisibleRect ?? textView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let ns = textView.string as NSString
        var lineNumber = 1
        var idx = 0
        while idx < charRange.location && idx < ns.length {
            if ns.character(at: idx) == 0x0A {
                lineNumber += 1
            }
            idx += 1
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: SchemeTheme.gutterText,
        ]
        let originOffsetY = textView.textContainerOrigin.y - visibleRect.minY

        var cur = charRange.location
        if ns.length == 0 {
            let label = NSAttributedString(string: "1", attributes: attrs)
            label.draw(at: NSPoint(x: bounds.width - label.size().width - 7, y: originOffsetY + 2))
            return
        }

        while cur <= NSMaxRange(charRange) && cur <= ns.length {
            if cur == ns.length {
                if ns.length > 0 && ns.character(at: ns.length - 1) == 0x0A {
                    let extraRect = layoutManager.extraLineFragmentRect
                    if extraRect.height > 0 {
                        let label = NSAttributedString(string: "\(lineNumber)", attributes: attrs)
                        let y = extraRect.minY + originOffsetY + (extraRect.height - label.size().height) / 2
                        label.draw(at: NSPoint(x: bounds.width - label.size().width - 7, y: y))
                    }
                }
                break
            }
            let lineRange = ns.lineRange(for: NSRange(location: cur, length: 0))
            let gRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            if gRange.location != NSNotFound {
                var effective = NSRange()
                let lineRect = layoutManager.lineFragmentRect(forGlyphAt: gRange.location, effectiveRange: &effective)
                let label = NSAttributedString(string: "\(lineNumber)", attributes: attrs)
                let y = lineRect.minY + originOffsetY + (lineRect.height - label.size().height) / 2
                label.draw(at: NSPoint(x: bounds.width - label.size().width - 7, y: y))
            }
            lineNumber += 1
            cur = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
    }
}

enum SchemeTheme {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        }
    }

    static let editorBackground = NSColor.textBackgroundColor
    static let gutterBackground = dynamic(
        light: NSColor(calibratedWhite: 0.96, alpha: 1),
        dark: NSColor(calibratedWhite: 0.14, alpha: 1)
    )
    static let gutterSeparator = NSColor.separatorColor
    static let gutterText = NSColor.secondaryLabelColor
    static let plainText = NSColor.labelColor
    static let comment = dynamic(
        light: NSColor(calibratedRed: 0.40, green: 0.46, blue: 0.50, alpha: 1),
        dark: NSColor(calibratedRed: 0.50, green: 0.58, blue: 0.64, alpha: 1)
    )
    static let string = dynamic(
        light: NSColor(calibratedRed: 0.72, green: 0.16, blue: 0.14, alpha: 1),
        dark: NSColor(calibratedRed: 0.96, green: 0.53, blue: 0.46, alpha: 1)
    )
    static let keyword = dynamic(
        light: NSColor(calibratedRed: 0.55, green: 0.14, blue: 0.62, alpha: 1),
        dark: NSColor(calibratedRed: 0.85, green: 0.55, blue: 0.92, alpha: 1)
    )
    static let boolean = dynamic(
        light: NSColor(calibratedRed: 0.05, green: 0.42, blue: 0.65, alpha: 1),
        dark: NSColor(calibratedRed: 0.42, green: 0.76, blue: 0.98, alpha: 1)
    )
    static let character = dynamic(
        light: NSColor(calibratedRed: 0.60, green: 0.34, blue: 0.06, alpha: 1),
        dark: NSColor(calibratedRed: 0.94, green: 0.72, blue: 0.40, alpha: 1)
    )
    static let number = dynamic(
        light: NSColor(calibratedRed: 0.08, green: 0.38, blue: 0.68, alpha: 1),
        dark: NSColor(calibratedRed: 0.52, green: 0.78, blue: 1.00, alpha: 1)
    )
    static let quote = dynamic(
        light: NSColor(calibratedRed: 0.10, green: 0.50, blue: 0.36, alpha: 1),
        dark: NSColor(calibratedRed: 0.45, green: 0.85, blue: 0.68, alpha: 1)
    )
    static let paren = dynamic(
        light: NSColor(calibratedWhite: 0.35, alpha: 1),
        dark: NSColor(calibratedWhite: 0.72, alpha: 1)
    )
    static let parenMatch = dynamic(
        light: NSColor(calibratedRed: 0.98, green: 0.88, blue: 0.38, alpha: 0.55),
        dark: NSColor(calibratedRed: 0.32, green: 0.50, blue: 0.72, alpha: 0.55)
    )
}
