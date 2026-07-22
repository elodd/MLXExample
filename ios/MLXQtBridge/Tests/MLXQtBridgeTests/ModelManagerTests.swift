import Foundation
import XCTest

@testable import MLXQtBridge

final class ModelManagerTests: XCTestCase {
    func testGenerateBeforeLoadingModelThrows() async {
        let manager = ModelManager()

        do {
            _ = try await manager.generate(prompt: "Hello")
            XCTFail("Expected generation without a loaded model to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Select and load an MLX model directory first."
            )
        }
    }

    func testLoadModelReportsMissingConfigFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await ModelManager().loadModel(at: directory.path)
            XCTFail("Expected a directory without config.json to be rejected")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The selected MLX model directory is missing config.json."
            )
        }
    }

    func testLoadModelReportsMissingTokenizerFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("{}".utf8).write(to: directory.appending(path: "config.json"))

        do {
            _ = try await ModelManager().loadModel(at: directory.path)
            XCTFail("Expected a directory without tokenizer.json to be rejected")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "The selected MLX model directory is missing tokenizer.json."
            )
        }
    }

    func testUnloadLeavesManagerWithoutActiveModel() async {
        let manager = ModelManager()
        await manager.unload()

        do {
            _ = try await manager.generate(prompt: "Hello")
            XCTFail("Expected generation after unload to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Select and load an MLX model directory first."
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
