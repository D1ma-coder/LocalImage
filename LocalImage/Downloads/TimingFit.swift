import Foundation

/// One measured duration and the size it depends on (megapixels of 1024×1024).
nonisolated struct TimingSample: Codable, Hashable {
    var x: Double
    var seconds: Double
}

/// Learns how long a stage takes on this Mac from its own recent measurements.
///
/// A single "seconds per megapixel" mixes up runs that differ in what really drives the time:
/// reference images add their tokens to every step and must be encoded before the first one,
/// and step time does not grow exactly in proportion to size. So every stage keeps a few samples
/// tagged with its own size and predicts from the ones closest to the run at hand.
nonisolated enum TimingFit {
    static let keep = 16

    static func appending(_ sample: TimingSample, to samples: [TimingSample]?) -> [TimingSample] {
        Array(((samples ?? []) + [sample]).suffix(keep))
    }

    /// The newest sample counts most: it reflects the Mac's current state (free memory, heat).
    private static func recency(_ count: Int) -> [Double] {
        (0..<count).map { pow(0.65, Double(count - 1 - $0)) }
    }

    /// seconds ≈ c · xᵏ. The exponent is fitted once the samples cover different sizes (else
    /// `exponent`), and the prediction leans on the samples nearest to `x`.
    static func power(_ samples: [TimingSample]?, at x: Double, exponent: Double, range: ClosedRange<Double>) -> Double? {
        let s = (samples ?? []).filter { $0.x > 0 && $0.seconds > 0 }
        guard !s.isEmpty, x > 0 else { return nil }
        let w = recency(s.count)
        let total = w.reduce(0, +)
        let lx = s.map { log($0.x) }, ly = s.map { log($0.seconds) }
        let mx = zip(w, lx).map(*).reduce(0, +) / total
        let my = zip(w, ly).map(*).reduce(0, +) / total
        let sxx = s.indices.map { w[$0] * (lx[$0] - mx) * (lx[$0] - mx) }.reduce(0, +) / total
        var k = exponent
        if sxx > 0.01 {
            let sxy = s.indices.map { w[$0] * (lx[$0] - mx) * (ly[$0] - my) }.reduce(0, +) / total
            k = (sxy / sxx).clamped(range.lowerBound, range.upperBound)
        }
        let target = log(x)
        var num = 0.0, den = 0.0
        for i in s.indices {
            let d = target - lx[i]
            let weight = w[i] * exp(-d * d / 0.5)  // twice the size: ×0.4, four times: ×0.02
            num += weight * (ly[i] + k * d)
            den += weight
        }
        return den > 0 ? exp(num / den) : nil
    }

    /// seconds ≈ a + b · x with b ≥ 0; `slope` stands in for b until the samples cover different x.
    static func linear(_ samples: [TimingSample]?, at x: Double, slope: Double) -> Double? {
        let s = (samples ?? []).filter { $0.seconds > 0 }
        guard !s.isEmpty else { return nil }
        let w = recency(s.count)
        let total = w.reduce(0, +)
        let mx = s.indices.map { w[$0] * s[$0].x }.reduce(0, +) / total
        let my = s.indices.map { w[$0] * s[$0].seconds }.reduce(0, +) / total
        let sxx = s.indices.map { w[$0] * (s[$0].x - mx) * (s[$0].x - mx) }.reduce(0, +) / total
        var b = slope
        if sxx > 0.04 {
            b = max(0, s.indices.map { w[$0] * (s[$0].x - mx) * (s[$0].seconds - my) }.reduce(0, +) / total / sxx)
        }
        return max(0.5, my + b * (x - mx))
    }
}
