import XCTest
@testable import MITSchemeCore

@MainActor
final class SchemeIntegrationTests: XCTestCase {
    private func requireConfiguredScheme() throws {
        let exe = ProcessInfo.processInfo.environment["MIT_SCHEME_APP_EXE"]
        try XCTSkipUnless(
            exe != nil && FileManager.default.isExecutableFile(atPath: exe!),
            "Set MIT_SCHEME_APP_EXE to run live MIT/GNU Scheme PTY integration tests"
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 15,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    func testLiveREPLEvaluateCompileErrorRestartAndInterrupt() async throws {
        try requireConfiguredScheme()

        let repl = REPLSession()
        defer { repl.stop() }
        repl.start()

        let ready = await waitUntil {
            if case .ready = repl.status { return true }
            return false
        }
        XCTAssertTrue(ready, "REPL did not reach initial ready prompt; status=\(repl.status)")

        // 1. Evaluate arithmetic and native compile-procedure.
        repl.evaluate("(+ 20 22)")
        let evalDone = await waitUntil {
            if case .ready = repl.status { return repl.entries.contains { $0.text.contains("42") } }
            return false
        }
        XCTAssertTrue(evalDone, "Expected ;Value: 42 in transcript: \(repl.entries.map(\.text))")

        repl.evaluate("((compile-procedure (lambda (x) (* x x))) 12)")
        let compileDone = await waitUntil {
            if case .ready = repl.status { return repl.entries.contains { $0.text.contains("144") } }
            return false
        }
        XCTAssertTrue(compileDone, "Expected 144 from compiled procedure")

        // 2. Provoke debugger error & recover with restart 1.
        repl.evaluate("(car 1)")
        let inDebugger = await waitUntil {
            if case .debugger = repl.status { return true }
            return false
        }
        XCTAssertTrue(inDebugger, "Expected REPL debugger prompt; status=\(repl.status)")
        guard case let .debugger(_, restarts) = repl.status else {
            XCTFail("Expected debugger status")
            return
        }
        XCTAssertFalse(restarts.isEmpty, "Expected parsed restarts in debugger")
        repl.abortToTopLevel()
        let recovered = await waitUntil {
            repl.status == .ready(level: 1)
        }
        XCTAssertTrue(recovered, "Expected recovery to level 1 prompt; status=\(repl.status)")

        // 3. Interrupt an infinite loop.
        repl.evaluate("(let loop () (loop))")
        try? await Task.sleep(nanoseconds: 250_000_000)
        repl.interrupt()
        let interrupted = await waitUntil(timeout: 10) {
            repl.status == .ready(level: 1)
        }
        XCTAssertTrue(interrupted, "Expected interrupt to return to level 1 prompt; status=\(repl.status)")
    }

    func testLiveEdwinSessionRendersSchemeBufferInVT100() async throws {
        try requireConfiguredScheme()

        let edwin = EdwinSession(rows: 30, cols: 90)
        defer { edwin.stop() }
        edwin.startIfNeeded(rows: 30, cols: 90)

        let loaded = await waitUntil(timeout: 20) {
            let text = edwin.emulator.plainTextSnapshot()
            return text.contains("*scheme*")
        }
        XCTAssertTrue(
            loaded,
            "Edwin did not render *scheme* buffer; snapshot:\n\(edwin.emulator.plainTextSnapshot())"
        )

        // Exit Edwin cleanly via C-x C-c (confirming "Kill Scheme" prompt if enabled).
        edwin.sendBytes(Data([0x18, 0x03]))
        _ = await waitUntil(timeout: 5) {
            !edwin.isRunning || edwin.emulator.plainTextSnapshot().contains("Kill ")
        }
        if edwin.isRunning {
            edwin.sendText("yes\r")
        }
        let exited = await waitUntil(timeout: 8) { !edwin.isRunning }
        XCTAssertTrue(exited, "Edwin did not exit cleanly after C-x C-c")
    }
}
