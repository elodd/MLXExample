import Foundation
import MLXLLM
import MLXLMCommon
import MLXLMTokenizers
import ZIPFoundation

public typealias MLXQtCallback = @convention(c) (
    UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void

private final class SessionBox: @unchecked Sendable {
    let session: ChatSession

    init(_ session: ChatSession) {
        self.session = session
    }

    func respond(to prompt: String) async throws -> String {
        try await session.respond(to: prompt)
    }
}

private final class ModelArchiveDownloader: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let destination: URL
    private let expectedBytes: Int64
    private let progressHandler: @Sendable (Int) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    private init(
        destination: URL,
        expectedBytes: Int64,
        progressHandler: @Sendable @escaping (Int) -> Void
    ) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.progressHandler = progressHandler
    }

    static func download(
        from source: URL,
        to destination: URL,
        expectedBytes: Int64,
        progressHandler: @Sendable @escaping (Int) -> Void
    ) async throws -> URL {
        guard let scheme = source.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            throw MLXBridgeError.invalidArchiveURL
        }
        let delegate = ModelArchiveDownloader(
            destination: destination,
            expectedBytes: expectedBytes,
            progressHandler: progressHandler
        )
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            let session = URLSession(
                configuration: configuration, delegate: delegate, delegateQueue: nil
            )
            delegate.session = session
            var request = URLRequest(
                url: source,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 120
            )
            request.setValue(nil, forHTTPHeaderField: "Range")
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let totalBytes = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite : expectedBytes
        guard totalBytes > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytes)
        progressHandler(min(90, Int((fraction * 90).rounded())))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode)
            else {
                let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
                throw MLXBridgeError.downloadRejected(status)
            }
            let handle = try FileHandle(forReadingFrom: location)
            let signature = try handle.read(upToCount: 4) ?? Data()
            guard Self.isZIPSignature(signature) else {
                try handle.close()
                throw MLXBridgeError.invalidDownload
            }
            let archiveBytes = try handle.seekToEnd()
            let tailSize = min(archiveBytes, 65_557)
            try handle.seek(toOffset: archiveBytes - tailSize)
            let tail = try handle.readToEnd() ?? Data()
            try handle.close()
            guard Self.containsEndOfCentralDirectory(tail) else {
                throw MLXBridgeError.incompleteArchive(archiveBytes)
            }
            let files = FileManager.default
            if files.fileExists(atPath: destination.path) {
                try files.removeItem(at: destination)
            }
            try files.moveItem(at: location, to: destination)
            progressHandler(90)
            continuation?.resume(returning: destination)
            continuation = nil
            session.finishTasksAndInvalidate()
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
            session.invalidateAndCancel()
        }
    }

    private static func isZIPSignature(_ data: Data) -> Bool {
        let signatures: [[UInt8]] = [
            [0x50, 0x4b, 0x03, 0x04],
            [0x50, 0x4b, 0x05, 0x06],
            [0x50, 0x4b, 0x07, 0x08],
        ]
        return signatures.contains(Array(data.prefix(4)))
    }

    private static func containsEndOfCentralDirectory(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        let bytes = [UInt8](data)
        guard bytes.count >= signature.count else { return false }
        for offset in 0...(bytes.count - signature.count)
        where Array(bytes[offset..<(offset + signature.count)]) == signature {
            return true
        }
        return false
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, let continuation else { return }
        self.continuation = nil
        continuation.resume(throwing: error)
    }
}

