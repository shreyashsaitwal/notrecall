import CryptoKit
import Foundation

enum RecallDownloadError: LocalizedError {
    case invalidFilename(String)
    case httpStatus(Int)
    case sha256Mismatch(expected: String, actual: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidFilename(let name):
            return "Refusing unsafe release filename: \(name)"
        case .httpStatus(let code):
            return "Download failed with HTTP \(code)."
        case .sha256Mismatch(let expected, let actual):
            return "Downloaded DMG failed SHA-256 verification (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)."
        case .cancelled:
            return "Download cancelled."
        }
    }
}

final class RecallDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double, Int64, Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private let destinationURL: URL
    private let lock = NSLock()
    private var finished = false

    private init(destinationURL: URL, onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void) {
        self.destinationURL = destinationURL
        self.onProgress = onProgress
        super.init()
    }

    static func cacheDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base.appending(path: "notrecall/downloads")
    }

    static func download(
        release: RecallReleaseInfo,
        onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void
    ) async throws -> URL {
        let safeName = URL(filePath: release.dmgName).lastPathComponent
        guard !safeName.isEmpty, safeName != ".", safeName != "..",
              !release.dmgName.contains("/"), !release.dmgName.contains("\\") else {
            throw RecallDownloadError.invalidFilename(release.dmgName)
        }

        let fm = FileManager.default
        let cacheDir = cacheDirectory()
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let dest = cacheDir.appending(path: safeName)

        // Reuse a verified cached DMG if already present.
        if fm.fileExists(atPath: dest.path), let expected = release.dmgSHA256 {
            if let existingHash = try? sha256File(at: dest), existingHash == expected.lowercased() {
                let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? (release.dmgSizeBytes ?? 0)
                onProgress(1.0, size, size)
                return dest
            }
            try? fm.removeItem(at: dest)
        }

        let staging = cacheDir.appending(path: "\(safeName).part-\(UUID().uuidString)")
        let downloader = RecallDownloader(destinationURL: staging, onProgress: onProgress)
        do {
            let downloadedURL = try await downloader.start(url: release.dmgURL)
            if let expected = release.dmgSHA256?.lowercased() {
                let actual = try sha256File(at: downloadedURL)
                if actual != expected {
                    try? fm.removeItem(at: downloadedURL)
                    throw RecallDownloadError.sha256Mismatch(expected: expected, actual: actual)
                }
            }
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: downloadedURL)
            } else {
                try fm.moveItem(at: downloadedURL, to: dest)
            }
            return dest
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private func start(url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                self.continuation = cont
                let config = URLSessionConfiguration.ephemeral
                config.httpAdditionalHeaders = ["User-Agent": "NotRecall"]
                let sess = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = sess
                let task = sess.downloadTask(with: url)
                self.downloadTask = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        lock.lock()
        let task = downloadTask
        lock.unlock()
        task?.cancel()
    }

    private func complete(with result: Result<URL, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        let sess = session
        session = nil
        downloadTask = nil
        lock.unlock()

        sess?.invalidateAndCancel()
        cont?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction: Double
        if totalBytesExpectedToWrite > 0 {
            fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        } else {
            fraction = 0
        }
        onProgress(fraction, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            complete(with: .failure(RecallDownloadError.httpStatus(http.statusCode)))
            return
        }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: location, to: destinationURL)
            complete(with: .success(destinationURL))
        } catch {
            complete(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            complete(with: .failure(RecallDownloadError.cancelled))
        } else {
            complete(with: .failure(error))
        }
    }

    static func sha256File(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
