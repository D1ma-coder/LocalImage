import Foundation
import Observation

/// What a model family can do, as reported by the installed mflux.
nonisolated struct FamilyCaps: Codable, Hashable, Identifiable {
    var key: String
    var repo: String?
    var defaultSteps: Int
    var supportsGuidance: Bool
    var defaultGuidance: Double
    var negativePrompt: Bool
    var img2img: Bool
    /// How many reference images the model edits from (0 = it can't); takes precedence over img2img.
    var references: Int
    /// Largest output the model is made for, in megapixels of 1024×1024.
    var maxMegapixels: Double
    var lora: Bool
    var computePrecision: Bool
    var lowRam: Bool
    var patterns: [String]

    var id: String { key }

    /// How many images can be attached: references for editing models, one source image for img2img.
    var maxImages: Int { references > 0 ? references : (img2img ? 1 : 0) }

    /// The model actually uses a negative prompt: mflux may accept the flag, but CFG-distilled
    /// (turbo) variants without guidance never encode it. Qwen-Image 2512 always runs true CFG.
    var usesNegativePrompt: Bool { negativePrompt && (supportsGuidance || key == "qwen-image") }

    var payload: [String: Any] {
        [
            "supportsGuidance": supportsGuidance, "negativePrompt": negativePrompt, "img2img": img2img,
            "computePrecision": computePrecision, "lowRam": lowRam,
        ]
    }
}

nonisolated struct EngineInfo: Codable {
    var mflux: String
    var mlx: String
    var protocolVersion: Int
    var families: [FamilyCaps]
}

/// Installs and verifies the MLX engine: uv → Python 3.12 venv → pinned mflux.
@Observable
final class Engine {
    enum State: Equatable {
        case checking
        case missing
        case installing(step: Int, title: String, detail: String)
        case ready
        case failed(String)
    }

    /// mflux internals are patched by the worker (previews, mixed quantization), so the version is pinned.
    static let mfluxVersion = "0.24.0"
    static let installSteps = 4
    /// Must match the worker's ENGINE_PROTOCOL; a cached families list from another protocol is re-read.
    static let protocolVersion = 5

    private(set) var state: State = .checking
    private(set) var info: EngineInfo?
    private(set) var installLog: [String] = []

    var isReady: Bool { state == .ready }

    func caps(for family: String) -> FamilyCaps? {
        info?.families.first { $0.key == family }
    }

    var supportedFamilies: [String] { info?.families.map(\.key) ?? [] }

    // MARK: Startup

    func bootstrap() async {
        if let data = try? Data(contentsOf: Paths.familiesCache),
           let cached = try? JSONDecoder().decode(EngineInfo.self, from: data),
           FileManager.default.isExecutableFile(atPath: Paths.python.path),
           cached.mflux == Self.mfluxVersion, cached.protocolVersion == Self.protocolVersion {
            info = cached
            state = .ready
            return
        }
        if FileManager.default.isExecutableFile(atPath: Paths.python.path) {
            state = .checking
            do {
                try await refreshFamilies()
                state = .ready
            } catch {
                state = .missing
            }
        } else {
            state = .missing
        }
    }

    // MARK: Install

    func install() async {
        installLog.removeAll()
        Paths.ensure(Paths.engine)
        do {
            set(step: 1, String(localized: "Менеджер окружений"), String(localized: "Ищем uv…"))
            let uv = try await locateOrFetchUV()

            set(step: 2, "Python 3.12", String(localized: "Создаём изолированное окружение…"))
            if !FileManager.default.isExecutableFile(atPath: Paths.python.path) {
                try await ProcessRunner.run(
                    uv, ["venv", "--python", "3.12", "--seed", Paths.venv.path],
                    environment: uvEnvironment, onLine: { [weak self] in self?.record($0) })
            }

            set(step: 3, String(localized: "MLX и mflux"), String(localized: "Загружаем пакеты (~1 ГБ)…"))
            try await ProcessRunner.run(
                uv, ["pip", "install", "--python", Paths.python.path, "mflux==\(Self.mfluxVersion)"],
                environment: uvEnvironment, onLine: { [weak self] line in
                    self?.record(line)
                    if case .installing(let step, let title, _) = self?.state, !line.isEmpty {
                        self?.state = .installing(step: step, title: title, detail: line.trimmingCharacters(in: .whitespaces))
                    }
                })

            set(step: 4, String(localized: "Проверка"), String(localized: "Запускаем движок…"))
            try await refreshFamilies()
            state = .ready
        } catch {
            record("ERROR: \(error.localizedDescription)")
            try? installLog.joined(separator: "\n").write(to: Paths.engineLog, atomically: true, encoding: .utf8)
            state = .failed(error.localizedDescription)
        }
    }

    func reinstall() async {
        try? FileManager.default.removeItem(at: Paths.venv)
        try? FileManager.default.removeItem(at: Paths.familiesCache)
        await install()
    }

    func refreshFamilies() async throws {
        let events = try await WorkerCall.run(command: "families")
        for event in events {
            guard case .other("families", let json) = event else { continue }
            let data = try JSONSerialization.data(withJSONObject: json["families"] ?? [])
            let families = try JSONDecoder().decode([FamilyCaps].self, from: data)
            let info = EngineInfo(
                mflux: json["mflux"] as? String ?? "?", mlx: json["mlx"] as? String ?? "?",
                protocolVersion: json["protocol"] as? Int ?? 0, families: families)
            self.info = info
            try JSONEncoder().encode(info).write(to: Paths.familiesCache)
            return
        }
        throw NSError(domain: "LocalImage", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "Движок не ответил")])
    }

    // MARK: uv

    private var uvEnvironment: [String: String] {
        [
            "UV_PYTHON_INSTALL_DIR": Paths.engine.appendingPathComponent("python").path,
            "UV_NO_PROGRESS": "1",
            // Self-contained: never bind the venv to a Homebrew/system Python that may disappear.
            "UV_PYTHON_PREFERENCE": "only-managed",
        ]
    }

    private func locateOrFetchUV() async throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            Paths.engine.appendingPathComponent("bin/uv").path,
            "/opt/homebrew/bin/uv", "/usr/local/bin/uv",
            "\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            record("uv: \(found)")
            return URL(fileURLWithPath: found)
        }
        set(step: 1, String(localized: "Менеджер окружений"), String(localized: "Скачиваем uv с GitHub (astral-sh/uv)…"))
        let url = URL(string: "https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz")!
        let (archive, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "LocalImage", code: 4, userInfo: [NSLocalizedDescriptionKey: String(localized: "Не удалось скачать uv")])
        }
        let unpack = Paths.ensure(Paths.engine.appendingPathComponent("uv-download"))
        try await ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", unpack.path],
            onLine: { [weak self] in self?.record($0) })
        let binDir = Paths.ensure(Paths.engine.appendingPathComponent("bin"))
        let extracted = unpack.appendingPathComponent("uv-aarch64-apple-darwin/uv")
        let target = binDir.appendingPathComponent("uv")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: extracted, to: target)
        try? FileManager.default.removeItem(at: unpack)
        return target
    }

    private func set(step: Int, _ title: String, _ detail: String) {
        state = .installing(step: step, title: title, detail: detail)
        record("== \(title): \(detail)")
    }

    private func record(_ line: String) {
        installLog.append(line)
        if installLog.count > 400 { installLog.removeFirst(installLog.count - 400) }
    }
}
