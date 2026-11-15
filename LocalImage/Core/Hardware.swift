import Foundation
import IOKit
import Metal

/// What this Mac can do. Used for memory hints and sensible defaults.
nonisolated struct Hardware: Sendable {
    let chip: String
    let memoryBytes: UInt64
    /// Metal's recommended working set: what the GPU can keep resident without the system paging.
    let gpuBudgetBytes: UInt64
    let gpuCores: Int?
    let performanceCores: Int

    static let current = Hardware.detect()

    var memoryGB: Double { Double(memoryBytes) / 1_073_741_824 }
    var budgetGB: Double { Double(gpuBudgetBytes) / 1e9 }
    /// Above this, macOS starts compressing/swapping hard and generation crawls.
    var hardLimitGB: Double { Double(memoryBytes) / 1e9 * 0.86 }

    /// bfloat16 is emulated on M1/M2 GPUs; float16 is noticeably faster there (measured +27% on M2 Pro).
    var prefersFloat16: Bool {
        let name = chip.lowercased()
        return name.contains("m1") || name.contains("m2")
    }

    var isLowMemory: Bool { memoryGB <= 18 }

    private static func detect() -> Hardware {
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let memory = sysctlUInt64("hw.memsize") ?? 0
        let device = MTLCreateSystemDefaultDevice()
        let budget = device?.recommendedMaxWorkingSetSize ?? UInt64(Double(memory) * 0.66)
        let perf = Int(sysctlUInt64("hw.perflevel0.physicalcpu") ?? 0)
        return Hardware(chip: chip, memoryBytes: memory, gpuBudgetBytes: budget, gpuCores: gpuCoreCount(), performanceCores: perf)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func gpuCoreCount() -> Int? {
        let matching = IOServiceMatching("AGXAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? NSNumber)?.intValue
    }
}