public actor ModelManager {
    // The actor serializes all access; SessionBox bridges ChatSession's
    // documented single-task contract to Swift 6's Sendable type system.
    private var session: SessionBox?
    private var preparedContainer: ModelContainer?
    private var modelDirectory: URL?
    private var progressHandler: (@Sendable (Int) -> Void)?
    private let archiveURL: URL?

    private static let defaultArchiveURL = URL(
        string: "https://drive.usercontent.google.com/download?id=1JH5g4_ZbrcgECzIFlq1QEKTdoH7-NtSo&export=download&confirm=t"
    )
    private static let modelName = "Qwen3-4B-4bit-mlx"
    private static let expectedArchiveBytes: Int64 = 2_051_232_582

    public init(archiveURL: URL? = nil) {
        self.archiveURL = archiveURL ?? Self.defaultArchiveURL
    }

    public func setProgressHandler(
        _ handler: (@Sendable (Int) -> Void)?
    ) {
        progressHandler = handler
    }

    public func resetDownload() throws {
        session = nil
        preparedContainer = nil
        modelDirectory = nil

        let files = FileManager.default
        let support = try files.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let models = support.appending(path: "Models", directoryHint: .isDirectory)
        if files.fileExists(atPath: models.path) {
            try files.removeItem(at: models)
        }
        progressHandler?(0)
    }

    public func ensureDownloaded() async throws {
        guard modelDirectory == nil else { return }
        guard let archiveURL else { throw MLXBridgeError.invalidArchiveURL }
        let files = FileManager.default
        let support = try files.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let models = support.appending(path: "Models", directoryHint: .isDirectory)
        let destination = models.appending(path: Self.modelName, directoryHint: .isDirectory)
        let config = destination.appending(path: "config.json")
        if files.fileExists(atPath: config.path) {
            modelDirectory = destination
            progressHandler?(100)
            return
        }

        try files.createDirectory(at: models, withIntermediateDirectories: true)
        let archive = models.appending(path: "\(Self.modelName).zip")
        let staging = models.appending(path: "\(Self.modelName)-extracting", directoryHint: .isDirectory)
        if files.fileExists(atPath: archive.path) { try files.removeItem(at: archive) }
        if files.fileExists(atPath: staging.path) { try files.removeItem(at: staging) }
        try files.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            _ = try await ModelArchiveDownloader.download(
                from: archiveURL, to: archive,
                expectedBytes: Self.expectedArchiveBytes,
                progressHandler: progressHandler ?? { _ in }
            )
            progressHandler?(92)
            do {
                try files.unzipItem(at: archive, to: staging)
            } catch {
                let bytes = (try? archive.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize).map(Int64.init) ?? 0
                throw MLXBridgeError.corruptArchive(bytes)
            }
            progressHandler?(98)
        } catch {
            try? files.removeItem(at: archive)
            try? files.removeItem(at: staging)
            throw error
        }

        guard let extracted = findModelDirectory(in: staging) else {
            throw MLXBridgeError.invalidArchive
        }
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        if extracted == staging {
            try files.moveItem(at: staging, to: destination)
        } else {
            try files.moveItem(at: extracted, to: destination)
            try? files.removeItem(at: staging)
        }
        try? files.removeItem(at: archive)
        modelDirectory = destination
        progressHandler?(100)
    }

    public func load() async throws {
        try await ensureDownloaded()
        guard let modelDirectory else { throw MLXBridgeError.modelNotLoaded }
        preparedContainer = try await loadModelContainer(
            from: modelDirectory, using: TokenizersLoader()
        )
        guard let preparedContainer else { throw MLXBridgeError.modelNotLoaded }
        session = makeSession(preparedContainer)
    }

    public func unload() {
        session = nil
        preparedContainer = nil
        modelDirectory = nil
    }

    func loadModel(at path: String) async throws -> String {
        unload()

        let directory = URL(filePath: path, directoryHint: .isDirectory)
        let requiredFiles = ["config.json", "tokenizer.json"]
        for file in requiredFiles where !FileManager.default.fileExists(
            atPath: directory.appending(path: file).path
        ) {
            throw MLXBridgeError.missingFile(file)
        }

        let container = try await loadModelContainer(
            from: directory,
            using: TokenizersLoader()
        )
        var parameters = GenerateParameters()
        parameters.maxTokens = 512
        parameters.maxKVSize = 2048
        parameters.temperature = 0.7
        session = SessionBox(ChatSession(container, generateParameters: parameters))
        return directory.lastPathComponent
    }

    func downloadAndLoadModel(
        progressHandler: @Sendable @escaping (Int) -> Void
    ) async throws -> String {
        unload()
        self.progressHandler = progressHandler
        try await ensureDownloaded()
        try await load()
        return Self.modelName
    }

    private func findModelDirectory(in root: URL) -> URL? {
        let files = FileManager.default
        if files.fileExists(atPath: root.appending(path: "config.json").path) { return root }
        guard let enumerator = files.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return nil }
        for case let url as URL in enumerator
        where files.fileExists(atPath: url.appending(path: "config.json").path) {
            return url
        }
        return nil
    }

    private func makeSession(_ container: ModelContainer) -> SessionBox {
        var parameters = GenerateParameters()
        parameters.maxTokens = 512
        parameters.maxKVSize = 2048
        parameters.temperature = 0.7
        return SessionBox(ChatSession(container, generateParameters: parameters))
    }

    public func generate(prompt: String) async throws -> String {
        guard let session else { throw MLXBridgeError.modelNotLoaded }
        return try await session.respond(to: prompt)
    }

    func cancel() {
        // ChatSession does not currently expose cooperative cancellation.
    }
}

private enum MLXBridgeError: LocalizedError {
    case missingFile(String)
    case modelNotLoaded
    case invalidRepository
    case invalidArchive
    case invalidArchiveURL
    case downloadRejected(Int)
    case invalidDownload
    case incompleteArchive(UInt64)
    case corruptArchive(Int64)

