import Foundation
import MLXQtBridge

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
    @Published var progress = 0
    @Published var modelName = "No model selected"
    @Published var status = "Ready"
    @Published var isDownloading = false
    @Published var isModelReady = false
    @Published var isGenerating = false

    private let modelManager = ModelManager()

    var canDownload: Bool { !isDownloading && !isModelReady }
    var canSend: Bool {
        isModelReady && !isGenerating && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func downloadModel() {
        guard canDownload else { return }
        isDownloading = true
        modelName = "Downloading Qwen3 4B…"
        status = "Downloading model… Keep the app open"

        Task {
            await modelManager.setProgressHandler { [weak self] value in
                Task { @MainActor in self?.progress = value }
            }
            do {
                try await modelManager.ensureDownloaded()
                status = "Loading model…"
                try await modelManager.load()
                progress = 100
                modelName = "Qwen3-4B-4bit-mlx"
                status = "Model ready"
                isModelReady = true
            } catch {
                messages.append(.init(author: .error, text: error.localizedDescription))
                modelName = "Download failed"
                status = "Download failed"
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
        status = "Thinking…"

        Task {
            do {
                let response = try await modelManager.generate(prompt: prompt)
                messages.append(.init(author: .model, text: response))
                status = "Ready"
            } catch {
                messages.append(.init(author: .error, text: error.localizedDescription))
                status = "Model error"
            }
            isGenerating = false
        }
    }
}
