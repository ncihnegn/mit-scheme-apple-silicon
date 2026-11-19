import Foundation

public struct REPLRestartOption: Identifiable, Equatable, Sendable {
    public let number: Int
    public let description: String

    public var id: Int { number }

    public init(number: Int, description: String) {
        self.number = number
        self.description = description
    }
}

public struct REPLPrompt: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case normal
        case debugger
    }

    public let level: Int
    public let kind: Kind

    public init(level: Int, kind: Kind) {
        self.level = level
        self.kind = kind
    }
}

public enum REPLStatus: Equatable, Sendable {
    case stopped
    case starting
    case ready(level: Int)
    case evaluating
    case debugger(level: Int, restarts: [REPLRestartOption])
    case exited(code: Int32)

    public var label: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting…"
        case let .ready(level):
            return level <= 1 ? "Ready" : "Level \(level)"
        case .evaluating:
            return "Evaluating…"
        case let .debugger(level, _):
            return "Debugger (Lv.\(level))"
        case let .exited(code):
            return "Exited (\(code))"
        }
    }

    public var canEvaluate: Bool {
        switch self {
        case .ready, .debugger:
            return true
        default:
            return false
        }
    }
}

public struct REPLTranscriptEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case banner
        case input
        case output
        case error
        case system
    }

    public let id: UUID
    public let kind: Kind
    public let text: String
    public let timestamp: Date

    public init(id: UUID = UUID(), kind: Kind, text: String, timestamp: Date = Date()) {
        self.id = id
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
    }
}

public enum REPLOutputParser {
    private static let ansiRegex = try! NSRegularExpression(
        pattern: #"\x1B(?:\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_])"#
    )
    private static let promptRegex = try! NSRegularExpression(
        pattern: #"(?:^|\n)([0-9]+)\s+(\]=>|error>)[ \t]*$"#
    )
    private static let restartRegex = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*;?\s*\(RESTART\s+([0-9]+)\)\s*=>\s*(.+?)\s*$"#
    )
    private static let releaseRegex = try! NSRegularExpression(
        pattern: #"Release\s+([^\|\r\n]+?)(?:\s*\|\|\s*([^\r\n]+))?\s*$"#,
        options: [.anchorsMatchLines]
    )

    public static func stripANSI(_ input: String) -> String {
        let noCR = input.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "")
        let range = NSRange(noCR.startIndex..<noCR.endIndex, in: noCR)
        return ansiRegex.stringByReplacingMatches(in: noCR, range: range, withTemplate: "")
    }

    public static func extractPromptSplit(
        in cleanBuffer: String
    ) -> (body: String, prompt: REPLPrompt)? {
        let ns = cleanBuffer as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        guard let match = promptRegex.firstMatch(in: cleanBuffer, range: fullRange) else {
            return nil
        }
        let levelStr = ns.substring(with: match.range(at: 1))
        let kindStr = ns.substring(with: match.range(at: 2))
        guard let level = Int(levelStr) else { return nil }
        let kind: REPLPrompt.Kind = (kindStr == "error>") ? .debugger : .normal

        let bodyRaw = ns.substring(to: match.range.location)
        let body = bodyRaw.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        return (body, REPLPrompt(level: level, kind: kind))
    }

    public static func parseRestarts(in text: String) -> [REPLRestartOption] {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return restartRegex.matches(in: text, range: range).compactMap { m in
            guard let num = Int(ns.substring(with: m.range(at: 1))) else { return nil }
            let desc = ns.substring(with: m.range(at: 2))
            return REPLRestartOption(number: num, description: desc)
        }
    }

    public static func parseBannerSummary(in text: String) -> String? {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = releaseRegex.firstMatch(in: text, range: range) else { return nil }
        let ver = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        if m.range(at: 2).location != NSNotFound {
            let arch = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            return "MIT/GNU Scheme \(ver) · \(arch)"
        }
        return "MIT/GNU Scheme \(ver)"
    }
}

@MainActor
public final class REPLSession: ObservableObject {
    @Published public private(set) var entries: [REPLTranscriptEntry] = []
    @Published public private(set) var liveOutput: String = ""
    @Published public private(set) var status: REPLStatus = .stopped
    @Published public private(set) var history: [String] = []
    @Published public private(set) var launchSummary: String = ""
    @Published public private(set) var runtimeSummary: String = "MIT/GNU Scheme"
    @Published public private(set) var currentPromptText: String = "1 ]=>"

    private var process: PTYProcess?
    private var pendingBuffer: String = ""
    private var sawInitialPrompt = false
    private var generation: UInt64 = 0

    public init() {}

    deinit {
        process?.terminate()
    }

