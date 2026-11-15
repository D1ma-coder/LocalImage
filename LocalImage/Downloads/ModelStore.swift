import Foundation
import Observation

nonisolated struct InstalledModel: Codable, Identifiable, Hashable {
    enum Status: String, Codable { case queued, downloading, paused, quantizing, ready, failed }

    var id: String
    var title: String
    var repo: String
    var revision: String
    var family: String
    var prebuilt: Bool
    var prebuiltBits: Int?
    /// Target bit widths for local quantization of an original checkpoint (nil = keep BF16).
    var textBits: Int?
    var imageBits: Int?
    var keepSource: Bool
    var files: [HFFile]
    var status: Status
    var error: String?
    var footprint: Footprint
    var createdAt: Date
    var secondsPerStepPerMP: Double?
    /// Measured on this Mac: model load + prompt encoding, and final VAE decode per megapixel.
    var loadSeconds: Double?
    var decodeSecondsPerMP: Double?
    var sizeOnDisk: Int64?

    var root: URL { Paths.models.appendingPathComponent(id, isDirectory: true) }
    var sourceDir: URL { root.appendingPathComponent("source", isDirectory: true) }
    var optimizedDir: URL { root.appendingPathComponent("optimized", isDirectory: true) }
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var needsQuantization: Bool { !prebuilt && (textBits ?? 16) < 16 || !prebuilt && (imageBits ?? 16) < 16 }

    /// Directory handed to mflux.
    var weightsDir: URL {
        if needsQuantization, FileManager.default.fileExists(atPath: optimizedDir.path) { return optimizedDir }
        return sourceDir
    }

    var quantLabel: String {
        if prebuilt { return Format.bits(prebuiltBits) }
        if textBits == imageBits { return Format.bits(imageBits) }
        return "T\(textBits.map(String.init) ?? "16")·I\(imageBits.map(String.init) ?? "16")"
    }

    var isReady: Bool { status == .ready }
}

/// Live progress of a download or optimization (not persisted).
@Observable
final class TransferProgress {
    var done: Int64 = 0
    var total: Int64 = 0
    var bytesPerSecond: Double = 0
    var currentFile = ""
    var attempt = 0
    var note = ""

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    var eta: Double { bytesPerSecond > 1 ? Double(total - done) / bytesPerSecond : .infinity }
}

nonisolated final class ByteCounter: @unchecked Sendable {
    private var value: Int64 = 0
    private let lock = NSLock()
    func set(_ v: Int64) { lock.lock(); value = v; lock.unlock() }
    var current: Int64 { lock.lock(); defer { lock.unlock() }; return value }
}

/// Serializes memory-heavy jobs (generation, quantization) so they never overlap on a 16 GB Mac.
@Observable
final class HeavyJobGate {
    private(set) var holder: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire(_ name: String) async {
        if holder == nil { holder = name; return }
        await withCheckedContinuation { waiters.append($0) }
        holder = name
    }

    func release() {
        holder = nil
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}

@Observable
final class ModelStore {
    private(set) var models: [InstalledModel] = []
    private(set) var progress: [String: TransferProgress] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var quantizers: [String: WorkerProcess] = [:]
    /// Only one model downloads at a time; the rest wait in order.
    private var activeDownload: String?
    let gate: HeavyJobGate
    weak var engine: Engine?

    init(gate: HeavyJobGate) {
        self.gate = gate
    }

    var readyModels: [InstalledModel] { models.filter(\.isReady) }
    var activeCount: Int { models.filter { [.queued, .downloading, .quantizing].contains($0.status) }.count }

    func model(_ id: String) -> InstalledModel? { models.first { $0.id == id } }

    // MARK: Persistence

