import Foundation

@MainActor
public final class EdwinSession: ObservableObject {
    public let emulator: VT100Emulator

    @Published public private(set) var isRunning = false
    @Published public private(set) var revision: UInt64 = 0
    @Published public private(set) var exitCode: Int32?
    @Published public private(set) var errorMessage: String?

    private var process: PTYProcess?
    private var rows = 36
    private var cols = 100
    private var generation: UInt64 = 0

    public init(rows: Int = 36, cols: Int = 100) {
        self.rows = max(2, rows)
        self.cols = max(10, cols)
        self.emulator = VT100Emulator(rows: self.rows, cols: self.cols)
    }

    deinit {
        process?.terminate()
    }

    public func startIfNeeded(rows: Int? = nil, cols: Int? = nil, fileURL: URL? = nil) {
        if let rows, let cols {
            resize(rows: rows, cols: cols)
        }
        if let process, process.isRunning {
            return
        }
        start(fileURL: fileURL)
    }

    public func restart(rows: Int? = nil, cols: Int? = nil, fileURL: URL? = nil) {
        stop()
        if let rows, let cols {
            resize(rows: rows, cols: cols)
        }
        start(fileURL: fileURL)
    }

    public func start(fileURL: URL? = nil) {
        stop()
        generation &+= 1
        let myGen = generation
        exitCode = nil
        errorMessage = nil

        do {
            let config = try SchemeLocator.resolve(mode: .edwin(fileURL: fileURL))
            let pty = try PTYProcess(
                executableURL: config.executableURL,
                arguments: config.arguments,
                environment: config.environment,
                workingDirectory: config.workingDirectory,
                rows: rows,
                cols: cols,
                echo: true,
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
            self.isRunning = true
        } catch {
            self.isRunning = false
            self.errorMessage = error.localizedDescription
        }
    }

    public func stop() {
        generation &+= 1
        let old = process
        process = nil
        old?.terminate()
        isRunning = false
    }

    public func resize(rows newRows: Int, cols newCols: Int) {
        let r = max(2, newRows)
        let c = max(10, newCols)
        guard r != rows || c != cols else { return }
        rows = r
        cols = c
        emulator.resize(rows: r, cols: c)
        revision = emulator.dirtyRevision
        process?.resize(rows: r, cols: c)
    }

    public func sendBytes(_ data: Data) {
        process?.write(data)
    }

    public func sendText(_ string: String) {
        process?.write(string)
    }

    public func openFileInEdwin(_ url: URL) {
        if isRunning {
            // Send C-x C-f <path> RET into Edwin.
            var bytes = Data([0x18, 0x06])
            if let pathData = (url.path + "\r").data(using: .utf8) {
                bytes.append(pathData)
            }
            sendBytes(bytes)
        } else {
            start(fileURL: url)
        }
    }

    private func handleOutput(_ data: Data, generation gen: UInt64) {
        guard gen == generation else { return }
        emulator.feed(data)
        revision = emulator.dirtyRevision
    }

    private func handleExit(_ code: Int32, generation gen: UInt64) {
        guard gen == generation else { return }
        process = nil
        isRunning = false
        exitCode = code
    }
}
