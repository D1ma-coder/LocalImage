import Foundation

enum Aspect: String, Codable, CaseIterable, Identifiable {
    case square = "1:1", photo = "4:3", classic = "3:2", wide = "16:9", portrait = "3:4", tall = "2:3", story = "9:16", source = "src"

    var id: String { rawValue }
    var ratio: Double {
        switch self {
        case .square: 1
        case .photo: 4.0 / 3
        case .classic: 3.0 / 2
        case .wide: 16.0 / 9
        case .portrait: 3.0 / 4
        case .tall: 2.0 / 3
        case .story: 9.0 / 16
        case .source: 1
        }
    }

    var title: String { self == .source ? String(localized: "Как у исходника") : rawValue }
    static var presets: [Aspect] { [.square, .photo, .classic, .wide, .portrait, .tall, .story] }
}

enum Quality: String, Codable, CaseIterable, Identifiable {
    case draft, standard, high, max

    var id: String { rawValue }
    var megapixels: Double {
        switch self {
        case .draft: 0.42
        case .standard: 1.0
        case .high: 1.6
        case .max: 2.3
        }
    }

    var title: String {
        switch self {
        case .draft: String(localized: "Черновик")
        case .standard: String(localized: "Стандарт")
        case .high: String(localized: "Высокое")
        case .max: String(localized: "Максимум")
        }
    }
}

enum MemoryMode: String, Codable, CaseIterable, Identifiable {
    case auto, saver, speed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: String(localized: "Авто")
        case .saver: String(localized: "Экономия")
        case .speed: String(localized: "Скорость")
        }
    }
}

enum Precision: String, Codable, CaseIterable, Identifiable {
    case auto, bfloat16, float16
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: String(localized: "Авто")
        case .bfloat16: "bfloat16"
        case .float16: "float16"
        }
    }
}

/// Everything the user can set for a generation. Persisted between launches.
struct GenerationSettings: Codable, Equatable {
    var modelID: String?
    var prompt = ""
    var negativePrompt = ""
    var aspect: Aspect = .square
    var quality: Quality = .standard
    var steps: Int?  // nil = model default
    var count = 1
    var seed = Int.random(in: 1...999_999_999)
    var randomSeed = true
    var guidance: Double?  // nil = model default
    /// First attached image (also the img2img source); the rest are extra references.
    var initImagePath: String?
    var extraImagePaths: [String]?
    var strength = 0.4
    var memoryMode: MemoryMode = .auto
    var precision: Precision = .auto
    var previewEvery = 1  // 0 = off
    var previewFull = false

    /// All attached images in order.
    var imagePaths: [String] {
        get { (initImagePath.map { [$0] } ?? []) + (extraImagePaths ?? []) }
        set {
            initImagePath = newValue.first
            extraImagePaths = newValue.count > 1 ? Array(newValue.dropFirst()) : nil
        }
    }

    private static let key = "generationSettings.v1"

    static func load() -> GenerationSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(GenerationSettings.self, from: data) else { return GenerationSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Pixel size for the current aspect & quality (multiples of 16, as the transformers patchify 2×2 latents).
    func dimensions(sourceAspect: Double?) -> (width: Int, height: Int) {
        let ratio = aspect == .source ? (sourceAspect ?? 1) : aspect.ratio
        let pixels = quality.megapixels * 1_048_576
        let width = (pixels * ratio).squareRoot()
        let height = width / ratio
        func snap(_ value: Double) -> Int { max(256, Int((value / 16).rounded()) * 16) }
        return (snap(width), snap(height))
    }
}

/// Saved next to each image as `<name>.lix.json`; drives the gallery and "repeat".
nonisolated struct GenerationRecord: Codable, Hashable {
    var prompt: String
    var negativePrompt: String?
    var modelID: String
    var modelTitle: String
    var family: String
    var quant: String
    var width: Int
    var height: Int
    var steps: Int
    var seed: Int
    var guidance: Double?
    var initImagePath: String?
    var extraImagePaths: [String]?
    var strength: Double?
    var seconds: Double?
    var date: Date

    var imagePaths: [String] { (initImagePath.map { [$0] } ?? []) + (extraImagePaths ?? []) }
}
