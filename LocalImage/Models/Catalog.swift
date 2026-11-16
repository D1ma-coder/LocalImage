import Foundation

/// A pre-quantized community build of a model (mflux format, ready to run).
struct PrebuiltVariant: Hashable, Identifiable {
    var repo: String
    var bits: Int?
    /// Runtime GB per part, measured from the published files.
    var footprint: Footprint

    var id: String { repo }
}

/// Curated, known-good models. Anything else is reachable through Hugging Face search.
struct CatalogEntry: Identifiable, Hashable {
    var family: String
    var title: String
    var tagline: String
    var about: String
    var originalRepo: String
    var gated: Bool
    var textEncoder: String
    var imageParams: Double  // billions
    var textParams: Double
    var vaeGB: Double
    var prebuilt: [PrebuiltVariant]
    var tags: [String]

    var id: String { family }
    var defaultFootprint: Footprint { prebuilt.first?.footprint ?? Footprint.from(textParams: textParams, imageParams: imageParams, vaeGB: vaeGB, textBits: 4, imageBits: 4) }
}

enum Catalog {
    static let entries: [CatalogEntry] = [
        CatalogEntry(
            family: "z-image-turbo", title: "Z-Image Turbo",
            tagline: "Быстрая, фотореалистичная, 9 шагов",
            about: String(localized: "Модель Tongyi-MAI на 6 млрд параметров с текстовым энкодером Qwen3-4B. Лучшее соотношение качества и скорости для 16 ГБ: реализм, свет, текстуры, понимает русский и китайский текст в промпте. Distilled — guidance не нужен."),
            originalRepo: "Tongyi-MAI/Z-Image-Turbo", gated: false, textEncoder: "Qwen3-4B",
            imageParams: 6.15, textParams: 4.02, vaeGB: 0.17,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/z-image-turbo-mflux-q4", bits: 4, footprint: Footprint(text: 2.26, image: 3.46, vae: 0.17)),
                PrebuiltVariant(repo: "mflux-community/z-image-turbo-mflux-q8", bits: 8, footprint: Footprint(text: 4.27, image: 6.54, vae: 0.17)),
            ],
            tags: ["6B", "Быстрая", "Фото"]),
        CatalogEntry(
            family: "flux2-klein-4b", title: "FLUX.2 klein 4B",
            tagline: "Самая быстрая: 4 шага, лицензия Apache 2.0",
            about: String(localized: "Компактная модель Black Forest Labs (4 млрд + Qwen3-4B). Генерирует за 4 шага, хорошо держит композицию и умеет img2img. Отличный выбор для быстрых итераций на 16 ГБ."),
            originalRepo: "black-forest-labs/FLUX.2-klein-4B", gated: false, textEncoder: "Qwen3-4B",
            imageParams: 3.88, textParams: 4.02, vaeGB: 0.17,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/flux2-klein-4b-mflux-q4", bits: 4, footprint: Footprint(text: 2.26, image: 2.18, vae: 0.17)),
                PrebuiltVariant(repo: "mflux-community/flux2-klein-4b-mflux-q8", bits: 8, footprint: Footprint(text: 4.27, image: 4.12, vae: 0.17)),
            ],
            tags: ["4B", "Самая быстрая", "Apache 2.0"]),
        CatalogEntry(
            family: "flux3-image-klein", title: "FLUX 3 Image klein",
            tagline: "Сильная типографика и композиция, 16 шагов",
            about: String(localized: "Модель 5.6 млрд с энкодером на 4 млрд. Хорошо рисует текст на изображениях, понимает сложные сцены. Оригинал требует принять лицензию на Hugging Face; готовые сборки доступны сразу."),
            originalRepo: "black-forest-labs/flux-3-image-klein", gated: true, textEncoder: "Qwen3-4B",
            imageParams: 5.55, textParams: 4.44, vaeGB: 0.34,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/flux-3-image-klein-mflux-q4", bits: 4, footprint: Footprint(text: 2.04, image: 3.12, vae: 0.17)),
                PrebuiltVariant(repo: "mflux-community/flux-3-image-klein-mflux-q8", bits: 8, footprint: Footprint(text: 3.85, image: 5.90, vae: 0.17)),
            ],
            tags: ["5.6B", "Текст", "Композиция"]),
        CatalogEntry(
            family: "qwen-image-2.1-turbo", title: "Qwen-Image 2.1 Turbo",
            tagline: "VL-энкодер Qwen3-VL, точное следование промпту",
            about: String(localized: "7.1 млрд в диффузионной части и мультимодальный энкодер Qwen3-VL-8B. Отлично понимает длинные описания и знания о мире, рендерит текст. Здесь особенно полезно раздельное квантование: VL-энкодер большой, но выгружается до начала рисования."),
            originalRepo: "Qwen/Qwen-Image-2.1-Turbo", gated: false, textEncoder: "Qwen3-VL-8B",
            imageParams: 7.1, textParams: 8.77, vaeGB: 0.68,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/qwen-image-2-1-turbo-mflux-q4", bits: 4, footprint: Footprint(text: 5.13, image: 4.15, vae: 0.68)),
                PrebuiltVariant(repo: "mflux-community/qwen-image-2-1-turbo-mflux-q6", bits: 6, footprint: Footprint(text: 7.29, image: 5.90, vae: 0.68)),
                PrebuiltVariant(repo: "mflux-community/qwen-image-2-1-turbo-mflux-q8", bits: 8, footprint: Footprint(text: 9.44, image: 7.66, vae: 0.68)),
            ],
            tags: ["7.1B", "VL", "Текст"]),
        CatalogEntry(
            family: "flux2-klein-9b", title: "FLUX.2 klein 9B",
            tagline: "Старшая klein: больше деталей, 4 шага",
            about: String(localized: "9 млрд параметров и энкодер Qwen3-8B. Заметно детальнее 4B при той же скорости в шагах. Некоммерческая лицензия; оригинал — после принятия условий на Hugging Face."),
            originalRepo: "black-forest-labs/FLUX.2-klein-9B", gated: true, textEncoder: "Qwen3-8B",
            imageParams: 9.08, textParams: 8.19, vaeGB: 0.17,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/flux2-klein-9b-mflux-q4", bits: 4, footprint: Footprint(text: 4.26, image: 5.11, vae: 0.17)),
                PrebuiltVariant(repo: "mflux-community/flux2-klein-9b-mflux-q8", bits: 8, footprint: Footprint(text: 8.04, image: 9.65, vae: 0.17)),
            ],
            tags: ["9B", "Детали"]),
        CatalogEntry(
            family: "krea-2", title: "Krea 2 Turbo",
            tagline: "Широкий диапазон стилей, 8 шагов",
            about: String(localized: "12 млрд параметров. Сильна в художественных стилях и креативных экспериментах. На 16 ГБ — только 4-битная сборка и умеренные разрешения."),
            originalRepo: "krea/Krea-2-Turbo", gated: true, textEncoder: "Qwen3-4B",
            imageParams: 13.1, textParams: 4.44, vaeGB: 0.51,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/krea-2-turbo-mflux-q4", bits: 4, footprint: Footprint(text: 8.04, image: 7.21, vae: 0.51)),
                PrebuiltVariant(repo: "mflux-community/krea-2-turbo-mflux-q8", bits: 8, footprint: Footprint(text: 8.04, image: 13.62, vae: 0.51)),
            ],
            tags: ["12B", "Стили"]),
        CatalogEntry(
            family: "qwen-image", title: "Qwen-Image 2512",
            tagline: "Большая модель 20B с VL-энкодером",
            about: String(localized: "20 млрд параметров и Qwen2.5-VL-7B. Лучшее понимание сложных промптов и мира, но медленная и требует 32 ГБ+ для комфортной работы."),
            originalRepo: "Qwen/Qwen-Image-2512", gated: false, textEncoder: "Qwen2.5-VL-7B",
            imageParams: 20.4, textParams: 8.29, vaeGB: 0.25,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/qwen-image-2512-mflux-q4", bits: 4, footprint: Footprint(text: 14.14, image: 13.20, vae: 0.25)),
                PrebuiltVariant(repo: "mflux-community/qwen-image-2512-mflux-q8", bits: 8, footprint: Footprint(text: 14.14, image: 21.71, vae: 0.25)),
            ],
            tags: ["20B", "VL", "Тяжёлая"]),
        CatalogEntry(
            family: "schnell", title: "FLUX.1 schnell",
            tagline: "Классика, 4 шага",
            about: String(localized: "Первое поколение FLUX (12 млрд + T5-XXL). Проверенная модель с огромным количеством LoRA в сообществе."),
            originalRepo: "black-forest-labs/FLUX.1-schnell", gated: true, textEncoder: "T5-XXL + CLIP",
            imageParams: 11.9, textParams: 4.88, vaeGB: 0.17,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/flux-1-schnell-mflux-q4", bits: 4, footprint: Footprint(text: 2.75, image: 6.69, vae: 0.16)),
            ],
            tags: ["12B", "Классика"]),
        CatalogEntry(
            family: "z-image", title: "Z-Image",
            tagline: "Базовая версия Z-Image Turbo",
            about: String(localized: "Недистиллированная базовая модель Tongyi-MAI на 6 млрд параметров с энкодером Qwen3-4B. Больше шагов, но поддерживает guidance и негативный промпт."),
            originalRepo: "Tongyi-MAI/Z-Image", gated: false, textEncoder: "Qwen3-4B",
            imageParams: 6.15, textParams: 4.02, vaeGB: 0.17,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/z-image-base-mflux-q4", bits: 4, footprint: Footprint(text: 2.26, image: 3.46, vae: 0.16)),
                PrebuiltVariant(repo: "mflux-community/z-image-base-mflux-q8", bits: 8, footprint: Footprint(text: 4.27, image: 6.54, vae: 0.17)),
            ],
            tags: ["6B", "Base", "Apache 2.0"]),
        CatalogEntry(
            family: "flux2-klein-base-4b", title: "FLUX.2 klein Base 4B",
            tagline: "Базовая klein 4B",
            about: String(localized: "Недистиллированная версия FLUX.2 klein 4B: больше шагов, поддерживает guidance. Лицензия Apache 2.0."),
            originalRepo: "black-forest-labs/FLUX.2-klein-base-4B", gated: false, textEncoder: "Qwen3-4B",
            imageParams: 3.88, textParams: 4.02, vaeGB: 0.17,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/flux-2-klein-base-4b-mflux-q4", bits: 4, footprint: Footprint(text: 2.26, image: 2.18, vae: 0.17)),
                PrebuiltVariant(repo: "mflux-community/flux-2-klein-base-4b-mflux-q8", bits: 8, footprint: Footprint(text: 4.27, image: 4.12, vae: 0.17)),
            ],
            tags: ["4B", "Base", "Apache 2.0"]),
        CatalogEntry(
            family: "qwen-image-2.1", title: "Qwen-Image 2.1",
            tagline: "Полная версия Qwen-Image 2.1",
            about: String(localized: "7.1 млрд в диффузионной части и энкодер Qwen3-VL-8B. Недистиллированная версия: больше шагов, поддерживает guidance."),
            originalRepo: "Qwen/Qwen-Image-2.1", gated: false, textEncoder: "Qwen3-VL-8B",
            imageParams: 7.1, textParams: 8.77, vaeGB: 0.68,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/qwen-image-2-1-mflux-q4", bits: 4, footprint: Footprint(text: 5.13, image: 4.15, vae: 0.68)),
                PrebuiltVariant(repo: "mflux-community/qwen-image-2-1-mflux-q8", bits: 8, footprint: Footprint(text: 9.44, image: 7.66, vae: 0.68)),
            ],
            tags: ["7.1B", "VL"]),
        CatalogEntry(
            family: "iris-3b", title: "Iris 3B",
            tagline: "Компактная 3B",
            about: String(localized: "Модель speridlabs на 3 млрд параметров. Лицензия Apache 2.0."),
            originalRepo: "speridlabs/iris-3b", gated: false, textEncoder: "LLM 4B",
            imageParams: 2.99, textParams: 4.02, vaeGB: 0.17,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/iris-3b-turbo-mflux-q4", bits: 4, footprint: Footprint(text: 2.26, image: 2.78, vae: 0.17)),
                PrebuiltVariant(repo: "mflux-community/iris-3b-turbo-mflux-q8", bits: 8, footprint: Footprint(text: 4.27, image: 3.73, vae: 0.17)),
            ],
            tags: ["3B", "Apache 2.0"]),
        CatalogEntry(
            family: "ernie-image-turbo", title: "ERNIE-Image Turbo",
            tagline: "Модель Baidu, быстрая",
            about: String(localized: "Модель Baidu на 8 млрд параметров, дистиллированная версия. Лицензия Apache 2.0."),
            originalRepo: "baidu/ERNIE-Image-Turbo", gated: false, textEncoder: "LLM 3.9B",
            imageParams: 8.03, textParams: 3.85, vaeGB: 0.17,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/ernie-image-turbo-mflux-q4", bits: 4, footprint: Footprint(text: 1.93, image: 4.52, vae: 0.17)),
                PrebuiltVariant(repo: "mflux-community/ernie-image-turbo-mflux-q8", bits: 8, footprint: Footprint(text: 3.64, image: 8.54, vae: 0.17)),
            ],
            tags: ["8B", "Быстрая", "Apache 2.0"]),
        CatalogEntry(
            family: "ernie-image", title: "ERNIE-Image",
            tagline: "Модель Baidu, базовая",
            about: String(localized: "Модель Baidu на 8 млрд параметров, базовая версия с guidance. Лицензия Apache 2.0."),
            originalRepo: "baidu/ERNIE-Image", gated: false, textEncoder: "LLM 3.9B",
            imageParams: 8.03, textParams: 3.85, vaeGB: 0.17,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/ernie-image-base-mflux-q4", bits: 4, footprint: Footprint(text: 1.93, image: 4.52, vae: 0.17)),
                PrebuiltVariant(repo: "mflux-community/ernie-image-base-mflux-q8", bits: 8, footprint: Footprint(text: 3.64, image: 8.54, vae: 0.17)),
            ],
            tags: ["8B", "Base", "Apache 2.0"]),
        CatalogEntry(
            family: "boogu-image-turbo", title: "Boogu Image Turbo",
            tagline: "10B с мультимодальным энкодером",
            about: String(localized: "Модель на 10 млрд параметров с мультимодальным энкодером. Лицензия Apache 2.0."),
            originalRepo: "Boogu/Boogu-Image-0.1-Turbo", gated: false, textEncoder: "MLLM 8.8B",
            imageParams: 10.3, textParams: 8.77, vaeGB: 0.34,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/boogu-image-turbo-mflux-q4", bits: 4, footprint: Footprint(text: 4.73, image: 6.44, vae: 0.16)),
                PrebuiltVariant(repo: "mflux-community/boogu-image-turbo-mflux-q8", bits: 8, footprint: Footprint(text: 8.51, image: 11.58, vae: 0.17)),
            ],
            tags: ["10B", "VL", "Apache 2.0"]),
        CatalogEntry(
            family: "moss-image-sft", title: "MOSS-Image",
            tagline: "Модель OpenMOSS",
            about: String(localized: "Модель OpenMOSS на 5 млрд параметров. Лицензия Apache 2.0."),
            originalRepo: "OpenMOSS-Team/MOSS-Image-SFT", gated: false, textEncoder: "LLM 8.4B",
            imageParams: 5.08, textParams: 8.4, vaeGB: 0.25,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/moss-image-sft-mflux-q4", bits: 4, footprint: Footprint(text: 4.47, image: 2.86, vae: 0.12)),
                PrebuiltVariant(repo: "mflux-community/moss-image-sft-mflux-q8", bits: 8, footprint: Footprint(text: 8.43, image: 5.4, vae: 0.12)),
            ],
            tags: ["5B", "Apache 2.0"]),
        CatalogEntry(
            family: "anima-turbo", title: "Anima Turbo",
            tagline: "Лёгкая аниме-модель",
            about: String(localized: "Компактная модель circlestone-labs для аниме-иллюстраций, быстрая версия."),
            originalRepo: "circlestone-labs/Anima", gated: false, textEncoder: "LLM 0.6B",
            imageParams: 2.4, textParams: 0.6, vaeGB: 0.25,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/anima-turbo-mflux-q4", bits: 4, footprint: Footprint(text: 1.19, image: 1.65, vae: 0.25)),
                PrebuiltVariant(repo: "mflux-community/anima-turbo-mflux-q8", bits: 8, footprint: Footprint(text: 1.19, image: 2.53, vae: 0.25)),
            ],
            tags: ["2B", "Аниме", "Лёгкая"]),
        CatalogEntry(
            family: "anima-aesthetic", title: "Anima Aesthetic",
            tagline: "Аниме, эстетическая версия",
            about: String(localized: "Компактная модель circlestone-labs для аниме-иллюстраций, версия с упором на эстетику."),
            originalRepo: "circlestone-labs/Anima", gated: false, textEncoder: "LLM 0.6B",
            imageParams: 2.4, textParams: 0.6, vaeGB: 0.25,
            prebuilt: [
                PrebuiltVariant(repo: "mflux-community/anima-aesthetic-mflux-q4", bits: 4, footprint: Footprint(text: 1.19, image: 1.65, vae: 0.25)),
                PrebuiltVariant(repo: "mflux-community/anima-aesthetic-mflux-q8", bits: 8, footprint: Footprint(text: 1.19, image: 2.53, vae: 0.25)),
            ],
            tags: ["2B", "Аниме", "Лёгкая"]),
    ]

    static func entry(for family: String) -> CatalogEntry? {
        entries.first { $0.family == family }
    }

    /// Human-readable names for every family the engine supports.
    static func title(for family: String) -> String {
        if let entry = entry(for: family) { return entry.title }
        return [
            "z-image": "Z-Image (Base)", "flux2-klein-base-4b": "FLUX.2 klein Base 4B",
            "flux2-klein-base-9b": "FLUX.2 klein Base 9B", "flux3-image-klein-base": "FLUX 3 Image klein Base",
            "qwen-image-2.1": "Qwen-Image 2.1", "dev": "FLUX.1 dev", "krea-dev": "FLUX.1 Krea dev",
            "iris-3b": "Iris 3B", "anima-turbo": "Anima Turbo", "anima-aesthetic": "Anima Aesthetic",
            "ernie-image-turbo": "ERNIE-Image Turbo", "ernie-image": "ERNIE-Image",
            "boogu-image-turbo": "Boogu Image Turbo", "lens-turbo": "Lens Turbo",
            "moss-image-sft": "MOSS-Image", "fibo2": "FIBO 2", "ming-image-design": "Ming-Image Design",
        ][family] ?? family
    }
}
