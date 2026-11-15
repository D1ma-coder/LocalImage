import Foundation

/// Runtime size of a model's parts, in GB of (unified) memory.
nonisolated struct Footprint: Codable, Hashable {
    var text: Double
    var image: Double
    var vae: Double

    var total: Double { text + image + vae }

    /// Parameter counts (billions) → runtime GB at the given bit widths.
    static func from(textParams: Double, imageParams: Double, vaeGB: Double, textBits: Int?, imageBits: Int?) -> Footprint {
        Footprint(
            text: MemoryModel.runtimeGB(params: textParams, bits: textBits),
            image: MemoryModel.runtimeGB(params: imageParams, bits: imageBits),
            vae: vaeGB)
    }
}

nonisolated enum Fit: Int, Comparable {
    case comfortable = 0, tight, tooBig

    static func < (lhs: Fit, rhs: Fit) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .comfortable: "Хватает памяти"
        case .tight: "Впритык"
        case .tooBig: "Не хватит памяти"
        }
    }

    var symbol: String {
        switch self {
        case .comfortable: "checkmark.circle.fill"
        case .tight: "exclamationmark.triangle.fill"
        case .tooBig: "xmark.octagon.fill"
        }
    }
}

/// Memory model calibrated on real runs (Z-Image Turbo q4 on M2 Pro 16 GB):
/// MLX loads weights lazily and mflux evicts the text encoder before denoising,
/// so for a single image the text and image parts never peak together.
nonisolated enum MemoryModel {
    static let allowedBits = [3, 4, 5, 6, 8, 16]

    static func runtimeGB(params: Double, bits: Int?) -> Double {
        guard let bits, bits < 16 else { return params * 2 }
        // packed weights + bf16 scale & bias per group of 64
        return params * (Double(bits) / 8 + 0.0625)
    }

    /// Denoising activations, GB per megapixel; ~2.4 GB/MP measured for a 6B transformer.
    static func activationsGB(imageGB: Double, megapixels: Double) -> Double {
        let approxParams = max(1, imageGB / 0.6)  // ~0.56 GB per B at 4-bit
        return (0.9 + 0.25 * min(approxParams, 24)) * megapixels
    }

    static func peakGB(_ footprint: Footprint, megapixels: Double = 1.0, batch: Bool = false) -> Double {
        let activations = activationsGB(imageGB: footprint.image, megapixels: megapixels)
        let denoise = footprint.image + footprint.vae + activations
        let encode = footprint.text + 0.6
        let overhead = 0.7  // Python, tokenizers, Metal heaps
        return (batch ? footprint.text + denoise : max(encode, denoise)) + overhead
    }

    static func fit(peak: Double, hardware: Hardware = .current) -> Fit {
        if peak <= hardware.budgetGB * 0.95 { return .comfortable }
        if peak <= hardware.hardLimitGB { return .tight }
        return .tooBig
    }

    static func fit(_ footprint: Footprint, megapixels: Double = 1.0, hardware: Hardware = .current) -> Fit {
        fit(peak: peakGB(footprint, megapixels: megapixels), hardware: hardware)
    }

    // MARK: Quantization combos

    static func imageQuality(_ bits: Int) -> Double {
        [3: 0.80, 4: 0.90, 5: 0.94, 6: 0.97, 8: 0.995, 16: 1.0][bits] ?? 0.9
    }

    static func textQuality(_ bits: Int) -> Double {
        [3: 0.86, 4: 0.95, 5: 0.97, 6: 0.985, 8: 0.998, 16: 1.0][bits] ?? 0.95
    }

    struct Combo: Hashable, Identifiable {
        var textBits: Int
        var imageBits: Int
        var footprint: Footprint
        var peak: Double
        var fit: Fit
        var label: String = ""

        var id: String { "\(textBits)-\(imageBits)" }
        var quality: Double { 0.7 * MemoryModel.imageQuality(imageBits) + 0.3 * MemoryModel.textQuality(textBits) }
        var diskGB: Double { footprint.total }
        var short: String { "Текст \(Format.bits(textBits)) · Изображение \(Format.bits(imageBits))" }
    }

    static func allCombos(textParams: Double, imageParams: Double, vaeGB: Double, hardware: Hardware = .current) -> [Combo] {
        var combos: [Combo] = []
        // BF16 text encoders are indistinguishable from 8-bit but take twice the disk and batch memory.
        for t in [4, 6, 8] {
            for i in allowedBits {
                let fp = Footprint.from(textParams: textParams, imageParams: imageParams, vaeGB: vaeGB, textBits: t, imageBits: i)
                let peak = peakGB(fp)
                combos.append(Combo(textBits: t, imageBits: i, footprint: fp, peak: peak, fit: fit(peak: peak, hardware: hardware)))
            }
        }
        return combos
    }

    /// Up to three named suggestions: best quality that fits comfortably, a lighter balance, and the minimum.
    static func suggestions(textParams: Double, imageParams: Double, vaeGB: Double, hardware: Hardware = .current) -> [Combo] {
        let combos = allCombos(textParams: textParams, imageParams: imageParams, vaeGB: vaeGB, hardware: hardware)
        func best(_ candidates: [Combo]) -> Combo? {
            candidates.max { a, b in
                a.quality == b.quality ? a.diskGB > b.diskGB : a.quality < b.quality
            }
        }
        var result: [Combo] = []
        let comfortable = combos.filter { $0.fit == .comfortable }
        if var top = best(comfortable) ?? best(combos.filter { $0.fit == .tight }) {
            top.label = "Рекомендуем"
            result.append(top)
            let lighter = comfortable.filter { $0.diskGB <= top.diskGB * 0.72 && $0.imageBits >= 4 }
            if var balance = best(lighter) {
                balance.label = "Баланс"
                result.append(balance)
            }
        }
        if var minimum = combos.filter({ $0.textBits == 4 && $0.imageBits == 4 }).first,
           !result.contains(where: { $0.id == minimum.id }) {
            minimum.label = "Минимум памяти"
            result.append(minimum)
        }
        return result
    }
}
