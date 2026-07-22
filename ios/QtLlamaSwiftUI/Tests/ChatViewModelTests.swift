import XCTest
@testable import QtLlama

@MainActor
final class ChatViewModelTests: XCTestCase {
    func testInitialStateAndAvailability() {
        let viewModel = ChatViewModel(modelManager: ModelManagerStub())

        XCTAssertEqual(viewModel.messages, [])
        XCTAssertEqual(viewModel.modelName, "No model selected")
        XCTAssertEqual(viewModel.status, "Ready")
        XCTAssertTrue(viewModel.canDownload)
        XCTAssertFalse(viewModel.canSend)
    }

    func testCanSendRequiresReadyModelAndNonWhitespaceDraft() {
        let viewModel = ChatViewModel(modelManager: ModelManagerStub())
        viewModel.isModelReady = true

        viewModel.draft = " \n\t "
        XCTAssertFalse(viewModel.canSend)

        viewModel.draft = "Hello"
        XCTAssertTrue(viewModel.canSend)

        viewModel.isGenerating = true
        XCTAssertFalse(viewModel.canSend)
    }

    func testDownloadSuccessUpdatesProgressAndReadyState() async {
        let stub = ModelManagerStub(progressValues: [15, 72])
        let viewModel = ChatViewModel(modelManager: stub)

        viewModel.downloadModel()

        await waitUntil { viewModel.isModelReady && !viewModel.isDownloading }
        XCTAssertEqual(viewModel.progress, 100)
        XCTAssertEqual(viewModel.modelName, "Qwen3-4B-4bit-mlx")
        XCTAssertEqual(viewModel.status, "Model ready")
        let calls = await stub.calls()
        XCTAssertEqual(calls, [.ensureDownloaded, .load])
    }

    func testDownloadFailureShowsErrorAndAllowsRetry() async {
        let stub = ModelManagerStub(downloadError: TestError.download)
        let viewModel = ChatViewModel(modelManager: stub)

        viewModel.downloadModel()

        await waitUntil { !viewModel.isDownloading && !viewModel.messages.isEmpty }
        XCTAssertEqual(viewModel.messages.last?.author, .error)
        XCTAssertEqual(viewModel.messages.last?.text, TestError.download.localizedDescription)
        XCTAssertEqual(viewModel.modelName, "Download failed")
        XCTAssertEqual(viewModel.status, "Download failed")
        XCTAssertTrue(viewModel.canDownload)
        XCTAssertFalse(viewModel.isModelReady)
    }

    func testSendTrimsPromptAndAppendsResponse() async {
        let stub = ModelManagerStub(response: "Hi there")
        let viewModel = ChatViewModel(modelManager: stub)
        viewModel.isModelReady = true
        viewModel.draft = "  Hello model \n"

        viewModel.send()

        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.first?.author, .user)
        XCTAssertEqual(viewModel.messages.first?.text, "Hello model")
        XCTAssertEqual(viewModel.draft, "")
        XCTAssertTrue(viewModel.isGenerating)
        await waitUntil { !viewModel.isGenerating }
        XCTAssertEqual(viewModel.messages.map(\.author), [.user, .model])
        XCTAssertEqual(viewModel.messages.last?.text, "Hi there")
        XCTAssertEqual(viewModel.status, "Ready")
        let prompts = await stub.prompts()
        XCTAssertEqual(prompts, ["Hello model"])
    }

    func testSendFailureAppendsError() async {
        let stub = ModelManagerStub(generateError: TestError.generation)
        let viewModel = ChatViewModel(modelManager: stub)
        viewModel.isModelReady = true
        viewModel.draft = "Hello"

        viewModel.send()

        await waitUntil { !viewModel.isGenerating }
        XCTAssertEqual(viewModel.messages.map(\.author), [.user, .error])
        XCTAssertEqual(viewModel.messages.last?.text, TestError.generation.localizedDescription)
        XCTAssertEqual(viewModel.status, "Model error")
    }

    func testSendIgnoresInvalidState() async {
        let stub = ModelManagerStub()
        let viewModel = ChatViewModel(modelManager: stub)
        viewModel.draft = "Hello"

        viewModel.send()

        await Task.yield()
        XCTAssertEqual(viewModel.messages, [])
        XCTAssertEqual(viewModel.draft, "Hello")
        let prompts = await stub.prompts()
        XCTAssertEqual(prompts, [])
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() && clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "Timed out waiting for asynchronous state change")
    }
}

private enum TestError: LocalizedError {
    case download
    case generation

    var errorDescription: String? {
        switch self {
        case .download: "Test download failed"
        case .generation: "Test generation failed"
        }
    }
}

private actor ModelManagerStub: ModelManaging {
    enum Call: Equatable {
        case ensureDownloaded
        case load
    }

    private let progressValues: [Int]
    private let downloadError: Error?
    private let generateError: Error?
    private let response: String
    private var progressHandler: (@Sendable (Int) -> Void)?
    private var recordedCalls: [Call] = []
    private var recordedPrompts: [String] = []

    init(
        progressValues: [Int] = [],
        downloadError: Error? = nil,
        generateError: Error? = nil,
        response: String = "Response"
    ) {
        self.progressValues = progressValues
        self.downloadError = downloadError
        self.generateError = generateError
        self.response = response
    }

    func setProgressHandler(_ handler: (@Sendable (Int) -> Void)?) {
        progressHandler = handler
    }

    func ensureDownloaded() throws {
        recordedCalls.append(.ensureDownloaded)
        progressValues.forEach { progressHandler?($0) }
        if let downloadError { throw downloadError }
    }

    func load() throws {
        recordedCalls.append(.load)
    }

    func generate(prompt: String) throws -> String {
        recordedPrompts.append(prompt)
        if let generateError { throw generateError }
        return response
    }

    func calls() -> [Call] { recordedCalls }
    func prompts() -> [String] { recordedPrompts }
}
