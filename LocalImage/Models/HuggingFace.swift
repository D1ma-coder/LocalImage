import Foundation

nonisolated struct HFModelSummary: Identifiable, Hashable, Decodable {
    var id: String
    var downloads: Int?
    var likes: Int?
    var pipelineTag: String?
    var tags: [String]?
    var lastModified: String?
    var gated: GatedValue?
    var trendingScore: Double?
    var libraryName: String?
    var safetensors: Safetensors?

    struct Safetensors: Hashable, Decodable { var total: Double? }

    enum CodingKeys: String, CodingKey {
        case id, downloads, likes, tags, lastModified, gated, trendingScore, safetensors
        case pipelineTag = "pipeline_tag"
        case libraryName = "library_name"
    }

    var owner: String { String(id.split(separator: "/").first ?? "") }
    var name: String { String(id.split(separator: "/").last ?? Substring(id)) }
    var parameters: Double? { safetensors?.total }

    /// `gated` is `false` or a string ("auto"/"manual") in the HF API.
    enum GatedValue: Hashable, Decodable {
        case open, gated

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) { self = flag ? .gated : .open; return }
            self = (try? container.decode(String.self)) != nil ? .gated : .open
        }
    }

    var isGated: Bool { gated == .gated }
}

nonisolated struct HFFile: Hashable, Codable {
    var path: String
    var size: Int64
}

nonisolated struct HFRepoInfo {
    var id: String
    var sha: String
    var gated: Bool
    var tags: [String]
    var baseModels: [String]
    var files: [HFFile]
    var pipelineClass: String?
    var libraryName: String?
}

