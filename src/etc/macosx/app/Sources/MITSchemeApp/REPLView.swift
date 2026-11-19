import AppKit
import MITSchemeCore
import SwiftUI

struct REPLView: View {
    @ObservedObject var session: REPLSession
    var fontSize: CGFloat

    @State private var inputText: String = ""
    @State private var historyIndex: Int? = nil
    @State private var draftInput: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(session.entries) { entry in
                            transcriptRow(entry)
                                .id(entry.id)
                        }
                        if !session.liveOutput.isEmpty {
                            Text(session.liveOutput)
                                .font(.system(size: fontSize, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .id("LIVE_TAIL")
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("BOTTOM_ANCHOR")
                    }
                    .padding(.vertical, 8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: session.entries.count) { _ in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                    }
                }
                .onChange(of: session.liveOutput) { _ in
                    proxy.scrollTo("BOTTOM_ANCHOR", anchor: .bottom)
                }
            }

            if case let .debugger(level, restarts) = session.status {
                debuggerBar(level: level, restarts: restarts)
            }

            Divider()

            promptInputBar
        }
    }

    @ViewBuilder
    private func transcriptRow(_ entry: REPLTranscriptEntry) -> some View {
        switch entry.kind {
        case .banner:
            Text(entry.text)
                .font(.system(size: max(11, fontSize - 1), design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))

        case .input:
            HStack(alignment: .top, spacing: 6) {
                Text("λ>")
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundColor(.accentColor)
                Text(entry.text)
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

        case .output:
            Text(entry.text)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)

        case .error:
            Text(entry.text)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.08))

        case .system:
            Text(entry.text)
                .font(.system(size: max(11, fontSize - 1), design: .monospaced))
                .italic()
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
        }
    }

    private func debuggerBar(level: Int, restarts: [REPLRestartOption]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Condition / Debugger (Level \(level))")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Abort to Top Level") {
                    session.abortToTopLevel()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
            }

            if !restarts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(restarts) { option in
                            Button("Restart \(option.number): \(option.description)") {
                                session.invokeRestart(option.number)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(option.description)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    private var promptInputBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(session.currentPromptText)
                .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                .foregroundColor(isDebugger ? .orange : .accentColor)
                .padding(.top, 7)

            REPLInputTextView(
                text: $inputText,
                fontSize: fontSize,
                onSubmit: submitInput,
                onHistoryPrevious: navigateHistoryPrevious,
                onHistoryNext: navigateHistoryNext,
                onClear: { session.clearTranscript() }
            )
            .frame(minHeight: 34, maxHeight: 110)

            VStack(spacing: 4) {
                Button {
                    submitInput()
                } label: {
                    Image(systemName: "return")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Evaluate expression (Return when balanced)")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var isDebugger: Bool {
        if case .debugger = session.status { return true }
        return false
    }

    private func submitInput() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.evaluate(trimmed)
        inputText = ""
        historyIndex = nil
        draftInput = ""
    }

    private func navigateHistoryPrevious() {
        guard !session.history.isEmpty else { return }
        if let current = historyIndex {
            let nextIdx = max(0, current - 1)
            historyIndex = nextIdx
            inputText = session.history[nextIdx]
        } else {
            draftInput = inputText
            let lastIdx = session.history.count - 1
            historyIndex = lastIdx
            inputText = session.history[lastIdx]
        }
    }

    private func navigateHistoryNext() {
        guard let current = historyIndex else { return }
        let nextIdx = current + 1
        if nextIdx < session.history.count {
            historyIndex = nextIdx
            inputText = session.history[nextIdx]
        } else {
            historyIndex = nil
            inputText = draftInput
        }
    }
}

struct REPLInputTextView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var onSubmit: () -> Void
    var onHistoryPrevious: () -> Void
    var onHistoryNext: () -> Void
    var onClear: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true

        let tv = InputNSTextView()
        tv.coordinator = context.coordinator
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.allowsUndo = true
        tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.textColor = NSColor.labelColor
        tv.textContainerInset = NSSize(width: 4, height: 5)
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]

        scrollView.documentView = tv
        context.coordinator.textView = tv
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scrollView.documentView as? NSTextView else { return }
        let targetFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if tv.font?.pointSize != targetFont.pointSize {
            tv.font = targetFont
        }
        if tv.string != text {
            tv.string = text
            let end = (text as NSString).length
            tv.setSelectedRange(NSRange(location: end, length: 0))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: REPLInputTextView
        weak var textView: InputNSTextView?

        init(_ parent: REPLInputTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }

    final class InputNSTextView: NSTextView {
        weak var coordinator: Coordinator?

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Cmd+K clears the REPL transcript.
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "k" {
                coordinator?.parent.onClear()
                return
            }

            // Return submits when Scheme expression is balanced (unless Shift is held).
            if event.keyCode == 36 || event.keyCode == 76 {
                if flags.contains(.shift) {
                    insertNewline(nil)
                    return
                }
                if flags.isEmpty {
                    let current = string
                    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && SchemeSyntaxHighlighter.isBalanced(current) {
                        coordinator?.parent.onSubmit()
                        return
                    }
                }
            }

            // Up/Down navigate command history when cursor is on first/last line.
            if event.keyCode == 126 && flags.intersection([.command, .option, .control]).isEmpty {
                let ns = string as NSString
                let loc = min(selectedRange().location, ns.length)
                let before = ns.substring(to: loc)
                if !before.contains("\n") {
                    coordinator?.parent.onHistoryPrevious()
                    return
                }
            }
            if event.keyCode == 125 && flags.intersection([.command, .option, .control]).isEmpty {
                let ns = string as NSString
                let loc = min(selectedRange().location, ns.length)
                let after = ns.substring(from: loc)
                if !after.contains("\n") {
                    coordinator?.parent.onHistoryNext()
                    return
                }
            }

            super.keyDown(with: event)
        }
    }
}
