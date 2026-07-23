import Foundation
import Testing

@testable import QtLlama

@MainActor
struct ChatViewModelTests {
    @Test func initialStateAndAvailability() {
        let viewModel = ChatViewModel(modelManager: ModelManagerStub())

        #expect(viewModel.messages == [])
        #expect(viewModel.modelName == "No model selected")
        #expect(viewModel.modelStatus == "No model selected")
        #expect(viewModel.canDownload)
        #expect(!viewModel.canSend)
    }

    @Test func canSendRequiresReadyModelAndNonWhitespaceDraft() {
        let viewModel = ChatViewModel(modelManager: ModelManagerStub())
        viewModel.isModelReady = true

        viewModel.draft = " \n\t "
        #expect(!viewModel.canSend)

        viewModel.draft = "Hello"
        #expect(viewModel.canSend)

        viewModel.isGenerating = true
        #expect(!viewModel.canSend)
    }

    @Test func downloadSuccessUpdatesProgressAndReadyState() async {
        let stub = ModelManagerStub(progressValues: [15, 72])
        let viewModel = ChatViewModel(modelManager: stub)

        viewModel.downloadModel()

        #expect(await waitUntil { viewModel.isModelReady && !viewModel.isDownloading })
        #expect(viewModel.downloadProgress == 100)
        #expect(viewModel.modelName == "Qwen3-4B-4bit-mlx")
        #expect(viewModel.modelStatus == "Model ready")
        let calls = await stub.calls()
        #expect(calls == [.ensureDownloaded, .load])
    }

    @Test func downloadFailureShowsErrorAndAllowsRetry() async {
        let stub = ModelManagerStub(downloadError: TestError.download)
        let viewModel = ChatViewModel(modelManager: stub)

        viewModel.downloadModel()

        #expect(await waitUntil { !viewModel.isDownloading && !viewModel.messages.isEmpty })
        #expect(viewModel.messages.last?.author == .error)
        #expect(viewModel.messages.last?.text == TestError.download.localizedDescription)
        #expect(viewModel.modelName == "Download failed")
        #expect(viewModel.modelStatus == "Download failed")
        #expect(viewModel.canDownload)
        #expect(!viewModel.isModelReady)
    }

    @Test func sendTrimsPromptAndAppendsResponse() async {
        let stub = ModelManagerStub(response: "Hi there")
        let viewModel = ChatViewModel(modelManager: stub)
        viewModel.isModelReady = true
        viewModel.draft = "  Hello model \n"

        viewModel.send()

        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.author == .user)
        #expect(viewModel.messages.first?.text == "Hello model")
        #expect(viewModel.draft == "")
        #expect(viewModel.isGenerating)
        #expect(viewModel.generationProgress.isActive)
        #expect(viewModel.generationProgress.progress == 0.05)
        #expect(viewModel.generationProgress.status == "Preparing model")
        #expect(await waitUntil { !viewModel.isGenerating })
        #expect(!viewModel.generationProgress.isActive)
        #expect(viewModel.generationProgress.progress == 1)
        #expect(viewModel.generationProgress.status == "Complete")
        #expect(viewModel.messages.map(\.author) == [.user, .model])
        #expect(viewModel.messages.last?.text == "Hi there")
        #expect(viewModel.modelStatus == "Ready")
        let prompts = await stub.prompts()
        #expect(prompts == ["Hello model"])
    }

    @Test func sendFailureAppendsError() async {
        let stub = ModelManagerStub(generateError: TestError.generation)
        let viewModel = ChatViewModel(modelManager: stub)
        viewModel.isModelReady = true
        viewModel.draft = "Hello"

        viewModel.send()

        #expect(await waitUntil { !viewModel.isGenerating })
        #expect(viewModel.messages.map(\.author) == [.user, .error])
        #expect(viewModel.messages.last?.text == TestError.generation.localizedDescription)
        #expect(viewModel.modelStatus == "Model error")
        #expect(!viewModel.generationProgress.isActive)
        #expect(viewModel.generationProgress.status == "Stopped")
    }

    @Test func sendIgnoresInvalidState() async {
        let stub = ModelManagerStub()
        let viewModel = ChatViewModel(modelManager: stub)
        viewModel.draft = "Hello"

        viewModel.send()

        await Task.yield()
        #expect(viewModel.messages == [])
        #expect(viewModel.draft == "Hello")
        let prompts = await stub.prompts()
        #expect(prompts == [])
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() && clock.now < deadline {
            await Task.yield()
        }
        return condition()
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