    func load(resume: Bool = true) {
        Paths.ensure(Paths.models)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Paths.models, includingPropertiesForKeys: nil)) ?? []
        var loaded: [InstalledModel] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for dir in dirs {
            let manifest = dir.appendingPathComponent("model.json")
            guard let data = try? Data(contentsOf: manifest),
                  var model = try? decoder.decode(InstalledModel.self, from: data) else { continue }
            if model.id != dir.lastPathComponent { model.id = dir.lastPathComponent }
            loaded.append(model)
        }
        models = loaded.sorted { $0.createdAt > $1.createdAt }
        // Resume whatever was in flight when the app quit.
        if resume {
            for model in models where [.queued, .downloading, .quantizing].contains(model.status) {
                start(model.id)
            }
        }
        refreshSizes()
    }

    private func save(_ model: InstalledModel) {
        Paths.ensure(model.root)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(model) {
            try? data.write(to: model.root.appendingPathComponent("model.json"), options: .atomic)
        }
    }

    private func update(_ id: String, _ change: (inout InstalledModel) -> Void) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        change(&models[index])
        save(models[index])
    }

    func refreshSizes() {
        for model in models where model.isReady || model.status == .paused {
            let id = model.id
            let root = model.root
            Task.detached(priority: .utility) {
                let size = Paths.directorySize(root)
                await MainActor.run { self.update(id) { $0.sizeOnDisk = size } }
            }
        }
    }

    func recordTimings(_ id: String, loadSeconds: Double?, decodeSecondsPerMP: Double?) {
        update(id) { model in
            if let load = loadSeconds {
                model.loadSeconds = model.loadSeconds.map { $0 * 0.6 + load * 0.4 } ?? load
            }
            if let decode = decodeSecondsPerMP {
                model.decodeSecondsPerMP = model.decodeSecondsPerMP.map { $0 * 0.6 + decode * 0.4 } ?? decode
            }
        }
    }

    func recordSpeed(_ id: String, secondsPerStepPerMP: Double) {
        update(id) { model in
            if let old = model.secondsPerStepPerMP {
                // A big disagreement (stale or polluted history) is corrected quickly.
                let ratio = max(old, secondsPerStepPerMP) / max(0.001, min(old, secondsPerStepPerMP))
                let w = ratio > 1.5 ? 0.75 : 0.4
                model.secondsPerStepPerMP = old * (1 - w) + secondsPerStepPerMP * w
            } else {
                model.secondsPerStepPerMP = secondsPerStepPerMP
            }
        }
    }

    // MARK: Adding

    @discardableResult
    func add(
        repo: String, revision: String, family: String, title: String, files: [HFFile],
        prebuilt: Bool, prebuiltBits: Int?, textBits: Int?, imageBits: Int?, keepSource: Bool,
        footprint: Footprint
    ) -> String {
        var id = repo.replacingOccurrences(of: "/", with: "__")
        if !prebuilt { id += "__t\(textBits ?? 16)i\(imageBits ?? 16)" }
        if let existing = models.first(where: { $0.id == id }) {
            if existing.status != .ready { start(id) }
            return id
        }
        let model = InstalledModel(
            id: id, title: title, repo: repo, revision: revision, family: family, prebuilt: prebuilt,
            prebuiltBits: prebuiltBits, textBits: textBits, imageBits: imageBits, keepSource: keepSource,
            files: files, status: .queued, error: nil, footprint: footprint, createdAt: Date())
        models.insert(model, at: 0)
        save(model)
        start(id)
        return id
    }

    // MARK: Control

    func start(_ id: String) {
        guard tasks[id] == nil, let model = model(id) else { return }
        let progress = self.progress[id] ?? TransferProgress()
        self.progress[id] = progress
        update(id) { $0.error = nil }
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.run(id, progress: progress, startStatus: model.status)
            self.tasks[id] = nil
        }
    }

    func pause(_ id: String) {
        tasks[id]?.cancel()
        quantizers[id]?.cancel()
        update(id) { $0.status = .paused }
    }

    func remove(_ id: String) {
        tasks[id]?.cancel()
        quantizers[id]?.kill()
        guard let model = model(id) else { return }
        models.removeAll { $0.id == id }
        progress[id] = nil
        let root = model.root
        Task.detached { try? FileManager.default.removeItem(at: root) }
    }

    func shutdown() {
        for worker in quantizers.values { worker.kill() }
    }

    func revealInFinder(_ id: String) -> URL? { model(id)?.root }

    // MARK: Pipeline

    private func run(_ id: String, progress: TransferProgress, startStatus: InstalledModel.Status) async {
        guard let model = model(id) else { return }
        let sourceComplete = model.files.allSatisfy { file in
            let url = model.sourceDir.appendingPathComponent(file.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
            return size == file.size
        }
        if !sourceComplete || startStatus != .quantizing {
            guard await download(id, progress: progress) else { return }
        }
        guard let current = self.model(id) else { return }
        if current.needsQuantization {
            guard await quantize(id, progress: progress) else { return }
        }
        update(id) { $0.status = .ready; $0.error = nil }
        progress.note = ""
        refreshSizes()
    }

    /// Downloads every missing file with resume and retries. Returns false on pause/failure.
    private func download(_ id: String, progress: TransferProgress) async -> Bool {
        guard let model = model(id) else { return false }
        let needed = model.totalBytes - alreadyOnDisk(model)
        let free = Paths.freeDiskBytes(at: Paths.models)
        if needed > free - 2_000_000_000 {
            update(id) {
                $0.status = .failed
                $0.error = "Мало места на диске: нужно \(Format.bytes(needed)), свободно \(Format.bytes(free))."
            }
            return false
        }
        while let active = activeDownload, active != id {
            if Task.isCancelled { return false }
            update(id) { if $0.status != .queued { $0.status = .queued } }
            progress.note = "В очереди"
            try? await Task.sleep(for: .milliseconds(500))
        }
        if Task.isCancelled { return false }
        activeDownload = id
        defer { if activeDownload == id { activeDownload = nil } }
        update(id) { $0.status = .downloading }
        progress.total = model.totalBytes
        progress.note = ""
        var completed = alreadyCompleted(model)
        let counter = ByteCounter()
        let ticker = Task { [weak self] in
            var lastBytes = completed
            var lastTime = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard self != nil else { return }
                let now = Date()
                let done = completed + counter.current
                let instant = Double(done - lastBytes) / max(0.001, now.timeIntervalSince(lastTime))
                progress.bytesPerSecond = progress.bytesPerSecond == 0 ? instant : progress.bytesPerSecond * 0.8 + instant * 0.2
                progress.done = done
                lastBytes = done
                lastTime = now
            }
        }
        defer { ticker.cancel() }

        for file in model.files {
            let destination = model.sourceDir.appendingPathComponent(file.path)
            if fileSize(destination) == file.size { continue }
            progress.currentFile = file.path
            let url = HFClient.resolveURL(repo: model.repo, revision: model.revision, path: file.path)
            let transfer = FileTransfer(url: url, destination: destination, expectedSize: file.size) { bytes in
                counter.set(bytes)
            }
            defer { transfer.invalidate() }
            var attempt = 0
            while true {
                if Task.isCancelled { return false }
                attempt += 1
                progress.attempt = attempt
                counter.set(transfer.partialBytes)
                do {
                    try await transfer.run()
                    break
                } catch is CancellationError {
                    return false
                } catch {
                    if Task.isCancelled { return false }
                    let failure = error as? FileTransfer.Failure
                    let retryable = failure?.retryable ?? true
                    if !retryable || attempt >= 12 {
                        update(id) { $0.status = .failed; $0.error = "\(file.path): \(error.localizedDescription)" }
                        return false
                    }
                    let delay = min(60.0, pow(2.0, Double(attempt - 1)))
                    progress.note = "Обрыв связи, повтор через \(Int(delay)) с (попытка \(attempt + 1))"
                    try? await Task.sleep(for: .seconds(delay))
                    progress.note = ""
                }
            }
            completed += file.size
            counter.set(0)
            progress.done = completed
        }
        progress.done = model.totalBytes
        progress.bytesPerSecond = 0
        return true
    }

    private func quantize(_ id: String, progress: TransferProgress) async -> Bool {
        guard let model = model(id) else { return false }
        update(id) { $0.status = .quantizing }
        progress.note = "Ждём окончания генерации…"
        await gate.acquire("quantize")
        defer { gate.release() }
        if Task.isCancelled { return false }
        progress.note = "Квантование: текст \(Format.bits(model.textBits)), изображение \(Format.bits(model.imageBits))"
        try? FileManager.default.removeItem(at: model.optimizedDir)
        let payload: [String: Any] = [
            "source": model.sourceDir.path, "destination": model.optimizedDir.path, "family": model.family,
            "textBits": model.textBits ?? 16, "imageBits": model.imageBits ?? 16,
        ]
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            var errorText: String?
            do {
                let worker = try WorkerProcess.start(
                    command: "quantize", payload: payload,
                    onEvent: { event in
                        switch event {
                        case .log(let line): progress.note = line
                        case .error(let message): errorText = message
                        default: break
                        }
                    },
                    onExit: { [weak self] status in
                        self?.quantizers[id] = nil
                        if status == 0 {
                            continuation.resume(returning: .success(()))
                        } else {
                            continuation.resume(returning: .failure(NSError(
                                domain: "LocalImage", code: Int(status),
                                userInfo: [NSLocalizedDescriptionKey: errorText ?? "Квантование не удалось (код \(status))"])))
                        }
                    })
                quantizers[id] = worker
            } catch {
                continuation.resume(returning: .failure(error))
            }
        }
        switch result {
        case .success:
            if !model.keepSource { try? FileManager.default.removeItem(at: model.sourceDir) }
            return true
        case .failure(let error):
            if self.model(id)?.status == .paused { return false }
            update(id) { $0.status = .failed; $0.error = error.localizedDescription }
            return false
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
    }

    private func alreadyCompleted(_ model: InstalledModel) -> Int64 {
        model.files.reduce(0) { sum, file in
            fileSize(model.sourceDir.appendingPathComponent(file.path)) == file.size ? sum + file.size : sum
        }
    }

    private func alreadyOnDisk(_ model: InstalledModel) -> Int64 {
        model.files.reduce(0) { sum, file in
            let url = model.sourceDir.appendingPathComponent(file.path)
            let full = fileSize(url)
            if full == file.size { return sum + file.size }
            return sum + max(0, fileSize(url.appendingPathExtension("part")))
        }
    }
}
