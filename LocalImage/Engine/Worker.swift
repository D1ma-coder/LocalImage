import Foundation

/// One event from the Python worker (a JSON line on its event channel).
nonisolated enum WorkerEvent {
    case phase(String)
    case denoise(start: Int, total: Int, width: Int, height: Int)
    case step(step: Int, total: Int, elapsed: Double, paused: Double)
    case preview(step: Int, url: URL)
    case image(URL, seed: Int?, seconds: Double?)
    case done([String: Any])
    case cancelled
    case error(String)
    case log(String)
    case other(String, [String: Any])

    init(json: [String: Any]) {
        let name = json["event"] as? String ?? ""
        switch name {
        case "phase": self = .phase(json["phase"] as? String ?? "")
        case "denoise":
            self = .denoise(
                start: json["start"] as? Int ?? 0, total: json["total"] as? Int ?? 0,
                width: json["width"] as? Int ?? 0, height: json["height"] as? Int ?? 0)
        case "step":
            self = .step(
                step: json["step"] as? Int ?? 0, total: json["total"] as? Int ?? 0,
                elapsed: (json["elapsed"] as? NSNumber)?.doubleValue ?? 0,
                paused: (json["paused"] as? NSNumber)?.doubleValue ?? 0)
        case "preview":
            self = .preview(step: json["step"] as? Int ?? 0, url: URL(fileURLWithPath: json["path"] as? String ?? ""))
        case "image":
            self = .image(
                URL(fileURLWithPath: json["path"] as? String ?? ""), seed: json["seed"] as? Int,
                seconds: (json["seconds"] as? NSNumber)?.doubleValue)
        case "done": self = .done(json)
        case "cancelled": self = .cancelled
        case "error": self = .error(Self.errorText(json))
        case "log": self = .log(json["message"] as? String ?? "")
        default: self = .other(name, json)
        }
    }
}

/// A running worker process. Events are delivered on the main actor in order.
final class WorkerProcess {
    private let process = Process()
    private let events = Pipe()
    private let logs = Pipe()
    private(set) var logTail = TailBuffer(limit: 200)
    private var finished = false

    var isRunning: Bool { process.isRunning }

    /// Starts `python -I lix_worker.py <command> <json>`.
    static func start(
        command: String,
        payload: [String: Any],
        onEvent: @escaping @MainActor (WorkerEvent) -> Void,
        onLog: (@MainActor (String) -> Void)? = nil,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> WorkerProcess {
        guard let script = Paths.workerScript else {
            throw NSError(domain: "LocalImage", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Не найден скрипт движка в приложении")])
        }
        guard FileManager.default.isExecutableFile(atPath: Paths.python.path) else {
            throw NSError(domain: "LocalImage", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Движок не установлен")])
        }
        let worker = WorkerProcess()
        let json = try JSONSerialization.data(withJSONObject: payload)
        worker.process.executableURL = Paths.python
        worker.process.arguments = ["-I", script.path, command, String(decoding: json, as: UTF8.self)]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["TQDM_DISABLE"] = "0"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        if let token = TokenStore.load() { env["HF_TOKEN"] = token }
        worker.process.environment = env
        worker.process.standardOutput = worker.events
        worker.process.standardError = worker.logs
        worker.process.standardInput = FileHandle.nullDevice

        let eventLines = LineBuffer()
        worker.events.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for line in eventLines.append(chunk) {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let event = WorkerEvent(json: object)
                Task { @MainActor in onEvent(event) }
            }
        }
        let logLines = LineBuffer()
        let tail = worker.logTail
        worker.logs.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            // tqdm redraws with \r; keep the last segment of each line.
            let text = String(decoding: chunk, as: UTF8.self).replacingOccurrences(of: "\r", with: "\n")
            for line in logLines.append(Data(text.utf8)) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                if line.hasPrefix("W1") && line.contains("Redirects are currently not supported") { continue }
                tail.add(line)
                if let onLog { Task { @MainActor in onLog(line) } }
            }
        }
        worker.process.terminationHandler = { proc in
            let status = proc.terminationStatus
            // Drain whatever is left before reporting the exit.
            let rest = worker.events.fileHandleForReading.readDataToEndOfFile()
            worker.events.fileHandleForReading.readabilityHandler = nil
            worker.logs.fileHandleForReading.readabilityHandler = nil
            var finalEvents: [WorkerEvent] = []
            for line in eventLines.append(rest) + [eventLines.flush()].compactMap({ $0 }) {
                if let data = line.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    finalEvents.append(WorkerEvent(json: object))
                }
            }
            Task { @MainActor in
                for event in finalEvents { onEvent(event) }
                onExit(status)
            }
        }
        try worker.process.run()
        return worker
    }

    /// Graceful stop: the worker turns SIGINT into a clean cancellation.
    func cancel() {
        guard process.isRunning else { return }
        process.interrupt()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.process.isRunning, self.process.processIdentifier == pid else { return }
            self.process.terminate()
        }
    }

    /// Immediate stop: SIGKILL. The OS frees all of the worker's unified memory at once;
    /// nothing in a generating worker needs a graceful shutdown.
    func forceKill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    func kill() {
        guard process.isRunning else { return }
        process.terminate()
    }
}

/// Convenience: run a worker command to completion and collect its events.
enum WorkerCall {
    static func run(command: String, payload: [String: Any] = [:]) async throws -> [WorkerEvent] {
        try await withCheckedThrowingContinuation { continuation in
            var collected: [WorkerEvent] = []
            var holder: WorkerProcess?
            do {
                holder = try WorkerProcess.start(
                    command: command, payload: payload,
                    onEvent: { collected.append($0) },
                    onExit: { status in
                        if status == 0 {
                            continuation.resume(returning: collected)
                        } else {
                            let message = collected.compactMap { event -> String? in
                                if case .error(let text) = event { return text }
                                return nil
                            }.last ?? (holder?.logTail.text ?? String(localized: "Код выхода \(status)"))
                            continuation.resume(throwing: NSError(
                                domain: "LocalImage", code: Int(status),
                                userInfo: [NSLocalizedDescriptionKey: message]))
                        }
                        holder = nil
                    })
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}


extension WorkerEvent {
    /// The worker sends an error code plus an English message; the text the user sees is localized here.
    nonisolated static func errorText(_ json: [String: Any]) -> String {
        let message = json["message"] as? String ?? ""
        let params = json["params"] as? [String: Any] ?? [:]
        switch json["code"] as? String {
        case "unsupported_family":
            let family = params["family"] as? String ?? "?"
            return String(localized: "Семейство модели «\(family)» не поддерживается")
        case "generation_rejected": return String(localized: "mflux отклонил параметры генерации (подробности в журнале)")
        case "no_image": return String(localized: "Генерация завершилась без изображения (подробности в журнале)")
        case "save_failed": return String(localized: "mflux не смог сохранить модель (подробности в журнале)")
        case "out_of_memory":
            return String(localized: "Не хватило памяти. Попробуйте меньшее разрешение, режим экономии памяти или более сильное квантование.") + "\n" + message
        default: return message.isEmpty ? String(localized: "Неизвестная ошибка") : message
        }
    }
}
