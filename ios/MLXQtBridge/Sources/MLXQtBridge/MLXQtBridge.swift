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
    private let progressHandler: @Sendable (Int) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    private init(destination: URL, progressHandler: @Sendable @escaping (Int) -> Void) {
        self.destination = destination
        self.progressHandler = progressHandler
    }

    static func download(
        from source: URL,
        to destination: URL,
        progressHandler: @Sendable @escaping (Int) -> Void
    ) async throws -> URL {
        let delegate = ModelArchiveDownloader(
            destination: destination, progressHandler: progressHandler
        )
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            let session = URLSession(
                configuration: .default, delegate: delegate, delegateQueue: nil
            )
            delegate.session = session
            session.downloadTask(with: source).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progressHandler(min(90, Int((fraction * 90).rounded())))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
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

    private static let archiveURL = URL(string:
        "https://drive.usercontent.google.com/download?id=1fgLH3juOqMJLx2JR3-S6ST7-sxWsYF7I&export=download&confirm=t"
    )!
    private static let modelName = "Qwen3-4B-4bit-mlx"

    public init() {}

    public func setProgressHandler(
        _ handler: (@Sendable (Int) -> Void)?
    ) {
        progressHandler = handler
    }

    public func ensureDownloaded() async throws {
        guard modelDirectory == nil else { return }
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
        if files.fileExists(atPath: staging.path) { try files.removeItem(at: staging) }
        try files.createDirectory(at: staging, withIntermediateDirectories: true)

        _ = try await ModelArchiveDownloader.download(
            from: Self.archiveURL, to: archive,
            progressHandler: progressHandler ?? { _ in }
        )
        progressHandler?(92)
        try files.unzipItem(at: archive, to: staging)
        progressHandler?(98)

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
        }
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
