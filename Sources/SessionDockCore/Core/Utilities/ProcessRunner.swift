import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let truncated: Bool
    public let duration: Duration
}

public enum ProcessRunnerError: LocalizedError {
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): "Could not start process: \(detail)"
        }
    }
}

/// Runs an external command with captured, size-limited output. Cancelling the
/// surrounding task terminates the child process.
public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration? = nil,
        outputLimit: Int = 2_000_000
    ) async throws -> ProcessResult {
        let handle = ProcessHandle()
        let clock = ContinuousClock()
        let started = clock.now

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = environment ?? ProcessInfo.processInfo.environment
                process.standardInput = FileHandle.nullDevice

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let stdoutBox = OutputBox(limit: outputLimit)
                let stderrBox = OutputBox(limit: outputLimit)
                // The result is delivered once the process has exited and both pipes reached end of file.
                // A grandchild that inherited the pipes can keep them open after the process exits, so
                // the wait for end of file is bounded by a grace period.
                let completion = Completion { status in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    handle.cancelTimer()
                    let out = stdoutBox.snapshot()
                    let err = stderrBox.snapshot()
                    continuation.resume(returning: ProcessResult(
                        exitCode: status,
                        stdout: out.text,
                        stderr: err.text,
                        timedOut: handle.didTimeOut,
                        truncated: out.truncated || err.truncated,
                        duration: clock.now - started
                    ))
                }
                stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                    let data = fileHandle.availableData
                    if data.isEmpty {
                        fileHandle.readabilityHandler = nil
                        completion.streamClosed()
                    } else {
                        stdoutBox.append(data)
                    }
                }
                stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                    let data = fileHandle.availableData
                    if data.isEmpty {
                        fileHandle.readabilityHandler = nil
                        completion.streamClosed()
                    } else {
                        stderrBox.append(data)
                    }
                }

                process.terminationHandler = { finished in
                    completion.exited(status: finished.terminationStatus)
                    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                        completion.forceFinish()
                    }
                }

                handle.process = process
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                    return
                }
                if let timeout {
                    handle.startTimer(timeout)
                }
                if Task.isCancelled { process.terminate() }
            }
        } onCancel: {
            handle.terminate()
        }
    }
}

private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var _process: Process?
    private var _timer: Task<Void, Never>?
    private var _timedOut = false

    var process: Process? {
        get { lock.withLock { _process } }
        set { lock.withLock { _process = newValue } }
    }

    var didTimeOut: Bool { lock.withLock { _timedOut } }

    func startTimer(_ timeout: Duration) {
        let task = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            let running = self.lock.withLock { () -> Process? in
                self._timedOut = true
                return self._process
            }
            if let running, running.isRunning { running.terminate() }
        }
        lock.withLock { _timer = task }
    }

    func cancelTimer() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            defer { _timer = nil }
            return _timer
        }
        task?.cancel()
    }

    func terminate() {
        let running = lock.withLock { _process }
        if let running, running.isRunning { running.terminate() }
    }
}

private final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var openStreams = 2
    private var finished = false
    private let deliver: @Sendable (Int32) -> Void

    init(deliver: @escaping @Sendable (Int32) -> Void) {
        self.deliver = deliver
    }

    func streamClosed() {
        update { openStreams -= 1 }
    }

    func exited(status: Int32) {
        update { self.status = status }
    }

    /// Delivers the result after the grace period even if a pipe is still held open.
    func forceFinish() {
        update { openStreams = 0 }
    }

    private func update(_ change: () -> Void) {
        let ready = lock.withLock { () -> Int32? in
            change()
            guard !finished, let status, openStreams <= 0 else { return nil }
            finished = true
            return status
        }
        if let ready { deliver(ready) }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.withLock {
            let remaining = limit - data.count
            if remaining <= 0 {
                truncated = truncated || !chunk.isEmpty
            } else if chunk.count > remaining {
                data.append(chunk.prefix(remaining))
                truncated = true
            } else {
                data.append(chunk)
            }
        }
    }

    func snapshot() -> (text: String, truncated: Bool) {
        lock.withLock {
            (String(decoding: data, as: UTF8.self), truncated)
        }
    }
}
