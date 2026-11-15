import Foundation

// MARK: - Hugging Face token (plain file, mode 600 — no Keychain)

nonisolated enum TokenStore {
    static var fileURL: URL { Paths.appSupport.appendingPathComponent("hf_token") }

    static func load() -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    static func save(_ token: String?) {
        guard let token, !token.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        Paths.ensure(Paths.appSupport)
        // Create the file owner-only before writing the secret into it.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? Data(token.utf8).write(to: fileURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

// MARK: - Formatting

nonisolated enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func gb(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f ГБ", value) : String(format: "%.0f ГБ", value)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/с"
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 60 { return String(format: "%.0f с", seconds) }
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes) мин \(Int(seconds) % 60) с" }
        return "\(minutes / 60) ч \(minutes % 60) мин"
    }

    static func count(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1e6) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1e3) }
        return "\(value)"
    }

    static func bits(_ bits: Int?) -> String {
        guard let bits, bits < 16 else { return "BF16" }
        return "\(bits)-бит"
    }
}

// MARK: - Glob matching (fnmatch semantics, like huggingface_hub allow_patterns)

nonisolated enum Glob {
    static func matches(_ path: String, _ pattern: String) -> Bool {
        var regex = "^"
        for char in pattern {
            switch char {
            case "*": regex += ".*"
            case "?": regex += "."
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\": regex += "\\\(char)"
            default: regex.append(char)
            }
        }
        regex += "$"
        regex = regex.replacingOccurrences(of: ".*.*", with: ".*")
        return path.range(of: regex, options: .regularExpression) != nil
    }

    static func matchesAny(_ path: String, _ patterns: [String]) -> Bool {
        patterns.contains { matches(path, $0) }
    }
}

// MARK: - Process helpers

/// Thread-safe line splitter for process output pipes.
nonisolated final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        var lines: [String] = []
        while let range = data.firstRange(of: Data([0x0A])) {
            let lineData = data.subdata(in: data.startIndex..<range.lowerBound)
            data.removeSubrange(data.startIndex...range.lowerBound)
            lines.append(String(decoding: lineData, as: UTF8.self))
        }
        return lines
    }

    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty else { return nil }
        defer { data.removeAll() }
        return String(decoding: data, as: UTF8.self)
    }
}

enum ProcessRunner {
    struct Failure: LocalizedError {
        let status: Int32
        let tail: String
        var errorDescription: String? { "Процесс завершился с кодом \(status).\n\(tail)" }
    }

    /// Runs a command, streaming every output line (stdout + stderr) to `onLine` on the main actor.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String] = [:],
        onLine: @escaping @MainActor (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = LineBuffer()
        let tail = TailBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for line in buffer.append(chunk) {
                tail.add(line)
                Task { @MainActor in onLine(line) }
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { proc in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if let rest = buffer.flush() { tail.add(rest) }
                    if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: Failure(status: proc.terminationStatus, tail: tail.text))
                    }
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.interrupt() }
        }
    }
}

nonisolated final class TailBuffer: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()
    private let limit: Int

    init(limit: Int = 30) { self.limit = limit }

    func add(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
