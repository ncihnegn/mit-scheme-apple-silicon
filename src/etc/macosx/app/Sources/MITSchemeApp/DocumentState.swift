import AppKit
import Foundation
import MITSchemeCore
import UniformTypeIdentifiers

@MainActor
public final class DocumentState: ObservableObject {
    @Published public var fileURL: URL?
    @Published public var text: String
    @Published public var isDirty: Bool = false
    @Published public var cursorLine: Int = 1
    @Published public var cursorColumn: Int = 1
    @Published public var selectedRange: NSRange = NSRange(location: 0, length: 0)
    @Published public var lastErrorMessage: String?

    public nonisolated static let starterCode = """
    ;;;; MIT/GNU Scheme — Native Apple Silicon Workbench
    ;;;;
    ;;;; Shortcuts:
    ;;;;   Cmd+Return        Evaluate top-level form at cursor (or selection)
    ;;;;   Cmd+Shift+Return  Evaluate entire buffer
    ;;;;   Switch to "Edwin" in the toolbar for the classic integrated Emacs editor.

    (define (fact n)
      (if (<= n 1)
          1
          (* n (fact (- n 1)))))

    (fact 25)

    ;; Dynamically compile to native AArch64 machine code in MAP_JIT code space:
    (let ((square (compile-procedure (lambda (x) (* x x)))))
      (list microcode-id/compiled-code-type
            (code-address? square)
            (square 12)))
    """

    public init(text: String = DocumentState.starterCode) {
        self.text = text
    }

    public var displayName: String {
        fileURL?.lastPathComponent ?? "untitled.scm"
    }

    public func updateTextFromEditor(_ newText: String) {
        guard newText != text else { return }
        text = newText
        isDirty = true
    }

    public func updateSelection(_ range: NSRange) {
        selectedRange = range
        let ns = text as NSString
        let loc = max(0, min(range.location, ns.length))
        var line = 1
        var lineStart = 0
        var i = 0
        while i < loc {
            if ns.character(at: i) == 0x0A {
                line += 1
                lineStart = i + 1
            }
            i += 1
        }
        cursorLine = line
        cursorColumn = (loc - lineStart) + 1
    }

    public func newDocument() {
        fileURL = nil
        text = ""
        isDirty = false
        selectedRange = NSRange(location: 0, length: 0)
        cursorLine = 1
        cursorColumn = 1
    }

    public func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "scm") ?? .sourceCode,
            UTType(filenameExtension: "sld") ?? .sourceCode,
            UTType(filenameExtension: "ss") ?? .sourceCode,
            .plainText,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            openFile(url)
        }
    }

    public func openFile(_ url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            fileURL = url
            text = content
            isDirty = false
            selectedRange = NSRange(location: 0, length: 0)
            cursorLine = 1
            cursorColumn = 1
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    @discardableResult
    public func save() -> Bool {
        guard let url = fileURL else {
            return saveAs()
        }
        return write(to: url)
    }

    @discardableResult
    public func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "scm") ?? .plainText]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "untitled.scm"
        if panel.runModal() == .OK, let url = panel.url {
            return write(to: url)
        }
        return false
    }

    private func write(to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            fileURL = url
            isDirty = false
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    public func currentEvaluationSnippet() -> String? {
        let ns = text as NSString
        if selectedRange.length > 0 && selectedRange.location + selectedRange.length <= ns.length {
            let selected = ns.substring(with: selectedRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !selected.isEmpty {
                return selected
            }
        }
        return SchemeSyntaxHighlighter.enclosingTopLevelForm(
            in: text,
            utf16Offset: selectedRange.location
        )?.text
    }
}
