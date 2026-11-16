import Foundation

/// How hard a generation may drive this Mac, set in Settings → Load.
///
/// The GPU limit works as a duty cycle: after each step the worker idles for
/// `step time × (100 / percent − 1)`. It re-reads the value from `fileURL` every step,
/// so a change applies to the generation that is already running.
nonisolated enum HardwareLoad {
    static let percentKey = "hardwareLoad.percent"
    static let lowPriorityKey = "hardwareLoad.lowPriority"
    static let range = 30...100

    static var percent: Int {
        let value = UserDefaults.standard.integer(forKey: percentKey)
        return value == 0 ? 100 : min(range.upperBound, max(range.lowerBound, value))
    }

    /// Share of wall time the GPU spends computing (1 = no pauses).
    static var fraction: Double { Double(percent) / 100 }

    static var lowPriority: Bool { UserDefaults.standard.bool(forKey: lowPriorityKey) }

    static var fileURL: URL { Paths.appSupport.appendingPathComponent("hardware-load") }

    /// Writes the current limit where the worker looks for it.
    static func publish() {
        Paths.ensure(Paths.appSupport)
        try? String(percent).write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
