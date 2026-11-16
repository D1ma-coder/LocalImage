import AppKit
import Foundation
import Observation

nonisolated struct GalleryItem: Identifiable, Hashable {
    var url: URL
    var record: GenerationRecord?
    var date: Date
    var id: URL { url }
}

/// Owns the generation workflow: parameters → worker job → live steps → saved results.
@Observable
final class Studio {
    enum Phase: Equatable {
        case idle, starting, loading, encoding, denoising, decoding, finishing

        var title: String {
            switch self {
            case .idle: ""
            case .starting: String(localized: "Запуск движка")
            case .loading: String(localized: "Загрузка модели")
            case .encoding: String(localized: "Кодирование промпта")
            case .denoising: String(localized: "Рисование")
            case .decoding: String(localized: "Декодирование")
            case .finishing: String(localized: "Сохранение")
            }
        }
    }

    var settings = GenerationSettings.load() {
        didSet {
            if settings.modelID != selectedModelID { selectedModelID = settings.modelID }
            if settings.modelID != oldValue.modelID, dropsInitImage {
                settings.initImagePath = nil
                if settings.aspect == .source { settings.aspect = .square }
                initImage = nil
            }
            if settings != oldValue { settings.save() }
        }
    }
    /// Separate observed copy of `settings.modelID`, so views that only care about the model
    /// (the toolbar switcher) don't redraw on every parameter change.
    private(set) var selectedModelID: String?

    private(set) var phase: Phase = .idle
    private(set) var step = 0
    private(set) var totalSteps = 0
    private(set) var startStep = 0
    private(set) var secondsPerStep: Double?
    private(set) var imageIndex = 0
    private(set) var imageCount = 1
    /// Newest preview of the image being generated (only the latest is kept).
    private(set) var livePreview: NSImage?
    /// The newest step is done and its preview is still decoding.
    private(set) var previewPending = false
    private(set) var results: [GalleryItem] = []
    private(set) var lastError: String?
    private(set) var log: [String] = []
    private(set) var gallery: [GalleryItem] = []
    private(set) var jobStarted: Date?

    /// Journal sheet visibility (shared by canvas and inspector).
    var showLog = false

    /// A finished image the user opened from the strip while the batch keeps generating.
    var pinnedResult: GalleryItem?
    var shownResult: GalleryItem?
    var initImage: NSImage?

    private var worker: WorkerProcess?
    /// Identifies the current job; events and exits of stopped jobs are ignored.
    private var jobID = UUID()
    /// Output prefix of the current job, used to remove a half-written PNG after a hard stop.
    private var jobOutputPrefix: URL?
    private var jobPreviewEvery = 1
    private var denoiseStarted: Date?

    // MARK: ETA model state
    /// Smoothed predicted finish time of the whole job; `remainingSeconds` counts down to it.
    private(set) var remainingSeconds: Double?
    private var predictedEnd: Date?
    private var lastStepAt: Date?
    private var stepDurationEMA: Double?
    private var decodeStartedAt: Date?
    private var measuredDecode: Double?
    private var imageStartedAt: Date?
    private var etaTask: Task<Void, Never>?
    private var warmupInterval: Double?
    /// Measured cost of one whole image in this job (denoise start → saved) and the gap to the next one.
    private var lastImageCompute: Double?
    private var interImageGap: Double?
    private var lastImageDoneAt: Date?
    private var jobMegapixels = 1.0
    private var jobModelID: String?
    private var currentRecordBase: GenerationRecord?

    let store: ModelStore
    let engine: Engine
    let gate: HeavyJobGate

    init(store: ModelStore, engine: Engine, gate: HeavyJobGate) {
        self.store = store
        self.engine = engine
        self.gate = gate
        selectedModelID = settings.modelID
        if let path = settings.initImagePath { initImage = NSImage(contentsOfFile: path) }
        if initImage == nil { settings.initImagePath = nil }
    }

    var isRunning: Bool { phase != .idle }

    var selectedModel: InstalledModel? {
        guard let id = selectedModelID else { return nil }
        return store.model(id).flatMap { $0.isReady ? $0 : nil }
    }