    public func start() {
        if let process, process.isRunning {
            return
        }
        stop()

        generation &+= 1
        let myGen = generation
        pendingBuffer = ""
        liveOutput = ""
        sawInitialPrompt = false
        currentPromptText = "1 ]=>"
        status = .starting

        do {
            let config = try SchemeLocator.resolve(mode: .repl)
            launchSummary = config.sourceDescription
            let pty = try PTYProcess(
                executableURL: config.executableURL,
                arguments: config.arguments,
                environment: config.environment,
                workingDirectory: config.workingDirectory,
                rows: 40,
                cols: 100,
                echo: false,
                onOutput: { [weak self] data in
                    Task { @MainActor [weak self] in
                        self?.handleOutput(data, generation: myGen)
                    }
                },
                onExit: { [weak self] code in
                    Task { @MainActor [weak self] in
                        self?.handleExit(code, generation: myGen)
                    }
                }
            )
            self.process = pty
        } catch {
            status = .stopped
            entries.append(
                REPLTranscriptEntry(kind: .error, text: "Failed to start Scheme: \(error.localizedDescription)")
            )
        }
    }

    public func restart() {
        entries.append(REPLTranscriptEntry(kind: .system, text: "Restarting Scheme session…"))
        stop()
        start()
    }

    public func stop() {
        generation &+= 1
        let old = process
        process = nil
        old?.terminate()
        pendingBuffer = ""
        liveOutput = ""
        status = .stopped
    }

    public func clearTranscript() {
        entries.removeAll()
        liveOutput = ""
    }

    public func evaluate(_ rawCode: String) {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }

        if process == nil || !(process?.isRunning ?? false) {
            start()
        }
        guard let process, process.isRunning else { return }

        if history.last != code {
            history.append(code)
            if history.count > 200 {
                history.removeFirst(history.count - 200)
            }
        }

        entries.append(REPLTranscriptEntry(kind: .input, text: code))
        status = .evaluating

        let exactPayload = code.hasSuffix("\n") ? code : (code + "\n")
        process.write(exactPayload)
    }

    public func loadFile(_ url: URL) {
        let escaped = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        evaluate("(load \"\(escaped)\")")
    }

    public func invokeRestart(_ number: Int) {
        evaluate("(restart \(number))")
    }

    public func abortToTopLevel() {
        if case let .debugger(_, restarts) = status,
           let top = restarts.first(where: { $0.description.localizedCaseInsensitiveContains("level 1") }) {
            invokeRestart(top.number)
            return
        }
        interrupt()
    }

    public func interrupt() {
        guard let process, process.isRunning else { return }
        let myGen = generation
        process.sendInterrupt()
        // Follow SIGINT with 'g' so ux_sig's interactive raw prompt aborts to top level.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 35_000_000)
            guard let self, self.generation == myGen, let proc = self.process, proc.isRunning else { return }
            proc.write("g")
        }
    }

    private func handleOutput(_ data: Data, generation gen: UInt64) {
        guard gen == generation else { return }
        let decoded = String(decoding: data, as: UTF8.self)
        pendingBuffer += REPLOutputParser.stripANSI(decoded)

        if let split = REPLOutputParser.extractPromptSplit(in: pendingBuffer) {
            pendingBuffer = ""
            liveOutput = ""
            let body = split.body
            let prompt = split.prompt

            if !sawInitialPrompt {
                sawInitialPrompt = true
                if !body.isEmpty {
                    entries.append(REPLTranscriptEntry(kind: .banner, text: body))
                    if let summary = REPLOutputParser.parseBannerSummary(in: body) {
                        runtimeSummary = summary
                    }
                }
            } else if !body.isEmpty {
                let kind: REPLTranscriptEntry.Kind = (prompt.kind == .debugger) ? .error : .output
                entries.append(REPLTranscriptEntry(kind: kind, text: body))
            }

            switch prompt.kind {
            case .normal:
                currentPromptText = "\(prompt.level) ]=>"
                status = .ready(level: prompt.level)
            case .debugger:
                currentPromptText = "\(prompt.level) error>"
                let restarts = REPLOutputParser.parseRestarts(in: body)
                status = .debugger(level: prompt.level, restarts: restarts)
            }
        } else {
            let trimmed = pendingBuffer.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            liveOutput = trimmed
        }
    }

    private func handleExit(_ code: Int32, generation gen: UInt64) {
        guard gen == generation else { return }
        if !pendingBuffer.isEmpty {
            let residual = pendingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !residual.isEmpty {
                entries.append(REPLTranscriptEntry(kind: .output, text: residual))
            }
            pendingBuffer = ""
        }
        liveOutput = ""
        process = nil
        status = .exited(code: code)
        entries.append(REPLTranscriptEntry(kind: .system, text: "Scheme exited with status \(code)."))
    }
}
