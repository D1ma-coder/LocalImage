import Foundation

/// All on-disk locations the app uses. Nothing lives inside the app bundle except the worker script.
nonisolated enum Paths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LocalImage", isDirectory: true)
    }()

    static var engine: URL { appSupport.appendingPathComponent("engine", isDirectory: true) }
    static var venv: URL { engine.appendingPathComponent("venv", isDirectory: true) }
    static var python: URL { venv.appendingPathComponent("bin/python3") }
    static var familiesCache: URL { engine.appendingPathComponent("families.json") }
    static var engineLog: URL { engine.appendingPathComponent("install.log") }

    static var defaultModels: URL { appSupport.appendingPathComponent("models", isDirectory: true) }
    static var defaultOutputs: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalImage", isDirectory: true)
    }

    static var previews: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LocalImagePreviews", isDirectory: true)
    }

    static var models: URL {
        if let custom = UserDefaults.standard.string(forKey: "modelsDirectory"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return defaultModels
    }

    static var outputs: URL {
        if let custom = UserDefaults.standard.string(forKey: "outputsDirectory"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return defaultOutputs
    }

    static var workerScript: URL? {
        if let override = ProcessInfo.processInfo.environment["LIX_WORKER_SCRIPT"] {
            return URL(fileURLWithPath: override)
        }
        return Bundle.main.url(forResource: "lix_worker", withExtension: "py")
    }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func freeDiskBytes(at url: URL) -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}