    var caps: FamilyCaps? { selectedModel.flatMap { engine.caps(for: $0.family) } }

    var effectiveSteps: Int { settings.steps ?? caps?.defaultSteps ?? 20 }

    var dimensions: (width: Int, height: Int) {
        let sourceAspect = initImage.map { Double($0.size.width / max(1, $0.size.height)) }
        return settings.dimensions(sourceAspect: sourceAspect)
    }

    var megapixels: Double { Double(dimensions.width * dimensions.height) / 1_048_576 }

    var estimatedPeak: Double? {
        guard let model = selectedModel else { return nil }
        return MemoryModel.peakGB(model.footprint, megapixels: megapixels, batch: settings.count > 1)
    }

    var fit: Fit? { estimatedPeak.map { MemoryModel.fit(peak: $0) } }

    /// Expected duration from measured speed of this model on this Mac.
    var estimatedSeconds: Double? {
        guard let model = selectedModel, let rate = model.secondsPerStepPerMP else { return nil }
        let steps = effectiveSteps - skippedSteps
        let perImage = rate * megapixels * Double(max(0, steps)) + (model.decodeSecondsPerMP ?? 0) * megapixels
        return (model.loadSeconds ?? 0) + perImage * Double(settings.count)
    }

    /// Steps mflux skips for img2img: the first int(steps × strength), at least one.
    var skippedSteps: Int {
        guard settings.initImagePath != nil, caps?.img2img == true else { return 0 }
        return min(effectiveSteps - 1, max(1, Int(Double(effectiveSteps) * settings.strength.clamped(0, 1))))
    }

    /// Progress counted only over the steps that actually run (img2img skips the first ones).
    var runStep: Int { max(0, step - startStep) }
    var runTotal: Int { max(1, totalSteps - startStep) }

    var etaSeconds: Double? { remainingSeconds }

    /// Phase-aware estimate of the time left for the whole job, as of `now`.
    /// Uses live measurements of this run, falling back to this model's history on this Mac.
    private func estimateRemaining(now: Date) -> Double? {
        let model = jobModelID.flatMap { store.model($0) }
        let mp = jobMegapixels
        // Steady-state step time; the warm-up interval only stands in until a normal step is seen.
        guard let stepDuration = stepDurationEMA ?? model?.secondsPerStepPerMP.map({ $0 * mp }) ?? warmupInterval.map({ $0 * 0.6 }) else { return nil }
        let decode = measuredDecode ?? model?.decodeSecondsPerMP.map { $0 * mp } ?? max(1.5, stepDuration * 0.6)
        let load = model?.loadSeconds ?? 8
        let stepsPerImage = Double(max(1, totalSteps - startStep))
        /// What is left of an activity expected to take `expected`, already running for `elapsed`.
        /// Overruns never reach zero: the estimate stretches gently instead of freezing at 0.
        func left(_ expected: Double, _ elapsed: Double) -> Double {
            elapsed < expected * 0.9 ? expected - elapsed : max(expected * 0.1, elapsed * 0.12)
        }
        var remaining = 0.0
        switch phase {
        case .idle:
            return nil
        case .starting, .loading, .encoding:
            let elapsed = now.timeIntervalSince(jobStarted ?? now)
            remaining = left(load, elapsed) + stepsPerImage * stepDuration + decode
        case .denoising:
            let sinceStep = now.timeIntervalSince(lastStepAt ?? now)
            let stepsAfterCurrent = Double(max(0, totalSteps - step - 1))
            remaining = (step < totalSteps ? left(stepDuration, sinceStep) : 0) + stepsAfterCurrent * stepDuration + decode
        case .decoding:
            remaining = left(decode, now.timeIntervalSince(decodeStartedAt ?? now))
        case .finishing:
            remaining = 0.3
        }
        let imagesAfter = Double(max(0, imageCount - imageIndex - 1))
        if phase == .finishing && imageIndex < imageCount - 1 { remaining = 0 }
        // Later images of a batch: the real cost of the previous image beats any model.
        let perImage = lastImageCompute ?? (stepsPerImage * stepDuration + decode)
        remaining += imagesAfter * (perImage + (interImageGap ?? 0.6))
        return remaining
    }

