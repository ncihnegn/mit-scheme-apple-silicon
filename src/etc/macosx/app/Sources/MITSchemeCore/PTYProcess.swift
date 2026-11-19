import CPTYSpawn
import Darwin
import Dispatch
import Foundation

public enum PTYProcessError: LocalizedError, Sendable {
    case openPTYFailed(Int32)
    case forkFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case let .openPTYFailed(code):
            return "openpty failed: \(String(cString: strerror(code))) (\(code))"
        case let .forkFailed(code):
            return "fork failed: \(String(cString: strerror(code))) (\(code))"
        }
    }
}

public final class PTYProcess: @unchecked Sendable {
    private let stateLock = NSLock()
    private let ioQueue = DispatchQueue(label: "org.gnu.mit-scheme.pty-io", qos: .userInitiated)

    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var processSource: DispatchSourceProcess?
    private var exited = false

    private let onOutput: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32) -> Void

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL? = nil,
        rows: Int = 24,
        cols: Int = 80,
        echo: Bool = true,
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        self.onOutput = onOutput
        self.onExit = onExit

        // Pre-allocate C strings before spawning so child touches zero Swift/ObjC runtime.
        let fullArgs = [executableURL.path] + arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = fullArgs.map { strdup($0) }
        cArgs.append(nil)

        let envStrings = environment.map { "\($0.key)=\($0.value)" }
        var cEnv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
        cEnv.append(nil)

        let cExe = strdup(executableURL.path)
        let cCwd: UnsafeMutablePointer<CChar>? = workingDirectory.flatMap { strdup($0.path) }

        defer {
            for ptr in cArgs {
                if let ptr { free(ptr) }
            }
            for ptr in cEnv {
                if let ptr { free(ptr) }
            }
            if let cExe { free(cExe) }
            if let cCwd { free(cCwd) }
        }

        var master: Int32 = -1
        var pid: pid_t = -1
        var spawnErrno: Int32 = 0
        let rc = cArgs.withUnsafeMutableBufferPointer { argBuf in
            cEnv.withUnsafeMutableBufferPointer { envBuf in
                mit_scheme_pty_spawn(
                    cExe,
                    argBuf.baseAddress,
                    envBuf.baseAddress,
                    cCwd,
                    Int32(clamping: rows),
                    Int32(clamping: cols),
                    echo ? 1 : 0,
                    &master,
                    &pid,
                    &spawnErrno
                )
            }
        }
        if rc == -1 {
            throw PTYProcessError.openPTYFailed(spawnErrno)
        } else if rc != 0 {
            throw PTYProcessError.forkFailed(spawnErrno)
        }

        self.masterFD = master
        self.childPID = pid

        startMonitoring(master: master, pid: pid)
    }

    deinit {
        terminate()
    }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !exited && childPID > 0
    }

    public func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let fd = self.masterFD
            self.stateLock.unlock()
            guard fd >= 0 else { return }

            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var offset = 0
                let count = rawBuffer.count
                var retries = 0
                while offset < count {
                    let written = Darwin.write(fd, base.advanced(by: offset), count - offset)
                    if written > 0 {
                        offset += written
                        retries = 0
                    } else if errno == EAGAIN || errno == EINTR {
                        retries += 1
                        if retries > 500 {
                            break
                        }
                        usleep(1000)
                    } else {
                        break
                    }
                }
            }
        }
    }

    public func resize(rows: Int, cols: Int) {
        let clampedRows = UInt16(clamping: max(1, min(rows, 500)))
        let clampedCols = UInt16(clamping: max(1, min(cols, 500)))
        stateLock.lock()
        let fd = masterFD
        let pid = childPID
        let alive = !exited
        stateLock.unlock()
        guard alive, fd >= 0 else { return }

        var ws = winsize(ws_row: clampedRows, ws_col: clampedCols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, UInt(TIOCSWINSZ), &ws)
        if pid > 0 {
            _ = kill(-pid, SIGWINCH)
        }
    }

    public func sendInterrupt() {
        stateLock.lock()
        let pid = childPID
        let alive = !exited
        stateLock.unlock()
        guard alive, pid > 0 else { return }
        _ = kill(-pid, SIGINT)
    }

    public func terminate() {
        stateLock.lock()
        let pid = childPID
        let alreadyExited = exited
        let rSource = readSource
        let pSource = processSource
        readSource = nil
        processSource = nil
        masterFD = -1
        exited = true
        stateLock.unlock()

        rSource?.cancel()
        pSource?.cancel()

        if pid > 0 && !alreadyExited {
            _ = kill(-pid, SIGTERM)
            var status: Int32 = 0
            var reaped = false
            for _ in 0..<20 {
                let res = waitpid(pid, &status, WNOHANG)
                if res == pid || (res < 0 && errno == ECHILD) {
                    reaped = true
                    break
                }
                usleep(10_000)
            }
            if !reaped {
                _ = kill(-pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
            }
        }
    }

    private func startMonitoring(master: Int32, pid: pid_t) {
        let rSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: ioQueue)
        rSource.setEventHandler { [weak self] in
            self?.drainAvailableBytes()
        }
        rSource.setCancelHandler {
            Darwin.close(master)
        }

        let pSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: ioQueue)
        pSource.setEventHandler { [weak self] in
            self?.handleProcessExit()
        }

        stateLock.lock()
        self.readSource = rSource
        self.processSource = pSource
        stateLock.unlock()

        rSource.resume()
        pSource.resume()
    }

    private func drainAvailableBytes() {
        stateLock.lock()
        let fd = masterFD
        stateLock.unlock()
        guard fd >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                onOutput(Data(buffer[0..<n]))
            } else if n == 0 {
                handleProcessExit()
                break
            } else if errno == EAGAIN || errno == EINTR {
                break
            } else {
                handleProcessExit()
                break
            }
        }
    }

    private func handleProcessExit() {
        // Drain any remaining unread bytes before closing the master FD.
        stateLock.lock()
        let fd = masterFD
        stateLock.unlock()
        if fd >= 0 {
            var tailBuffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = Darwin.read(fd, &tailBuffer, tailBuffer.count)
                if n > 0 {
                    onOutput(Data(tailBuffer[0..<n]))
                } else {
                    break
                }
            }
        }

        stateLock.lock()
        if exited {
            stateLock.unlock()
            return
        }
        exited = true
        let pid = childPID
        masterFD = -1
        let rSource = readSource
        let pSource = processSource
        readSource = nil
        processSource = nil
        stateLock.unlock()

        rSource?.cancel()
        pSource?.cancel()

        var status: Int32 = 0
        if pid > 0 {
            _ = waitpid(pid, &status, 0)
        }
        let code: Int32
        if (status & 0x7f) == 0 {
            code = (status >> 8) & 0xff
        } else {
            code = 128 + (status & 0x7f)
        }
        onExit(code)
    }
}
