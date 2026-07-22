import Foundation
import MLXQtBridge

protocol ModelManaging: Sendable {
    func setProgressHandler(_ handler: (@Sendable (Int) -> Void)?) async
    func resetDownload() async throws
    func ensureDownloaded() async throws
    func load() async throws
    func generate(prompt: String) async throws -> String
}

extension ModelManaging {
    func resetDownload() async throws {}
}

extension ModelManager: ModelManaging {}

struct ChatMessage: Identifiable, Equatable {
    enum Author {
        case user
        case model
        case error
    }

    let id = UUID()
    let author: Author
    let text: String
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var downloadProgress = 0
    @Published var modelName = "No model selected"
    @Published var modelStatus = "Ready"
    @Published var isDownloading = false
    @Published var downloadFailed = false
    @Published var isModelReady = false
    @Published var isGenerating = false

    private let modelManager: any ModelManaging

    init(modelManager: any ModelManaging = ModelManager()) {
        self.modelManager = modelManager
    }

    var canDownload: Bool { !isDownloading && !isModelReady }
    var canSend: Bool {
        isModelReady && !isGenerating && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func downloadModel() {
        guard canDownload else { return }
        downloadProgress = 0
        isDownloading = true
        modelName = "Downloading Qwen3 4B…"
        modelStatus = "Downloading model… Keep the app open"

        Task {
            await modelManager.setProgressHandler { [weak self] value in
                Task { @MainActor in self?.downloadProgress = value }
            }
            do {
                if downloadFailed {
                    messages.removeAll { $0.author == .error }
                    try await modelManager.resetDownload()
                }
                try await modelManager.ensureDownloaded()
                modelStatus = "Loading model…"
                try await modelManager.load()
                downloadProgress = 100
                modelName = "Qwen3-4B-4bit-mlx"
                modelStatus = "Model ready"
                downloadFailed = false
                isModelReady = true
            } catch {
                messages.append(.init(author: .error, text: error.localizedDescription))
                modelName = "Download failed"
                modelStatus = "Download failed"
                downloadFailed = true
            }
            isDownloading = false
        }
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, isModelReady, !isGenerating else { return }
        messages.append(.init(author: .user, text: prompt))
        draft = ""
        isGenerating = true
        modelStatus = "Thinking…"

        Task {
            do {
                let response = try await modelManager.generate(prompt: prompt)
                messages.append(.init(author: .model, text: response))
                modelStatus = "Ready"
            } catch {
                messages.append(.init(author: .error, text: error.localizedDescription))
                modelStatus = "Model error"
            }
            isGenerating = false
        }
    }
}
