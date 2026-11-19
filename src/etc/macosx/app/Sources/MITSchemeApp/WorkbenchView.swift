import MITSchemeCore
import SwiftUI

public enum WorkbenchMode: String, CaseIterable, Identifiable {
    case workbench = "Workbench"
    case edwin = "Edwin"

    public var id: String { rawValue }
}

@MainActor
public final class AppModel: ObservableObject {
    public let document = DocumentState()
    public let repl = REPLSession()
    public let edwin = EdwinSession()

    @Published public var mode: WorkbenchMode = .workbench
    @Published public var fontSize: CGFloat = 13.5
    @Published public var optionAsMeta: Bool = true

    public init() {
        repl.start()
    }

    public func evaluateCurrentForm() {
        if mode != .workbench {
            mode = .workbench
        }
        if let snippet = document.currentEvaluationSnippet() {
            repl.evaluate(snippet)
        }
    }

    public func evaluateBuffer() {
        if mode != .workbench {
            mode = .workbench
        }
        let code = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        repl.evaluate(code)
    }

    public func openExternalFiles(_ urls: [URL]) {
        guard let first = urls.first else { return }
        document.openFile(first)
        if mode == .edwin {
            edwin.openFileInEdwin(first)
        }
    }

    public func openCurrentFileInEdwin() {
        mode = .edwin
        if let url = document.fileURL {
            edwin.openFileInEdwin(url)
        }
    }

    public func shutdown() {
        repl.stop()
        edwin.stop()
    }
}

struct WorkbenchView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var document: DocumentState
    @ObservedObject var repl: REPLSession
    @ObservedObject var edwin: EdwinSession

    init(model: AppModel) {
        self.model = model
        self.document = model.document
        self.repl = model.repl
        self.edwin = model.edwin
    }

    var body: some View {
        VStack(spacing: 0) {
            contentArea
            Divider()
            statusFooter
        }
        .frame(minWidth: 880, minHeight: 560)
        .navigationTitle(windowTitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(WorkbenchMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if model.mode == .workbench {
                    Button {
                        model.evaluateCurrentForm()
                    } label: {
                        Label("Run Form", systemImage: "play.fill")
                    }
                    .help("Evaluate form at cursor or selection (⌘↩)")

                    Button {
                        model.evaluateBuffer()
                    } label: {
                        Label("Run Buffer", systemImage: "play.rectangle.on.rectangle")
                    }
                    .help("Evaluate entire buffer (⌘⇧↩)")

                    Button {
                        repl.interrupt()
                    } label: {
                        Label("Interrupt", systemImage: "stop.circle")
                    }
                    .disabled(repl.status != .evaluating)
                    .help("Interrupt running evaluation (⌘.)")

                    Button {
                        repl.restart()
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    .help("Restart Scheme REPL")
                } else {
                    Toggle("Opt as Meta", isOn: $model.optionAsMeta)
                        .toggleStyle(.checkbox)
                        .help("Send ESC prefix when holding Option key in Edwin")

                    Button {
                        edwin.restart()
                    } label: {
                        Label("Restart Edwin", systemImage: "arrow.clockwise")
                    }
                    .help("Restart integrated Edwin session")
                }

                Divider()

                Button {
                    document.openPanel()
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .help("Open Scheme file (⌘O)")

                Button {
                    _ = document.save()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .help("Save Scheme file (⌘S)")

                Divider()

                Button {
                    model.fontSize = max(10, model.fontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .help("Decrease Font Size (⌘-)")

                Button {
                    model.fontSize = min(24, model.fontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .help("Increase Font Size (⌘+)")
            }
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        switch model.mode {
        case .workbench:
            HSplitView {
                SchemeEditorView(
                    text: Binding(
                        get: { document.text },
                        set: { document.updateTextFromEditor($0) }
                    ),
                    fontSize: model.fontSize,
                    onSelectionChange: { document.updateSelection($0) },
                    onEvaluateCurrent: { model.evaluateCurrentForm() },
                    onEvaluateBuffer: { model.evaluateBuffer() }
                )
                .frame(minWidth: 320, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

                REPLView(session: repl, fontSize: model.fontSize)
                    .frame(minWidth: 320, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }

        case .edwin:
            VStack(spacing: 0) {
                TerminalView(
                    session: edwin,
                    revision: edwin.revision,
                    fontSize: model.fontSize,
                    optionAsMeta: model.optionAsMeta
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let code = edwin.exitCode, !edwin.isRunning {
                    HStack {
                        Text("Edwin exited with status \(code).")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Restart Edwin") {
                            edwin.restart()
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor))
                }
            }
        }
    }

    private var statusFooter: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(model.mode == .workbench ? repl.status.label : (edwin.isRunning ? "Edwin Active" : "Edwin Stopped"))
                .font(.system(size: 11, weight: .medium))

            Divider().frame(height: 12)

            if model.mode == .workbench {
                Text("\(document.displayName)\(document.isDirty ? " •" : "")")
                    .font(.system(size: 11))
                    .lineLimit(1)
                Text("Ln \(document.cursorLine), Col \(document.cursorColumn)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("VT100 \(edwin.emulator.rows)×\(edwin.emulator.cols)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("C-x C-c exits · Opt=Meta \(model.optionAsMeta ? "On" : "Off")")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let err = document.lastErrorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .lineLimit(1)
            }

            Text(repl.runtimeSummary)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusColor: Color {
        if model.mode == .edwin {
            return edwin.isRunning ? .green : .orange
        }
        switch repl.status {
        case .ready: return .green
        case .evaluating, .starting: return .blue
        case .debugger: return .orange
        case .stopped, .exited: return .red
        }
    }

    private var windowTitle: String {
        let dirty = document.isDirty ? " — Edited" : ""
        return "\(document.displayName)\(dirty) — MIT/GNU Scheme"
    }
}