/// Minimal, dependency-free Hugging Face Hub client.
nonisolated enum HFClient {
    static let base = URL(string: "https://huggingface.co")!

    static func request(_ url: URL, range: ClosedRange<Int64>? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let token = TokenStore.load() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        return request
    }

    static func get(_ url: URL, range: ClosedRange<Int64>? = nil) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(url, range: range))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HFError(status: status) }
        return data
    }

    struct HFError: LocalizedError {
        var status: Int
        var errorDescription: String? {
            switch status {
            case 401, 403: String(localized: "Нет доступа: примите лицензию на странице модели и укажите токен Hugging Face в настройках.")
            case 404: String(localized: "Репозиторий или файл не найден.")
            case 429: String(localized: "Hugging Face ограничил частоту запросов. Повторите через минуту.")
            default: String(localized: "Hugging Face ответил ошибкой \(status).")
            }
        }
    }

    // MARK: Search

    static func search(_ query: String, sort: String = "downloads", pipelineTag: String? = nil, limit: Int = 40) async throws -> [HFModelSummary] {
        var components = URLComponents(url: base.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
        ] + ["downloads", "likes", "trendingScore", "gated", "lastModified", "tags", "pipeline_tag", "library_name", "safetensors"]
            .map { URLQueryItem(name: "expand[]", value: $0) }
        if let pipelineTag { components.queryItems?.append(URLQueryItem(name: "pipeline_tag", value: pipelineTag)) }
        let data = try await get(components.url!)
        return try JSONDecoder().decode([HFModelSummary].self, from: data)
    }

    // MARK: Repo

    static func info(_ repo: String) async throws -> HFRepoInfo {
        let infoURL = base.appendingPathComponent("api/models/\(repo)")
        let data = try await get(infoURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let sha = json["sha"] as? String ?? "main"
        let gatedValue = json["gated"]
        let gated = (gatedValue as? Bool) ?? (gatedValue is String)
        let tags = json["tags"] as? [String] ?? []
        let card = json["cardData"] as? [String: Any] ?? [:]
        var baseModels: [String] = []
        if let single = card["base_model"] as? String { baseModels = [single] }
        if let many = card["base_model"] as? [String] { baseModels = many }
        baseModels += tags.compactMap { tag in
            tag.hasPrefix("base_model:") ? tag.split(separator: ":").last.map(String.init) : nil
        }

        let treeURL = base.appendingPathComponent("api/models/\(repo)/tree/\(sha)")
        var components = URLComponents(url: treeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        let treeData = try await get(components.url!)
        let tree = try JSONSerialization.jsonObject(with: treeData) as? [[String: Any]] ?? []
        let files = tree.compactMap { item -> HFFile? in
            guard item["type"] as? String == "file", let path = item["path"] as? String else { return nil }
            let size = (item["size"] as? NSNumber)?.int64Value ?? 0
            return HFFile(path: path, size: size)
        }

        var pipelineClass: String?
        if files.contains(where: { $0.path == "model_index.json" }),
           let indexData = try? await get(resolveURL(repo: repo, revision: sha, path: "model_index.json")),
           let index = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any] {
            pipelineClass = index["_class_name"] as? String
        }
        return HFRepoInfo(
            id: repo, sha: sha, gated: gated, tags: tags, baseModels: baseModels, files: files,
            pipelineClass: pipelineClass, libraryName: json["library_name"] as? String)
    }

    static func resolveURL(repo: String, revision: String, path: String) -> URL {
        let escaped = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(escaped)")!
    }

    static func whoami() async throws -> String {
        let data = try await get(base.appendingPathComponent("api/whoami-v2"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["name"] as? String ?? "?"
    }

    // MARK: Parameter counting (safetensors headers via HTTP Range)

    /// Reads only the JSON header of each safetensors file and sums tensor element counts.
    static func parameterCount(repo: String, revision: String, files: [HFFile]) async -> Double? {
        var total: Double = 0
        for file in files where file.path.hasSuffix(".safetensors") {
            let url = resolveURL(repo: repo, revision: revision, path: file.path)
            guard let lengthData = try? await get(url, range: 0...7), lengthData.count == 8 else { return nil }
            let length = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            guard length > 0, length < 50_000_000,
                  let header = try? await get(url, range: 8...Int64(8 + length - 1)),
                  let json = try? JSONSerialization.jsonObject(with: header) as? [String: Any]
            else { return nil }
            for (key, value) in json where key != "__metadata__" {
                guard let tensor = value as? [String: Any], let shape = tensor["shape"] as? [Int] else { continue }
                total += Double(shape.reduce(1, *))
            }
        }
        return total / 1e9
    }
}

// MARK: - Family detection

nonisolated struct RepoAnalysis {
    var info: HFRepoInfo
    var family: String?
    var prebuiltBits: Int??  // .some(nil) → mflux BF16 save; nil → not an mflux build
    var isPrebuilt: Bool { prebuiltBits != nil }
    /// Files to download for this family (weights filtered by mflux patterns).
    var selectedFiles: [HFFile] = []
    var footprintAtSource: Footprint?  // runtime GB if run as downloaded
    var textParams: Double?
    var imageParams: Double?
    var vaeGB: Double = 0.2

    var downloadBytes: Int64 { selectedFiles.reduce(0) { $0 + $1.size } }
}

nonisolated enum FamilyDetector {
    static func role(ofPath path: String) -> String {
        let top = path.contains("/") ? String(path.split(separator: "/").first!) : ""
        let name = top.isEmpty ? path.lowercased() : top.lowercased()
        if name.contains("vae") || name.contains("decoder") { return "vae" }
        if name.contains("text_encoder") || name.contains("mllm") || name.contains("clip") || name.contains("t5") || name == "pe" { return "text" }
        if name.contains("tokenizer") || name.contains("processor") || name.contains("scheduler") { return "other" }
        return "image"
    }

    /// Picks the mflux family for a repo using pipeline class, base model and name heuristics.
    static func detect(_ info: HFRepoInfo, supported: [String]) -> String? {
        let candidates = [info.id] + info.baseModels
        for name in candidates {
            if let family = byName(name), supported.contains(family) { return family }
        }
        if let cls = info.pipelineClass?.lowercased() {
            let id = info.id.lowercased()
            let guess: String? = switch true {
            case cls.contains("zimage"): id.contains("turbo") ? "z-image-turbo" : "z-image"
            case cls.contains("flux2"): id.contains("9b") ? "flux2-klein-9b" : "flux2-klein-4b"
            case cls.contains("qwenimage") && !cls.contains("edit"): "qwen-image"
            case cls == "fluxpipeline": id.contains("schnell") ? "schnell" : "dev"
            default: nil
            }
            if let guess, supported.contains(guess) { return guess }
        }
        return nil
    }

    static func byName(_ raw: String) -> String? {
        let n = raw.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: ".", with: "-")
        let base = n.contains("base")
        if n.contains("z-image") || n.contains("zimage") { return n.contains("turbo") ? "z-image-turbo" : "z-image" }
        if n.contains("flux-3") || n.contains("flux3") { return base ? "flux3-image-klein-base" : "flux3-image-klein" }
        if n.contains("klein") {
            let nine = n.contains("9b")
            if base { return nine ? "flux2-klein-base-9b" : "flux2-klein-base-4b" }
            return nine ? "flux2-klein-9b" : "flux2-klein-4b"
        }
        if n.contains("krea-2") || n.contains("krea2") { return "krea-2" }
        if n.contains("flux-1-krea") || n.contains("krea-dev") { return "krea-dev" }
        if n.contains("schnell") { return "schnell" }
        if n.contains("flux-1-dev") && !n.contains("kontext") && !n.contains("fill") { return "dev" }
        if n.contains("qwen-image-2-1") || n.contains("qwen-image-21") {
            return n.contains("turbo") ? "qwen-image-2.1-turbo" : "qwen-image-2.1"
        }
        if n.contains("qwen-image") && !n.contains("edit") && !n.contains("layered") { return "qwen-image" }
        if n.contains("ernie-image") { return n.contains("turbo") ? "ernie-image-turbo" : "ernie-image" }
        if n.contains("iris-3b") { return "iris-3b" }
        if n.contains("anima") { return "anima-turbo" }
        if n.contains("boogu") { return "boogu-image-turbo" }
        if n.contains("moss-image") { return "moss-image-sft" }
        if n.contains("fibo-2") { return "fibo2" }
        if n.contains("ming-image") { return "ming-image-design" }
        return nil
    }

    static func prebuiltBits(_ info: HFRepoInfo) -> Int?? {
        prebuiltBits(id: info.id, tags: info.tags, library: info.libraryName)
    }

    /// nil → not an MLX (mflux) build; .some(nil) → BF16 build; .some(n) → n-bit build.
    static func prebuiltBits(id rawID: String, tags: [String], library: String?) -> Int?? {
        let id = rawID.lowercased()
        let isMflux = id.contains("mflux") || tags.contains("mflux") || library == "mflux"
        guard isMflux else { return nil }
        let compact = id.replacingOccurrences(of: "[-_ ]", with: "", options: .regularExpression)   // "8-bit" → "8bit"
        for (marker, bits) in [("q3", 3), ("3bit", 3), ("q4", 4), ("4bit", 4), ("q5", 5), ("5bit", 5),
                               ("q6", 6), ("6bit", 6), ("q8", 8), ("8bit", 8)] where compact.contains(marker) {
            return .some(bits)
        }
        return .some(nil)
    }

    /// Files to fetch: small files (configs, tokenizers) always, large weights only if mflux needs them.
    static func select(files: [HFFile], patterns: [String], prebuilt: Bool) -> [HFFile] {
        let skipExtensions = ["png", "jpg", "jpeg", "gif", "webp", "mp4", "pdf"]
        return files.filter { file in
            let ext = (file.path as NSString).pathExtension.lowercased()
            if skipExtensions.contains(ext) || file.path.hasPrefix(".") { return false }
            let isWeight = ["safetensors", "bin", "pt", "pth", "ckpt", "gguf", "onnx", "msgpack", "h5"].contains(ext)
            if !isWeight { return file.size < 60_000_000 }
            if ext != "safetensors" { return false }
            if prebuilt { return true }
            return Glob.matchesAny(file.path, patterns)
        }
    }

    static func footprint(of files: [HFFile]) -> Footprint {
        var fp = Footprint(text: 0, image: 0, vae: 0)
        for file in files where file.path.hasSuffix(".safetensors") {
            let gb = Double(file.size) / 1e9
            switch role(ofPath: file.path) {
            case "text": fp.text += gb
            case "vae": fp.vae += gb
            case "image": fp.image += gb
            default: break
            }
        }
        return fp
    }
}

// MARK: - Analysis

enum RepoAnalyzer {
    static func analyze(repo: String, family forced: String?, engine: Engine, countParams: Bool) async throws -> RepoAnalysis {
        let info = try await HFClient.info(repo)
        let family = forced ?? FamilyDetector.detect(info, supported: engine.supportedFamilies)
        let prebuilt = FamilyDetector.prebuiltBits(info)
        let patterns = family.flatMap { engine.caps(for: $0)?.patterns } ?? []
        let files = FamilyDetector.select(files: info.files, patterns: patterns.isEmpty ? ["*.safetensors"] : patterns,
                                          prebuilt: prebuilt != nil)
        var analysis = RepoAnalysis(info: info, family: family, prebuiltBits: prebuilt, selectedFiles: files)
        let footprint = FamilyDetector.footprint(of: files)
        analysis.footprintAtSource = footprint
        analysis.vaeGB = max(0.1, footprint.vae)
        if prebuilt == nil && countParams {
            let weights = files.filter { $0.path.hasSuffix(".safetensors") }
            async let text = HFClient.parameterCount(
                repo: repo, revision: info.sha, files: weights.filter { FamilyDetector.role(ofPath: $0.path) == "text" })
            async let image = HFClient.parameterCount(
                repo: repo, revision: info.sha, files: weights.filter { FamilyDetector.role(ofPath: $0.path) == "image" })
            analysis.textParams = await text ?? footprint.text / 2
            analysis.imageParams = await image ?? footprint.image / 2
        }
        return analysis
    }
}
