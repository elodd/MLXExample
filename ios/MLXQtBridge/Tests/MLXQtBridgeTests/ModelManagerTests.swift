import Foundation
import Testing

@testable import MLXQtBridge

@MainActor
struct ModelManagerTests {
    @Test func generateBeforeLoadingModelThrows() async {
        let manager = ModelManager()

        do {
            _ = try await manager.generate(prompt: "Hello")
            Issue.record("Expected generation without a loaded model to fail")
        } catch {
            #expect(
                error.localizedDescription
                    == "Select and load an MLX model directory first."
            )
        }
    }

    @Test func loadModelReportsMissingConfigFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await ModelManager().loadModel(at: directory.path)
            Issue.record("Expected a directory without config.json to be rejected")
        } catch {
            #expect(
                error.localizedDescription
                    == "The selected MLX model directory is missing config.json."
            )
        }
    }

    @Test func loadModelReportsMissingTokenizerFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appending(path: "config.json"))

        do {
            _ = try await ModelManager().loadModel(at: directory.path)
            Issue.record("Expected a directory without tokenizer.json to be rejected")
        } catch {
            #expect(
                error.localizedDescription
                    == "The selected MLX model directory is missing tokenizer.json."
            )
        }
    }

    @Test func unloadLeavesManagerWithoutActiveModel() async {
        let manager = ModelManager()
        await manager.unload()

        do {
            _ = try await manager.generate(prompt: "Hello")
            Issue.record("Expected generation after unload to fail")
        } catch {
            #expect(
                error.localizedDescription
                    == "Select and load an MLX model directory first."
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