    var errorDescription: String? {
        switch self {
        case .missingFile(let file):
            "The selected MLX model directory is missing \(file)."
        case .modelNotLoaded:
            "Select and load an MLX model directory first."
        case .invalidRepository:
            "Enter a Hugging Face MLX repository ID."
        case .invalidArchive:
            "The downloaded Google Drive archive does not contain an MLX model."
        case .invalidArchiveURL:
            "Configure a valid HTTP or HTTPS model archive URL before downloading."
        case .downloadRejected(let status):
            status > 0
                ? "The model server rejected the download (HTTP \(status))."
                : "The model server returned an invalid response."
        case .invalidDownload:
            "The model server did not return a ZIP archive. Check that the download URL points directly to the ZIP file."
        case .incompleteArchive(let bytes):
            "The model ZIP is incomplete (downloaded \(Self.byteCount(bytes)) without a ZIP directory). Check the hosted file and try again on a stable connection."
        case .corruptArchive(let bytes):
            "The downloaded model ZIP is corrupt (\(Self.byteCount(UInt64(max(0, bytes))))). Recreate the ZIP or verify that the server returns the complete file."
        }
    }

    private static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes), countStyle: .file
        )
    }
}

@_cdecl("mlxqt_download_model")
public func mlxqtDownloadModel(
    _ pointer: UnsafeMutableRawPointer?,
    _ progress: MLXQtCallback?,
    _ success: MLXQtCallback?,
    _ failure: MLXQtCallback?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let pointer else {
        callback("Invalid MLX bridge.", function: failure, context: context)
        return
    }
    let handle = Unmanaged<MLXBridgeHandle>.fromOpaque(pointer).takeUnretainedValue()
    let callbacks = CallbackBox(
        progress: progress, success: success, failure: failure, context: context
    )
    Task {
        do {
            let name = try await handle.runner.downloadAndLoadModel(
                progressHandler: { percent in
                    callback(
                        String(percent), function: callbacks.progress,
                        context: callbacks.context
                    )
                }
            )
            callback(name, function: callbacks.success, context: callbacks.context)
        } catch {
            callback(
                error.localizedDescription,
                function: callbacks.failure,
                context: callbacks.context
            )
        }
    }
}

private final class MLXBridgeHandle: @unchecked Sendable {
    let runner = ModelManager()
}

private final class CallbackBox: @unchecked Sendable {
    let progress: MLXQtCallback?
    let success: MLXQtCallback?
    let failure: MLXQtCallback?
    let context: UnsafeMutableRawPointer?

    init(
        progress: MLXQtCallback? = nil,
        success: MLXQtCallback?, failure: MLXQtCallback?,
        context: UnsafeMutableRawPointer?
    ) {
        self.progress = progress
        self.success = success
        self.failure = failure
        self.context = context
    }
}

private func callback(
    _ value: String,
    function: MLXQtCallback?,
    context: UnsafeMutableRawPointer?
) {
    guard let function else { return }
    value.withCString { function($0, context) }
}

@_cdecl("mlxqt_create")
public func mlxqtCreate() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(MLXBridgeHandle()).toOpaque()
}

@_cdecl("mlxqt_destroy")
public func mlxqtDestroy(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<MLXBridgeHandle>.fromOpaque(pointer).release()
}

@_cdecl("mlxqt_load_model")
public func mlxqtLoadModel(
    _ pointer: UnsafeMutableRawPointer?,
    _ path: UnsafePointer<CChar>?,
    _ success: MLXQtCallback?,
    _ failure: MLXQtCallback?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let pointer, let path else {
        callback("Invalid MLX model path.", function: failure, context: context)
        return
    }
    let handle = Unmanaged<MLXBridgeHandle>.fromOpaque(pointer).takeUnretainedValue()
    let modelPath = String(cString: path)
    let callbacks = CallbackBox(success: success, failure: failure, context: context)
    Task {
        do {
            let name = try await handle.runner.loadModel(at: modelPath)
            callback(name, function: callbacks.success, context: callbacks.context)
        } catch {
            callback(
                error.localizedDescription,
                function: callbacks.failure,
                context: callbacks.context
            )
        }
    }
}

@_cdecl("mlxqt_generate")
public func mlxqtGenerate(
    _ pointer: UnsafeMutableRawPointer?,
    _ prompt: UnsafePointer<CChar>?,
    _ success: MLXQtCallback?,
    _ failure: MLXQtCallback?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let pointer, let prompt else {
        callback("Invalid prompt.", function: failure, context: context)
        return
    }
    let handle = Unmanaged<MLXBridgeHandle>.fromOpaque(pointer).takeUnretainedValue()
    let text = String(cString: prompt)
    let callbacks = CallbackBox(success: success, failure: failure, context: context)
    Task {
        do {
            let response = try await handle.runner.generate(prompt: text)
            callback(response, function: callbacks.success, context: callbacks.context)
        } catch {
            callback(
                error.localizedDescription,
                function: callbacks.failure,
                context: callbacks.context
            )
        }
    }
}

@_cdecl("mlxqt_cancel")
public func mlxqtCancel(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    let handle = Unmanaged<MLXBridgeHandle>.fromOpaque(pointer).takeUnretainedValue()
    Task { await handle.runner.cancel() }
}