    /// Ticks 4×/s while generating: the countdown runs between events, and new measurements
    /// move the predicted finish smoothly instead of making the number jump.
    private func startETA() {
        etaTask?.cancel()
        predictedEnd = nil
        remainingSeconds = nil
        etaTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning else { break }
                let now = Date()
                if let raw = self.estimateRemaining(now: now) {
                    let target = now.addingTimeInterval(raw)
                    if let end = self.predictedEnd {
                        let delta = target.timeIntervalSince(end)
                        // Large surprises (≥ 25%) are followed quickly, small noise is filtered out.
                        let k = abs(delta) > max(2, raw * 0.25) ? 0.35 : 0.12
                        self.predictedEnd = end.addingTimeInterval(delta * k)
                    } else {
                        self.predictedEnd = target
                    }
                    self.remainingSeconds = max(0, self.predictedEnd!.timeIntervalSince(now))
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopETA() {
        etaTask?.cancel()
        etaTask = nil
        remainingSeconds = nil
        predictedEnd = nil
    }

    /// Pixel size of the job's images: the skeleton takes this shape before any preview exists.
    private(set) var jobSize: CGSize?

    /// Progress of the image being made right now, 0…1 (loading counts as 0, decoding as 99%).
    var imageFraction: Double {
        switch phase {
        case .denoising:
            let span = max(1, totalSteps - startStep)
            return min(0.98, Double(max(0, step - startStep)) / Double(span))
        case .decoding: return 0.99
        case .finishing: return 1
        default: return 0
        }
    }

    var imagePercent: Int { Int((imageFraction * 100).rounded(.down)) }

    /// The strip shows one in-progress slot while an image of the job is still being made.
    var showsProgressSlot: Bool { isRunning && results.count < imageCount }

    /// All steps are done; the final image is being decoded and saved.
    private(set) var finalPending = false

    func appendLog(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    func clearError() { lastError = nil }

    /// A model without img2img can't use a source image.
    private var dropsInitImage: Bool { settings.initImagePath != nil && caps.map { !$0.img2img } == true }

    /// Picks a model by hand; a source image the model can't use is removed, even when it is already selected.
    func selectModel(_ id: String) {
        settings.modelID = id
        if dropsInitImage { setInitImage(nil) }
    }

    // MARK: Init image

    func setInitImage(_ url: URL?) {
        guard let url else {
            initImage = nil
            settings.initImagePath = nil
            if settings.aspect == .source { settings.aspect = .square }
            return
        }
        // Keep a private copy so moving/deleting the original does not break "repeat".
        let folder = Paths.ensure(Paths.appSupport.appendingPathComponent("inputs"))
        let copy = folder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        try? FileManager.default.copyItem(at: url, to: copy)
        let path = FileManager.default.fileExists(atPath: copy.path) ? copy : url
        initImage = NSImage(contentsOf: path)
        settings.initImagePath = initImage == nil ? nil : path.path
        if initImage != nil { settings.aspect = .source }
    }

    // MARK: Generate

    func generate() {
        guard !isRunning else { return }
        lastError = nil
        guard engine.isReady else { lastError = String(localized: "Движок ещё не установлен."); return }
        guard let model = selectedModel, let caps else { lastError = String(localized: "Выберите загруженную модель."); return }
        let prompt = settings.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { lastError = String(localized: "Опишите, что нарисовать."); return }

        if settings.randomSeed { settings.seed = Int.random(in: 1...999_999_999) }
        let seeds = (0..<settings.count).map { settings.seed + $0 }
        let (width, height) = dimensions
        let day = DateFormatter.day.string(from: Date())
        let folder = Paths.ensure(Paths.outputs.appendingPathComponent(day, isDirectory: true))
        let stamp = DateFormatter.time.string(from: Date())
        let output = folder.appendingPathComponent("\(stamp)-\(seeds[0]).png")
        jobOutputPrefix = folder.appendingPathComponent("\(stamp)-\(seeds[0])")
        let previewDir = Paths.previews.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: Paths.previews)
        Paths.ensure(previewDir)

        let hardware = Hardware.current
        let peak = MemoryModel.peakGB(model.footprint, megapixels: megapixels, batch: settings.count > 1)
        let lowRam: Bool = switch settings.memoryMode {
        case .saver: true
        case .speed: false
        case .auto: peak > hardware.budgetGB * 0.8
        }
        let precision: String? = switch settings.precision {
        case .auto: hardware.prefersFloat16 && caps.computePrecision ? "float16" : nil
        case .bfloat16: nil
        case .float16: "float16"
        }

        var job: [String: Any] = [
            "family": model.family, "modelPath": model.weightsDir.path, "prompt": prompt,
            "width": width, "height": height, "seeds": seeds, "output": output.path,
            "caps": caps.payload, "lowRam": lowRam, "metadata": false,
            "preview": [
                "dir": previewDir.path, "every": settings.previewEvery,
                "scale": settings.previewFull ? 1.0 : 0.5, "maxSide": settings.previewFull ? 1536 : 768,
            ],
        ]
        if let steps = settings.steps { job["steps"] = steps }
        if let guidance = settings.guidance, caps.supportsGuidance { job["guidance"] = guidance }
        if caps.usesNegativePrompt, !settings.negativePrompt.isEmpty { job["negativePrompt"] = settings.negativePrompt }
        if let path = settings.initImagePath, caps.img2img {
            job["imagePath"] = path
            job["imageStrength"] = settings.strength
        }
        if let precision { job["computePrecision"] = precision }
        // An original checkpoint whose optimized copy is missing gets quantized on load.
        if model.needsQuantization && model.weightsDir == model.sourceDir {
            job["textBits"] = model.textBits ?? 16
            job["imageBits"] = model.imageBits ?? 16
        }

        currentRecordBase = GenerationRecord(
            prompt: prompt, negativePrompt: caps.usesNegativePrompt ? settings.negativePrompt : nil,
            modelID: model.id, modelTitle: model.title, family: model.family, quant: model.quantLabel,
            width: width, height: height, steps: effectiveSteps, seed: seeds[0],
            guidance: caps.supportsGuidance ? settings.guidance : nil,
            initImagePath: caps.img2img ? settings.initImagePath : nil,
            strength: settings.initImagePath != nil && caps.img2img ? settings.strength : nil,
            seconds: nil, date: Date())

        livePreview = nil
        previewPending = false
        finalPending = false
        jobSize = CGSize(width: width, height: height)
        jobPreviewEvery = settings.previewEvery
        results = []
        pinnedResult = nil
        shownResult = nil
        imageIndex = 0
        imageCount = seeds.count
        // Predicted until the worker reports the real start, so the display and ETA are right from the outset.
        startStep = skippedSteps
        step = startStep
        totalSteps = effectiveSteps
        secondsPerStep = nil
        log.removeAll()
        phase = .starting
        jobStarted = Date()
        imageStartedAt = jobStarted
        lastStepAt = nil
        stepDurationEMA = nil
        warmupInterval = nil
        lastImageCompute = nil
        interImageGap = nil
        lastImageDoneAt = nil
        decodeStartedAt = nil
        measuredDecode = nil
        jobMegapixels = Double(width * height) / 1_048_576
        jobModelID = model.id
        startETA()

        let id = UUID()
        jobID = id
        Task { await run(job: job, modelID: model.id, id: id) }
    }

    private func run(job: [String: Any], modelID: String, id: UUID) async {
        if gate.holder != nil { appendLog(String(localized: "Ждём завершения предыдущей задачи…")) }
        await gate.acquire("generate")
        guard id == jobID else {
            gate.release()  // stopped while waiting
            return
        }
        do {
            worker = try WorkerProcess.start(
                command: "generate", payload: job,
                onEvent: { [weak self] event in
                    guard let self, self.jobID == id else { return }
                    self.handle(event, modelID: modelID)
                },
                onLog: { [weak self] line in
                    guard let self, self.jobID == id else { return }
                    self.appendLog(line)
                },
                onExit: { [weak self] status in self?.finished(status: status, id: id) })
        } catch {
            lastError = error.localizedDescription
            phase = .idle
            gate.release()
        }
    }

    /// Called on app termination: never leave a worker holding GPU memory.
    func shutdown() {
        worker?.forceKill()
    }

    /// Instant stop: the UI resets at once and the worker is killed (memory is freed by the OS).
    /// Images already finished in a batch stay; a half-written one is removed.
    func cancel() {
        guard isRunning else { return }
        let stopped = worker
        let prefix = jobOutputPrefix
        let kept = Set(results.map(\.url))
        jobID = UUID()  // detach: late events and the exit of the old job are ignored
        worker = nil
        stopped?.forceKill()
        previewPending = false
        finalPending = false
        pinnedResult = nil
        phase = .idle
        jobStarted = nil
        appendLog(String(localized: "Остановлено пользователем"))
        stopETA()
        if let prefix { removePartialOutputs(prefix: prefix, keeping: kept) }
    }

    private func removePartialOutputs(prefix: URL, keeping kept: Set<URL>) {
        let folder = prefix.deletingLastPathComponent()
        let stem = prefix.lastPathComponent
        // Give the kernel a moment to reap the process before looking at its files.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix(stem) && file.pathExtension == "png" {
                if !kept.contains(file) { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    private func handle(_ event: WorkerEvent, modelID: String) {
        switch event {
        case .phase(let name):
            phase = switch name {
            case "starting": .starting
            case "loading": .loading
            case "encoding": .encoding
            case "decoding": .decoding
            default: phase
            }
            if phase == .decoding {
                previewPending = false
                finalPending = true
                if decodeStartedAt == nil { decodeStartedAt = Date() }
            }
        case .denoise(let start, let total, _, _):
            phase = .denoising
            finalPending = false
            startStep = start
            totalSteps = total
            step = start
            livePreview = nil
            previewPending = false
            denoiseStarted = Date()
            lastStepAt = denoiseStarted
            decodeStartedAt = nil
            if let done = lastImageDoneAt, let started = denoiseStarted {
                let gap = started.timeIntervalSince(done)
                interImageGap = interImageGap.map { $0 * 0.5 + gap * 0.5 } ?? gap
            }
            // First image of the job: everything before denoising was model load + prompt encoding.
            if imageIndex == 0, results.isEmpty, let started = jobStarted, let id = jobModelID {
                store.recordTimings(id, loadSeconds: Date().timeIntervalSince(started), decodeSecondsPerMP: nil)
            }
        case .step(let current, let total, let elapsed):
            step = current
            totalSteps = total
            let computed = current - startStep
            if computed > 0 { secondsPerStep = elapsed / Double(computed) }
            let now = Date()
            if let last = lastStepAt {
                let dt = now.timeIntervalSince(last)
                if computed <= 1 {
                    // First interval of an image includes warm-up (VAE/kernels): keep it out of the step model.
                    warmupInterval = dt
                } else if let ema = stepDurationEMA {
                    // Recent steps matter most; a single outlier (> 2×) moves the estimate only a little.
                    let weight = dt > ema * 2 ? 0.15 : 0.45
                    stepDurationEMA = ema * (1 - weight) + dt * weight
                } else {
                    stepDurationEMA = dt
                }
            }
            lastStepAt = now
            if current >= total { decodeStartedAt = now }
            if current >= total { finalPending = true }
            // If the previous preview failed this simply resets; no stale loaders remain.
            previewPending = previewExpected(for: current, total: total)
        case .preview(_, let url):
            if let image = NSImage(contentsOf: url) { livePreview = image }
            previewPending = false
        case .image(let url, let seed, let seconds):
            phase = .finishing
            finalPending = false
            previewPending = false
            var record = currentRecordBase
            if let seed { record?.seed = seed }
            // Real wall time of this image (mflux reports 0 here).
            let imageSeconds = Date().timeIntervalSince(imageStartedAt ?? Date())
            record?.seconds = (seconds ?? 0) > 0 ? seconds : imageSeconds
            if let started = decodeStartedAt {
                let decode = Date().timeIntervalSince(started)
                measuredDecode = measuredDecode.map { $0 * 0.5 + decode * 0.5 } ?? decode
                store.recordTimings(modelID, loadSeconds: nil, decodeSecondsPerMP: decode / max(0.1, jobMegapixels))
            }
            imageStartedAt = Date()
            record?.date = Date()
            if let record { writeSidecar(record, for: url) }
            let item = GalleryItem(url: url, record: record, date: Date())
            results.append(item)
            gallery.insert(item, at: 0)
            shownResult = item
            if let perStep = stepDurationEMA ?? secondsPerStep, let record {
                let mp = Double(record.width * record.height) / 1_048_576
                store.recordSpeed(modelID, secondsPerStepPerMP: perStep / max(0.1, mp))
            }
            if let started = denoiseStarted {
                let compute = Date().timeIntervalSince(started)
                lastImageCompute = lastImageCompute.map { $0 * 0.4 + compute * 0.6 } ?? compute
            }
            lastImageDoneAt = Date()
            imageIndex = min(imageCount - 1, imageIndex + 1)
        case .error(let message):
            lastError = message
        case .log(let line):
            appendLog(line)
        case .cancelled, .done, .other:
            break
        }
    }

    /// Mirrors the worker's rule: every N-th step and the first one, never the last.
    private func previewExpected(for step: Int, total: Int) -> Bool {
        guard jobPreviewEvery > 0, step < total else { return false }
        return step % jobPreviewEvery == 0 || step == startStep + 1
    }

    private func finished(status: Int32, id: UUID) {
        gate.release()  // the exiting worker held the gate, whether or not it was stopped
        guard id == jobID else { return }  // a stopped job: the UI was already reset
        worker = nil
        finalPending = false
        previewPending = false
        if status != 0 && lastError == nil {
            lastError = String(localized: "Движок завершился с ошибкой (код \(status)). Подробности — в журнале.")
        }
        phase = .idle
        jobStarted = nil
        stopETA()
    }

    // MARK: Gallery

    private func writeSidecar(_ record: GenerationRecord, for image: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(record) {
            try? data.write(to: image.deletingPathExtension().appendingPathExtension("lix.json"))
        }
    }

    func loadGallery() {
        let root = Paths.outputs
        Task.detached(priority: .utility) {
            let items = Self.scanGallery(root)
            await MainActor.run { self.gallery = items }
        }
    }

    nonisolated private static func scanGallery(_ root: URL) -> [GalleryItem] {
        var items: [GalleryItem] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "png" else { continue }
            let sidecar = url.deletingPathExtension().appendingPathExtension("lix.json")
            let record = (try? Data(contentsOf: sidecar)).flatMap { try? decoder.decode(GenerationRecord.self, from: $0) }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            items.append(GalleryItem(url: url, record: record, date: record?.date ?? created))
        }
        return items.sorted { $0.date > $1.date }
    }

    func delete(_ item: GalleryItem) {
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        try? FileManager.default.trashItem(at: item.url.deletingPathExtension().appendingPathExtension("lix.json"), resultingItemURL: nil)
        gallery.removeAll { $0.id == item.id }
        results.removeAll { $0.id == item.id }
        if shownResult?.id == item.id { shownResult = nil }
        if pinnedResult?.id == item.id { pinnedResult = nil }
    }

    /// Restores the parameters of a past image into the editor.
    func reuse(_ record: GenerationRecord, includeSeed: Bool) {
        settings.prompt = record.prompt
        settings.negativePrompt = record.negativePrompt ?? ""
        if store.model(record.modelID)?.isReady == true { settings.modelID = record.modelID }
        settings.steps = record.steps
        settings.guidance = record.guidance
        if includeSeed {
            settings.seed = record.seed
            settings.randomSeed = false
        }
        if let path = record.initImagePath, FileManager.default.fileExists(atPath: path) {
            initImage = NSImage(contentsOfFile: path)
            settings.initImagePath = path
            settings.strength = record.strength ?? settings.strength
        }
    }
}

extension DateFormatter {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        return formatter
    }()
}

extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(high, Swift.max(low, self)) }
}
