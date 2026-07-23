import Foundation

@MainActor
final class GenerationProgress: ObservableObject {
    @Published private(set) var progress = 0.05
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var status = "Preparing model"
    @Published private(set) var isActive = false

    private var progressTask: Task<Void, Never>?

    func start() {
        progressTask?.cancel()
        progress = 0.05
        elapsedSeconds = 0
        status = "Preparing model"
        isActive = true

        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.advance()
            }
        }
    }

    func finish() {
        progressTask?.cancel()
        progressTask = nil
        progress = 1
        status = "Complete"
        isActive = false
    }

    func fail() {
        progressTask?.cancel()
        progressTask = nil
        status = "Stopped"
        isActive = false
    }

    private func advance() {
        elapsedSeconds += 1

        switch elapsedSeconds {
        case 0...2:
            status = "Preparing model"
        case 3...7:
            status = "Reading your prompt"
        case 8...15:
            status = "Generating response"
        default:
            status = "Still working"
        }

        // Approach 95% more slowly over time; only the real response completes it.
        let remaining = 0.95 - progress
        progress = min(0.95, progress + max(0.004, remaining * 0.12))
    }
}
