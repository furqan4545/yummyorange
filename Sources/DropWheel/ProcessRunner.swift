import Foundation

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ProcessRunner {
    /// Runs a tool to completion and captures its output. `onStdoutLine` sees stdout line by line as it arrives.
    @discardableResult
    static func run(_ tool: URL, _ args: [String], onStdoutLine: ((String) -> Void)? = nil) throws -> ProcessResult {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var outData = Data(), errData = Data()
        var lineBuffer = Data()
        let lock = NSLock()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); outData.append(chunk); lineBuffer.append(chunk)
            var lines: [String] = []
            while let nl = lineBuffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: lineBuffer[lineBuffer.startIndex..<nl], as: UTF8.self))
                lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            }
            lock.unlock()
            if let onStdoutLine { lines.forEach(onStdoutLine) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); errData.append(chunk); lock.unlock()
        }

        try process.run()
        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // Drain anything left after the handlers were removed.
        let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
        let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); outData.append(restOut); errData.append(restErr); lock.unlock()

        return ProcessResult(status: process.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self))
    }
}
