import Foundation

/// Downloads one file with HTTP Range resume into `<destination>.part`, then moves it into place.
/// Data arrives on a background delegate queue and is written straight to disk (constant memory).
nonisolated final class FileTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Failure: LocalizedError {
        var message: String
        var retryable: Bool
        var errorDescription: String? { message }
    }

    private let url: URL
    private let destination: URL
    private let partURL: URL
    private let expectedSize: Int64
    private let onBytes: @Sendable (Int64) -> Void

    private var session: URLSession!
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var received: Int64 = 0
    private let lock = NSLock()

    init(url: URL, destination: URL, expectedSize: Int64, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.url = url
        self.destination = destination
        self.partURL = destination.appendingPathExtension("part")
        self.expectedSize = expectedSize
        self.onBytes = onBytes
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 4
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    var partialBytes: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? Int64) ?? 0
    }

    /// Performs one attempt from the current partial offset.
    func run() async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: partURL.path) {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
        }
        let offset = partialBytes
        if expectedSize > 0 && offset == expectedSize {
            try finish()
            return
        }
        if expectedSize > 0 && offset > expectedSize {
            try? FileManager.default.removeItem(at: partURL)
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
        }
        var request = HFClient.request(url)
        request.timeoutInterval = 60
        let start = partialBytes
        if start > 0 { request.setValue("bytes=\(start)-", forHTTPHeaderField: "Range") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.continuation = continuation
                self.received = start
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
        try finish()
    }

    func invalidate() { session.invalidateAndCancel() }

    private func finish() throws {
        let size = partialBytes
        if expectedSize > 0 && size != expectedSize {
            throw Failure(message: String(localized: "Размер файла не совпал (\(size) из \(expectedSize))"), retryable: true)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partURL, to: destination)
    }

    private func complete(_ error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        try? handle?.close()
        handle = nil
        lock.unlock()
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 206:
            handle = try? FileHandle(forWritingTo: partURL)
            _ = try? handle?.seekToEnd()
        case 200:
            // Server ignored the Range header: restart the file from zero.
            try? FileManager.default.removeItem(at: partURL)
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            handle = try? FileHandle(forWritingTo: partURL)
            lock.lock(); received = 0; lock.unlock()
        case 416:
            completionHandler(.cancel)
            complete(nil)  // already complete; finish() validates the size
            return
        default:
            completionHandler(.cancel)
            let retryable = status == 429 || status >= 500
            complete(Failure(message: HFClient.HFError(status: status).localizedDescription, retryable: retryable))
            return
        }
        if handle == nil {
            completionHandler(.cancel)
            complete(Failure(message: String(localized: "Не удалось открыть файл для записи"), retryable: false))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            complete(Failure(message: String(localized: "Ошибка записи на диск: \(error.localizedDescription)"), retryable: false))
            return
        }
        lock.lock()
        received += Int64(data.count)
        let value = received
        lock.unlock()
        onBytes(value)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError {
            if error.code == .cancelled {
                complete(CancellationError())
            } else {
                complete(Failure(message: error.localizedDescription, retryable: true))
            }
        } else if let error {
            complete(error)
        } else {
            complete(nil)
        }
    }

    // Keep the auth header only for huggingface.co; CDN redirects are pre-signed.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        if request.url?.host?.hasSuffix("huggingface.co") != true {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            redirected.setValue(range, forHTTPHeaderField: "Range")
        }
        completionHandler(redirected)
    }
}
