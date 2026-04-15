import Foundation
import Darwin

enum CrashReporter {
    private static let queue = DispatchQueue(label: "moly.crash.reporter")
    private static var runtimeLogURL: URL?
    private static var latestCrashURL: URL?
    private static var installed = false
    private static var crashFileDescriptor: Int32 = -1

    static func configure(exportRoot: URL) {
        queue.sync {
            let runtimeDirectory = exportRoot.appendingPathComponent("logs", isDirectory: true)
            let crashDirectory = exportRoot.appendingPathComponent("crash-reports", isDirectory: true)
            try? FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: crashDirectory, withIntermediateDirectories: true)

            runtimeLogURL = runtimeDirectory.appendingPathComponent("runtime.log")
            latestCrashURL = crashDirectory.appendingPathComponent("latest-crash.log")

            if crashFileDescriptor != -1 {
                close(crashFileDescriptor)
                crashFileDescriptor = -1
            }

            if let latestCrashURL {
                crashFileDescriptor = open(latestCrashURL.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
            }

            if !installed {
                installHandlers()
                installed = true
            }
        }
    }

    static func appendRuntime(_ line: String) {
        queue.async {
            guard let runtimeLogURL else { return }
            let payload = line + "\n"
            if FileManager.default.fileExists(atPath: runtimeLogURL.path) {
                if let handle = try? FileHandle(forWritingTo: runtimeLogURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(payload.utf8))
                }
            } else {
                try? payload.write(to: runtimeLogURL, atomically: true, encoding: .utf8)
            }
        }
    }

    static func latestCrashReportPath() -> String {
        queue.sync { latestCrashURL?.path ?? "-" }
    }

    private static func installHandlers() {
        NSSetUncaughtExceptionHandler(crashExceptionHandler)

        signal(SIGABRT, crashSignalHandler)
        signal(SIGILL, crashSignalHandler)
        signal(SIGSEGV, crashSignalHandler)
        signal(SIGBUS, crashSignalHandler)
        signal(SIGTRAP, crashSignalHandler)
    }

    static func handleFatalSignal(_ signal: Int32) {
        let name: String
        switch signal {
        case SIGABRT: name = "SIGABRT"
        case SIGILL: name = "SIGILL"
        case SIGSEGV: name = "SIGSEGV"
        case SIGBUS: name = "SIGBUS"
        case SIGTRAP: name = "SIGTRAP"
        default: name = "SIGNAL \(signal)"
        }

        let message = """
        Moly Context Hub received a fatal signal.
        Signal: \(name)
        Time: \(isoTimestamp())
        """
        writeCrashMessage(message)
    }

    static func handleObjectiveCException(name: String, reason: String) {
        let message = """
        Moly Context Hub encountered an uncaught Objective-C exception.
        Name: \(name)
        Reason: \(reason)
        Time: \(isoTimestamp())
        """
        writeCrashMessage(message)
    }

    private static func writeCrashMessage(_ message: String) {
        guard crashFileDescriptor != -1 else { return }
        let payload = "\n=== Crash Report ===\n\(message)\n"
        payload.utf8CString.withUnsafeBufferPointer { buffer in
            _ = Darwin.write(crashFileDescriptor, buffer.baseAddress, buffer.count - 1)
        }
    }

    private static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private let crashSignalHandler: @convention(c) (Int32) -> Void = { signalCode in
    CrashReporter.handleFatalSignal(signalCode)
    Darwin.signal(signalCode, SIG_DFL)
    raise(signalCode)
}

private let crashExceptionHandler: @convention(c) (NSException) -> Void = { exception in
    CrashReporter.handleObjectiveCException(
        name: exception.name.rawValue,
        reason: exception.reason ?? "Unknown reason"
    )
}
